import AppKit
import BetterTileCore

public enum TabbedUIIntent {
    case select(WindowID), activate(UUID), close(WindowID), float(WindowID)
    case move(WindowID, pane: UUID, index: Int?)
    case split(WindowID, pane: UUID, edge: TabbedEdge)
    case preset(TabbedPreset), undo, repair, removePane(UUID)
    /// VoiceOver moves a Bento pane divider by a fraction of its area.
    case adjustDivider(UUID, by: Double)
}

/// AppKit chrome only: tab strips, empty-pane targets, and a shared display curtain.
/// It knows pane values and emits intents; it never writes Accessibility
/// attributes or owns layout sessions. Pane dividers belong to Bento's overlay.
@MainActor
public final class TabbedOverlayController {
    public var onIntent: ((TabbedUIIntent) -> Void)?
    public var overlayAppearance = OverlayAppearance() {
        didSet {
            for panel in panes.values { (panel.contentView as? TabbedPaneView)?.overlayAppearance = overlayAppearance }
            for panel in [curtain, preview, floatTarget].compactMap({ $0 }) {
                (panel.contentView as? OverlayGlassView)?.overlayAppearance = overlayAppearance
            }
        }
    }
    public private(set) var isInteracting = false
    private var state = TabbedLayoutState()
    private var bounds = BTRect(x: 0, y: 0, width: 1, height: 1)
    private var windows: [WindowID: WindowSnapshot] = [:]
    /// Includes failed lookups as nil so they are not repeated on refresh.
    private var applicationIcons: [String: NSImage?] = [:]
    private var panes: [UUID: NSPanel] = [:]
    private var curtain: NSPanel?
    /// Accessibility-only divider controls. Pointer resizing uses Bento's
    /// divider overlay, so these panels ignore the mouse.
    private var dividerControls: [UUID: NSPanel] = [:]
    private var preview: NSPanel?
    private var floatTarget: NSPanel?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private let addGlobalKeyMonitor: (@escaping @MainActor (UInt16) -> Void) -> Any?
    private let addLocalKeyMonitor: (@escaping @MainActor (UInt16) -> Bool) -> Any?
    private let removeMonitor: (Any) -> Void
    private let orderPanel: (NSPanel, NSWindow.OrderingMode, Int) -> Void
    private var draggedWindow: WindowID?
    private var dropIntent: TabbedUIIntent?
    private var cancelled = false
    private var canUndo = false

    public convenience init() {
        self.init(addGlobalKeyMonitor: { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode
                MainActor.assumeIsolated { handler(keyCode) }
            }
        })
    }

    init(
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
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) },
        orderPanel: @escaping (NSPanel, NSWindow.OrderingMode, Int) -> Void = { $0.order($1, relativeTo: $2) }
    ) {
        self.addGlobalKeyMonitor = addGlobalKeyMonitor
        self.addLocalKeyMonitor = addLocalKeyMonitor
        self.removeMonitor = removeMonitor
        self.orderPanel = orderPanel
    }

    /// `selectedWindowNumbers` holds validated WindowServer numbers of the
    /// panes' selected windows. With a number, a pane's chrome joins the
    /// normal window stack beside that window, so a window in front of the
    /// selected tab also covers its strip. Without one, chrome floats and
    /// hides only under `obscuringFrames`.
    public func refresh(state: TabbedLayoutState, bounds: BTRect, windows: [WindowSnapshot], obscuringFrames: [BTRect] = [], canUndo: Bool = false, selectedWindowNumbers: [WindowID: Int] = [:], curtainAnchorWindowNumber: Int? = nil) {
        self.state = state
        self.bounds = bounds
        self.canUndo = canUndo
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let frames = state.frames(in: bounds)
        let numbers = selectedWindowNumbers.filter { $0.value > 0 }
        // An empty pane has no window of its own. It sits above the active
        // pane's selected tab, which is normally the front of the layout.
        let emptyPaneAnchor = ([state.activeWindowID].compactMap { $0 } + state.selectedWindowIDs)
            .lazy.compactMap { numbers[$0] }.first
        for id in panes.keys.filter({ frames[$0] == nil }) { panes.removeValue(forKey: id)?.orderOut(nil) }
        for (index, pane) in state.panes.enumerated() {
            guard let frame = frames[pane.id] else { continue }
            let panel = panes[pane.id] ?? makePanel()
            let view = panel.contentView as? TabbedPaneView ?? TabbedPaneView()
            view.overlayAppearance = overlayAppearance
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
                if let cached = applicationIcons[bundleID] { return cached }
                let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
                applicationIcons[bundleID] = .some(icon)
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
            if let anchor = pane.selected.flatMap({ numbers[$0] }) ?? (pane.tabs.isEmpty ? emptyPaneAnchor : nil) {
                panel.level = .normal
                orderPanel(panel, .above, anchor)
            } else {
                panel.level = .floating
                if obscuringFrames.contains(where: { $0.intersection(chrome) != nil }) { panel.orderOut(nil) }
                else { panel.orderFrontRegardless() }
            }
            panes[pane.id] = panel
        }
        let hasSelectedIdentities = !state.selectedWindowIDs.isEmpty
            && state.selectedWindowIDs.allSatisfy { numbers[$0] != nil }
        let anchor = curtainAnchorWindowNumber.flatMap { number in
            hasSelectedIdentities && state.selectedWindowIDs.contains(where: { numbers[$0] == number }) ? number : nil
        }
        refreshCurtain(anchor: anchor)
        refreshDividerControls()
    }

    /// WindowServer numbers of this overlay's panels, which Tabbed's stacking
    /// repair must not treat as application windows.
    public var windowNumbers: Set<Int> {
        let panels = Array(panes.values) + [curtain].compactMap { $0 } + Array(dividerControls.values) + [preview, floatTarget].compactMap { $0 }
        return Set(panels.map(\.windowNumber).filter { $0 > 0 })
    }

    public func hide() {
        cancelInteraction()
        for panel in Array(panes.values) + Array(dividerControls.values) + [curtain].compactMap({ $0 }) { panel.orderOut(nil) }
        curtain = nil
    }

    /// The caller verifies all selected windows are above inactive tabs, then
    /// supplies the exact number of the backmost selected window.
    private func refreshCurtain(anchor: Int?) {
        guard let anchor, anchor > 0 else { curtain?.orderOut(nil); return }
        let panel = curtain ?? makePanel()
        panel.level = .normal
        panel.isExcludedFromWindowsMenu = true
        panel.setAccessibilityElement(false)
        panel.animationBehavior = .none
        let view = panel.contentView as? TabbedCurtainView ?? TabbedCurtainView()
        view.overlayAppearance = overlayAppearance
        view.onClick = { [weak self, weak panel] point in
            guard let self, let panel else { return }
            let screen = panel.convertPoint(toScreen: point)
            let point = CoordinateConverter.pointToTopLeft(screen, mainScreenFrame: NSScreen.screens.first?.frame ?? .zero)
            let frames = self.state.frames(in: self.bounds)
            guard let pane = self.state.panes.first(where: { frames[$0.id]?.contains(point) == true }) else { return }
            if let selected = pane.selected { self.send(.select(selected)) }
            else { self.send(.activate(pane.id)) }
        }
        panel.contentView = view
        panel.setFrame(appKit(bounds), display: false)
        orderPanel(panel, .below, anchor)
        curtain = panel
    }

    private func refreshDividerControls() {
        let dividers = state.dividers(in: bounds)
        let ids = Set(dividers.compactMap(\.branchID))
        for id in dividerControls.keys where !ids.contains(id) { dividerControls.removeValue(forKey: id)?.orderOut(nil) }
        for divider in dividers {
            guard let branchID = divider.branchID, let parent = divider.parentBounds else { continue }
            let panel = dividerControls[branchID] ?? makePanel()
            panel.ignoresMouseEvents = true
            let view = panel.contentView as? TabbedDividerAccessibilityView ?? TabbedDividerAccessibilityView()
            view.onAdjust = { [weak self] delta in self?.send(.adjustDivider(branchID, by: delta)) }
            let extent = divider.axis == .vertical ? parent.size.width : parent.size.height
            let start = divider.axis == .vertical ? parent.minX : parent.minY
            view.setAccessibilityValue(((divider.coordinate - start) / max(1, extent) * 100).rounded())
            panel.contentView = view
            let gap = TabbedLayoutState.gap
            let frame = divider.axis == .vertical
                ? BTRect(x: divider.coordinate - gap / 2, y: divider.spanStart, width: gap, height: divider.spanEnd - divider.spanStart)
                : BTRect(x: divider.spanStart, y: divider.coordinate - gap / 2, width: divider.spanEnd - divider.spanStart, height: gap)
            panel.setFrame(appKit(frame), display: false)
            // A divider drag refreshes on every display tick. These panels
            // draw nothing, so ordering them once is enough.
            if !panel.isVisible { panel.orderFrontRegardless() }
            dividerControls[branchID] = panel
        }
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
        curtain?.setFrame(appKit(bounds), display: false)
        refreshDividerControls()
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
            for edge in TabbedEdge.allCases { item("Split \(edge.rawValue.capitalized)", .split(id, pane: pane.id, edge: edge), enabled: state.panes.count < TabbedLayoutState.maximumPaneCount, in: menu) }
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
        let view = tabbedGlassSurface(cornerRadius: 10, tint: .controlAccentColor, appearance: overlayAppearance)
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
                    let strip = (panes[pane.id]?.contentView as? TabbedPaneView)?.strip
                        ?? TabbedStripLayout(width: frame.size.width, count: pane.tabs.count,
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
                    if let edge, state.panes.count < TabbedLayoutState.maximumPaneCount {
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
                let surface = tabbedGlassSurface(cornerRadius: 8, tint: .controlAccentColor, appearance: overlayAppearance)
                let label = NSTextField(labelWithString: "")
                label.alignment = .center
                label.font = .systemFont(ofSize: 15, weight: .semibold)
                label.textColor = .labelColor
                surface.addSubview(label)
                panel.contentView = surface
            }
            panel.setFrame(appKit(highlight), display: true)
            if let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first {
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

    public func cancelInteraction() {
        cancelled = true
        finishInteraction()
    }

    private func finishInteraction() {
        preview?.orderOut(nil); floatTarget?.orderOut(nil)
        preview = nil; floatTarget = nil
        if let globalKeyMonitor { removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        draggedWindow = nil; dropIntent = nil
        isInteracting = false
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

/// A frosted plate covers the glass so a hidden tab cannot read clearly
/// through it. A click brings the pane's selected window forward; the curtain
/// has no accessibility controls.
@MainActor final class TabbedCurtainView: OverlayGlassView {
    var onClick: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = 0
        frostFloor = 0.96
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        onClick?(convert(event.locationInWindow, from: nil))
    }
}

@MainActor
private func tabbedGlassSurface(cornerRadius: CGFloat, tint: NSColor? = nil, appearance: OverlayAppearance) -> OverlayGlassView {
    let view = OverlayGlassView()
    view.cornerRadius = cornerRadius
    view.tint = tint
    view.overlayAppearance = appearance
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

    init(width: Double, count: Int, selectedIndex: Int?, startIndex: Int = 0) {
        menuFrame = NSRect(x: max(32, width - 42), y: 0, width: min(42, max(0, width - 32)), height: TabbedLayoutState.headerHeight)
        let available = max(0, menuFrame.minX - 32)
        let visible = min(count, max(1, Int(available / 110)))
        tabWidth = min(210, available / Double(max(1, visible)))
        let selected = min(max(0, selectedIndex ?? 0), max(0, count - 1))
        let start = min(max(0, count - visible), max(selected - visible + 1, min(max(0, startIndex), selected)))
        visibleRange = start..<(start + visible)
        hiddenCount = count - visible
    }

    func tabFrame(_ index: Int) -> NSRect {
        NSRect(x: 32 + Double(index - visibleRange.lowerBound) * tabWidth, y: 0, width: tabWidth, height: TabbedLayoutState.headerHeight)
    }

    func closeFrame(_ index: Int) -> NSRect {
        let tab = tabFrame(index)
        return NSRect(x: tab.maxX - 24, y: 0, width: 24, height: TabbedLayoutState.headerHeight)
    }

    func tabIndex(at point: NSPoint) -> Int? {
        visibleRange.first { tabFrame($0).contains(point) }
    }

    func insertion(at x: Double) -> (index: Int, x: Double) {
        let offset = min(visibleRange.count, max(0, Int(((x - 32) / max(1, tabWidth)).rounded())))
        return (visibleRange.lowerBound + offset, 32 + Double(offset) * tabWidth)
    }
}

/// A tab strip on real Liquid Glass. The glass is a background sibling that
/// only draws; the strip content above it handles every event in its own
/// coordinates, so clicks never depend on the glass view's internal layout.
@MainActor final class TabbedPaneView: NSView {
    private let glass = OverlayGlassView()
    private let content = TabbedPaneContentView()

    weak var owner: TabbedOverlayController? { didSet { content.owner = owner } }
    var pane: TabbedPane { get { content.pane } set { content.pane = newValue; refreshAppearance() } }
    var overlayAppearance = OverlayAppearance() { didSet { refreshAppearance() } }
    var number: Int { get { content.number } set { content.number = newValue } }
    var active: Bool { get { content.active } set { content.active = newValue } }
    var titles: [String] { get { content.titles } set { content.titles = newValue } }
    var icons: [NSImage?] { get { content.icons } set { content.icons = newValue } }
    var strip: TabbedStripLayout { content.strip }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = 7
        for view in [glass, content] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        refreshAppearance()
        // Reduce Transparency and Increase Contrast can change while the
        // strip is on screen.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        glass.frame = bounds
        content.frame = bounds
    }

    /// Test seam for the accessibility display options.
    var displayOptions: () -> (reduceTransparency: Bool, increaseContrast: Bool) = {
        let workspace = NSWorkspace.shared
        return (workspace.accessibilityDisplayShouldReduceTransparency,
                workspace.accessibilityDisplayShouldIncreaseContrast)
    }
    var showsGlass: Bool { glass.showsGlass }

    func refreshAppearance() {
        glass.displayOptions = displayOptions
        glass.isLight = pane.tabs.isEmpty
        glass.cornerRadius = pane.tabs.isEmpty ? 16 : 7
        glass.overlayAppearance = overlayAppearance
        content.needsDisplay = true
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { content.needsDisplay = true } }
    }

    var stripLayout: TabbedStripLayout { content.strip }
    func updateToolTips() { content.updateToolTips() }
    func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren(content.accessibilityButtons(parent: self))
    }

    override func mouseDown(with event: NSEvent) { content.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { content.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { content.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { content.rightMouseDown(with: event) }
    override func keyDown(with event: NSEvent) { content.keyDown(with: event) }
}

@MainActor final class TabbedPaneContentView: NSView {
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
    private var firstVisibleIndex = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { nil }

    var strip: TabbedStripLayout {
        TabbedStripLayout(width: bounds.width, count: pane.tabs.count,
                          selectedIndex: pane.tabs.firstIndex(where: { $0 == pane.selected }),
                          startIndex: firstVisibleIndex)
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
        addToolTip(NSRect(x: 0, y: 0, width: 32, height: TabbedLayoutState.headerHeight), owner: "Use this pane for new windows" as NSString, userData: nil)
        let menuHelp = strip.hiddenCount > 0
            ? "\(strip.hiddenCount) more tabs. Show all tabs and layout actions"
            : "Show all tabs and layout actions"
        addToolTip(strip.menuFrame, owner: menuHelp as NSString, userData: nil)
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
                NSColor.controlAccentColor.withAlphaComponent(active ? 0.10 : 0.05).setFill()
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
            let compact = tab.width < 80
            let tabIcon = icons.indices.contains(index) ? icons[index] : nil
            if tab.width >= 110 || compact,
               let icon = tabIcon ?? (compact ? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) : nil) {
                let displayedIcon = icon.isTemplate
                    ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor])) ?? icon
                    : icon
                displayedIcon.draw(in: NSRect(x: rect.minX + (compact ? 4 : 8), y: 9, width: 16, height: 16),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                titleFrame.origin.x += 22
                titleFrame.size.width -= 22
            }
            if !compact {
                drawText(titles.indices.contains(index) ? titles[index] : "Window", in: titleFrame, color: .labelColor, bold: pane.selected == id, trailing: 17)
            }
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
            let centerY = max(52, (bounds.height + TabbedLayoutState.headerHeight) / 2)
            let plate = NSRect(x: max(8, bounds.midX - 165), y: centerY - 64,
                               width: min(330, max(0, bounds.width - 16)), height: min(112, max(0, bounds.height - centerY + 64)))
            NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: plate, xRadius: 12, yRadius: 12).fill()
            if bounds.width >= 200 && bounds.height >= 170 {
                drawSymbol("rectangle.stack.badge.plus", in: NSRect(x: bounds.midX - 15, y: centerY - 54, width: 30, height: 30), color: .secondaryLabelColor)
            }
            drawText("Drop a tab here", in: NSRect(x: 8, y: centerY - 10, width: max(0, bounds.width - 16), height: 22), color: .labelColor, bold: true, centered: true)
            if bounds.width >= 240 && bounds.height >= 130 {
                drawText(active ? "New windows open in this pane" : "Click to use this pane for new windows", in: NSRect(x: 12, y: centerY + 15, width: max(0, bounds.width - 24), height: 20), color: .secondaryLabelColor, centered: true)
            }
        }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: pane.tabs.isEmpty ? 16 : 7, yRadius: pane.tabs.isEmpty ? 16 : 7)
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

    fileprivate func accessibilityButtons(parent: NSView) -> [TabbedAccessibilityButton] {
        firstVisibleIndex = strip.visibleRange.lowerBound
        var children: [TabbedAccessibilityButton] = []
        func button(_ label: String, rect: NSRect, action: @escaping @MainActor @Sendable () -> Void) {
            let element = TabbedAccessibilityButton(action: action)
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(parent)
            if let window { element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil))) }
            children.append(element)
        }
        button("Use pane \(number) for new windows", rect: NSRect(x: 0, y: 0, width: 30, height: TabbedLayoutState.headerHeight)) { [weak self] in
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
        let menuLabel = "Pane \(number) layout and tab actions" + (strip.hiddenCount > 0 ? ", \(strip.hiddenCount) more tabs" : "")
        button(menuLabel, rect: strip.menuFrame) { [weak self] in
            guard let self, let owner else { return }
            owner.menu(pane: pane, windowID: nil).popUp(positioning: nil, at: NSPoint(x: strip.menuFrame.minX, y: TabbedLayoutState.headerHeight), in: self)
        }
        return children
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

/// A VoiceOver slider over a Bento pane divider. It draws nothing and takes no
/// clicks; pointer resizing belongs to Bento's divider handle.
@MainActor final class TabbedDividerAccessibilityView: NSView {
    var onAdjust: ((Double) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityEnabled(true)
        setAccessibilityLabel("Resize panes")
        setAccessibilityMinValue(5)
        setAccessibilityMaxValue(95)
        setAccessibilityHelp("Adjust the first pane's share in five percent steps.")
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityPerformIncrement() -> Bool { onAdjust?(0.05); return onAdjust != nil }
    override func accessibilityPerformDecrement() -> Bool { onAdjust?(-0.05); return onAdjust != nil }
}
