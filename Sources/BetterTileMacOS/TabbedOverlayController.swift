import AppKit
import BetterTileCore

public enum TabbedUIIntent {
    case select(WindowID), activate(UUID), close(WindowID), float(WindowID)
    case move(WindowID, pane: UUID, index: Int?)
    case split(WindowID, pane: UUID, edge: TabbedEdge)
    case preset(TabbedPreset), undo, repair, removePane(UUID)
    case beginResize, resize(UUID, Double), endResize, cancelResize
}

/// AppKit chrome only. It knows pane values and emits intents; it never writes
/// Accessibility attributes or owns layout sessions.
@MainActor
public final class TabbedOverlayController {
    public var onIntent: ((TabbedUIIntent) -> Void)?
    public private(set) var isInteracting = false
    private var state = TabbedLayoutState()
    private var bounds = BTRect(x: 0, y: 0, width: 1, height: 1)
    private var windows: [WindowID: WindowSnapshot] = [:]
    private var applicationIcons: [String: NSImage] = [:]
    private var panes: [UUID: NSPanel] = [:]
    private var handles: [UUID: NSPanel] = [:]
    private var preview: NSPanel?
    private var floatTarget: NSPanel?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private let addGlobalKeyMonitor: (@escaping @MainActor (UInt16) -> Void) -> Any?
    private let addLocalKeyMonitor: (@escaping @MainActor (UInt16) -> Bool) -> Any?
    private let removeMonitor: (Any) -> Void
    private var draggedWindow: WindowID?
    private var dropIntent: TabbedUIIntent?
    private var isResizing = false
    private var cancelled = false
    private var canUndo = false
    private let displayTicks: ResizeDisplayLink
    private var pendingResize: (id: UUID, ratio: Double)?

    public convenience init() {
        self.init(displayTicks: ResizeDisplayLink())
    }

    init(
        displayTicks: ResizeDisplayLink,
        addGlobalKeyMonitor: @escaping (@escaping @MainActor (UInt16) -> Void) -> Any? = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode
                MainActor.assumeIsolated { handler(keyCode) }
            }
        },
        addLocalKeyMonitor: @escaping (@escaping @MainActor (UInt16) -> Bool) -> Any? = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode
                let consumed = MainActor.assumeIsolated { handler(keyCode) }
                return consumed ? nil : event
            }
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.displayTicks = displayTicks
        self.addGlobalKeyMonitor = addGlobalKeyMonitor
        self.addLocalKeyMonitor = addLocalKeyMonitor
        self.removeMonitor = removeMonitor
    }

    public func refresh(state: TabbedLayoutState, bounds: BTRect, windows: [WindowSnapshot], obscuringFrames: [BTRect] = [], canUndo: Bool = false) {
        self.state = state
        self.bounds = bounds
        self.canUndo = canUndo
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let frames = state.frames(in: bounds)
        for id in panes.keys.filter({ frames[$0] == nil }) { panes.removeValue(forKey: id)?.orderOut(nil) }
        for (index, pane) in state.panes.enumerated() {
            guard let frame = frames[pane.id] else { continue }
            let panel = panes[pane.id] ?? makePanel()
            let view = panel.contentView as? TabbedPaneView ?? TabbedPaneView()
            view.owner = self
            view.pane = pane
            view.number = index + 1
            view.active = state.activePaneID == pane.id
            view.titles = pane.tabs.map { id in
                guard let window = self.windows[id] else { return "Unavailable window" }
                return window.title.isEmpty ? (window.bundleIdentifier ?? "Window") : window.title
            }
            view.icons = pane.tabs.map { id in
                guard let bundleID = self.windows[id]?.bundleIdentifier else { return nil }
                if let icon = applicationIcons[bundleID] { return icon }
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                applicationIcons[bundleID] = icon
                return icon
            }
            panel.contentView = view
            let chrome = BTRect(x: frame.minX, y: frame.minY, width: frame.size.width,
                                height: pane.tabs.isEmpty ? frame.size.height : TabbedLayoutState.headerHeight)
            panel.setFrame(appKit(chrome), display: true)
            view.needsDisplay = true
            view.updateAccessibility()
            view.updateToolTips()
            view.setAccessibilityLabel("Pane \(index + 1)\(pane.tabs.isEmpty ? ", empty" : "")")
            if obscuringFrames.contains(where: { $0.intersection(chrome) != nil }) { panel.orderOut(nil) }
            else { panel.orderFrontRegardless() }
            panes[pane.id] = panel
        }
        let dividers = state.dividers(in: bounds)
        let dividerIDs = Set(dividers.map(\.id))
        for id in handles.keys.filter({ !dividerIDs.contains($0) }) { handles.removeValue(forKey: id)?.orderOut(nil) }
        for divider in dividers {
            let panel = handles[divider.id] ?? makePanel()
            let view = panel.contentView as? TabbedDividerView ?? TabbedDividerView()
            view.owner = self
            view.divider = divider
            panel.contentView = view
            panel.setFrame(appKit(divider.frame), display: true)
            view.setAccessibilityLabel("Resize panes")
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.slider)
            view.setAccessibilityEnabled(true)
            view.setAccessibilityValue(divider.ratio * 100)
            view.setAccessibilityMinValue(5)
            view.setAccessibilityMaxValue(95)
            view.setAccessibilityHelp("Adjust the first pane's share of the layout in five percent steps.")
            view.toolTip = "Drag to resize panes"
            view.needsDisplay = true
            panel.invalidateCursorRects(for: view)
            if obscuringFrames.contains(where: { $0.intersection(divider.frame) != nil }) { panel.orderOut(nil) }
            else { panel.orderFrontRegardless() }
            handles[divider.id] = panel
        }
    }

    public func hide() {
        cancelInteraction()
        for panel in Array(panes.values) + Array(handles.values) { panel.orderOut(nil) }
    }

    /// A resize changes geometry only. Keep panel ordering and content views
    /// intact, and let AppKit draw the changes together after this tick.
    public func refreshResize(state: TabbedLayoutState, bounds: BTRect) {
        self.state = state
        self.bounds = bounds
        let frames = state.frames(in: bounds)
        for pane in state.panes {
            guard let frame = frames[pane.id], let panel = panes[pane.id],
                  let view = panel.contentView as? TabbedPaneView else { continue }
            let chrome = BTRect(x: frame.minX, y: frame.minY, width: frame.size.width,
                               height: pane.tabs.isEmpty ? frame.size.height : TabbedLayoutState.headerHeight)
            panel.setFrame(appKit(chrome), display: false)
            view.updateAccessibility()
            view.updateToolTips()
            view.needsDisplay = true
        }
        for divider in state.dividers(in: bounds) {
            guard let panel = handles[divider.id], let view = panel.contentView as? TabbedDividerView else { continue }
            view.divider = divider
            panel.setFrame(appKit(divider.frame), display: false)
            view.setAccessibilityValue(divider.ratio * 100)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        return panel
    }

    private func appKit(_ rect: BTRect) -> NSRect {
        CoordinateConverter.toAppKit(rect, mainScreenFrame: NSScreen.screens.first?.frame ?? .zero)
    }

    fileprivate func screenPoint(_ event: NSEvent) -> BTPoint {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return CoordinateConverter.pointToTopLeft(point, mainScreenFrame: NSScreen.screens.first?.frame ?? .zero)
    }

    fileprivate func send(_ intent: TabbedUIIntent) { onIntent?(intent) }

    func menu(pane: TabbedPane, windowID: WindowID?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ intent: TabbedUIIntent, enabled: Bool = true, selected: Bool = false, in menu: NSMenu) {
            let action = TabbedMenuAction { [weak self] in self?.send(intent) }
            let entry = NSMenuItem(title: title, action: #selector(TabbedMenuAction.invoke), keyEquivalent: "")
            entry.target = action
            entry.representedObject = action
            entry.isEnabled = enabled
            entry.state = selected ? .on : .off
            menu.addItem(entry)
        }
        if let id = windowID {
            item("Select Tab", .select(id), in: menu)
            item("Close Window…", .close(id), in: menu)
            item("Move out of Tabbed", .float(id), in: menu)
            let move = NSMenuItem(title: "Move to Pane", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, other) in state.panes.enumerated() where other.id != pane.id {
                item("Pane \(index + 1)", .move(id, pane: other.id, index: nil), in: submenu)
            }
            move.submenu = submenu
            if !submenu.items.isEmpty { menu.addItem(move) }
            if let index = pane.tabs.firstIndex(of: id) {
                if index > 0 { item("Move Tab Left", .move(id, pane: pane.id, index: index - 1), in: menu) }
                if index + 1 < pane.tabs.count { item("Move Tab Right", .move(id, pane: pane.id, index: index + 1), in: menu) }
            }
            for edge in TabbedEdge.allCases { item("Split \(edge.rawValue.capitalized)", .split(id, pane: pane.id, edge: edge), enabled: state.panes.count < 12, in: menu) }
            menu.addItem(.separator())
        } else if !pane.tabs.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Tabs in This Pane"))
            for id in pane.tabs {
                let window = windows[id]
                let title = window.map { $0.title.isEmpty ? ($0.bundleIdentifier ?? "Window") : $0.title } ?? "Unavailable window"
                item(title, .select(id), selected: pane.selected == id, in: menu)
            }
            menu.addItem(.separator())
        }
        let floating = windows.values.filter { state.floatingWindowIDs.contains($0.id) }.sorted { $0.id < $1.id }
        if !floating.isEmpty {
            let add = NSMenuItem(title: "Add Floating Window Here", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for window in floating {
                item(window.title.isEmpty ? (window.bundleIdentifier ?? "Window") : window.title,
                     .move(window.id, pane: pane.id, index: nil), in: submenu)
            }
            add.submenu = submenu
            menu.addItem(add)
        }
        let layout = NSMenuItem(title: "Change Layout", action: nil, keyEquivalent: "")
        let presets = NSMenu()
        for preset in TabbedPreset.allCases { item(preset.title, .preset(preset), in: presets) }
        layout.submenu = presets
        menu.addItem(layout)
        menu.addItem(.separator())
        item("Undo Layout Change", .undo, enabled: canUndo, in: menu)
        item("Repair Tabbed", .repair, in: menu)
        if pane.tabs.isEmpty && state.panes.count > 1 { item("Remove Empty Pane", .removePane(pane.id), in: menu) }
        return menu
    }

    fileprivate func beginDrag(_ id: WindowID) {
        guard !isInteracting else { return }
        isInteracting = true
        cancelled = false
        draggedWindow = id
        installEscape()
        let panel = makePanel()
        let view = tabbedGlassSurface(cornerRadius: 10, tint: .controlAccentColor)
        if let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Float window") {
            let icon = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            icon.contentTintColor = .labelColor
            icon.frame = NSRect(x: 12, y: 16, width: 16, height: 16)
            view.addSubview(icon)
        }
        let label = NSTextField(labelWithString: "Float window")
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.frame = NSRect(x: 32, y: 13, width: 146, height: 22)
        view.addSubview(label)
        panel.contentView = view
        panel.ignoresMouseEvents = true
        panel.setFrame(appKit(floatFrame), display: true)
        panel.orderFrontRegardless()
        floatTarget = panel
    }

    private var floatFrame: BTRect { BTRect(x: bounds.midX - 95, y: bounds.maxY - 70, width: 190, height: 48) }

    fileprivate func drag(to point: BTPoint) {
        guard let id = draggedWindow, !cancelled else { return }
        dropIntent = nil
        var highlight: BTRect?
        var destinationLabel = ""
        if floatFrame.contains(point) {
            dropIntent = .float(id)
            highlight = floatFrame
        } else {
            let frames = state.frames(in: bounds)
            for (index, pane) in state.panes.enumerated() {
                guard let frame = frames[pane.id], frame.contains(point) else { continue }
                if point.y < frame.minY + TabbedLayoutState.headerHeight {
                    let strip = TabbedStripLayout(width: frame.size.width, count: pane.tabs.count,
                                                 selectedIndex: pane.tabs.firstIndex(where: { $0 == pane.selected }))
                    let insertion = strip.insertion(at: point.x - frame.minX)
                    var index = insertion.index
                    if let old = pane.tabs.firstIndex(of: id), old < index { index -= 1 }
                    dropIntent = .move(id, pane: pane.id, index: index)
                    highlight = BTRect(x: frame.minX + insertion.x - 1, y: frame.minY + 3, width: 2, height: 28)
                } else {
                    let content = TabbedLayoutState.contentFrame(frame)
                    let edge: TabbedEdge?
                    if point.x < content.minX + 28 { edge = .left }
                    else if point.x > content.maxX - 28 { edge = .right }
                    else if point.y < content.minY + 28 { edge = .top }
                    else if point.y > content.maxY - 28 { edge = .bottom }
                    else { edge = nil }
                    if let edge, state.panes.count < 12 {
                        dropIntent = .split(id, pane: pane.id, edge: edge)
                        destinationLabel = "Split \(edge.rawValue.capitalized) · Pane \(index + 1)"
                        highlight = BTRect(x: edge == .right ? content.midX : content.minX,
                                           y: edge == .bottom ? content.midY : content.minY,
                                           width: edge == .left || edge == .right ? content.size.width / 2 : content.size.width,
                                           height: edge == .top || edge == .bottom ? content.size.height / 2 : content.size.height)
                    } else if edge == nil {
                        dropIntent = .move(id, pane: pane.id, index: nil)
                        destinationLabel = "Move to Pane \(index + 1)"
                        highlight = content
                    }
                }
                break
            }
        }
        if let highlight {
            let panel = preview ?? makePanel()
            panel.ignoresMouseEvents = true
            if preview == nil {
                let surface = tabbedGlassSurface(cornerRadius: 8, tint: .controlAccentColor)
                let label = NSTextField(labelWithString: "")
                label.alignment = .center
                label.font = .systemFont(ofSize: 15, weight: .semibold)
                label.textColor = .labelColor
                surface.addSubview(label)
                panel.contentView = surface
            }
            panel.setFrame(appKit(highlight), display: true)
            if let label = panel.contentView?.subviews.first as? NSTextField {
                label.stringValue = destinationLabel
                label.isHidden = destinationLabel.isEmpty || highlight.size.width < 170 || highlight.size.height < 48
                label.frame = NSRect(x: 8, y: max(0, (highlight.size.height - 22) / 2), width: max(0, highlight.size.width - 16), height: 22)
            }
            panel.orderFrontRegardless()
            preview = panel
        } else { preview?.orderOut(nil) }
    }

    fileprivate func endDrag() {
        let intent = cancelled ? nil : dropIntent
        finishInteraction()
        if let intent { send(intent) }
    }

    func beginResize() {
        guard !isInteracting else { return }
        isInteracting = true
        isResizing = true
        cancelled = false
        installEscape()
        displayTicks.start(on: handles.values.first?.contentView, maximumFramesPerSecond: 60) { [weak self] in
            self?.displayTick()
        }
        send(.beginResize)
    }

    func resize(_ divider: TabbedDivider, point: BTPoint) {
        guard isResizing, !cancelled else { return }
        let length = (divider.vertical ? divider.bounds.size.width : divider.bounds.size.height) - TabbedLayoutState.gap
        let offset = divider.vertical ? point.x - divider.bounds.minX : point.y - divider.bounds.minY
        pendingResize = (divider.id, offset / max(1, length))
    }

    func displayTick() {
        guard let pendingResize else { return }
        self.pendingResize = nil
        send(.resize(pendingResize.id, pendingResize.ratio))
    }

    func endResize() {
        guard isResizing else { return }
        let wasCancelled = cancelled
        if !wasCancelled { displayTick() }
        finishInteraction()
        if !wasCancelled { send(.endResize) }
    }

    public func cancelInteraction() {
        let resize = isResizing
        cancelled = true
        pendingResize = nil
        finishInteraction()
        if resize { send(.cancelResize) }
    }

    private func finishInteraction() {
        preview?.orderOut(nil); floatTarget?.orderOut(nil)
        preview = nil; floatTarget = nil
        if let globalKeyMonitor { removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        draggedWindow = nil; dropIntent = nil
        pendingResize = nil
        displayTicks.stop()
        isInteracting = false; isResizing = false
    }

    private func installEscape() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }
        globalKeyMonitor = addGlobalKeyMonitor { [weak self] keyCode in
            guard keyCode == 53 else { return }
            self?.cancelInteraction()
        }
        localKeyMonitor = addLocalKeyMonitor { [weak self] keyCode in
            guard keyCode == 53 else { return false }
            self?.cancelInteraction()
            return true
        }
    }
}

@MainActor
private func configureTabbedGlass(
    _ view: NSVisualEffectView,
    cornerRadius: CGFloat,
    tint: NSColor? = nil
) {
    view.material = .headerView
    view.blendingMode = .withinWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerCurve = .continuous
    view.layer?.cornerRadius = cornerRadius
    view.layer?.masksToBounds = true
    let workspace = NSWorkspace.shared
    if workspace.accessibilityDisplayShouldReduceTransparency {
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    } else {
        view.layer?.backgroundColor = tint?.withAlphaComponent(0.18).cgColor
    }
    view.layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
    view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
}

@MainActor
private func tabbedGlassSurface(cornerRadius: CGFloat, tint: NSColor? = nil) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configureTabbedGlass(view, cornerRadius: cornerRadius, tint: tint)
    return view
}

@MainActor private final class TabbedMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

/// One geometry for drawing, hit testing, accessibility, and drag insertion.
struct TabbedStripLayout {
    let visibleRange: Range<Int>
    let tabWidth: Double
    let menuFrame: NSRect
    let hiddenCount: Int

    init(width: Double, count: Int, selectedIndex: Int?) {
        menuFrame = NSRect(x: max(32, width - 42), y: 0, width: min(42, max(0, width - 32)), height: 34)
        let available = max(0, menuFrame.minX - 32)
        let visible = min(count, max(1, Int(available / 110)))
        tabWidth = min(210, available / Double(max(1, visible)))
        let start = min(max(0, (selectedIndex ?? 0) - visible + 1), count - visible)
        visibleRange = start..<(start + visible)
        hiddenCount = count - visible
    }

    func tabFrame(_ index: Int) -> NSRect {
        NSRect(x: 32 + Double(index - visibleRange.lowerBound) * tabWidth, y: 0, width: tabWidth, height: 34)
    }

    func closeFrame(_ index: Int) -> NSRect {
        let tab = tabFrame(index)
        return NSRect(x: tab.maxX - 24, y: 0, width: 24, height: 34)
    }

    func tabIndex(at point: NSPoint) -> Int? {
        visibleRange.first { tabFrame($0).contains(point) }
    }

    func insertion(at x: Double) -> (index: Int, x: Double) {
        let offset = min(visibleRange.count, max(0, Int(((x - 32) / max(1, tabWidth)).rounded())))
        return (visibleRange.lowerBound + offset, 32 + Double(offset) * tabWidth)
    }
}

@MainActor final class TabbedPaneView: NSVisualEffectView {
    weak var owner: TabbedOverlayController?
    var pane = TabbedPane()
    var number = 1
    var active = false { didSet { needsDisplay = true } }
    var titles: [String] = []
    var icons: [NSImage?] = []
    private var downPoint: NSPoint?
    private var downTab: WindowID?
    private var downClose: WindowID?
    private var dragging = false
    private var hoverPoint: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTabbedGlass(self, cornerRadius: 7)
    }

    required init?(coder: NSCoder) { nil }

    var strip: TabbedStripLayout {
        TabbedStripLayout(width: bounds.width, count: pane.tabs.count,
                          selectedIndex: pane.tabs.firstIndex(where: { $0 == pane.selected }))
    }
    private func tabIndex(at point: NSPoint) -> Int? {
        strip.tabIndex(at: point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hoverPoint = nil; needsDisplay = true }

    func updateToolTips() {
        removeAllToolTips()
        addToolTip(NSRect(x: 0, y: 0, width: 32, height: 34), owner: "Use this pane for new windows" as NSString, userData: nil)
        addToolTip(strip.menuFrame, owner: "Show all tabs and layout actions" as NSString, userData: nil)
        for index in strip.visibleRange {
            let title = titles.indices.contains(index) ? titles[index] : "Window"
            var label = strip.tabFrame(index)
            label.size.width -= 24
            addToolTip(label, owner: title as NSString, userData: nil)
            addToolTip(strip.closeFrame(index), owner: "Close \(title)" as NSString, userData: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        configureTabbedGlass(self, cornerRadius: 7)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: 34)
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: header).fill()
        if active {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 6, width: 24, height: 22), xRadius: 6, yRadius: 6).fill()
        }
        drawText("\(number)", in: NSRect(x: 4, y: 9, width: 24, height: 18), color: active ? .controlAccentColor : .secondaryLabelColor, bold: true, centered: true)
        let strip = strip
        for index in strip.visibleRange {
            let id = pane.tabs[index]
            let tab = strip.tabFrame(index)
            let rect = tab.insetBy(dx: 1, dy: 3)
            if pane.selected == id {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                let capsule = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                capsule.fill()
                NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
                capsule.lineWidth = 0.75
                capsule.stroke()
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 7, y: 30, width: max(0, rect.width - 14), height: 2), xRadius: 1, yRadius: 1).fill()
            } else if let hoverPoint, tab.contains(hoverPoint) {
                NSColor.labelColor.withAlphaComponent(downTab == id ? 0.12 : 0.06).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            var titleFrame = rect.insetBy(dx: 8, dy: 6)
            if tab.width >= 110, icons.indices.contains(index), let icon = icons[index] {
                let displayedIcon = icon.isTemplate
                    ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor])) ?? icon
                    : icon
                displayedIcon.draw(in: NSRect(x: rect.minX + 8, y: 9, width: 16, height: 16),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                titleFrame.origin.x += 22
                titleFrame.size.width -= 22
            }
            drawText(titles.indices.contains(index) ? titles[index] : "Window", in: titleFrame, color: .labelColor, bold: pane.selected == id, trailing: 17)
            let close = strip.closeFrame(index)
            if let hoverPoint, close.contains(hoverPoint) {
                NSColor.labelColor.withAlphaComponent(downClose == id ? 0.18 : 0.09).setFill()
                NSBezierPath(roundedRect: close.insetBy(dx: 2, dy: 7), xRadius: 4, yRadius: 4).fill()
            }
            drawSymbol("xmark", in: NSRect(x: close.midX - 4, y: 13, width: 8, height: 8), color: .labelColor)
        }
        if let hoverPoint, strip.menuFrame.contains(hoverPoint) {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: strip.menuFrame.insetBy(dx: 3, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        if strip.hiddenCount > 0 {
            drawText("+\(strip.hiddenCount)", in: strip.menuFrame.insetBy(dx: 2, dy: 8), color: .labelColor, bold: true, centered: true)
        } else {
            drawSymbol("ellipsis", in: NSRect(x: strip.menuFrame.midX - 8, y: 9, width: 16, height: 16), color: .labelColor)
        }
        if pane.tabs.isEmpty {
            let centerY = max(52, (bounds.height + 34) / 2)
            if bounds.width >= 200 && bounds.height >= 170 {
                drawSymbol("rectangle.stack.badge.plus", in: NSRect(x: bounds.midX - 15, y: centerY - 54, width: 30, height: 30), color: .secondaryLabelColor)
            }
            drawText("Drop a tab here", in: NSRect(x: 8, y: centerY - 10, width: max(0, bounds.width - 16), height: 22), color: .labelColor, bold: true, centered: true)
            if bounds.width >= 240 && bounds.height >= 130 {
                drawText(active ? "New windows open in this pane" : "Click to use this pane for new windows", in: NSRect(x: 12, y: centerY + 15, width: max(0, bounds.width - 24), height: 20), color: .secondaryLabelColor, centered: true)
            }
        }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
        outline.lineWidth = active ? 1.5 : 0.75
        (active
            ? NSColor.controlAccentColor.withAlphaComponent(owner?.isInteracting == true ? 0.72 : 0.32)
            : NSColor.separatorColor.withAlphaComponent(0.5)
        ).setStroke()
        outline.stroke()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let scale = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let fitted = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.withSymbolConfiguration(configuration)?.draw(in: fitted, from: .zero, operation: .sourceOver,
                                                           fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, bold: Bool = false, centered: Bool = false, trailing: Double = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = centered ? .center : .left
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - trailing), height: rect.height), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }

    func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        var children: [TabbedAccessibilityButton] = []
        func button(_ label: String, rect: NSRect, action: @escaping @MainActor @Sendable () -> Void) {
            let element = TabbedAccessibilityButton(action: action)
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            if let window { element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil))) }
            children.append(element)
        }
        button("Use pane \(number) for new windows", rect: NSRect(x: 0, y: 0, width: 30, height: 34)) { [weak self] in
            guard let self else { return }; owner?.send(.activate(pane.id))
        }
        let strip = strip
        for index in strip.visibleRange {
            let id = pane.tabs[index]
            let title = titles.indices.contains(index) ? titles[index] : "Window"
            var rect = strip.tabFrame(index)
            rect.size.width -= 24
            button("\(title)\(pane.selected == id ? ", selected" : "")", rect: rect) { [weak self] in self?.owner?.send(.select(id)) }
            button("Close \(title)", rect: strip.closeFrame(index)) { [weak self] in self?.owner?.send(.close(id)) }
        }
        button("Pane \(number) layout and tab actions", rect: strip.menuFrame) { [weak self] in
            guard let self, let owner else { return }
            owner.menu(pane: pane, windowID: nil).popUp(positioning: nil, at: NSPoint(x: strip.menuFrame.minX, y: 34), in: self)
        }
        setAccessibilityChildren(children)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        downTab = nil; downClose = nil; downPoint = nil; dragging = false
        if strip.menuFrame.contains(point) || event.modifierFlags.contains(.control) { showMenu(event); return }
        if let index = tabIndex(at: point) {
            let id = pane.tabs[index]
            if strip.closeFrame(index).contains(point) { downClose = id; hoverPoint = point; needsDisplay = true; return }
            downTab = id; downPoint = point; dragging = false
            hoverPoint = point; needsDisplay = true
        } else { owner?.send(.activate(pane.id)) }
    }
    override func mouseDragged(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        guard let id = downTab, let downPoint, let owner else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging && hypot(point.x - downPoint.x, point.y - downPoint.y) >= 5 {
            dragging = true; owner.beginDrag(id)
        }
        if dragging { owner.drag(to: owner.screenPoint(event)) }
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dragging, let owner {
            owner.drag(to: owner.screenPoint(event))
            owner.endDrag()
        }
        else if let downClose,
                let index = tabIndex(at: point),
                pane.tabs[index] == downClose,
                strip.closeFrame(index).contains(point) { owner?.send(.close(downClose)) }
        else if let downTab,
                let index = tabIndex(at: point),
                pane.tabs[index] == downTab,
                !strip.closeFrame(index).contains(point) { owner?.send(.select(downTab)) }
        downTab = nil; downClose = nil; downPoint = nil; dragging = false
        needsDisplay = true
    }
    override func rightMouseDown(with event: NSEvent) { showMenu(event) }
    private func showMenu(_ event: NSEvent) {
        guard let owner else { return }
        let index = tabIndex(at: convert(event.locationInWindow, from: nil))
        let menu = owner.menu(pane: pane, windowID: index.map { pane.tabs[$0] })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func keyDown(with event: NSEvent) {
        guard let selected = pane.selected, let index = pane.tabs.firstIndex(of: selected) else { super.keyDown(with: event); return }
        if event.keyCode == 123 || event.keyCode == 124 {
            let next = (index + (event.keyCode == 123 ? -1 : 1) + pane.tabs.count) % pane.tabs.count
            owner?.send(.select(pane.tabs[next]))
        } else { super.keyDown(with: event) }
    }
}

@MainActor final class TabbedDividerView: NSVisualEffectView {
    weak var owner: TabbedOverlayController?
    var divider: TabbedDivider? { didSet { needsDisplay = true } }
    private var dragStart: (divider: TabbedDivider, point: BTPoint)?
    override var wantsUpdateLayer: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTabbedGlass(self, cornerRadius: 3)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        configureTabbedGlass(self, cornerRadius: 3)
        NSColor.controlAccentColor.withAlphaComponent(owner?.isInteracting == true ? 0.5 : 0.16).setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.64).setFill()
        let grip = divider?.vertical == true
            ? NSRect(x: bounds.midX - 1, y: bounds.midY - 12, width: 2, height: min(24, bounds.height))
            : NSRect(x: bounds.midX - 12, y: bounds.midY - 1, width: min(24, bounds.width), height: 2)
        NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: divider?.vertical == true ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {
        guard let divider, let owner, !owner.isInteracting else { return }
        dragStart = (divider, owner.screenPoint(event))
        owner.beginResize()
    }
    override func mouseDragged(with event: NSEvent) {
        updateResize(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        updateResize(with: event)
        dragStart = nil
        owner?.endResize()
    }

    private func updateResize(with event: NSEvent) {
        guard let dragStart, let owner else { return }
        let divider = dragStart.divider
        let point = owner.screenPoint(event)
        let length = (divider.vertical ? divider.bounds.size.width : divider.bounds.size.height) - TabbedLayoutState.gap
        // Keep the grab offset and original split bounds while the handle moves.
        let translated = BTPoint(
            x: divider.bounds.minX + divider.ratio * length + point.x - dragStart.point.x,
            y: divider.bounds.minY + divider.ratio * length + point.y - dragStart.point.y
        )
        owner.resize(divider, point: translated)
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(by: 0.05) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -0.05) }

    private func adjust(by delta: Double) -> Bool {
        guard let divider, let owner, !owner.isInteracting else { return false }
        owner.beginResize()
        owner.send(.resize(divider.id, min(0.95, max(0.05, divider.ratio + delta))))
        owner.endResize()
        return true
    }
}

private final class TabbedAccessibilityButton: NSAccessibilityElement {
    nonisolated let action: @MainActor @Sendable () -> Void
    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        super.init()
    }
    override func accessibilityPerformPress() -> Bool {
        let action = self.action
        MainActor.assumeIsolated { action() }
        return true
    }
}
