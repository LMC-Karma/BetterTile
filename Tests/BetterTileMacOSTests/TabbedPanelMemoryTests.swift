import AppKit
import BetterTileCore
import BetterTileTestSupport
import Testing
@testable import BetterTileMacOS

@MainActor private func memoryOverlay() -> TabbedOverlayController {
    TabbedOverlayController(dragTicks: ResizeDisplayLink(automatic: false),
        pointerTicks: ResizeDisplayLink(automatic: false),
        panelFactory: {
            UnconstrainedTabbedTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        },
        addGlobalKeyMonitor: { _ in nil }, addLocalKeyMonitor: { _ in nil }, removeMonitor: { _ in },
        automaticallyAdvanceVisibility: false,
        mainScreenFrame: { UnconstrainedTabbedTestPanel.referenceScreenFrame })
}

@Test(.macOSTestApplication) @MainActor
func tabbedUnchangedPaneAppearanceReusesNativeGlass() {
    let view = TabbedPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let pane = view.pane
    let appearance = view.overlayAppearance
    let initial = view.appearanceRefreshCount
    for index in 0..<100 {
        view.pane = pane
        view.active = false
        view.presentation = .alwaysVisible
        view.overlayAppearance = appearance
        view.setAutoHideCollapsed(false, at: Double(index), animated: false)
    }
    #expect(view.appearanceRefreshCount == initial)
    #expect(view.glass.frame == view.bounds)
    #expect(!view.content.isHidden)

    var occupied = pane
    occupied.tabs = [WindowID(rawValue: "appearance-tab")]
    occupied.selected = occupied.tabs[0]
    view.pane = occupied
    #expect(view.appearanceRefreshCount == initial + 1)
    occupied.tabs.append(WindowID(rawValue: "appearance-second-tab"))
    view.pane = occupied
    #expect(view.appearanceRefreshCount == initial + 1)
    view.active = true
    #expect(view.appearanceRefreshCount == initial + 2)
    view.overlayAppearance.useLiquidGlass = false
    #expect(view.appearanceRefreshCount == initial + 3)
    #expect(!view.showsGlass && view.glass.plateOpacity == 1)
}

@Test(.macOSTestApplication) @MainActor
func tabbedUnchangedCollapseStillFinishesItsPendingAnimation() {
    let view = TabbedPaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 34))
    view.reduceMotion = { false }
    view.setAutoHideCollapsed(true, at: 0, animated: false)
    let collapsed = view.appearanceRefreshCount
    view.setAutoHideCollapsed(true, at: 1, animated: true)
    #expect(view.appearanceRefreshCount == collapsed)
    view.setAutoHideCollapsed(false, at: 2, animated: true)
    #expect(view.autoHideAnimationDeadline != nil)
    #expect(view.layer?.mask != nil)
    view.setAutoHideCollapsed(false, at: 2.2, animated: true)
    #expect(view.autoHideAnimationDeadline == nil)
    #expect(view.layer?.mask == nil)
    #expect(!view.content.isHidden)
    let revealed = view.appearanceRefreshCount
    view.setAutoHideCollapsed(false, at: 3, animated: true)
    #expect(view.appearanceRefreshCount == revealed)
}

@Test(.macOSTestApplication) @MainActor
func tabbedSpaceSuspensionKeepsPaneContentForTheSlide() {
    let overlay = memoryOverlay()
    overlay.keepsPanelsOnSpace = true
    defer { overlay.hide() }
    var state = TabbedLayoutState()
    state.reconcile(windowIDs: [WindowID(rawValue: "memory-space-tab")], removed: [], focused: nil)
    overlay.refresh(state: state, bounds: BTRect(x: 40000, y: 0, width: 1000, height: 800), windows: [])
    let panels = NSApp.windows.filter { overlay.windowNumbers.contains($0.windowNumber) }
    overlay.prepareForSpaceChange()
    #expect(!panels.isEmpty)
    #expect(panels.allSatisfy { $0.contentView != nil && $0.isVisible })
}

@Test(.macOSTestApplication) @MainActor
func tabbedRevealReusesPanelsAndMaterialWithManualClock() throws {
    let clock = ManualClock()
    let origin = clock.now
    var panels: [UnconstrainedTabbedTestPanel] = []
    let overlay = TabbedOverlayController(dragTicks: ResizeDisplayLink(automatic: false),
        pointerTicks: ResizeDisplayLink(automatic: false), panelFactory: {
            let p = UnconstrainedTabbedTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                                 backing: .buffered, defer: false)
            panels.append(p)
            return p
        }, addGlobalKeyMonitor: { _ in nil }, addLocalKeyMonitor: { _ in nil }, removeMonitor: { _ in },
        visibilityClock: {
            let d = origin.duration(to: clock.now).components
            return Double(d.seconds) + Double(d.attoseconds) / 1e18
        }, timerClock: clock.clock, automaticallyAdvanceVisibility: false,
        mainScreenFrame: { UnconstrainedTabbedTestPanel.referenceScreenFrame })
    defer { overlay.hide() }
    var state = TabbedLayoutState(presentation: .autoHide)
    let ids = (0..<4).map { WindowID(rawValue: "manual-reveal-\($0)") }
    state.reconcile(windowIDs: ids, removed: [], focused: ids[0])
    let bounds = BTRect(x: 40000, y: 0, width: 2560, height: 1410)
    let numbers = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, 123 + $0.offset) })
    func refresh() {
        overlay.refresh(state: state, bounds: bounds, windows: [], selectedWindowNumbers: numbers,
                        curtainAnchorWindowNumber: state.activeWindowID.flatMap { numbers[$0] })
    }
    refresh()
    let view = try #require(panels.compactMap { $0.contentView as? TabbedPaneView }.first)
    view.reduceMotion = { false }
    let material = view.glass.glass
    let originalPanels = panels.map(ObjectIdentifier.init)
    #expect(view.collapsed && view.content.isHidden)
    overlay.updateAutoHidePointer(at: BTPoint(x: bounds.midX, y: 3))
    clock.advance(by: .milliseconds(79)); overlay.advanceBarVisibility()
    #expect(view.collapsed)
    clock.advance(by: .milliseconds(2)); overlay.advanceBarVisibility()
    #expect(!view.collapsed && !view.content.isHidden)
    #expect(view.autoHideAnimationDeadline != nil)
    clock.advance(by: .milliseconds(161)); overlay.advanceBarVisibility()
    #expect(view.autoHideAnimationDeadline == nil)
    for id in ids.dropFirst() { state.select(id); refresh() }
    #expect(panels.map(ObjectIdentifier.init) == originalPanels)
    #expect(view.glass.glass === material)
    overlay.updateAutoHidePointer(at: BTPoint(x: bounds.midX, y: 1000))
    clock.advance(by: .milliseconds(301)); overlay.advanceBarVisibility()
    clock.advance(by: .milliseconds(161)); overlay.advanceBarVisibility()
    #expect(view.collapsed && view.content.isHidden)
    #expect(panels.map(ObjectIdentifier.init) == originalPanels)
}

@Test(.macOSTestApplication) @MainActor
func tabbedCurtainReleasesFullAreaMaskWhenCutoutsEnd() throws {
    let view = TabbedCurtainView(frame: NSRect(x: 0, y: 0, width: 2560, height: 1410))
    #expect(view.layer?.mask == nil)
    let strip = NSRect(x: 0, y: 0, width: 1280, height: 34)
    view.excludedStrips = [strip]
    let mask = try #require(view.layer?.mask as? CAShapeLayer)
    #expect(mask.path?.contains(CGPoint(x: 640, y: 17), using: .evenOdd) == false)
    #expect(mask.path?.contains(CGPoint(x: 1, y: 1), using: .evenOdd) == true)
    view.setFrameSize(NSSize(width: 2800, height: 1600))
    view.layoutSubtreeIfNeeded()
    #expect(mask.path?.contains(CGPoint(x: 2700, y: 1500), using: .evenOdd) == true)
    view.excludedStrips = []
    #expect(view.layer?.mask == nil)
    #expect(mask.path == nil)
    view.excludedStrips = [strip]
    #expect(view.layer?.mask === mask)
}
