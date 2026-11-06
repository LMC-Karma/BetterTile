import AppKit
import BetterTileCore
import SwiftUI

/// `reselecting` is set only by a tab drag whose press selected the dragged
/// tab. It names the tab its pane showed before that press. When the drop
/// takes the dragged tab out of that pane, the pane selects that tab again.
public enum TabbedUIIntent {
    case select(WindowID), activate(UUID), close(WindowID)
    case float(WindowID, reselecting: WindowID? = nil)
    case move(WindowID, pane: UUID, index: Int?, reselecting: WindowID? = nil)
    case split(WindowID, pane: UUID, edge: TabbedEdge, reselecting: WindowID? = nil)
    case preset(TabbedPreset, grouping: TabbedPresetGrouping = .keepTabGroups)
    case undo, repair, removePane(UUID)
    /// VoiceOver moves a Bento pane divider by a fraction of its area.
    case adjustDivider(UUID, by: Double)
}

/// Where a dragged real window joins a Tabbed pane as a tab.
public struct TabbedDropZone: Equatable, Sendable {
    public let paneID: UUID
    /// The tab index in the strip; nil for an empty pane.
    public let index: Int?
    public let paneFrame: BTRect
    /// The insertion line drawn over the strip; nil for an empty pane.
    public let indicator: BTRect?
}

/// AppKit chrome only: tab strips, empty-pane targets, and a shared display curtain.
/// It knows pane values and emits intents; it never writes Accessibility
/// attributes or owns layout sessions. Pane dividers belong to Bento's overlay.
@MainActor
public final class TabbedOverlayController: NSObject, NSMenuDelegate {
    /// Set before the first refresh, while the owning exact Space is active.
    public var keepsPanelsOnSpace = false
    private var spaceChangeSuspended = false

    /// Stop timers and input without ordering the Space-owned surfaces out.
    public func prepareForSpaceChange() {
        pointerSamples.cancel()
        spaceChangeSuspended = true
        autoHidePointerMonitor = nil
        autoHidePointerCache = nil
        onDismissApplicationPicker?()
        gallery?.cancel()
        endKeyboardFocus(returning: false)
        cancelInteraction()
        visibilityTask?.cancel()
        barVisibility.removeAll()
        selectionPanes.removeAll()
        syncVisibilityEscape()
        acceptsTabDrags = false
        for pane in state.panes { updateBar(pane.id, ordering: false) }
    }
    public var onIntent: ((TabbedUIIntent) -> Void)?
    public var onAddApplication: ((UUID, NSView, NSRect) -> Void)?
    public var onDismissApplicationPicker: (() -> Void)?
    private var applicationPickerPaneID: UUID?
    public var onPaneRequestAction: ((UUID, PaneRequestAction) -> Void)?
    private var paneRequestStatus: PaneRequestStatus?
    /// The WindowServer number of a window that a pane request is waiting for the user to click.
    private var requestRevealNumber: Int?
    /// The pane that a request reveal moved below its window, and the stack anchor that the last
    /// refresh gave it. Ending the reveal orders the pane by that anchor again.
    private var revealedPane: (id: UUID, anchor: Int?)?

    public func setPaneRequestStatus(_ status: PaneRequestStatus?) {
        guard paneRequestStatus != status else { return }
        let previousStatus = paneRequestStatus
        let previous = previousStatus?.paneID
        paneRequestStatus = status
        // A cleared status or another request ends the reveal, even without revealRequestWindow(nil).
        if status?.requestID != previousStatus?.requestID || status?.paneID != previous {
            requestRevealNumber = nil
            endRequestReveal()
        }
        for id in Set([previous, status?.paneID].compactMap { $0 }) {
            guard let view = panes[id]?.contentView as? TabbedPaneView else { continue }
            view.content.setRequestStatus(status?.paneID == id ? status : nil)
            updateBar(id)
            view.updateAccessibility()
        }
    }

    /// While a pane waits for the user to click a window BetterTile asked an app to open, that pane's
    /// panel drops to the normal level just below the window, so the window can be seen and clicked.
    /// Other panes keep their order. `nil` orders the pane as the last refresh did, at once.
    public func revealRequestWindow(number: Int?) {
        guard requestRevealNumber != number else { return }
        requestRevealNumber = number
        guard let number else { endRequestReveal(); return }
        guard let paneID = paneRequestStatus?.paneID, let panel = panes[paneID] else { return }
        if revealedPane?.id != paneID {
            endRequestReveal()
            revealedPane = (paneID, paneAnchors[paneID])
        }
        paneAnchors.removeValue(forKey: paneID)
        panel.level = .normal
        orderPanel(panel, .below, number)
    }

    /// Hidden or suspended surfaces stay where they are; the next refresh orders them.
    private func endRequestReveal() {
        guard let revealed = revealedPane else { return }
        revealedPane = nil
        guard !spaceChangeSuspended, let panel = panes[revealed.id],
              let pane = state.panes.first(where: { $0.id == revealed.id }),
              let frame = state.frames(in: bounds)[revealed.id] else { return }
        let panelFrame = panel.frame
        orderPane(revealed.id, panel: panel, anchor: revealed.anchor, chrome: chromeFrame(for: pane, frame: frame))
        // Ordering can enlarge a borderless panel to 10 points.
        if panel.frame != panelFrame { panel.setFrame(panelFrame, display: false) }
    }

    /// With a validated anchor, the pane's chrome joins the normal window stack above it.
    /// Without one, it floats and hides under an obscuring frame.
    private func orderPane(_ id: UUID, panel: NSPanel, anchor: Int?, chrome: BTRect) {
        if let anchor {
            paneAnchors[id] = anchor
            panel.level = .normal
            orderPanel(panel, .above, anchor)
        } else {
            paneAnchors.removeValue(forKey: id)
            panel.level = .floating
            if obscuringFrames.contains(where: { $0.intersection(chrome) != nil }) { panel.orderOut(nil) }
            else { panel.orderFrontRegardless() }
        }
    }

    public func holdApplicationPicker(_ paneID: UUID, enabled: Bool) {
        if enabled { applicationPickerPaneID = paneID }
        else if applicationPickerPaneID == paneID { applicationPickerPaneID = nil }
        holdBar(paneID, .applicationPicker, enabled: enabled)
    }

    /// Full pane bounds, including the window area, in AppKit screen coordinates.
    public func paneFrameInAppKit(_ paneID: UUID) -> NSRect? {
        state.frames(in: bounds)[paneID].map { appKit($0) }
    }

    public func showPaneApplicationPicker(_ paneID: UUID) {
        guard let view = panes[paneID]?.contentView as? TabbedPaneView else { return }
        addApplication(paneID: paneID, from: view.content, rect: view.content.addButton.frame)
    }

    fileprivate func addApplication(paneID: UUID, from view: NSView, rect: NSRect) {
        // The app model queues this action behind an actual placement. A tab-drag
        // enablement flag must not silently disable application selection.
        guard !spaceChangeSuspended, !isInteracting, !isDropPending,
              state.panes.contains(where: { $0.id == paneID }), view.window?.isVisible == true else { return }
        gallery?.cancel()
        onAddApplication?(paneID, view, rect)
    }
    public var overlayAppearance = OverlayAppearance() {
        didSet {
            (curtain?.contentView as? TabbedCurtainView)?.overlayAppearance = overlayAppearance
            for panel in panes.values { (panel.contentView as? TabbedPaneView)?.overlayAppearance = overlayAppearance }
            for panel in [preview, floatTarget, draggedTabPanel].compactMap({ $0 }) {
                (panel.contentView as? OverlayGlassView)?.overlayAppearance = overlayAppearance
            }
        }
    }
    public private(set) var isInteracting = false
    public private(set) var isDropPending = false
    public var acceptsTabDrags = true {
        didSet {
            if !acceptsTabDrags { gallery?.cancel() }
            if acceptsTabDrags {
                pressSelection = nil
                // The placement ended, so each strip shows the selection it
                // confirmed, including a rejected press's previous tab.
                for panel in panes.values { (panel.contentView as? TabbedPaneView)?.dropPressedSelection() }
            }
            if !acceptsTabDrags, isInteracting { cancelInteraction() }
        }
    }
    /// The tab whose press started the placement that now blocks tab drags.
    /// Only that placement lets a blocked drag start at release.
    private var pressSelection: WindowID?
    public private(set) var state = TabbedLayoutState() { didSet { layoutGeneration &+= 1 } }
    private var bounds = BTRect(x: 0, y: 0, width: 1, height: 1) { didSet { layoutGeneration &+= 1 } }
    private var windows: [WindowID: WindowSnapshot] = [:]
    private var obscuringFrames: [BTRect] = []
    /// Includes failed lookups as nil so they are not repeated on refresh.
    private var applicationIcons: [String: NSImage?] = [:]
    private var panes: [UUID: NSPanel] = [:]
    private var paneAnchors: [UUID: Int] = [:]
    private var curtain: NSPanel?
    /// Accessibility-only divider controls. Pointer resizing uses Bento's
    /// divider overlay, so these panels ignore the mouse.
    private var dividerControls: [UUID: NSPanel] = [:]
    private var preview: NSPanel?
    private var floatTarget: NSPanel?
    private var draggedTabPanel: NSPanel?
    private var dragOffset = NSPoint.zero
    private var lastDragPoint: BTPoint?
    private var pendingDragPoint: BTPoint?
    private let dragTicks: ResizeDisplayLink
    private var nextScrollTime: TimeInterval = 0
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private let addGlobalKeyMonitor: (@escaping @MainActor (UInt16) -> Void) -> Any?
    private let addLocalKeyMonitor: (@escaping @MainActor (UInt16) -> Bool) -> Any?
    private let removeMonitor: (Any) -> Void
    private let orderPanel: (NSPanel, NSWindow.OrderingMode, Int) -> Void
    private let panelFactory: () -> NSPanel
    var chooserPresenterFactory: ((NSView, NSSize) -> TabbedChooserPresenter)?
    private var draggedWindow: WindowID?
    /// The tab the source pane showed before the press that selected the
    /// dragged tab. Nil when the press did not change the selection.
    private var dragReselecting: WindowID?
    private var curtainBounds: BTRect?
    /// True while a curtain is kept over an order that could not be read
    /// back. The caller should verify the order again soon.
    public private(set) var needsCurtainVerification = false
    /// Unreadable refreshes in a row that kept the curtain. An order that
    /// stays unreadable can also mean a floating window failed to rise, so
    /// the curtain gives way after a few.
    private var curtainHolds = 0
    static let maximumCurtainHolds = 4
    /// Reads the real primary button. A tab drag whose mouse-up never
    /// arrives finishes on the next display tick instead of staying armed.
    private let primaryButtonIsPressed: () -> Bool
    /// Where the pointer is now; the release point when a mouse-up was lost.
    private let pointerLocation: () -> BTPoint?
    private var dropIntent: TabbedUIIntent?
    private var cancelled = false
    private var canUndo = false
    private(set) var gallery: TabbedLayoutGallery?
    private let galleryPreview: PlacementWireframeController
    private(set) var previewedGalleryState: TabbedLayoutState?
    private var barVisibility: [UUID: TabbedBarVisibility] = [:]
    private var selectionPanes: Set<UUID> = []
    private(set) var visibilityTask: Task<Void, Never>?
    private var visibilityGlobalMonitor: Any?
    private var visibilityLocalMonitor: Any?
    public var dividerIsDragging: () -> Bool = { false }
    private var menuPaneID: UUID?
    private var keyboardPaneID: UUID?
    private var keyboardTab: WindowID?
    private let timerClock: BetterTileClock
    private let visibilityClock: () -> TimeInterval
    private let automaticallyAdvanceVisibility: Bool
    private let observesAutoHidePointer: Bool
    private var autoHidePointerMonitor: TabbedAutoHidePointerMonitor?
    private let pointerTicks: ResizeDisplayLink
    private lazy var pointerSamples = DisplayRefreshSample<BTPoint>(ticks: pointerTicks) { [weak self] in
        self?.updateAutoHidePointer(at: $0)
    }
    private var now: TimeInterval { visibilityClock() }

    /// One pane as an auto-hide pointer sample sees it.
    private struct AutoHidePointerPane {
        let id: UUID
        let hasTabs: Bool
        let frame: BTRect
        /// The six-point band while collapsed, and the full strip while revealed or collapsing.
        let collapsedBand: BTRect
        let revealedBand: BTRect
    }
    /// Pane frames and hover bands for one layout generation and request pane.
    private struct AutoHidePointerGeometry {
        let generation: Int
        let requestPaneID: UUID?
        /// Nil outside Auto-hide.
        let panes: [AutoHidePointerPane]?
        /// Where a strip panel can lie under the pointer: each full strip, and the whole pane that
        /// shows a request status. A sample anywhere else can only end a hover.
        let inputAreas: [BTRect]
    }
    /// Changes with every write to `state` or `bounds`: refreshes, resizes, closed windows, and
    /// display, gap, and presentation changes.
    private var layoutGeneration = 0
    private var autoHidePointerCache: AutoHidePointerGeometry?
    /// Each build reads `state.frames(in:)` once.
    private(set) var autoHidePointerCacheBuilds = 0
    /// Samples that did not return early.
    private(set) var autoHidePointerPasses = 0

    /// Pointer samples arrive on every mouse move, so they reuse the geometry until the layout or
    /// the request pane changes. `built` is true when this call read the frames again.
    private func autoHidePointerGeometry() -> (geometry: AutoHidePointerGeometry, built: Bool) {
        let requestPaneID = paneRequestStatus?.paneID
        if let cache = autoHidePointerCache, cache.generation == layoutGeneration, cache.requestPaneID == requestPaneID {
            return (cache, false)
        }
        autoHidePointerCacheBuilds += 1
        let presentation = state.presentation
        var panes: [AutoHidePointerPane]?
        if presentation == .autoHide {
            let frames = state.frames(in: bounds)
            panes = state.panes.compactMap { pane in
                frames[pane.id].map { frame in
                    AutoHidePointerPane(id: pane.id, hasTabs: !pane.tabs.isEmpty, frame: frame,
                                        collapsedBand: BTRect(x: frame.minX, y: frame.minY, width: frame.size.width, height: 6),
                                        revealedBand: BTRect(x: frame.minX, y: frame.minY, width: frame.size.width,
                                                             height: presentation.barHeight))
                }
            }
        }
        let inputAreas = (panes ?? []).filter(\.hasTabs).map { $0.id == requestPaneID ? $0.frame : $0.revealedBand }
        let geometry = AutoHidePointerGeometry(generation: layoutGeneration, requestPaneID: requestPaneID,
                                               panes: panes, inputAreas: inputAreas)
        autoHidePointerCache = geometry
        return (geometry, true)
    }

    /// Observe the band without placing an input panel over the window's controls.
    func queueAutoHidePointer(at point: BTPoint) {
        guard !spaceChangeSuspended, state.presentation == .autoHide else { return }
        pointerSamples.submit(point)
    }

    func flushAutoHidePointer() { pointerSamples.flush() }

    func updateAutoHidePointer(at point: BTPoint) {
        guard !spaceChangeSuspended else { return }
        let (geometry, built) = autoHidePointerGeometry()
        guard let geometryPanes = geometry.panes else { return }
        let dividerDragging = dividerIsDragging()
        // Outside every input area no strip is under the pointer, so a sample only ends hovers.
        // A new geometry always gets one full pass, so every panel's input matches it.
        if !built, !geometry.inputAreas.contains(where: { $0.contains(point) }),
           !autoHideHoverEnds(geometryPanes, dividerDragging: dividerDragging) { return }
        autoHidePointerPasses += 1
        for pane in geometryPanes {
            guard let panel = panes[pane.id] else { continue }
            let priority = pane.hasTabs && (autoHideResizePriority(at: point, frame: pane.frame) || dividerDragging)
            if panel.ignoresMouseEvents != priority { panel.ignoresMouseEvents = priority }
            guard pane.hasTabs else { continue }
            let revealed = barVisibility[pane.id]?.isRevealed == true || (panel.contentView as? TabbedPaneView)?.isAutoHideCollapsing(at: now) == true
            let area = revealed ? pane.revealedBand : pane.collapsedBand
            hoverPane(pane.id, inside: panel.isVisible && area.contains(point) && !priority)
        }
    }

    /// Whether `hoverPane(_:inside: false)` would change any pane's visibility.
    private func autoHideHoverEnds(_ geometryPanes: [AutoHidePointerPane], dividerDragging: Bool) -> Bool {
        let time = now
        return geometryPanes.contains { pane in
            guard pane.hasTabs else { return false }
            let visibility = barVisibility[pane.id] ?? TabbedBarVisibility()
            var left = visibility
            left.setDividerDragging(dividerDragging)
            left.leave(at: time)
            return left != visibility
        }
    }

    private func autoHideResizePriority(at point: BTPoint, frame: BTRect) -> Bool {
        // Leave the narrow side lanes to divider handles and native resize corners.
        point.x < frame.minX + 7 || point.x >= frame.maxX - 7
    }

    fileprivate func trackPaneHover(_ id: UUID, inside: Bool) {
        if autoHidePointerMonitor != nil, let point = pointerLocation() { queueAutoHidePointer(at: point) }
        else { hoverPane(id, inside: inside) }
    }

    private func syncAutoHidePointer() {
        // After a display change, this refresh and the screen notification can arrive in either order.
        TabbedMainScreenFrame.invalidate()
        guard observesAutoHidePointer, state.presentation == .autoHide, !spaceChangeSuspended else {
            autoHidePointerMonitor = nil
            pointerSamples.cancel()
            for panel in panes.values { panel.ignoresMouseEvents = false }
            return
        }
        if autoHidePointerMonitor == nil {
            autoHidePointerMonitor = TabbedAutoHidePointerMonitor(sample: { [weak self] in
                guard let self, let point = self.pointerLocation() else { return }
                self.queueAutoHidePointer(at: point)
            }, flush: { [weak self] in self?.flushAutoHidePointer() })
        }
        if let point = pointerLocation() { updateAutoHidePointer(at: point) }
    }

    fileprivate func hoverPane(_ id: UUID, inside: Bool) {
        guard !spaceChangeSuspended, state.presentation == .autoHide else { return }
        let previous = barVisibility[id] ?? TabbedBarVisibility()
        var visibility = previous
        let wasRevealed = visibility.isRevealed
        visibility.setDividerDragging(dividerIsDragging())
        if inside {
            let reversing = (panes[id]?.contentView as? TabbedPaneView)?.isAutoHideCollapsing(at: now) == true
            visibility.enter(at: now, revealImmediately: reversing)
        } else { visibility.leave(at: now) }
        guard visibility != previous else { return }
        barVisibility[id] = visibility
        if wasRevealed != visibility.isRevealed { updateBar(id) }
        scheduleVisibility()
    }

    fileprivate func holdBar(_ id: UUID, _ reason: TabbedBarVisibility.Hold, enabled: Bool) {
        guard !spaceChangeSuspended else { return }
        guard state.presentation == .autoHide else {
            if reason == .keyboard { updateBar(id) }
            return
        }
        if reason == .selection {
            if enabled { selectionPanes.insert(id) } else { selectionPanes.remove(id) }
        }
        var visibility = barVisibility[id] ?? TabbedBarVisibility()
        visibility.setDividerDragging(dividerIsDragging())
        visibility.hold(reason, enabled: enabled, at: now)
        barVisibility[id] = visibility
        updateBar(id)
        scheduleVisibility()
    }

    private func scheduleVisibility() {
        guard !spaceChangeSuspended else { return }
        syncVisibilityEscape()
        visibilityTask?.cancel()
        var deadlines = barVisibility.values.compactMap(\.nextDeadline)
        deadlines += panes.values.compactMap { ($0.contentView as? TabbedPaneView)?.autoHideAnimationDeadline }
        // Poll only while a press hold can outlive its lost mouse-up.
        if !selectionPanes.isEmpty { deadlines.append(now + 0.050) }
        guard automaticallyAdvanceVisibility, let deadline = deadlines.min() else { return }
        let delay = max(0, deadline - now)
        let clock = timerClock
        visibilityTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.advanceBarVisibility()
        }
    }

    /// Uses the injected monotonic clock; tests advance without wall-clock sleeps.
    func advanceBarVisibility() {
        guard !spaceChangeSuspended else { return }
        if !selectionPanes.isEmpty, !primaryButtonIsPressed() {
            for id in selectionPanes { barVisibility[id]?.hold(.selection, enabled: false, at: now) }
            selectionPanes.removeAll()
        }
        for id in barVisibility.keys {
            barVisibility[id]?.setDividerDragging(dividerIsDragging())
            barVisibility[id]?.advance(to: now)
            updateBar(id)
        }
        scheduleVisibility()
    }

    private func syncVisibilityEscape() {
        let revealed = state.presentation == .autoHide && barVisibility.values.contains { $0.isRevealed }
        if revealed, visibilityGlobalMonitor == nil, visibilityLocalMonitor == nil {
            visibilityGlobalMonitor = addGlobalKeyMonitor { [weak self] key in
                if key == 53 { self?.dismissBars() }
            }
            visibilityLocalMonitor = addLocalKeyMonitor { [weak self] key in
                guard key == 53, self?.isInteracting != true else { return false }
                // Local monitors run before the chooser's field editor. Let its responder
                // chain cancel composition, clear search, or close without hiding the bars.
                // Every display's monitor must yield, including bars without this chooser.
                // This panel type covers today's Tabbed gallery and popup searches. Other
                // popup searches are Settings sheets, outside the pane/auto-hide hosting path.
                guard !(NSApp.keyWindow is TabbedChooserPanel) else { return false }
                self?.dismissBars()
                return true
            }
        } else if !revealed {
            if let visibilityGlobalMonitor { removeMonitor(visibilityGlobalMonitor) }
            if let visibilityLocalMonitor { removeMonitor(visibilityLocalMonitor) }
            visibilityGlobalMonitor = nil
            visibilityLocalMonitor = nil
        }
    }

    private func dismissBars() {
        onDismissApplicationPicker?()
        gallery?.cancel()
        if isInteracting { cancelInteraction() }
        endKeyboardFocus(returning: true)
        selectionPanes.removeAll()
        for id in barVisibility.keys { barVisibility[id]?.dismiss(); updateBar(id, animated: false) }
        scheduleVisibility()
    }

    private func chromeFrame(for pane: TabbedPane, frame: BTRect) -> BTRect {
        guard !pane.tabs.isEmpty, paneRequestStatus?.paneID != pane.id else { return frame }
        if state.presentation == .autoHide {
            return BTRect(x: frame.minX, y: frame.minY, width: frame.size.width,
                          height: barVisibility[pane.id]?.isRevealed == true || (panes[pane.id]?.contentView as? TabbedPaneView)?.autoHideAnimationDeadline != nil
                            ? state.presentation.barHeight : 6)
        }
        return BTRect(x: frame.minX, y: frame.minY, width: frame.size.width, height: state.presentation.barHeight)
    }

    private func updateBar(_ id: UUID, ordering: Bool = true, animated: Bool = true) {
        guard !ordering || !spaceChangeSuspended else { return }
        guard let pane = state.panes.first(where: { $0.id == id }), let frame = state.frames(in: bounds)[id],
              let panel = panes[id], let view = panel.contentView as? TabbedPaneView else { return }
        view.presentation = state.presentation
        let collapsed = state.presentation == .autoHide && !pane.tabs.isEmpty && barVisibility[id]?.isRevealed != true
        // The selected window can rise above a visible strip without a focus event.
        // Restore the validated anchor before the revealed strip overlaps that window.
        if ordering, panel.level == .normal, view.collapsed, !collapsed, let anchor = paneAnchors[id] {
            orderPanel(panel, .above, anchor)
        }
        view.setAutoHideCollapsed(collapsed,
                                  at: now, animated: animated && ordering && !spaceChangeSuspended && !dividerIsDragging() && !pane.tabs.isEmpty)
        if pane.tabs.isEmpty { panel.ignoresMouseEvents = false }
        view.keyboardTab = keyboardPaneID == id ? keyboardTab : nil
        let logicalChrome = chromeFrame(for: pane, frame: frame)
        let chrome = appKit(logicalChrome)
        view.setChromeSize(chrome.size)
        if panel.frame != chrome { panel.setFrame(chrome, display: false) }
        if ordering, panel.level == .floating {
            if obscuringFrames.contains(where: { $0.intersection(logicalChrome) != nil }) { panel.orderOut(nil) }
            else if !panel.isVisible { panel.orderFrontRegardless() }
        } else if ordering, !panel.isVisible, let anchor = paneAnchors[id] {
            orderPanel(panel, .above, anchor)
        }
        // Ordering can enlarge a borderless panel to 10 points.
        if panel.frame != chrome { panel.setFrame(chrome, display: false) }
        view.needsDisplay = true
        view.updateToolTips()
        view.updateAccessibility()
    }

    public private(set) var showTabBarFailureReason: String?

    /// Takes key focus without activating BetterTile or changing app windows.
    @discardableResult public func showTabBar() -> Bool {
        showTabBarFailureReason = "The tab bar is not available right now."
        guard !spaceChangeSuspended else { return false }
        guard !dividerIsDragging() else {
            showTabBarFailureReason = "Finish the divider drag first."
            return false
        }
        guard let panel = panes[state.activePaneID],
              let view = panel.contentView as? TabbedPaneView else { return false }
        guard panel.isVisible else {
            showTabBarFailureReason = "The tab bar is covered by another window."
            return false
        }
        endKeyboardFocus(returning: false)
        keyboardPaneID = state.activePaneID
        keyboardTab = state.activeWindowID
        holdBar(state.activePaneID, .keyboard, enabled: true)
        guard panel.isVisible else {
            endKeyboardFocus(returning: false)
            showTabBarFailureReason = "The tab bar is covered by another window."
            return false
        }
        (panel as? TabbedStripPanel)?.allowsKeyboardFocus = true
        panel.makeKey()
        panel.makeFirstResponder(view)
        showTabBarFailureReason = nil
        return true
    }

    fileprivate func handleBarKey(_ keyCode: UInt16) -> Bool {
        guard let paneID = keyboardPaneID, let pane = state.panes.first(where: { $0.id == paneID }) else { return false }
        switch keyCode {
        case 123, 124, 125, 126:
            guard !pane.tabs.isEmpty else { return true }
            let index = keyboardTab.flatMap { pane.tabs.firstIndex(of: $0) } ?? 0
            keyboardTab = pane.tabs[(index + ([123, 126].contains(keyCode) ? -1 : 1) + pane.tabs.count) % pane.tabs.count]
            updateBar(paneID)
            if let view = panes[paneID]?.contentView { NSAccessibility.post(element: view, notification: .valueChanged) }
        case 36, 76:
            let selected = keyboardTab
            endKeyboardFocus(returning: false)
            if let selected { send(.select(selected)) }
        case 53: endKeyboardFocus(returning: true)
        default: return false
        }
        return true
    }

    private func endKeyboardFocus(returning: Bool) {
        guard let id = keyboardPaneID else { return }
        keyboardPaneID = nil
        keyboardTab = nil
        (panes[id] as? TabbedStripPanel)?.allowsKeyboardFocus = false
        // AppKit releases key focus on orderOut; updateBar restores the validated stack anchor.
        if panes[id]?.isKeyWindow == true { panes[id]?.orderOut(nil) }
        if returning {
            selectionPanes.remove(id)
            barVisibility[id]?.dismiss()
        } else { barVisibility[id]?.hold(.keyboard, enabled: false, at: now) }
        updateBar(id, animated: !returning)
        scheduleVisibility()
        if returning, let selected = state.panes.first(where: { $0.id == id })?.selected { send(.select(selected)) }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        if let menuPaneID { holdBar(menuPaneID, .menu, enabled: true) }
    }
    public func menuDidClose(_ menu: NSMenu) {
        if let menuPaneID {
            hoverPane(menuPaneID, inside: panes[menuPaneID]?.frame.contains(NSEvent.mouseLocation) == true)
            holdBar(menuPaneID, .menu, enabled: false)
        }
        menuPaneID = nil
    }


    public override convenience init() {
        self.init(addGlobalKeyMonitor: { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode
                MainActor.assumeIsolated { handler(keyCode) }
            }
        }, primaryButtonIsPressed: { NSEvent.pressedMouseButtons & 1 != 0 }, observesAutoHidePointer: true,
        pointerLocation: {
            // Without a screen there is no pointer position; the drag falls
            // back to its last sampled point.
            TabbedMainScreenFrame.current.map {
                CoordinateConverter.pointToTopLeft(NSEvent.mouseLocation, mainScreenFrame: $0)
            }
        })
    }

    init(
        dragTicks: ResizeDisplayLink = ResizeDisplayLink(),
        pointerTicks: ResizeDisplayLink = ResizeDisplayLink(),
        panelFactory: @escaping () -> NSPanel = {
            TabbedStripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        },
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
        orderPanel: @escaping (NSPanel, NSWindow.OrderingMode, Int) -> Void = { $0.order($1, relativeTo: $2) },
        primaryButtonIsPressed: @escaping () -> Bool = { true },
        observesAutoHidePointer: Bool = false,
        visibilityClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        timerClock: BetterTileClock = .live,
        automaticallyAdvanceVisibility: Bool = true,
        pointerLocation: @escaping () -> BTPoint? = { nil }
    ) {
        self.panelFactory = panelFactory
        self.observesAutoHidePointer = observesAutoHidePointer
        self.visibilityClock = visibilityClock
        self.timerClock = timerClock
        self.automaticallyAdvanceVisibility = automaticallyAdvanceVisibility
        galleryPreview = PlacementWireframeController(panelFactory: panelFactory)
        self.primaryButtonIsPressed = primaryButtonIsPressed
        self.pointerLocation = pointerLocation
        self.dragTicks = dragTicks
        self.pointerTicks = pointerTicks
        self.addGlobalKeyMonitor = addGlobalKeyMonitor
        self.addLocalKeyMonitor = addLocalKeyMonitor
        self.removeMonitor = removeMonitor
        self.orderPanel = orderPanel
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(stripResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
    }

    @objc private func stripResignedKey(_ notification: Notification) {
        guard let id = keyboardPaneID, let panel = notification.object as? NSPanel, panes[id] === panel else { return }
        endKeyboardFocus(returning: false)
    }

    /// `selectedWindowNumbers` holds validated WindowServer numbers of the
    /// panes' selected windows. With a number, a pane's chrome joins the
    /// normal window stack beside that window, so a window in front of the
    /// selected tab also covers its strip. Without one, chrome floats and
    /// hides only under `obscuringFrames`. It also holds the number of the
    /// curtain anchor when that is not a selected tab.
    public func refresh(state: TabbedLayoutState, bounds: BTRect, windows: [WindowSnapshot], obscuringFrames: [BTRect] = [], canUndo: Bool = false, selectedWindowNumbers: [WindowID: Int] = [:], curtainAnchorWindowNumber: Int? = nil) {
        spaceChangeSuspended = false
        if let id = applicationPickerPaneID, !state.panes.contains(where: { $0.id == id }) || self.bounds != bounds {
            onDismissApplicationPicker?()
        }
        if self.state != state || self.bounds != bounds { gallery?.cancel() }
        if isDropPending, self.state != state || self.bounds != bounds { completeDrop() }
        if isInteracting, self.state != state || self.bounds != bounds { cancelInteraction() }
        if self.state.presentation != state.presentation {
            endKeyboardFocus(returning: false)
            barVisibility.removeAll()
            selectionPanes.removeAll()
            visibilityTask?.cancel()
        }
        self.state = state
        if let id = applicationPickerPaneID { holdBar(id, .applicationPicker, enabled: true) }
        self.bounds = bounds
        self.canUndo = canUndo
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        self.obscuringFrames = obscuringFrames
        let frames = state.frames(in: bounds)
        let numbers = selectedWindowNumbers.filter { $0.value > 0 }
        // An empty pane has no window of its own. It sits above the active
        // pane's selected tab, which is normally the front of the layout.
        let emptyPaneAnchor = ([state.activeWindowID].compactMap { $0 } + state.selectedWindowIDs)
            .lazy.compactMap { numbers[$0] }.first
        for id in panes.keys.filter({ frames[$0] == nil }) {
            if keyboardPaneID == id { endKeyboardFocus(returning: false) }
            barVisibility.removeValue(forKey: id)
            selectionPanes.remove(id)
            paneAnchors.removeValue(forKey: id)
            let panel = panes.removeValue(forKey: id)
            (panel?.contentView as? TabbedPaneView)?.content.removeAllToolTips()
            panel?.orderOut(nil)
        }
        revealedPane = nil
        let emptyPaneGlyph = state.panes.contains { $0.tabs.isEmpty }
            ? TabbedLayoutGallery.currentPreset(for: state).map(LayoutGlyph.layout) ?? .layouts : .layouts
        for (index, pane) in state.panes.enumerated() {
            guard let frame = frames[pane.id] else { continue }
            let panel = panes[pane.id] ?? makePanel(automaticAnimation: true)
            let view = panel.contentView as? TabbedPaneView ?? TabbedPaneView()
            let animateBar = panel.contentView === view && view.presentation == state.presentation
                && !view.pane.tabs.isEmpty && !pane.tabs.isEmpty && view.bounds.width == frame.size.width
            view.overlayAppearance = overlayAppearance
            view.owner = self
            view.pane = pane
            view.content.setRequestStatus(paneRequestStatus?.paneID == pane.id ? paneRequestStatus : nil)
            view.number = index + 1
            view.content.layoutGlyph = emptyPaneGlyph
            view.active = state.activePaneID == pane.id
            view.presentation = state.presentation
            view.setAutoHideCollapsed(state.presentation == .autoHide && !pane.tabs.isEmpty && barVisibility[pane.id]?.isRevealed != true,
                                      at: now, animated: animateBar)
            view.keyboardTab = keyboardPaneID == pane.id ? keyboardTab : nil
            view.titles = pane.tabs.map(tabTitle)
            view.icons = pane.tabs.map { id in
                guard let bundleID = self.windows[id]?.bundleIdentifier else { return nil }
                if let cached = applicationIcons[bundleID] { return cached }
                let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) }
                applicationIcons[bundleID] = .some(icon)
                return icon
            }
            if panel.contentView !== view { panel.contentView = view }
            let chrome = chromeFrame(for: pane, frame: frame)
            let chromeFrame = appKit(chrome)
            view.setChromeSize(chromeFrame.size)
            if panel.frame != chromeFrame { panel.setFrame(chromeFrame, display: true) }
            view.needsDisplay = true
            view.updateAccessibility()
            view.updateToolTips()
            view.setAccessibilityLabel("Pane \(index + 1)\(pane.tabs.isEmpty ? ", empty" : "")")
            let anchor = pane.selected.flatMap { numbers[$0] } ?? (pane.tabs.isEmpty ? emptyPaneAnchor : nil)
            if let reveal = requestRevealNumber, paneRequestStatus?.paneID == pane.id {
                revealedPane = (pane.id, anchor)
                paneAnchors.removeValue(forKey: pane.id)
                panel.level = .normal
                orderPanel(panel, .below, reveal)
            } else {
                orderPane(pane.id, panel: panel, anchor: anchor, chrome: chrome)
            }
            // First ordering can enlarge a borderless panel to 10 points.
            if panel.frame != chromeFrame { panel.setFrame(chromeFrame, display: false) }
            panes[pane.id] = panel
        }
        let hasSelectedIdentities = !state.selectedWindowIDs.isEmpty
            && state.selectedWindowIDs.allSatisfy { numbers[$0] != nil }
        let anchor = curtainAnchorWindowNumber.flatMap { number in
            // The anchor is a selected tab or a floating window kept in place
            // with them; either way it needs a validated number.
            hasSelectedIdentities && numbers.values.contains(number) ? number : nil
        }
        refreshCurtain(anchor: anchor, identitiesValid: hasSelectedIdentities)
        refreshDividerControls()
        syncAutoHidePointer()
        scheduleVisibility()
    }

    /// Confirmed lifecycle evidence can update a retained desktop without ordering
    /// any surface onto the current Space or touching an application window.
    public func removeUnavailableWindows(_ ids: Set<WindowID>) {
        let removed = state.windowIDs.union(state.floatingWindowIDs).intersection(ids)
        guard !removed.isEmpty else { return }
        let selectedWasRemoved = !Set(state.selectedWindowIDs).isDisjoint(with: removed)
        for id in removed { state.removeClosedWindow(id); windows.removeValue(forKey: id) }
        for (index, pane) in state.panes.enumerated() {
            guard let view = panes[pane.id]?.contentView as? TabbedPaneView else { continue }
            view.setAccessibilityLabel("Pane \(index + 1)\(pane.tabs.isEmpty ? ", empty" : "")")
            let previous = view.pane.tabs
            let icons = view.icons
            view.pane = pane
            view.active = state.activePaneID == pane.id
            view.titles = pane.tabs.map(tabTitle)
            view.icons = pane.tabs.map { id in
                previous.firstIndex(of: id).flatMap { icons.indices.contains($0) ? icons[$0] : nil }
            }
            if selectedWasRemoved {
                paneAnchors.removeValue(forKey: pane.id)
                if revealedPane?.id == pane.id { revealedPane?.anchor = nil }
            }
            updateBar(pane.id, ordering: false)
        }
        // The replacement selected tab has not had its stacking order verified.
        if selectedWasRemoved {
            curtain?.orderOut(nil)
            needsCurtainVerification = false
            curtainHolds = 0
        }
    }

    /// WindowServer numbers of this overlay's panels, which Tabbed's stacking
    /// repair must not treat as application windows.
    public var windowNumbers: Set<Int> {
        let panels = Array(panes.values) + [curtain].compactMap { $0 } + Array(dividerControls.values) + [preview, floatTarget, draggedTabPanel].compactMap { $0 }
        return Set(panels.map(\.windowNumber).filter { $0 > 0 })
    }

    /// Hides a curtain kept over an order that could not be verified.
    public func releaseUnverifiedCurtain() {
        guard needsCurtainVerification else { return }
        needsCurtainVerification = false
        curtainHolds = 0
        curtain?.orderOut(nil)
    }

    public func hide() {
        pointerSamples.cancel()
        autoHidePointerMonitor = nil
        autoHidePointerCache = nil
        onDismissApplicationPicker?()
        gallery?.cancel()
        previewLayoutGallery(nil, grouping: .keepTabGroups)
        endKeyboardFocus(returning: false)
        visibilityTask?.cancel()
        barVisibility.removeAll()
        selectionPanes.removeAll()
        paneAnchors.removeAll()
        revealedPane = nil
        obscuringFrames.removeAll()
        syncVisibilityEscape()
        needsCurtainVerification = false
        curtainHolds = 0
        curtainBounds = nil
        cancelInteraction()
        for panel in Array(panes.values) + Array(dividerControls.values) + [curtain].compactMap({ $0 }) {
            if let view = panel.contentView as? TabbedPaneView {
                view.setAutoHideCollapsed(state.presentation == .autoHide && !view.pane.tabs.isEmpty, at: now, animated: false)
                view.content.removeAllToolTips()
            }
            panel.orderOut(nil)
        }
        curtain = nil
    }

    /// The caller verifies all selected windows are above inactive tabs, then
    /// supplies the exact number of the backmost selected window.
    private func refreshCurtain(anchor: Int?, identitiesValid: Bool) {
        guard let anchor, anchor > 0 else {
            // Right after an application activates, or while a selection
            // changes, the window order often reads back stale for a moment.
            // Removing the curtain then exposes every hidden tab at once;
            // keeping it is never worse, and the caller verifies the order
            // again shortly.
            if identitiesValid, curtain?.isVisible == true, curtainBounds == bounds,
               curtainHolds < Self.maximumCurtainHolds {
                curtainHolds += 1
                needsCurtainVerification = true
                return
            }
            needsCurtainVerification = false
            curtainHolds = 0
            curtain?.orderOut(nil)
            return
        }
        needsCurtainVerification = false
        curtainHolds = 0
        curtainBounds = bounds
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
        if panel.contentView !== view { panel.contentView = view }
        let frame = appKit(bounds)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        updateCurtainExclusions(view)
        orderPanel(panel, .below, anchor)
        curtain = panel
    }

    private func updateCurtainExclusions(_ view: TabbedCurtainView) {
        let frames = state.frames(in: bounds)
        view.excludedStrips = state.panes.compactMap { pane in
            guard state.presentation != .autoHide, !pane.tabs.isEmpty, let frame = frames[pane.id] else { return nil }
            return NSRect(x: frame.minX - bounds.minX, y: frame.minY - bounds.minY,
                          width: frame.size.width, height: state.presentation.reservedInset)
        }
    }

    private func refreshDividerControls() {
        let dividers = state.dividers(in: bounds)
        let ids = Set(dividers.compactMap(\.branchID))
        for id in dividerControls.keys where !ids.contains(id) { dividerControls.removeValue(forKey: id)?.orderOut(nil) }
        for divider in dividers {
            guard let branchID = divider.branchID, let parent = divider.parentBounds else { continue }
            let panel = dividerControls[branchID] ?? makePanel(automaticAnimation: true)
            panel.ignoresMouseEvents = true
            let view = panel.contentView as? TabbedDividerAccessibilityView ?? TabbedDividerAccessibilityView()
            view.onAdjust = { [weak self] delta in self?.send(.adjustDivider(branchID, by: delta)) }
            let extent = divider.axis == .vertical ? parent.size.width : parent.size.height
            let start = divider.axis == .vertical ? parent.minX : parent.minY
            view.setAccessibilityValue(((divider.coordinate - start) / max(1, extent) * 100).rounded())
            if panel.contentView !== view { panel.contentView = view }
            let gap = TabbedLayoutState.gap
            let frame = divider.axis == .vertical
                ? BTRect(x: divider.coordinate - gap / 2, y: divider.spanStart, width: gap, height: divider.spanEnd - divider.spanStart)
                : BTRect(x: divider.spanStart, y: divider.coordinate - gap / 2, width: divider.spanEnd - divider.spanStart, height: gap)
            let controlFrame = appKit(frame)
            if panel.frame != controlFrame { panel.setFrame(controlFrame, display: false) }
            // A divider drag refreshes on every display tick. These panels
            // draw nothing, so ordering them once is enough.
            if !panel.isVisible { panel.orderFrontRegardless() }
            dividerControls[branchID] = panel
        }
    }

    /// A resize changes geometry only. Keep panel ordering and content views
    /// intact, and let AppKit draw the changes together after this tick.
    public func refreshResize(state: TabbedLayoutState, bounds: BTRect) {
        gallery?.cancel()
        if isDropPending, self.state != state || self.bounds != bounds { completeDrop() }
        if isInteracting, self.state != state || self.bounds != bounds { cancelInteraction() }
        self.state = state
        self.bounds = bounds
        for pane in state.panes { updateBar(pane.id) }
        if let curtain {
            let frame = appKit(bounds)
            if curtain.frame != frame { curtain.setFrame(frame, display: false) }
        }
        if let view = curtain?.contentView as? TabbedCurtainView { updateCurtainExclusions(view) }
        refreshDividerControls()
    }

    private func makePanel(automaticAnimation: Bool = false) -> NSPanel {
        let panel = panelFactory()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Retained Space strips keep AppKit's default animation; other panels do not animate.
        panel.animationBehavior = automaticAnimation && keepsPanelsOnSpace ? .default : .none
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        if keepsPanelsOnSpace { panel.collectionBehavior.remove(.moveToActiveSpace) }
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

    /// Sends a press's selection. It owns the drag block only when no other
    /// placement already held it.
    fileprivate func selectOnPress(_ id: WindowID) {
        pressSelection = acceptsTabDrags ? id : nil
        send(.select(id))
    }

    /// Another action is queued behind the current placement, so a drag
    /// blocked now no longer waits only for a press's own selection.
    public func yieldPressSelection() { pressSelection = nil }

    /// The model rejected the selection of `id` before any placement
    /// started. The strip that shows `id` as pressed shows its confirmed
    /// selection again at once. Other strips keep their pressed tabs.
    public func dropPressedSelection(of id: WindowID) {
        if pressSelection == id { pressSelection = nil }
        for panel in panes.values {
            guard let view = panel.contentView as? TabbedPaneView, view.displayedSelection == id else { continue }
            view.dropPressedSelection()
        }
    }

    func menu(pane: TabbedPane, windowID: WindowID?) -> NSMenu {
        menuPaneID = pane.id
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        @discardableResult
        func item(_ title: String, _ intent: TabbedUIIntent, enabled: Bool = true, selected: Bool = false, in menu: NSMenu) -> NSMenuItem {
            let action = TabbedMenuAction { [weak self] in self?.send(intent) }
            let entry = NSMenuItem(title: title, action: #selector(TabbedMenuAction.invoke), keyEquivalent: "")
            entry.target = action
            entry.representedObject = action
            entry.isEnabled = enabled
            entry.state = selected ? .on : .off
            menu.addItem(entry)
            return entry
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
                let entry = item(title, .select(id), selected: pane.selected == id, in: menu)
                entry.toolTip = title
                if let bundleID = window?.bundleIdentifier {
                    entry.image = (applicationIcons[bundleID] ?? nil)?.copy() as? NSImage
                    entry.image?.size = NSSize(width: 16, height: 16)
                }
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
        let action = TabbedMenuAction { [weak self] in
            // Present after NSMenu finishes tracking, anchored to this pane.
            DispatchQueue.main.async { [weak self] in self?.showLayoutGallery(paneID: pane.id) }
        }
        let layout = NSMenuItem(title: "Layout Gallery…", action: #selector(TabbedMenuAction.invoke), keyEquivalent: "")
        layout.target = action
        layout.representedObject = action
        menu.addItem(layout)
        menu.addItem(.separator())
        item("Undo Layout Change", .undo, enabled: canUndo, in: menu)
        item("Repair Layout", .repair, in: menu)
        if pane.tabs.isEmpty && state.panes.count > 1 { item("Remove Empty Pane", .removePane(pane.id), in: menu) }
        return menu
    }

    public var onChooserVisibilityChange: (() -> Void)?
    public var hasLayoutGallery: Bool { gallery != nil }

    public func handleChooserMouseEvent(_ event: GlobalGestureEvent) {
        gallery?.presenter.handleMouseEvent(event)
    }

    func showLayoutGallery(paneID: UUID) {
        onDismissApplicationPicker?()
        guard acceptsTabDrags, !isInteracting, !isDropPending,
              let view = panes[paneID]?.contentView as? TabbedPaneView,
              view.window?.isVisible == true else { return }
        let chooser = makeLayoutGallery(paneID: paneID)
        let anchor = view.pane.tabs.isEmpty
            ? view.content.convert(view.content.galleryButton.frame, to: view) : view.strip.menuFrame
        chooser.show(relativeTo: anchor, of: view, paneFrame: paneFrameInAppKit(paneID))
    }

    func makeLayoutGallery(paneID: UUID? = nil,
                           presenterFactory: ((NSView, NSSize) -> TabbedChooserPresenter)? = nil) -> TabbedLayoutGallery {
        gallery?.cancel()
        let paneID = paneID ?? state.activePaneID
        holdBar(paneID, .gallery, enabled: true)
        let chooser = TabbedLayoutGallery(state: state, onPreview: { [weak self] preset, grouping in
            self?.previewLayoutGallery(preset, grouping: grouping)
        }, onApply: { [weak self] preset, grouping in
            self?.send(.preset(preset, grouping: grouping))
        }, appearance: overlayAppearance, presenterFactory: presenterFactory ?? chooserPresenterFactory)
        chooser.onDismiss = { [weak self] in
            self?.gallery = nil
            self?.holdBar(paneID, .gallery, enabled: false)
            self?.onChooserVisibilityChange?()
        }
        gallery = chooser
        onChooserVisibilityChange?()
        return chooser
    }

    func previewLayoutGallery(_ preset: TabbedPreset?, grouping: TabbedPresetGrouping) {
        guard let preset else {
            previewedGalleryState = nil
            galleryPreview.hide()
            return
        }
        var candidate = state
        candidate.applyPreset(preset, grouping: grouping)
        candidate = (try? candidate.fittingMinimumWidths(in: bounds, windows: Array(windows.values))) ?? candidate
        previewedGalleryState = candidate
        let frames = candidate.frames(in: bounds)
        galleryPreview.show(candidate.panes.compactMap { pane in
            frames[pane.id].map { Placement(windowID: WindowID(rawValue: "gallery-\(pane.id)"), frame: $0) }
        })
    }

    var hasActiveTabDrag: Bool { isInteracting && draggedWindow != nil }

    fileprivate func tabTitle(_ id: WindowID) -> String {
        guard let window = windows[id] else { return "Unavailable window" }
        return window.title.isEmpty ? (window.bundleIdentifier ?? "Window") : window.title
    }

    /// `atRelease` starts a drag blocked while its press's own selection
    /// settled, at the mouse-up itself; its drop is queued behind that
    /// selection.
    /// - Parameter reselecting: The tab the source pane showed before this
    ///   gesture's press selected `id`. Every drop intent carries it.
    fileprivate func beginDrag(_ id: WindowID, offset: NSPoint, atRelease: Bool = false,
                               reselecting: WindowID? = nil) -> Bool {
        flushAutoHidePointer()
        guard acceptsTabDrags || (atRelease && pressSelection == id), !isInteracting, !isDropPending else { return false }
        isInteracting = true
        for pane in state.panes { holdBar(pane.id, .drag, enabled: true) }
        cancelled = false
        draggedWindow = id
        dragReselecting = reselecting == id ? nil : reselecting
        dragOffset = offset
        installEscape()
        if let source = panes.values.compactMap({ $0.contentView as? TabbedPaneView })
            .first(where: { $0.pane.tabs.contains(id) }) {
            let proxy = makePanel()
            proxy.ignoresMouseEvents = true
            proxy.hasShadow = true
            let surface = tabbedGlassSurface(cornerRadius: 7, appearance: overlayAppearance)
            let index = source.pane.tabs.firstIndex(of: id) ?? 0
            let title = NSTextField(labelWithString: source.titles.indices.contains(index) ? source.titles[index] : "Window")
            title.lineBreakMode = .byTruncatingTail
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .labelColor
            let tabWidth = source.strip.tabFrame(source.content.renderedIndex(of: id) ?? 0).width
            title.frame = NSRect(x: 30, y: 9, width: max(0, tabWidth - 42), height: 17)
            title.autoresizingMask = [.width]
            surface.addSubview(title)
            if let index = source.pane.tabs.firstIndex(of: id), index < source.icons.count, let icon = source.icons[index] {
                let image = NSImageView(image: icon)
                image.frame = NSRect(x: 8, y: 10, width: 16, height: 16)
                surface.addSubview(image)
            }
            proxy.contentView = surface
            proxy.setContentSize(NSSize(width: tabWidth, height: state.presentation.barHeight))
            draggedTabPanel = proxy
            dragTicks.start(on: source) { [weak self] in self?.processDragTick() }
        }
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
        return true
    }

    /// Where a dragged real window under `point` joins a pane as a tab: a
    /// tab strip, at the tab edge nearest the pointer, or an empty pane.
    /// Nil anywhere else. The strip geometry is the one drawn now.
    public func tabDropZone(at point: BTPoint, dragging id: WindowID) -> TabbedDropZone? {
        let frames = state.frames(in: bounds)
        if state.presentation == .autoHide {
            for pane in state.panes {
                guard let frame = frames[pane.id] else { continue }
                let height = barVisibility[pane.id]?.isRevealed == true ? state.presentation.barHeight : 6
                let inside = point.y >= frame.minY && point.y < frame.minY + height
                    && frame.contains(point) && !autoHideResizePriority(at: point, frame: frame)
                hoverPane(pane.id, inside: inside)
            }
        }
        guard let pane = state.panes.first(where: { frames[$0.id]?.contains(point) == true }),
              let frame = frames[pane.id] else { return nil }
        guard !pane.tabs.isEmpty else { return TabbedDropZone(paneID: pane.id, index: nil, paneFrame: frame, indicator: nil) }
        // A pane's only tab dropped on its own strip changes nothing.
        guard pane.tabs != [id] else { return nil }
        guard !dividerIsDragging() else { return nil }
        if state.presentation == .autoHide, autoHideResizePriority(at: point, frame: frame) { return nil }
        let chrome = chromeFrame(for: pane, frame: frame)
        guard chrome.contains(point) else { return nil }
        let strip = (panes[pane.id]?.contentView as? TabbedPaneView)?.strip
            ?? TabbedStripLayout(width: chrome.size.width, count: pane.tabs.count, selectedIndex: nil, presentation: state.presentation)
        let insertion = strip.insertion(at: point.x - chrome.minX)
        let indicatorWidth = 6.0
        return TabbedDropZone(
            paneID: pane.id,
            index: pane.dropIndex(atEdge: insertion.index, in: pane.tabs, dragging: id),
            paneFrame: frame,
            indicator: BTRect(x: chrome.minX + insertion.x - indicatorWidth / 2, y: frame.minY + 4,
                              width: indicatorWidth, height: state.presentation.barHeight - 8))
    }

    private var floatFrame: BTRect { BTRect(x: bounds.midX - 95, y: bounds.maxY - 70, width: 190, height: 48) }

    fileprivate func queueDrag(to point: BTPoint) {
        guard isInteracting, !cancelled else { return }
        pendingDragPoint = point
    }

    private func processDragTick() {
        // AppKit can lose a mouse-up, for example when the pointer leaves the
        // strip panel during a fast drag. Finish where the preview last
        // showed the destination; never let the next drag complete this one.
        if draggedWindow != nil, !primaryButtonIsPressed() {
            if let point = pointerLocation() ?? pendingDragPoint ?? lastDragPoint { drag(to: point) }
            endDrag()
            return
        }
        guard let point = pendingDragPoint ?? lastDragPoint else { return }
        let hasSample = pendingDragPoint != nil
        pendingDragPoint = nil
        // The first frame establishes provisional strips before they scroll.
        let scrolled = scrollDraggedStrip(at: point)
        if hasSample || scrolled { drag(to: point) }
    }

    fileprivate func drag(to point: BTPoint) {
        guard let id = draggedWindow, !cancelled else { return }
        lastDragPoint = point
        dropIntent = nil
        var stripDestination: (UUID, Int)?
        var proxyY = point.y - dragOffset.y
        var highlight: BTRect?
        var destinationLabel = ""
        if floatFrame.contains(point) {
            dropIntent = .float(id, reselecting: dragReselecting)
            highlight = floatFrame
        } else {
            let frames = state.frames(in: bounds)
            for (index, pane) in state.panes.enumerated() {
                guard let frame = frames[pane.id], frame.contains(point) else { continue }
                let chrome = chromeFrame(for: pane, frame: frame)
                if point.y < frame.minY + state.presentation.barHeight, chrome.contains(point) {
                    let view = panes[pane.id]?.contentView as? TabbedPaneView
                    let strip = view?.dropStrip(for: id)
                        ?? TabbedStripLayout(width: chrome.size.width, count: pane.tabs.count, selectedIndex: nil, presentation: state.presentation)
                    // The strip draws the dragged tab where the preview put
                    // it, so an edge after that slot counts it once. Fitted
                    // tabs differ in width, so the committed index is not
                    // that slot, and using it flipped the preview each move.
                    let order = view?.dropOrder(for: id) ?? (pane.tabs.contains(id) ? pane.tabs : pane.tabs + [id])
                    let index = pane.dropIndex(atEdge: strip.insertion(at: point.x - chrome.minX).index,
                                               in: order, dragging: id)
                    dropIntent = .move(id, pane: pane.id, index: index, reselecting: dragReselecting)
                    stripDestination = (pane.id, index)
                    proxyY = frame.minY
                } else {
                    let content = state.windowArea(frame)
                    let edge: TabbedEdge?
                    if point.x < content.minX + 28 { edge = .left }
                    else if point.x > content.maxX - 28 { edge = .right }
                    else if point.y < content.minY + 28 { edge = .top }
                    else if point.y > content.maxY - 28 { edge = .bottom }
                    else { edge = nil }
                    if let edge, state.panes.count < TabbedLayoutState.maximumPaneCount {
                        dropIntent = .split(id, pane: pane.id, edge: edge, reselecting: dragReselecting)
                        destinationLabel = "Split \(edge.rawValue.capitalized) · Pane \(index + 1)"
                        highlight = BTRect(x: edge == .right ? content.midX : content.minX,
                                           y: edge == .bottom ? content.midY : content.minY,
                                           width: edge == .left || edge == .right ? content.size.width / 2 : content.size.width,
                                           height: edge == .top || edge == .bottom ? content.size.height / 2 : content.size.height)
                    } else if edge == nil {
                        dropIntent = .move(id, pane: pane.id, index: nil, reselecting: dragReselecting)
                        destinationLabel = "Move to Pane \(index + 1)"
                        highlight = content
                    }
                }
                break
            }
        }
        for (paneID, panel) in panes {
            guard let view = panel.contentView as? TabbedPaneView else { continue }
            var order = view.pane.tabs.filter { $0 != id }
            if let (target, index) = stripDestination, paneID == target {
                order.insert(id, at: min(index, order.count))
            }
            view.previewDrag(order: order, lifted: id)
        }
        if let proxy = draggedTabPanel {
            proxy.setFrameOrigin(appKit(BTRect(x: point.x - dragOffset.x, y: proxyY,
                                              width: proxy.frame.width, height: proxy.frame.height)).origin)
            if !proxy.isVisible { proxy.orderFrontRegardless() }
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
            let target = appKit(highlight)
            let changed = panel.frame != target
            if changed { panel.setFrame(target, display: false) }
            if let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first,
               changed || label.stringValue != destinationLabel {
                label.stringValue = destinationLabel
                label.isHidden = destinationLabel.isEmpty || highlight.size.width < 170 || highlight.size.height < 48
                label.frame = NSRect(x: 8, y: max(0, (highlight.size.height - 22) / 2), width: max(0, highlight.size.width - 16), height: 22)
            }
            let appeared = !panel.isVisible
            if appeared { panel.orderFrontRegardless() }
            preview = panel
            if appeared { draggedTabPanel?.orderFrontRegardless() }
        } else if preview?.isVisible == true { preview?.orderOut(nil) }
    }

    private func scrollDraggedStrip(at point: BTPoint) -> Bool {
        guard let id = draggedWindow, CACurrentMediaTime() >= nextScrollTime else { return false }
        let frames = state.frames(in: bounds)
        for (paneID, panel) in panes {
            guard let pane = state.panes.first(where: { $0.id == paneID }), let frame = frames[paneID],
                  point.y < frame.minY + state.presentation.barHeight,
                  chromeFrame(for: pane, frame: frame).contains(point),
                  let view = panel.contentView as? TabbedPaneView,
                  view.content.previewOrder != nil else { continue }
            if view.scrollDrag(at: point.x - chromeFrame(for: pane, frame: frame).minX, lifted: id) {
                nextScrollTime = CACurrentMediaTime() + 0.18
                return true
            }
        }
        return false
    }

    fileprivate func endDrag() {
        guard isInteracting else { return }
        let intent = cancelled ? nil : dropIntent
        let keepsOrder: Bool
        if case let .move(_, paneID, index?, _) = intent,
           let view = panes[paneID]?.contentView as? TabbedPaneView,
           let pane = state.panes.first(where: { $0.id == paneID }),
           let frame = state.frames(in: bounds)[paneID], let proxy = draggedTabPanel {
            let slot = view.strip.tabFrame(index)
            let destination = appKit(BTRect(x: chromeFrame(for: pane, frame: frame).minX + slot.minX, y: frame.minY,
                                           width: slot.width, height: slot.height))
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                proxy.setFrame(destination, display: false)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    proxy.animator().setFrame(destination, display: false)
                }
            }
            keepsOrder = true
        } else { keepsOrder = false }
        finishInteraction(preservingDrop: keepsOrder)
        if let intent { send(intent) }
        if onIntent == nil { completeDrop() }
    }

    public func cancelInteraction() {
        cancelled = true
        finishInteraction()
    }

    /// The model calls this after the placement succeeds, fails, or is rejected.
    /// Until then a released tab retains its destination instead of jumping back.
    public func completeDrop() {
        guard isDropPending else { return }
        clearDragPresentation()
    }

    private func clearDragPresentation() {
        isDropPending = false
        for id in barVisibility.keys { holdBar(id, .drag, enabled: false) }
        draggedTabPanel?.orderOut(nil)
        draggedTabPanel = nil
        for panel in panes.values { (panel.contentView as? TabbedPaneView)?.endDragPreview() }
    }

    private func finishInteraction(preservingDrop: Bool = false) {
        dragTicks.stop()
        lastDragPoint = nil
        pendingDragPoint = nil
        nextScrollTime = 0
        if preservingDrop { isDropPending = true }
        else { clearDragPresentation() }
        preview?.orderOut(nil); floatTarget?.orderOut(nil)
        preview = nil; floatTarget = nil
        if let globalKeyMonitor { removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        draggedWindow = nil; dragReselecting = nil; dropIntent = nil
        isInteracting = false
        if !preservingDrop { for id in barVisibility.keys { holdBar(id, .drag, enabled: false) } }
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

/// The main display's AppKit frame for pointer conversion. Pointer samples arrive on every mouse
/// move, so the frame is read again only after the display configuration changes.
@MainActor enum TabbedMainScreenFrame {
    private static var cached: NSRect??
    private static var observer: NSObjectProtocol?

    static var current: NSRect? {
        if let cached { return cached }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { cached = nil }
            }
        }
        let frame = NSScreen.screens.first?.frame
        cached = .some(frame)
        return frame
    }

    static func invalidate() { cached = nil }
}

/// Pointer-only observation. Hidden chrome never intercepts the window's title bar.
@MainActor private final class TabbedAutoHidePointerMonitor {
    private var tokens: [Any] = []
    init(sample: @escaping @MainActor () -> Void, flush: @escaping @MainActor () -> Void) {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated {
                sample()
                if event.type == .leftMouseDown || event.type == .rightMouseDown { flush() }
            }
        }) { tokens.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated {
                sample()
                if event.type == .leftMouseDown || event.type == .rightMouseDown { flush() }
            }
            return event
        }) { tokens.append(token) }
    }
    isolated deinit { tokens.forEach(NSEvent.removeMonitor) }
}

/// Only Show Tab Bar makes a strip key; pointer interaction remains nonactivating.
@MainActor class TabbedStripPanel: NSPanel {
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
}

/// One native frosted backdrop obscures inactive windows, including overflow
/// between panes. Strip cutouts affect decoration only; the full input surface
/// prevents clicks from reaching inactive tabs.
@MainActor final class TabbedCurtainView: NSView {
    var onClick: ((NSPoint) -> Void)?
    var excludedStrips: [NSRect] = [] { didSet { updateMask() } }
    let surface = OverlayGlassView()
    private let cutouts = CAShapeLayer()
    var overlayAppearance: OverlayAppearance {
        get { surface.overlayAppearance }
        set { surface.overlayAppearance = newValue }
    }
    var displayOptions: () -> (reduceTransparency: Bool, increaseContrast: Bool) {
        get { surface.displayOptions }
        set { surface.displayOptions = newValue }
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        surface.cornerRadius = 0
        surface.isCurtain = true
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        cutouts.fillRule = .evenOdd
        layer?.mask = cutouts
        setAccessibilityElement(false)
        updateMask()
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); updateMask() }

    func refreshAppearance() { surface.refreshAppearance() }

    private func updateMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        cutouts.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        // Match the actual strip glass. Its rounded corners stay covered so
        // inactive windows cannot show through the space outside the strip.
        for rect in excludedStrips { path.addRoundedRect(in: rect, cornerWidth: 7, cornerHeight: 7) }
        cutouts.path = path
        CATransaction.commit()
    }
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
    /// Content-fitted tabs never shrink below this width before the strip
    /// starts to hide tabs behind the overflow menu.
    static let minimumTabWidth = 88.0
    static let maximumTabWidth = 200.0

    let visibleRange: Range<Int>
    /// The widest visible tab.
    let tabWidth: Double
    let menuFrame: NSRect
    let addFrame: NSRect
    let hiddenCount: Int
    /// Leading edge and width of each visible tab, in visible order.
    let height: Double
    private let offsets: [Double]
    private let widths: [Double]

    /// - Parameter preferredWidths: Each tab's content-fitted width, in
    ///   rendered order. When given, tabs keep their own widths and pack from
    ///   the leading edge; when space runs out they compress toward
    ///   `minimumTabWidth`, and only then hide. Without it every visible tab
    ///   shares the available width.
    init(width: Double, count: Int, selectedIndex: Int?, startIndex: Int = 0, preferredWidths: [Double]? = nil, presentation: TabbedStripPresentation = .alwaysVisible) {
        height = presentation.barHeight
        menuFrame = NSRect(x: max(32, width - 42), y: 0, width: min(42, max(0, width - 32)), height: height)
        addFrame = NSRect(x: max(32, menuFrame.minX - 30), y: 0, width: min(30, max(0, menuFrame.minX - 32)), height: height)
        let available = max(0, addFrame.minX - 32)
        let minimum = presentation == .compact ? 56 : (preferredWidths == nil ? 110 : Self.minimumTabWidth)
        let visible = min(count, max(1, Int(available / minimum)))
        let selected = min(max(0, selectedIndex ?? 0), max(0, count - 1))
        let start = selectedIndex == nil ? min(max(0, count - visible), max(0, startIndex))
            : min(max(0, count - visible), max(selected - visible + 1, min(max(0, startIndex), selected)))
        visibleRange = start..<(start + visible)
        hiddenCount = count - visible
        var widths: [Double]
        if let preferredWidths, preferredWidths.count == count {
            let natural = visibleRange.map { min(Self.maximumTabWidth, max(minimum, preferredWidths[$0])) }
            let total = natural.reduce(0, +)
            if total <= available {
                widths = natural
            } else if Double(visible) * minimum < available {
                let spare = available - Double(visible) * minimum
                let excess = natural.reduce(0) { $0 + ($1 - minimum) }
                widths = natural.map { minimum + ($0 - minimum) * spare / max(1, excess) }
            } else {
                widths = Array(repeating: available / Double(max(1, visible)), count: visible)
            }
        } else {
            widths = Array(repeating: min(210, available / Double(max(1, visible))), count: visible)
        }
        if count == 0 { widths = [] }
        var offsets: [Double] = []
        var x = 32.0
        for width in widths { offsets.append(x); x += width }
        self.widths = widths
        self.offsets = offsets
        tabWidth = widths.max() ?? min(210, available)
    }

    func tabFrame(_ index: Int) -> NSRect {
        let slot = index - visibleRange.lowerBound
        guard widths.indices.contains(slot) else {
            let x = (offsets.last.map { $0 + (widths.last ?? 0) }) ?? 32
            return NSRect(x: x, y: 0, width: tabWidth, height: height)
        }
        return NSRect(x: offsets[slot], y: 0, width: widths[slot], height: height)
    }

    func closeFrame(_ index: Int) -> NSRect {
        let tab = tabFrame(index)
        let width = min(24, tab.width)
        return NSRect(x: tab.maxX - width, y: 0, width: width, height: height)
    }

    func tabIndex(at point: NSPoint) -> Int? {
        visibleRange.first { tabFrame($0).contains(point) }
    }

    /// The tab edge nearest `x`, as an insertion index and its position.
    func insertion(at x: Double) -> (index: Int, x: Double) {
        let edges = offsets + [(offsets.last ?? 32) + (widths.last ?? 0)]
        let nearest = edges.indices.min { abs(edges[$0] - x) < abs(edges[$1] - x) } ?? 0
        return (visibleRange.lowerBound + nearest, edges[nearest])
    }
}

/// Presentation only. The controller supplies monotonic time and schedules completion.
struct TabbedAutoHideAnimation {
    struct Sample {
        var height: Double
        var opacity: Double
    }
    let start: TimeInterval
    let revealing: Bool
    let from: Sample
    var duration: TimeInterval { revealing ? 0.160 : 0.120 }

    func sample(at now: TimeInterval) -> Sample {
        let elapsed = max(0, now - start)
        if revealing {
            let progress = min(1, elapsed / duration)
            let eased = 1 - pow(1 - progress, 3)
            let fade = min(1, max(0, (elapsed - 0.064) / 0.096))
            return Sample(height: from.height + (34 - from.height) * eased,
                          opacity: from.opacity + (1 - from.opacity) * fade)
        }
        // Fade first, then retract upward into the filled three-point line.
        let progress = min(1, max(0, (elapsed - 0.060) / 0.060))
        return Sample(height: from.height + (3 - from.height) * pow(progress, 3),
                      opacity: from.opacity * (1 - min(1, elapsed / 0.060)))
    }
}

/// A tab strip on real Liquid Glass. The glass is a background sibling that
/// only draws; the strip content above it handles every event in its own
/// coordinates, so clicks never depend on the glass view's internal layout.
@MainActor final class TabbedPaneView: NSView {
    let glass = OverlayGlassView()
    let content = TabbedPaneContentView()

    weak var owner: TabbedOverlayController? { didSet { content.owner = owner } }
    var pane: TabbedPane { get { content.pane } set { content.pane = newValue; refreshAppearance() } }
    var overlayAppearance = OverlayAppearance() { didSet { refreshAppearance() } }
    var number: Int { get { content.number } set { content.number = newValue } }
    var active: Bool { get { content.active } set { content.active = newValue; refreshAppearance() } }
    var titles: [String] { get { content.titles } set { content.titles = newValue } }
    var icons: [NSImage?] { get { content.icons } set { content.icons = newValue } }
    var presentation: TabbedStripPresentation = .alwaysVisible {
        didSet { content.presentation = presentation; refreshAppearance() }
    }
    var keyboardTab: WindowID? { get { content.keyboardTab } set { content.keyboardTab = newValue } }
    private(set) var collapsed = false
    private var autoHideAnimation: TabbedAutoHideAnimation?
    var autoHideAnimationDeadline: TimeInterval? { autoHideAnimation.map { $0.start + $0.duration } }

    func isAutoHideCollapsing(at now: TimeInterval) -> Bool {
        collapsed && autoHideAnimationDeadline.map { now < $0 } == true
    }

    /// The same clock-driven samples generate the compositor animation and its reversal.
    func autoHidePresentation(at now: TimeInterval) -> TabbedAutoHideAnimation.Sample {
        autoHideAnimation?.sample(at: now) ?? .init(height: collapsed ? 3 : 34, opacity: collapsed ? 0 : 1)
    }

    func setAutoHideCollapsed(_ value: Bool, at now: TimeInterval, animated: Bool) {
        let current = autoHidePresentation(at: now)
        let changed = value != collapsed
        collapsed = value
        if changed && animated && !reduceMotion() {
            autoHideAnimation = TabbedAutoHideAnimation(start: now, revealing: !value, from: current)
            installAutoHideAnimation()
        } else if !animated || reduceMotion() || autoHideAnimationDeadline.map({ now >= $0 }) == true {
            autoHideAnimation = nil
            layer?.mask = nil
            content.layer?.removeAnimation(forKey: "autoHideFade")
        }
        content.isHidden = collapsed && autoHideAnimation == nil
        refreshAppearance()
        needsDisplay = true
    }

    private lazy var chromeWidth = widthAnchor.constraint(equalToConstant: 0)
    private lazy var chromeHeight = heightAnchor.constraint(equalToConstant: 0)

    func setChromeSize(_ size: NSSize) {
        // Keep deferred AppKit layout from imposing a 10-point content minimum.
        translatesAutoresizingMaskIntoConstraints = false
        chromeWidth.constant = size.width
        chromeHeight.constant = size.height
        NSLayoutConstraint.activate([chromeWidth, chromeHeight])
        frame = NSRect(origin: .zero, size: size)
    }

    var strip: TabbedStripLayout { content.strip }
    func dropStrip(for id: WindowID) -> TabbedStripLayout { content.dropStrip(for: id) }
    func dropOrder(for id: WindowID) -> [WindowID] { content.dropOrder(for: id) }
    func previewDrag(order: [WindowID], lifted: WindowID) { content.previewDrag(order: order, lifted: lifted) }
    func endDragPreview() { content.endDragPreview() }
    func scrollDrag(at x: Double, lifted: WindowID) -> Bool { content.scrollDrag(at: x, lifted: lifted) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        content.wantsLayer = true
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

    override func viewDidChangeEffectiveAppearance() { refreshAppearance() }

    @objc private func accessibilityDisplayOptionsChanged() {
        if reduceMotion() { owner?.advanceBarVisibility() }
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        glass.frame = collapsed && autoHideAnimation == nil ? indicatorFrame : bounds
        content.frame = bounds
    }

    /// A three-point material line, with the same left and right edges as the window.
    var indicatorFrame: NSRect { NSRect(x: 0, y: 3, width: bounds.width, height: 3) }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var revealAnimationDuration: TimeInterval { reduceMotion() ? 0 : 0.160 }

    private func installAutoHideAnimation() {
        guard let transition = autoHideAnimation, let layer else { return }
        // Clip the full-size content. AppKit and managed window frames never interpolate.
        let mask = CAShapeLayer()
        func path(_ sample: TabbedAutoHideAnimation.Sample) -> CGPath {
            let fraction = (sample.height - 3) / 31
            return CGPath(roundedRect: NSRect(x: 0, y: 3 * (1 - fraction), width: bounds.width, height: sample.height),
                          cornerWidth: 1.5 + 5.5 * fraction, cornerHeight: 1.5 + 5.5 * fraction, transform: nil)
        }
        mask.path = path(transition.sample(at: transition.start + transition.duration))
        let animation = CAKeyframeAnimation(keyPath: "path")
        // Samples use cubic ease-out for reveal and cubic ease-in for collapse.
        animation.values = (0...60).map { path(transition.sample(at: transition.start + transition.duration * Double($0) / 60)) }
        animation.duration = transition.duration
        animation.calculationMode = .linear
        layer.mask = mask
        mask.add(animation, forKey: transition.revealing ? "autoHideReveal" : "autoHideCollapse")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = transition.from.opacity
        fade.toValue = transition.revealing ? 1 : 0
        fade.beginTime = CACurrentMediaTime() + (transition.revealing ? 0.064 : 0)
        fade.duration = transition.revealing ? 0.096 : 0.060
        fade.fillMode = transition.revealing ? .backwards : .both
        fade.isRemovedOnCompletion = transition.revealing
        content.layer?.add(fade, forKey: "autoHideFade")
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
        // A request panel covers the pane with text, so it uses the popup surface.
        glass.isPopup = content.requestStatusView != nil
        glass.setPopupContent(content.requestStatusView, fillsBounds: false)
        let hidden = collapsed && autoHideAnimation == nil
        glass.cornerRadius = hidden ? 1.5 : (pane.tabs.isEmpty ? 16 : 7)
        glass.frame = hidden ? indicatorFrame : bounds
        glass.showsBorder = !hidden
        let solid = !overlayAppearance.useLiquidGlass || displayOptions().reduceTransparency || displayOptions().increaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            glass.layer?.backgroundColor = hidden && dark && !solid ? NSColor.white.withAlphaComponent(0.15).cgColor : NSColor.clear.cgColor
            let strength = (dark ? 0.35 : 0.25) + (active ? 0.05 : 0)
            glass.solidColor = hidden ? NSColor.labelColor.withAlphaComponent(1).blended(withFraction: 1 - strength, of: NSColor.windowBackgroundColor.withAlphaComponent(1)) : nil
        }
        glass.alphaValue = hidden && !solid ? (active ? 0.75 : 0.60) : 1
        glass.overlayAppearance = overlayAppearance
        content.needsDisplay = true
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { content.needsDisplay = true } }
    }

    var stripLayout: TabbedStripLayout { content.strip }
    var displayedSelection: WindowID? { content.displayedSelection }
    func dropPressedSelection() { content.dropPressedSelection() }
    func updateToolTips() { content.updateToolTips() }
    func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityHelp("Use Show Tab Bar for keyboard navigation. Arrows move between tabs; Return selects; Escape returns to the app.")
        setAccessibilityValue(content.keyboardTab.flatMap { owner?.tabTitle($0) })
        if collapsed {
            let button = TabbedAccessibilityButton { [weak self] in
                guard let self else { return }
                owner?.send(.activate(pane.id))
                owner?.showTabBar()
            }
            button.setAccessibilityRole(.button)
            button.setAccessibilityEnabled(true)
            button.setAccessibilityLabel("Show tabs in pane \(number)")
            button.setAccessibilityParent(self)
            if let window { button.setAccessibilityFrame(window.frame) }
            setAccessibilityChildren([button])
        } else {
            var children: [Any] = content.accessibilityButtons(parent: self)
            children.append(content.addButton)
            if let statusView = content.requestStatusView { children.append(statusView) }
            else if pane.tabs.isEmpty { children.append(content.emptyAddButton); children.append(content.galleryButton) }
            setAccessibilityChildren(children)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { owner?.trackPaneHover(pane.id, inside: true) }
    override func mouseExited(with event: NSEvent) { owner?.trackPaneHover(pane.id, inside: false) }
    override func mouseDown(with event: NSEvent) {
        owner?.flushAutoHidePointer()
        if collapsed { owner?.holdBar(pane.id, .selection, enabled: true) }
        else { content.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { content.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { content.mouseUp(with: event); owner?.holdBar(pane.id, .selection, enabled: false) }
    override func rightMouseDown(with event: NSEvent) { content.rightMouseDown(with: event) }
    override func keyDown(with event: NSEvent) {
        if !content.handleKeyDown(event) { super.keyDown(with: event) }
    }
}

@MainActor class TabbedPaneContentView: NSView {
    #if BETTERTILE_TEST_HOOKS
    /// Counts actual backing-layer draws, including AppKit-driven invalidation.
    private(set) var drawCount = 0
    private(set) var tabDrawCounts: [WindowID: Int] = [:]
    #endif
    // AppKit does not retain tooltip owners; delayed callbacks still use them.
    private var toolTipOwners: [NSView.ToolTipTag: NSString] = [:]

    @discardableResult override func addToolTip(_ rect: NSRect, owner: Any, userData data: UnsafeMutableRawPointer?) -> NSView.ToolTipTag {
        let tag = super.addToolTip(rect, owner: owner, userData: data)
        toolTipOwners[tag] = owner as? NSString
        return tag
    }

    override func removeToolTip(_ tag: NSView.ToolTipTag) {
        super.removeToolTip(tag)
        toolTipOwners.removeValue(forKey: tag)
    }

    override func removeAllToolTips() {
        super.removeAllToolTips()
        toolTipOwners.removeAll()
    }

    isolated deinit {
        super.removeAllToolTips()
    }

    let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add App")!, target: nil, action: nil)
    // Overlay buttons draw themselves, so they look the same whether or not the pane is key.
    let emptyAddButton: NSButton = OverlayButton(title: "Open App", kind: .primary)
    let galleryButton: NSButton = OverlayButton(title: "Choose Layout", kind: .secondary)
    private var requestStatus: PaneRequestStatus?
    private(set) var requestStatusView: NSHostingView<PaneRequestStatusBody>?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let status = requestStatusView, let host = status.superview, host !== self {
            let local = convert(point, from: superview)
            if let target = status.hitTest(host.convert(local, from: self)) { return target }
        }
        return super.hitTest(point)
    }

    func setRequestStatus(_ status: PaneRequestStatus?) {
        guard requestStatus != status else { return }
        requestStatus = status
        if let status {
            let body = PaneRequestStatusBody(status: status) { [weak self] action in self?.owner?.onPaneRequestAction?(status.requestID, action) }
            if let requestStatusView { requestStatusView.rootView = body }
            else {
                let host = NSHostingView(rootView: body)
                requestStatusView = host
                addSubview(host)
            }
        } else {
            requestStatusView?.removeFromSuperview()
            requestStatusView = nil
        }
        (superview as? TabbedPaneView)?.refreshAppearance()
        needsLayout = true
        needsDisplay = true
    }
    weak var owner: TabbedOverlayController?
    var presentation: TabbedStripPresentation = .alwaysVisible {
        didSet { if presentation != oldValue { layoutTabs(animated: false); needsDisplay = true } }
    }
    var keyboardTab: WindowID? { didSet { if keyboardTab != oldValue { layoutTabs(animated: false); needsDisplay = true } } }
    private var barHeight: Double { presentation.barHeight }
    var pane = TabbedPane() {
        didSet {
            galleryButton.isHidden = requestStatus != nil || !pane.tabs.isEmpty || bounds.height < 90
            needsLayout = true
            if let pressed = pressedSelection, pane.selected == pressed || !pane.tabs.contains(pressed) { pressedSelection = nil }
            if pane != oldValue { layoutTabs(animated: false); needsDisplay = true }
        }
    }
    /// A pressed tab draws as selected at once, until the layout confirms
    /// the selection or a short timeout shows that it did not happen.
    private var pressedSelection: WindowID? {
        didSet {
            guard pressedSelection != oldValue else { return }
            if presentation == .compact {
                layoutTabs(animated: false)
                updateToolTips()
                (superview as? TabbedPaneView)?.updateAccessibility()
            }
            updateHover()
            redrawTabs()
            guard let pressed = pressedSelection else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.pressedSelection == pressed { self?.pressedSelection = nil }
            }
        }
    }
    var displayedSelection: WindowID? { pressedSelection ?? pane.selected }
    func dropPressedSelection() { pressedSelection = nil }
    var number = 1 { didSet { if number != oldValue { needsDisplay = true } } }
    /// The icon of the display's current layout, shown in an empty pane. The Layouts icon
    /// stands for a layout that is not one of the five presets.
    var layoutGlyph = LayoutGlyph.layouts { didSet { if layoutGlyph != oldValue, pane.tabs.isEmpty { needsDisplay = true } } }
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }
    var titles: [String] = [] { didSet { if titles != oldValue { layoutTabs(animated: false) }; redrawTabs() } }
    var icons: [NSImage?] = [] { didSet { redrawTabs() } }
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private var titleWidths: [String: Double] = [:]
    private let tabArea = TabbedTabView()
    private var tabViews: [WindowID: TabbedTabView] = [:]
    private(set) var previewOrder: [WindowID]?
    private var liftedTab: WindowID?
    private var initialVisibleIndex: Int?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var renderedOrder: [WindowID] { previewOrder ?? pane.tabs }
    private var downPoint: NSPoint?
    private var downTab: WindowID?
    private var downClose: WindowID?
    /// The tab a press already selected, so its release does not select again.
    private var selectedOnPress: WindowID?
    /// The tab this pane showed when that press selected another tab. A drag
    /// from the press carries it, so a drop out of the pane can show it again.
    private var selectionBeforePress: WindowID?
    /// True while a drag past the threshold waits for the selection its press
    /// started. A drag that started and was cancelled is not resumed.
    private var blockedDrag = false
    private var dragging = false
    private var attemptedDrag = false
    private struct HoverState: Equatable {
        var menu = false
        var tab: WindowID?
        var close: WindowID?
    }
    private var hoverState = HoverState()
    private var hoverPoint: NSPoint? { didSet { updateHover() } }

    /// Pointer coordinates are not visual state. Keep the backing layers clean
    /// until the menu, a tab capsule, or a close button changes its highlight.
    private func updateHover() {
        var next = HoverState()
        if let point = hoverPoint, bounds.contains(point) {
            next.menu = strip.menuFrame.contains(point)
            if tabArea.frame.contains(point) {
                for (id, view) in tabViews {
                    let local = view.convert(point, from: self)
                    guard view.bounds.contains(local) else { continue }
                    // Selection already shows the capsule, title and close
                    // symbol. Only its close-button background changes on hover.
                    if id != displayedSelection { next.tab = id }
                    let close = NSRect(x: view.bounds.maxX - 24, y: 0, width: 24, height: view.bounds.height)
                    if close.contains(local) { next.close = id }
                    break
                }
            }
        }
        let previous = hoverState
        guard next != previous else { return }
        hoverState = next
        if next.menu != previous.menu { setNeedsDisplay(strip.menuFrame) }
        for id in Set([previous.tab, next.tab, previous.close, next.close].compactMap { $0 }) {
            tabViews[id]?.needsDisplay = true
        }
    }

    private var firstVisibleIndex = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }
    override var needsDisplay: Bool { didSet { if needsDisplay { redrawTabs() } } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        tabArea.wantsLayer = true
        tabArea.layer?.masksToBounds = true
        addSubview(tabArea)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        for button in [addButton, emptyAddButton] {
            button.target = self
            button.action = #selector(openApplicationPicker(_:))
            button.setAccessibilityLabel("Add app to this pane")
            button.toolTip = "Add an app to this pane. Use Show Tab Bar, then press +."
            addSubview(button)
        }
        emptyAddButton.isHidden = true
        galleryButton.target = self
        galleryButton.action = #selector(openGallery)
        galleryButton.isHidden = true
        addSubview(galleryButton)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsLayout = true; needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutTabs(animated: false)
        galleryButton.isHidden = requestStatus != nil || !pane.tabs.isEmpty || bounds.height < 90
        emptyAddButton.isHidden = galleryButton.isHidden
        addButton.frame = strip.addFrame.insetBy(dx: 2, dy: 2)
        addButton.setAccessibilityLabel("Add app to pane \(number)")
        emptyAddButton.setAccessibilityLabel("Add app to pane \(number)")
        layoutEmptyPaneButtons()
        requestStatusView?.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))
    }
    /// Natural widths, never truncated. Side by side when they fit; otherwise stacked.
    private func layoutEmptyPaneButtons() {
        let height = OverlayButtonMetrics.height, gap = OverlayButtonMetrics.spacing
        let primary = emptyAddButton.intrinsicContentSize.width, secondary = galleryButton.intrinsicContentSize.width
        let rowY = min(bounds.height - 32, max(40, (bounds.height + barHeight) / 2 + 36))
        if primary + gap + secondary <= bounds.width - 24 {
            let left = (bounds.width - (primary + gap + secondary)) / 2
            emptyAddButton.frame = NSRect(x: left, y: rowY, width: primary, height: height)
            galleryButton.frame = NSRect(x: left + primary + gap, y: rowY, width: secondary, height: height)
        } else {
            let top = min(rowY, bounds.height - 8 - 2 * height - gap)
            emptyAddButton.frame = NSRect(x: (bounds.width - primary) / 2, y: top, width: primary, height: height)
            galleryButton.frame = NSRect(x: (bounds.width - secondary) / 2, y: top + height + gap, width: secondary, height: height)
        }
    }

    @objc private func openApplicationPicker(_ sender: NSButton) {
        owner?.addApplication(paneID: pane.id, from: self, rect: sender.frame)
    }
    @objc private func openGallery() { owner?.showLayoutGallery(paneID: pane.id) }

    var strip: TabbedStripLayout {
        TabbedStripLayout(width: bounds.width, count: renderedOrder.count,
                          selectedIndex: previewOrder == nil ? pane.tabs.firstIndex(where: { $0 == (keyboardTab ?? pane.selected) }) : nil,
                          startIndex: firstVisibleIndex, preferredWidths: renderedOrder.map(preferredWidth), presentation: presentation)
    }

    func renderedIndex(of id: WindowID) -> Int? { renderedOrder.firstIndex(of: id) }

    /// Only Compact reserves title width for the displayed selection alone.
    private func preferredWidth(_ id: WindowID) -> Double {
        if presentation == .compact, id != displayedSelection { return 56 }
        let title = pane.tabs.firstIndex(of: id).flatMap { titles.indices.contains($0) ? titles[$0] : nil }
            ?? owner?.tabTitle(id) ?? "Window"
        let text: Double
        if let cached = titleWidths[title] { text = cached } else {
            text = ceil((title as NSString).size(withAttributes: [.font: Self.titleFont]).width)
            if titleWidths.count > 256 { titleWidths.removeAll() }
            titleWidths[title] = text
        }
        // Inset and padding, icon and gap, title, close button and padding:
        // the same geometry `drawTab` uses.
        return 2 + 8 + 21 + text + 28
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
    }

    override func mouseExited(with event: NSEvent) { hoverPoint = nil }

    func updateToolTips() {
        removeAllToolTips()
        addToolTip(NSRect(x: 0, y: 0, width: 32, height: barHeight), owner: "Use this pane for new windows" as NSString, userData: nil)
        let menuHelp = strip.hiddenCount > 0
            ? "\(strip.hiddenCount) more tabs. Show all tabs and layout actions"
            : "Show all tabs and layout actions"
        addToolTip(strip.menuFrame, owner: menuHelp as NSString, userData: nil)
        for slot in strip.visibleRange {
            let id = renderedOrder[slot]
            guard id != liftedTab, let index = pane.tabs.firstIndex(of: id) else { continue }
            let title = titles.indices.contains(index) ? titles[index] : "Window"
            var label = strip.tabFrame(slot)
            label.size.width -= 24
            addToolTip(label, owner: title as NSString, userData: nil)
            addToolTip(strip.closeFrame(slot), owner: "Close \(title)" as NSString, userData: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        #if BETTERTILE_TEST_HOOKS
        drawCount += 1
        #endif
        super.draw(dirtyRect)
        // The pane number reads on any glass tint: a solid shaded-accent badge for
        // the active pane, an outlined neutral one otherwise.
        let badge = NSBezierPath(roundedRect: NSRect(x: 5.5, y: (barHeight - 19) / 2, width: 21, height: 19), xRadius: 6, yRadius: 6)
        if active {
            // The shared accent shade keeps the white digit at 4.5:1 or better.
            PopupGlass.accentShadeColor.setFill()
            badge.fill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            badge.fill()
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            badge.lineWidth = 1
            badge.stroke()
        }
        drawText("\(number)", in: NSRect(x: 4, y: (barHeight - 16) / 2, width: 24, height: 18), color: active ? .white : .labelColor, bold: true, centered: true)
        let strip = strip
        if hoverState.menu {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: strip.menuFrame.insetBy(dx: 3, dy: 3), xRadius: 5, yRadius: 5).fill()
        }
        if strip.hiddenCount > 0 {
            drawText("+\(strip.hiddenCount)", in: strip.menuFrame.insetBy(dx: 2, dy: (barHeight - 18) / 2), color: .labelColor, bold: true, centered: true)
        } else {
            drawSymbol("ellipsis", in: NSRect(x: strip.menuFrame.midX - 8, y: (barHeight - 16) / 2, width: 16, height: 16), color: .labelColor)
        }
        if pane.tabs.isEmpty && requestStatus == nil {
            // SettingsRadius.panel. BetterTileMacOS cannot import the app layer's SettingsStyle, so these match its tokens by value.
            let panelRadius: CGFloat = 12
            let centerY = max(52, (bounds.height + barHeight) / 2)
            if bounds.width >= 200 && bounds.height >= 170 {
                let tile = NSRect(x: bounds.midX - 24, y: centerY - 92, width: 48, height: 48)
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: tile, xRadius: panelRadius, yRadius: panelRadius).fill()
                // The icon of this display's layout, 1.265 times a 26 point symbol, centred in the tile.
                if let context = NSGraphicsContext.current?.cgContext {
                    let size = CGFloat(LayoutGlyph.canvasSize(besideSymbolSize: 26))
                    layoutGlyph.stroke(in: context, origin: CGPoint(x: tile.midX - size / 2, y: tile.midY - size / 2),
                                       canvasSize: size, color: NSColor.secondaryLabelColor.cgColor, flipped: isFlipped)
                }
            }
            drawText("Pane \(number) is empty", in: NSRect(x: 8, y: centerY - 32, width: max(0, bounds.width - 16), height: 20), color: .labelColor, bold: true, centered: true)
            if bounds.width >= 240 && bounds.height >= 170 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byWordWrapping
                ("Open an app here, or change how this display is split." as NSString).draw(
                    in: NSRect(x: max(12, bounds.midX - 144), y: centerY - 4, width: min(288, bounds.width - 24), height: 32),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                     .paragraphStyle: paragraph])
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

    private func redrawTabs() { for view in tabViews.values { view.needsDisplay = true } }

    /// The order a drop of `id` is measured in: the preview while it holds
    /// the dragged tab, otherwise the tabs with `id` at its place or the end.
    func dropOrder(for id: WindowID) -> [WindowID] {
        previewOrder.flatMap { $0.contains(id) ? $0 : nil } ?? (pane.tabs.contains(id) ? pane.tabs : pane.tabs + [id])
    }

    func dropStrip(for id: WindowID) -> TabbedStripLayout {
        let order = dropOrder(for: id)
        return TabbedStripLayout(width: bounds.width, count: order.count,
                                 selectedIndex: nil, startIndex: previewOrder == nil ? strip.visibleRange.lowerBound : firstVisibleIndex,
                                 preferredWidths: order.map(preferredWidth), presentation: presentation)
    }

    func previewDrag(order: [WindowID], lifted: WindowID) {
        if initialVisibleIndex == nil { initialVisibleIndex = strip.visibleRange.lowerBound; firstVisibleIndex = strip.visibleRange.lowerBound }
        guard previewOrder != order || liftedTab != lifted else { return }
        previewOrder = order
        liftedTab = lifted
        layoutTabs(animated: true)
        needsDisplay = true
    }

    func endDragPreview() {
        previewOrder = nil
        liftedTab = nil
        if let initialVisibleIndex { firstVisibleIndex = initialVisibleIndex }
        initialVisibleIndex = nil
        // Cancellation must stop springs as well as restore hit-test geometry.
        for view in tabViews.values { view.layer?.removeAllAnimations() }
        layoutTabs(animated: false)
        needsDisplay = true
        updateToolTips()
        (superview as? TabbedPaneView)?.updateAccessibility()
    }

    func scrollDrag(at x: Double, lifted: WindowID) -> Bool {
        let layout = dropStrip(for: lifted)
        let direction = x < 52 ? -1 : (x > layout.menuFrame.minX - 20 ? 1 : 0)
        let count = pane.tabs.count + (pane.tabs.contains(lifted) ? 0 : 1)
        let next = min(max(0, count - layout.visibleRange.count), max(0, layout.visibleRange.lowerBound + direction))
        guard next != layout.visibleRange.lowerBound else { return false }
        firstVisibleIndex = next
        layoutTabs(animated: false)
        return true
    }

    private func layoutTabs(animated: Bool) {
        let layout = strip
        tabArea.frame = NSRect(x: 32, y: 0, width: max(0, layout.addFrame.minX - 32), height: barHeight)
        let visible = Set(layout.visibleRange.map { renderedOrder[$0] }.filter { $0 != liftedTab })
        for id in tabViews.keys.filter({ !visible.contains($0) }) { tabViews.removeValue(forKey: id)?.removeFromSuperview() }
        for index in layout.visibleRange {
            let id = renderedOrder[index]
            guard id != liftedTab, pane.tabs.contains(id) else { continue }
            let existing = tabViews[id]
            let view = existing ?? TabbedTabView()
            view.drawContent = { [weak self] rect in self?.drawTab(id, in: rect) }
            if existing == nil { tabArea.addSubview(view); tabViews[id] = view }
            let frame = layout.tabFrame(index).offsetBy(dx: -32, dy: 0)
            view.move(to: frame, animated: animated && existing != nil && !reduceMotion())
            view.needsDisplay = true
        }
        // A stationary pointer can change target when the strip is laid out.
        updateHover()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Every tab is an outlined capsule, so tabs stay distinct on Liquid
    /// Glass whatever the wallpaper tint. The selected tab is a raised plate
    /// with an accent outline when its pane is active.
    private func drawTab(_ id: WindowID, in tab: NSRect) {
        #if BETTERTILE_TEST_HOOKS
        tabDrawCounts[id, default: 0] += 1
        #endif
        guard let index = pane.tabs.firstIndex(of: id), tabViews[id] != nil else { return }
        let hovered = hoverState.tab == id
        let selected = displayedSelection == id
        let rect = tab.insetBy(dx: 2, dy: presentation == .compact ? 2 : 4)
        let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        if selected {
            NSColor.white.withAlphaComponent(isDark ? 0.3 : 0.85).setFill()
            capsule.fill()
            NSColor.labelColor.withAlphaComponent(active ? 0.55 : 0.38).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
            if active {
                // The accent bar marks where new windows and keys go.
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 9, y: rect.maxY - 3, width: max(0, rect.width - 18), height: 2),
                             xRadius: 1, yRadius: 1).fill()
            }
        } else {
            NSColor.labelColor.withAlphaComponent(downTab == id ? 0.16 : (hovered ? 0.11 : 0.07)).setFill()
            capsule.fill()
            NSColor.labelColor.withAlphaComponent(hovered ? 0.38 : 0.28).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
        }
        if keyboardTab == id {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: tab.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5)
            focus.lineWidth = 2
            focus.stroke()
        }
        var titleFrame = rect.insetBy(dx: 8, dy: presentation == .compact ? 1 : 5)
        let compact = (presentation == .compact && !selected) || tab.width < 72
        let tabIcon = icons.indices.contains(index) ? icons[index] : nil
        if let icon = tabIcon ?? ((compact || presentation == .compact) ? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) : nil) {
            let displayedIcon = icon.isTemplate
                ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor])) ?? icon
                : icon
            displayedIcon.draw(in: NSRect(x: rect.minX + (compact ? 4 : 7), y: (barHeight - 16) / 2, width: 16, height: 16),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            titleFrame.origin.x += 21
            titleFrame.size.width -= 21
        }
        if !compact {
            // The close button shows on the selected or hovered tab; other
            // tabs give its space to the title.
            drawText(titles.indices.contains(index) ? titles[index] : "Window", in: titleFrame, color: .labelColor,
                     bold: selected, trailing: selected || hovered ? 18 : 0)
        }
        // The close button keeps its slot, so widths never change on hover.
        let close = NSRect(x: tab.maxX - 24, y: 0, width: 24, height: tab.height)
        if hoverState.close == id {
            NSColor.labelColor.withAlphaComponent(downClose == id ? 0.18 : 0.1).setFill()
            NSBezierPath(roundedRect: NSRect(x: close.midX - 8, y: tab.midY - 8, width: 16, height: 16), xRadius: 8, yRadius: 8).fill()
        }
        if selected || hovered {
            drawSymbol("xmark", in: NSRect(x: close.midX - 4, y: tab.midY - 4, width: 8, height: 8),
                       color: NSColor.labelColor.withAlphaComponent(selected ? 0.85 : 0.65))
        }
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
        if previewOrder == nil { firstVisibleIndex = strip.visibleRange.lowerBound }
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
        button("Use pane \(number) for new windows", rect: NSRect(x: 0, y: 0, width: 30, height: barHeight)) { [weak self] in
            guard let self else { return }; owner?.send(.activate(pane.id))
        }
        let strip = strip
        for slot in strip.visibleRange {
            let id = renderedOrder[slot]
            guard id != liftedTab, let index = pane.tabs.firstIndex(of: id) else { continue }
            let title = titles.indices.contains(index) ? titles[index] : "Window"
            var rect = strip.tabFrame(slot)
            rect.size.width -= 24
            button("\(title)\(pane.selected == id ? ", selected" : "")", rect: rect) { [weak self] in self?.owner?.send(.select(id)) }
            button("Close \(title)", rect: strip.closeFrame(slot)) { [weak self] in self?.owner?.send(.close(id)) }
        }
        let menuLabel = "Pane \(number) layout and tab actions" + (strip.hiddenCount > 0 ? ", \(strip.hiddenCount) more tabs" : "")
        button(menuLabel, rect: strip.menuFrame) { [weak self] in
            guard let self, let owner else { return }
            owner.menu(pane: pane, windowID: nil).popUp(positioning: nil, at: NSPoint(x: strip.menuFrame.minX, y: barHeight), in: self)
        }
        return children
    }

    override func mouseDown(with event: NSEvent) {
        owner?.flushAutoHidePointer()
        let point = convert(event.locationInWindow, from: nil)
        // A new press proves the previous drag ended. Cancel a drag whose
        // mouse-up was lost rather than completing it with this gesture.
        if owner?.hasActiveTabDrag == true { owner?.cancelInteraction() }
        owner?.holdBar(pane.id, .selection, enabled: true)
        downTab = nil; downClose = nil; downPoint = nil; dragging = false; attemptedDrag = false; blockedDrag = false
        selectedOnPress = nil; selectionBeforePress = nil
        if strip.menuFrame.contains(point) || event.modifierFlags.contains(.control) { showMenu(event); return }
        if let index = tabIndex(at: point) {
            // A released strip shows provisional membership until placement
            // settles. Capture the displayed window identity; the model queues
            // its selection behind the move.
            let id = renderedOrder[index]
            if strip.closeFrame(index).contains(point) {
                guard owner?.isDropPending != true else { return }
                downClose = id; hoverPoint = point; needsDisplay = true; return
            }
            downTab = id; downPoint = point; dragging = false
            hoverPoint = point; needsDisplay = true
            // Like native tab bars, a press selects the tab at once; a drag
            // can still start from it. A pending drop keeps release-time
            // selection, which re-checks the displayed tab after placement.
            if owner?.isDropPending != true, previewOrder == nil, pane.selected != id {
                // The tab drawn as selected, which can be an earlier press
                // that has not settled yet.
                selectionBeforePress = displayedSelection
                selectedOnPress = id
                pressedSelection = id
                owner?.selectOnPress(id)
            }
        } else { owner?.send(.activate(pane.id)) }
    }
    override func mouseDragged(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        guard let id = downTab, let downPoint, let owner else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragging && hypot(point.x - downPoint.x, point.y - downPoint.y) >= 5 {
            attemptedDrag = true
            let tab = strip.tabFrame(renderedOrder.firstIndex(of: id) ?? 0)
            dragging = owner.beginDrag(id, offset: NSPoint(x: downPoint.x - tab.minX, y: downPoint.y),
                                       reselecting: selectionBeforePress)
            // Only this press's own selection blocks the drag; any other
            // placement keeps rejecting it.
            blockedDrag = !dragging && selectedOnPress == id
        }
        if dragging { owner.queueDrag(to: owner.screenPoint(event)) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { owner?.holdBar(pane.id, .selection, enabled: false) }
        let point = convert(event.locationInWindow, from: nil)
        // A drag blocked while a selection settled starts now, so its drop
        // is not lost; the model queues it behind the selection.
        if !dragging, blockedDrag, let id = downTab, let downPoint, let owner {
            let tab = strip.tabFrame(renderedOrder.firstIndex(of: id) ?? 0)
            dragging = owner.beginDrag(id, offset: NSPoint(x: downPoint.x - tab.minX, y: downPoint.y), atRelease: true,
                                       reselecting: selectionBeforePress)
        }
        if dragging, let owner {
            owner.drag(to: owner.screenPoint(event))
            owner.endDrag()
        }
        else if !attemptedDrag, let downClose,
                let index = tabIndex(at: point),
                renderedOrder[index] == downClose,
                strip.closeFrame(index).contains(point) { owner?.send(.close(downClose)) }
        else if !attemptedDrag, let downTab, downTab != selectedOnPress,
                let index = tabIndex(at: point),
                renderedOrder[index] == downTab,
                !strip.closeFrame(index).contains(point) { owner?.send(.select(downTab)) }
        downTab = nil; downClose = nil; downPoint = nil; dragging = false; attemptedDrag = false; blockedDrag = false
        selectedOnPress = nil; selectionBeforePress = nil
        needsDisplay = true
    }
    override func rightMouseDown(with event: NSEvent) { showMenu(event) }
    private func showMenu(_ event: NSEvent) {
        guard let owner, !owner.isDropPending else { return }
        defer { owner.holdBar(pane.id, .selection, enabled: false) }
        let index = tabIndex(at: convert(event.locationInWindow, from: nil))
        let menu = owner.menu(pane: pane, windowID: index.map { renderedOrder[$0] })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.characters == "+", !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
            owner?.addApplication(paneID: pane.id, from: self, rect: addButton.frame)
            return true
        }
        if owner?.handleBarKey(event.keyCode) == true { return true }
        guard let selected = pane.selected, let index = pane.tabs.firstIndex(of: selected),
              event.keyCode == 123 || event.keyCode == 124 else { return false }
        let next = (index + (event.keyCode == 123 ? -1 : 1) + pane.tabs.count) % pane.tabs.count
        owner?.send(.select(pane.tabs[next]))
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

/// A tab's native layer carries its spring. Pointer events stay with the strip.
@MainActor private final class TabbedTabView: NSView {
    var drawContent: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawContent?(bounds) }

    func move(to destination: NSRect, animated: Bool) {
        guard frame != destination else { return }
        let oldPosition = layer?.presentation()?.position ?? layer?.position
        let oldFrame = frame
        layer?.removeAnimation(forKey: "tabPosition")
        frame = destination
        guard animated, oldFrame != destination, let layer, let oldPosition else { return }
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: oldPosition)
        spring.toValue = NSValue(point: layer.position)
        spring.mass = 1
        spring.stiffness = 420
        spring.damping = 27
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "tabPosition")
    }
}

// SettingsSpacing.s8 rows and .s6 icons. BetterTileMacOS cannot import the app layer's SettingsStyle, so these match its tokens by value.
private enum PaneStatusMetrics {
    static let rowHeight: CGFloat = 32
    static let iconSize: CGFloat = 24
    static let rowRadius = PopupGlass.controlRadius
}

struct PaneRequestStatusBody: View {
    let status: PaneRequestStatus
    let action: (PaneRequestAction) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    content(showsIcon: geometry.size.height >= 300)
                    actions
                }
                .frame(maxWidth: 360)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
            // No fill: the pane's popup glass, or its opaque fallback, is the surface.
        }
    }

    private func content(showsIcon: Bool) -> some View {
        VStack(spacing: 12) {
            if showsIcon || isOpening { icon }
            Text(status.headline).font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if isOpening { ProgressView().controlSize(.small) }
            if !status.message.isEmpty {
                Text(status.message).font(.system(size: 11)).foregroundStyle(PopupGlass.secondaryText)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            windowLists
        }
    }

    private var isOpening: Bool {
        switch status.kind {
        case .opening, .stillOpening, .placing: true
        default: false
        }
    }

    @ViewBuilder private var icon: some View {
        switch status.kind {
        case .timedOut, .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: PaneStatusMetrics.iconSize))
                .foregroundStyle(status.kind == .failed ? Color.red : Color.orange)
                .accessibilityHidden(true)
        default:
            if let url = status.appIconURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                    .frame(width: PaneStatusMetrics.iconSize, height: PaneStatusMetrics.iconSize).accessibilityHidden(true)
            } else {
                Image(systemName: "app").font(.system(size: PaneStatusMetrics.iconSize)).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var windowLists: some View {
        if status.singleWindow == nil {
            switch status.kind {
            case let .awaitingClick(windows), let .noNewWindow(windows), let .other(_, windows):
                windowList(windows, label: "Windows on this desktop · live titles")
            case let .severalCopies(groups):
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in windowList(group.windows, label: group.label) }
            case let .timedOut(showing, windows):
                if showing { windowList(windows, label: "Windows on this desktop · live titles") }
            default: EmptyView()
            }
        }
    }

    private func windowList(_ windows: [PaneRequestWindow], label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(PopupGlass.secondaryText)
            if windows.isEmpty {
                Text("No \(status.appName) windows on this desktop.").font(.system(size: 11)).foregroundStyle(PopupGlass.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(windows) { window in
                HStack(spacing: 8) {
                    Image(systemName: "macwindow").frame(width: PaneStatusMetrics.iconSize).accessibilityHidden(true)
                    Text(window.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Use here") { action(.useWindow(window.id)) }.buttonStyle(PopupLinkStyle())
                        .accessibilityLabel("Use \(window.title) here")
                }
                .font(.system(size: 11)).padding(.horizontal, 8).frame(height: PaneStatusMetrics.rowHeight)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: PaneStatusMetrics.rowRadius))
                .help(window.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        if let window = status.singleWindow, let title = status.singleWindowButtonTitle {
            VStack(spacing: 8) {
                primaryButton(title, action: .useWindow(window.id)).keyboardShortcut(.defaultAction).help(window.title)
                OverlayButtonRow {
                    if case .timedOut = status.kind {
                        Button("Try Again") { action(.tryAgain) }.buttonStyle(OverlayButtonStyle(.secondary)).fixedSize()
                    }
                    cancel.fixedSize()
                }
            }
        } else {
            switch status.kind {
            // Two rows, so a small pane keeps room for the message.
            case .timedOut:
                VStack(spacing: 8) {
                    OverlayButtonRow { primaryButton("Try Again", action: .tryAgain).fixedSize(); cancel.fixedSize() }
                    Button("Use a window") { action(.showWindows) }.buttonStyle(PopupLinkStyle())
                }
            case .failed:
                VStack(spacing: 8) {
                    OverlayButtonRow { primaryButton("Try Again", action: .tryAgain).fixedSize(); cancel.fixedSize() }
                    Button("Choose Another App") { action(.chooseAnotherApp) }.buttonStyle(OverlayButtonStyle(.secondary)).fixedSize()
                }
            case .noNewWindow:
                OverlayButtonRow {
                    Button("Show \(status.appName)") { action(.showApp) }.buttonStyle(OverlayButtonStyle(.secondary)).fixedSize()
                    cancel.fixedSize()
                }
            default: cancel.fixedSize()
            }
        }
    }

    /// Accent fill shaded for white text. A long window title truncates in the middle.
    private func primaryButton(_ title: String, action intent: PaneRequestAction) -> some View {
        Button { action(intent) } label: { Text(title).lineLimit(1).truncationMode(.middle) }
            .buttonStyle(OverlayButtonStyle(.primary))
    }

    private var cancel: some View {
        Button("Cancel") { action(.cancel) }.buttonStyle(OverlayButtonStyle(.secondary))
    }
}
