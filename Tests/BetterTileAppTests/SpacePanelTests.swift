import AppKit
import BetterTileCore
@testable import BetterTileMacOS
@testable import BetterTileApp
import Testing

/// No test panel is ever ordered into the real window system. Keep AppKit
/// frame readbacks off screen too: the audit observes synthetic visibility.
@MainActor private final class FakeSpacePanel: OffscreenTestPanel {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        OffscreenTestWindows.check(self)
    }
    var shown = false
    var currentSpace: (() -> NativeSpaceID?)?
    var firstOrderedSpace: NativeSpaceID?
    func recordFirstOrder() {
        if firstOrderedSpace == nil { firstOrderedSpace = currentSpace?() }
    }
    var orders = 0
    var focusRequests = 0
    override var isVisible: Bool { shown }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { recordFirstOrder() }
        orders += 1
        shown = place != .out
    }
    override func orderFrontRegardless() { recordFirstOrder(); orders += 1; shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func makeKey() { focusRequests += 1 }
}

@MainActor private final class WeakSpacePanelOverlay {
    weak var value: TabbedOverlayController?
    init(_ value: TabbedOverlayController) { self.value = value }
}

@MainActor private final class WeakSpacePanel {
    weak var value: FakeSpacePanel?
    init(_ value: FakeSpacePanel) { self.value = value }
}

@MainActor private final class SpacePanelFixture {
    let system: FakeAppWindowSystem
    let model: BetterTileModel
    let a = NativeSpaceID(rawValue: 11)
    let b = NativeSpaceID(rawValue: 22)
    var weakPanels: [WeakSpacePanel] = []
    var panels: [FakeSpacePanel] { weakPanels.compactMap(\.value) }
    var overlays: [WeakSpacePanelOverlay] = []

    init(exact: Bool = true, usesManualClock: Bool = false) {
        _ = NSApplication.shared
        system = usesManualClock ? makeManualWindowSystem(drivingPolicyDeadlines: true) : FakeAppWindowSystem()
        model = makeOffscreenModel(
            store: ConfigurationStore(fileURL: URL(filePath: "/tmp/BetterTileSpacePanelTests-\(UUID().uuidString)/configuration.json")),
            system: system, startRuntime: false, presentsTabbedChrome: true)
        system.installWindowEventClock(in: model)
        model.primaryButtonIsPressed = { false }
        system.availableDisplays[0].frame.origin.x = 40000
        system.availableDisplays[0].visibleFrame.origin.x = 40000
        system.windows[0].frame.origin.x = 40000
        if exact {
            system.desktopObservation = NativeDesktopObservation(
                currentSpaceByDisplay: [system.mainDisplay.id: a],
                knownSpacesByDisplay: [system.mainDisplay.id: [a, b]],
                windowMembership: [system.windows[0].id: [a]])
        }
        model.tabbedOverlayFactory = { [unowned self] in
            let overlay = TabbedOverlayController(panelFactory: { [unowned self] in
                let panel = FakeSpacePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
                panel.currentSpace = { [weak system = self.system] in
                    guard let system else { return nil }
                    return system.desktopObservation?.currentSpace(on: system.mainDisplay.id)
                }
                weakPanels.append(WeakSpacePanel(panel))
                return panel
            }, addGlobalKeyMonitor: { _ in NSObject() }, addLocalKeyMonitor: { _ in NSObject() },
               removeMonitor: { _ in }, orderPanel: { panel, mode, anchor in panel.order(mode, relativeTo: anchor) },
               primaryButtonIsPressed: { false }, timerClock: system.clock)
            overlays.append(WeakSpacePanelOverlay(overlay))
            return overlay
        }
    }

    func enter() async throws {
        model.setActiveMode(.tabbed)
        try #require(await system.waitFor { self.model.presentedTabbedState(on: self.system.mainDisplay.id)?.windowIDs.count == 1
            && !self.model.hasPendingTabbedPlacement })
    }

    func switchTo(_ space: NativeSpaceID) {
        system.desktopObservation?.currentSpaceByDisplay[system.mainDisplay.id] = space
        system.offscreenWindowIDs = space == a ? [] : Set(system.windows.map(\.id))
        model.beginActiveSpaceStabilization()
    }

    func settle() async throws {
        try #require(await system.waitFor { !self.model.isStabilizingSpace && !self.model.hasPendingTabbedPlacement })
    }

    func close() {
        model.shutdown()
    }
}

@Test(.appTestApplication) @MainActor
func spacePanelUnknownSpaceKeepsLegacyHideBehavior() async throws {
    let f = SpacePanelFixture(exact: false)
    defer { f.close() }
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let panes = f.panels.filter { $0.contentView is TabbedPaneView }
    try #require(!panes.isEmpty && panes.allSatisfy { $0.isVisible })
    #expect(!overlay.keepsPanelsOnSpace)
    #expect(f.panels.allSatisfy { $0.collectionBehavior == [.moveToActiveSpace, .transient, .ignoresCycle] })
    f.switchTo(f.b)
    #expect(f.panels.allSatisfy { !$0.isVisible })
    try await f.settle()
    f.switchTo(f.a)
    try await f.settle()
    #expect(f.overlays.count == 1, "Inferred desktops must keep the existing display-scoped controller")
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id) == overlay.state)
}

@Test(.appTestApplication) @MainActor func spacePanelKeepsExactPanelsAndCorrectsChangedMembership() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let first = try #require(f.overlays.first?.value)
    let firstPanels = f.panels
    let orders = firstPanels.map(\.orders)
    #expect(first.keepsPanelsOnSpace)
    #expect(firstPanels.allSatisfy { !$0.collectionBehavior.contains(.moveToActiveSpace)
        && $0.styleMask.contains(.nonactivatingPanel) })
    f.switchTo(f.b)
    #expect(firstPanels.contains { $0.isVisible })
    #expect(firstPanels.map(\.orders) == orders)
    #expect(!first.acceptsTabDrags)
    // The active display must not route a drop into the outgoing session.
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id) == nil)
    try await f.settle()
    #expect(firstPanels.contains { $0.isVisible })
    var arrival = f.system.windows[0]
    arrival.id = WindowID(rawValue: "space-panel-arrival")
    arrival.processIdentifier += 1
    f.system.windows.append(arrival)
    f.system.desktopObservation?.windowMembership[arrival.id] = [f.a]
    f.switchTo(f.a)
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.windowIDs.count == 1)
    try await f.settle()
    try #require(await waitFor { first.state.windowIDs == Set(f.system.windows.map(\.id)) })
    #expect(f.overlays.count == 1)
    #expect(first.acceptsTabDrags)
    #expect(firstPanels.allSatisfy { $0.focusRequests == 0 })
    f.switchTo(f.b)
    try await f.settle()
    f.system.desktopObservation?.windowMembership[f.system.windows[0].id] = [f.b]
    f.switchTo(f.a)
    try await f.settle()
    #expect(first.state.windowIDs == [arrival.id])
}

@Test(.appTestApplication) @MainActor func spacePanelOwnsSeparateControllersAndRejectsInactiveClicks() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let first = try #require(f.overlays.first?.value)
    let aWindow = f.system.windows[0]
    f.switchTo(f.b)
    try await f.settle()
    var bWindow = aWindow
    bWindow.id = WindowID(rawValue: "space-panel-b")
    bWindow.processIdentifier += 1
    f.system.windows.append(bWindow)
    f.system.desktopObservation?.windowMembership[bWindow.id] = [f.b]
    f.system.offscreenWindowIDs = [aWindow.id]
    f.system.focusedID = bWindow.id
    f.model.setActiveMode(.tabbed)
    try #require(await waitFor { f.overlays.count == 2 && !f.model.hasPendingTabbedPlacement })
    let second = try #require(f.overlays[1].value)
    #expect(first !== second)
    let writes = f.system.frameWriteCounts
    first.onIntent?(.select(aWindow.id))
    #expect(f.system.frameWriteCounts == writes)
    #expect(f.model.activeTabbedState?.windowIDs == [bWindow.id])
    second.onIntent?(.select(bWindow.id))
    try await f.settle()
    f.system.desktopObservation?.currentSpaceByDisplay[f.system.mainDisplay.id] = f.a
    f.system.offscreenWindowIDs = [bWindow.id]
    f.system.focusedID = aWindow.id
    f.model.beginActiveSpaceStabilization()
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.windowIDs == [aWindow.id])
    try await f.settle()
    #expect(f.overlays.count == 2)
}

@Test(.appTestApplication) @MainActor func spacePanelRejectsClicksBeforeSpaceNotificationIsHandled() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let state = f.model.activeTabbedState
    let writes = f.system.frameWriteCounts
    f.system.desktopObservation?.currentSpaceByDisplay[f.system.mainDisplay.id] = f.b
    overlay.onIntent?(.float(f.system.windows[0].id))
    #expect(f.model.activeTabbedState == state)
    #expect(f.system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: ["space", "display", "observation", "permission", "shutdown"]) @MainActor
func spacePanelReleasesOrHidesPanelsWhenOwnerIsUnavailable(reason: String) async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let weak = try #require(f.overlays.first)
    let panels = f.panels
    f.switchTo(f.b)
    try await f.settle()
    switch reason {
    case "space":
        f.system.desktopObservation?.knownSpacesByDisplay[f.system.mainDisplay.id] = [f.b]
        f.model.beginActiveSpaceStabilization()
        try await f.settle()
    case "display":
        f.system.availableDisplays = []
        f.system.desktopObservation?.currentSpaceByDisplay = [:]
        f.system.desktopObservation?.knownSpacesByDisplay = [:]
        f.model.handleApplicationTopologyChange()
    case "observation":
        f.system.desktopObservation = nil
        f.model.beginActiveSpaceStabilization()
        try await f.settle()
    case "permission":
        f.system.permission = false
        _ = f.model.refreshPermission()
    default: f.model.shutdown()
    }
    #expect(panels.allSatisfy { !$0.isVisible })
    if reason != "permission" { #expect(weak.value == nil) }
}


@Test(.appTestApplication, arguments: [WindowSystemEvent.Kind.destroyed, .minimized]) @MainActor
func spacePanelOffSpaceLifecycleUpdatesBeforeArrival(kind: WindowSystemEvent.Kind) async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let window = f.system.windows[0]
    f.switchTo(f.b)
    try await f.settle()
    let writes = f.system.frameWriteCounts
    let raises = f.system.raiseRequests.count
    let orders = f.panels.map(\.orders)
    if kind == .destroyed { f.system.windows.removeAll() }
    else { f.system.windows[0].isMinimized = true }
    f.system.eventHandler?(WindowSystemEvent(kind: kind, windowID: window.id, processIdentifier: window.processIdentifier))
    #expect(overlay.state.windowIDs.isEmpty, "The retained strip must drop the unavailable tab before returning to its Space")
    #expect((overlay.state.returnSlots[window.id] != nil) == (kind == .minimized),
            "Minimization keeps the pane for a return; destruction forgets it")
    #expect(f.panels.compactMap { $0.contentView as? TabbedPaneView }.allSatisfy { $0.pane.tabs.isEmpty })
    #expect(f.system.frameWriteCounts == writes)
    #expect(f.system.raiseRequests.count == raises)
    #expect(f.panels.map(\.orders) == orders, "Off-Space updates must not reorder a panel onto the current desktop")
    f.switchTo(f.a)
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.windowIDs.isEmpty == true)
    try await f.settle()
    #expect(overlay.state.windowIDs.isEmpty)
}

@Test(.appTestApplication) @MainActor func spacePanelMissionControlUsesTransientWithDefaultAnimation() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    #expect(!f.panels.isEmpty)
    #expect(f.panels.allSatisfy { $0.collectionBehavior.contains(.transient)
        && !$0.collectionBehavior.contains(.stationary) && !$0.collectionBehavior.contains(.managed)
        && !$0.collectionBehavior.contains(.auxiliary)
        && $0.animationBehavior == ($0.contentView is TabbedCurtainView ? .none : .default) })
}

@Test(.appTestApplication) @MainActor func spacePanelLeavingTabbedReleasesOwner() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let weak = try #require(f.overlays.first)
    f.model.setActiveMode(.manual)
    try #require(await waitFor { f.model.activeLayoutMode == .manual && !f.model.hasPendingTabbedPlacement })
    #expect(f.panels.allSatisfy { !$0.isVisible })
    #expect(weak.value == nil)
}

@Test(.appTestApplication) @MainActor func spacePanelCountIsBoundedAcrossSwitchesAndEndedSessions() async throws {
    let f = SpacePanelFixture(usesManualClock: true)
    defer { f.close() }
    try await f.enter()
    let initialCount = f.panels.count
    for _ in 0..<20 {
        f.switchTo(f.b)
        try await f.settle()
        f.switchTo(f.a)
        try await f.settle()
        #expect(f.overlays.compactMap(\.value).count == 1)
        #expect(f.panels.count == initialCount)
    }
    for value in 100..<120 {
        // Mission Control removes the Tabbed desktop. Its window is not yet
        // visible on the new desktop, so the ended session is only retired.
        let space = NativeSpaceID(rawValue: UInt64(value))
        let created = f.overlays.count
        f.system.desktopObservation?.knownSpacesByDisplay[f.system.mainDisplay.id] = [space]
        f.system.desktopObservation?.windowMembership[f.system.windows[0].id] = [space]
        f.system.desktopObservation?.currentSpaceByDisplay[f.system.mainDisplay.id] = space
        f.system.offscreenWindowIDs = Set(f.system.windows.map(\.id))
        f.model.beginActiveSpaceStabilization()
        try await f.settle()
        // A retired session keeps model state only: no controller and no panel.
        #expect(f.overlays.compactMap(\.value).isEmpty)
        // AppKit can release a panel after its controller, on a later native callback.
        try #require(await f.system.waitFor { f.panels.isEmpty })
        #expect(f.panels.isEmpty)
        // The window arrives. The new desktop restores the retired Tabbed
        // desktop with a newly built controller and the same panel count.
        f.system.offscreenWindowIDs = []
        f.model.handleApplicationTopologyChange()
        try #require(await f.system.waitFor {
            f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.windowIDs.count == 1 && !f.model.hasPendingTabbedPlacement
        })
        // The retired controller is gone, so the live one was built on restore.
        #expect(f.overlays.compactMap(\.value).count == 1)
        #expect(f.overlays.count == created + 1)
        #expect(f.panels.count == initialCount)
    }
}

@Test(.appTestApplication, arguments: TabbedStripPresentation.allCases) @MainActor
func spacePanelPresentationResetsWithoutOrderingOnDeparture(presentation: TabbedStripPresentation) async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    f.model.configuration.tabbedStripPresentation = presentation
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let panel = try #require(f.panels.first { ($0.contentView as? TabbedPaneView)?.pane.tabs.isEmpty == false })
    let view = try #require(panel.contentView as? TabbedPaneView)
    if presentation == .autoHide {
        let menu = overlay.menu(pane: view.pane, windowID: nil)
        overlay.menuWillOpen(menu)
        #expect(!view.collapsed)
    }
    OffscreenTestWindows.check(panel)
    let orders = panel.orders
    f.switchTo(f.b)
    #expect(panel.orders == orders)
    #expect(abs(panel.frame.height - (presentation == .autoHide ? 6 : presentation.barHeight)) < 0.01)
    OffscreenTestWindows.check(panel)
    #expect(view.collapsed == (presentation == .autoHide))
    #expect(!overlay.showTabBar())
    try await f.settle()
    f.switchTo(f.a)
    try await f.settle()
    #expect(overlay.acceptsTabDrags)
    #expect(abs(panel.frame.height - (presentation == .autoHide ? 6 : presentation.barHeight)) < 0.01)
    #expect(f.panels.allSatisfy { $0.focusRequests == 0 })
}

@Test(.appTestApplication) @MainActor func spacePanelLifecycleEvidenceSurvivesStabilization() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let window = f.system.windows[0]
    f.switchTo(f.b)
    f.system.windows.removeAll()
    f.system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: window.id, processIdentifier: window.processIdentifier))
    #expect(overlay.state.windowIDs.isEmpty)
    try await f.settle()
    f.switchTo(f.a)
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.windowIDs.isEmpty == true)
    try await f.settle()
}

@Test(.appTestApplication) @MainActor func spacePanelTerminationClosureBatchUpdatesOnlyOwningTabs() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    var second = f.system.windows[0]
    second.id = WindowID(rawValue: "same-app-second")
    f.system.windows.append(second)
    var survivor = second
    survivor.id = WindowID(rawValue: "survivor")
    survivor.processIdentifier += 1
    f.system.windows.append(survivor)
    for window in f.system.windows { f.system.desktopObservation?.windowMembership[window.id] = [f.a] }
    f.model.setActiveMode(.tabbed)
    try #require(await waitFor { f.model.activeTabbedState?.windowIDs.count == 3 && !f.model.hasPendingTabbedPlacement })
    let overlay = try #require(f.overlays.first?.value)
    f.switchTo(f.b)
    try await f.settle()
    let writes = f.system.frameWriteCounts
    let closed = f.system.windows.filter { $0.processIdentifier != survivor.processIdentifier }
    f.system.windows = [survivor]
    // AccessibilityWindowSystem.synchronizeObservers emits this batch when an app terminates.
    for window in closed {
        f.system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: window.id, processIdentifier: window.processIdentifier))
    }
    #expect(overlay.state.windowIDs == [survivor.id])
    #expect(f.system.frameWriteCounts == writes)
}

@Test(.appTestApplication) @MainActor func spacePanelFullscreenDoesNotCreateOrOrderDesktopChrome() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let panels = f.panels
    let orders = panels.map(\.orders)
    f.system.desktopObservation?.fullscreenSpaceIDs = [f.b]
    f.switchTo(f.b)
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id) == nil)
    try await f.settle()
    #expect(f.overlays.count == 1)
    #expect(panels.map(\.orders) == orders)
    #expect(f.panels.allSatisfy { !$0.collectionBehavior.contains(.fullScreenAuxiliary)
        && !$0.collectionBehavior.contains(.canJoinAllSpaces) })
    f.switchTo(f.a)
    try await f.settle()
    #expect(f.overlays.count == 1)
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.windowIDs == [f.system.windows[0].id])
}

@Test(.appTestApplication) @MainActor func spacePanelTwoDisplaysKeepPickerAndGalleryScopedAfterReturn() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    let c = NativeSpaceID(rawValue: 33)
    var peer = f.system.availableDisplays[0]
    peer.id = DisplayID(rawValue: "peer")
    peer.frame.origin.x += 1100
    peer.visibleFrame.origin.x += 1100
    peer.isMain = false
    f.system.availableDisplays.append(peer)
    var peerWindow = f.system.windows[0]
    peerWindow.id = WindowID(rawValue: "peer-tab")
    peerWindow.processIdentifier += 1
    peerWindow.displayID = peer.id
    peerWindow.frame.origin.x += 1100
    f.system.windows.append(peerWindow)
    f.system.desktopObservation?.currentSpaceByDisplay[peer.id] = c
    f.system.desktopObservation?.knownSpacesByDisplay[peer.id] = [c]
    f.system.desktopObservation?.windowMembership[peerWindow.id] = [c]
    f.system.focusedID = f.system.windows[0].id
    try await f.enter()
    let first = try #require(f.overlays.first?.value)
    f.system.focusedID = peerWindow.id
    f.model.setActiveMode(.tabbed)
    try #require(await waitFor { f.model.presentedTabbedState(on: peer.id)?.windowIDs == [peerWindow.id]
        && !f.model.hasPendingTabbedPlacement })
    let second = try #require(f.overlays.last?.value)
    #expect(first !== second)
    f.system.desktopObservation?.currentSpaceByDisplay[f.system.mainDisplay.id] = f.b
    f.system.offscreenWindowIDs = [f.system.windows[0].id]
    f.model.beginActiveSpaceStabilization()
    try await f.settle()
    #expect(f.model.presentedTabbedState(on: peer.id)?.windowIDs == [peerWindow.id])
    let pane = try #require(second.state.panes.first?.id)
    let request = try #require(f.model.beginPaneApplicationPicker(paneID: pane, on: peer.id))
    first.onDismissApplicationPicker?()
    #expect(f.model.paneApplicationRequest?.id == request.id)
    f.model.cancelPaneApplicationRequest()
    let chooser = second.makeLayoutGallery()
    chooser.content.select(.grid)
    chooser.content.apply()
    try #require(await waitFor { f.model.presentedTabbedState(on: peer.id)?.panes.count == 4
        && !f.model.hasPendingTabbedPlacement })
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id) == nil)
    f.system.desktopObservation?.currentSpaceByDisplay[f.system.mainDisplay.id] = f.a
    f.system.offscreenWindowIDs = []
    f.model.beginActiveSpaceStabilization()
    try await f.settle()
    #expect(f.overlays.count == 2)
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.panes.count == first.state.panes.count)
    #expect(f.model.presentedTabbedState(on: peer.id)?.panes.count == 4)
    #expect(f.panels.allSatisfy { $0.focusRequests == 0 })
}

@Test(.appTestApplication) @MainActor func spacePanelShutdownReleasesActiveController() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let weak = try #require(f.overlays.first)
    f.model.shutdown()
    #expect(weak.value == nil)
    try #require(await waitFor { f.panels.isEmpty })
}


@Test(.appTestApplication) @MainActor func spacePanelCachedRemovalKeepsSurvivorContentAndHidesUnverifiedCurtain() throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    let overlay = f.model.tabbedOverlayFactory()
    defer { overlay.hide() }
    let selected = f.system.windows[0]
    var hidden = selected
    hidden.id = WindowID(rawValue: "hidden-survivor")
    hidden.title = "Surviving tab"
    var state = TabbedLayoutState(preset: .single)
    state.reconcile(windowIDs: [selected.id, hidden.id], removed: [], focused: selected.id)
    overlay.keepsPanelsOnSpace = true
    overlay.refresh(state: state, bounds: f.system.availableDisplays[0].visibleFrame,
                    windows: [selected, hidden], selectedWindowNumbers: [selected.id: 123],
                    curtainAnchorWindowNumber: 123)
    let curtain = try #require(f.panels.first { $0.contentView is TabbedCurtainView })
    let strip = try #require(f.panels.first { $0.contentView is TabbedPaneView })
    let view = try #require(strip.contentView as? TabbedPaneView)
    #expect(curtain.isVisible)
    overlay.prepareForSpaceChange()
    let orders = f.panels.map(\.orders)
    overlay.removeUnavailableWindows([selected.id])
    #expect(overlay.state.windowIDs == [hidden.id])
    #expect(view.pane.tabs == [hidden.id])
    #expect(view.pane.selected == hidden.id)
    #expect(view.titles == [hidden.title])
    #expect(!curtain.isVisible)
    #expect(strip.isVisible)
    #expect(!overlay.needsCurtainVerification)
    #expect(f.panels.map(\.orders) == orders)
    #expect(f.panels.allSatisfy { $0.focusRequests == 0 })
}

@Test(.appTestApplication) @MainActor func spacePanelBackgroundSweepDoesNotHideDepartedSession() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let panels = f.panels
    let orders = panels.map(\.orders)
    // A lifecycle/watchdog sweep can see the new native desktop before the
    // queued NSWorkspace Space-change callback runs.
    f.system.desktopObservation?.currentSpaceByDisplay[f.system.mainDisplay.id] = f.b
    f.system.offscreenWindowIDs = [f.system.windows[0].id]
    f.model.watchdog()
    #expect(panels.contains { $0.isVisible })
    #expect(panels.map(\.orders) == orders)
    #expect(!overlay.acceptsTabDrags)
    f.model.beginActiveSpaceStabilization()
    try await f.settle()
    f.switchTo(f.a)
    #expect(panels.contains { $0.isVisible })
    try await f.settle()
    #expect(f.overlays.count == 1)
}

@Test(.appTestApplication) @MainActor func spacePanelObservationLossKeepsUsableFallbackChrome() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let id = f.system.mainDisplay.id
    let nativeObservation = f.system.desktopObservation
    let exact = try #require(f.overlays.first?.value)
    let exactPanels = f.panels
    f.system.desktopObservation = nil
    f.model.handleApplicationTopologyChange()
    try await f.settle()
    #expect(f.model.activeLayoutMode == .tabbed)
    #expect(f.model.presentedTabbedState(on: id)?.windowIDs == [f.system.windows[0].id],
            "Native observation loss must retain usable legacy chrome for the matched Tabbed session")
    #expect(f.panels.contains { $0.isVisible && $0.collectionBehavior.contains(.moveToActiveSpace) })
    let fallback = try #require(f.overlays.last?.value)
    try #require(fallback !== exact)
    #expect(!fallback.keepsPanelsOnSpace)
    #expect(exactPanels.allSatisfy { !$0.isVisible })
    let unchanged = f.model.activeTabbedState
    exact.onIntent?(.preset(.grid, grouping: .keepTabGroups))
    #expect(f.model.activeTabbedState == unchanged, "A retired exact controller cannot act on fallback ownership")

    f.model.handleApplicationTopologyChange()
    try await f.settle()
    #expect(f.overlays.last?.value === fallback, "Fallback refresh reuses its display-scoped controller")
    let chooser = fallback.makeLayoutGallery()
    chooser.content.select(.grid)
    chooser.content.apply()
    try #require(await waitFor { f.model.activeTabbedState?.panes.count == 4 && !f.model.hasPendingTabbedPlacement })
    let pane = try #require(fallback.state.panes.last?.id)
    fallback.onIntent?(.activate(pane))
    #expect(f.model.activeTabbedState?.activePaneID == pane)
    let request = try #require(f.model.beginPaneApplicationPicker(paneID: pane, on: id))
    #expect(request.spaceID == nil, "A fallback picker captures current capability, not historical Space identity")
    f.model.advancePaneApplicationRequest()
    exact.onDismissApplicationPicker?()
    #expect(f.model.paneApplicationRequest?.id == request.id)
    f.model.cancelPaneApplicationRequest()

    let fallbackPanels = f.panels.filter { $0.collectionBehavior.contains(.moveToActiveSpace) }
    f.system.desktopObservation = nativeObservation
    f.model.handleApplicationTopologyChange()
    try await f.settle()
    let recovered = try #require(f.overlays.last?.value)
    #expect(recovered !== fallback && recovered !== exact)
    #expect(recovered.keepsPanelsOnSpace)
    #expect(fallbackPanels.allSatisfy { !$0.isVisible })
    #expect(f.model.presentedTabbedState(on: id)?.panes.count == 4)
    fallback.onIntent?(.preset(.single, grouping: .keepTabGroups))
    #expect(f.model.activeTabbedState?.panes.count == 4, "Retired fallback callbacks cannot mutate the recovered exact owner")
    f.model.handleApplicationTopologyChange()
    try await f.settle()
    #expect(f.overlays.last?.value === recovered)
    #expect(f.panels.allSatisfy { $0.focusRequests == 0 })
}

@Test(.appTestApplication, arguments: [WindowSystemEvent.Kind.destroyed, .minimized]) @MainActor
func spacePanelLifecycleImmediatelyBeforeDeparture(kind: WindowSystemEvent.Kind) async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let window = f.system.windows[0]
    if kind == .destroyed { f.system.windows.removeAll() }
    else { f.system.windows[0].isMinimized = true }
    f.system.eventHandler?(WindowSystemEvent(kind: kind, windowID: window.id, processIdentifier: window.processIdentifier))
    // Same main-actor turn: the Space callback arrives before the debounced sweep.
    f.switchTo(f.b)
    try await f.settle()
    #expect(overlay.state.windowIDs.isEmpty, "Departure must not freeze a confirmed closed/minimized tab")
    f.switchTo(f.a)
    #expect(f.model.presentedTabbedState(on: f.system.mainDisplay.id)?.windowIDs.isEmpty == true,
            "The cached strip must be correct before arrival stabilization")
    try await f.settle()
    #expect(overlay.state.windowIDs.isEmpty)
}

@Test(.appTestApplication, arguments: [WindowSystemEvent.Kind.destroyed, .minimized]) @MainActor
func spacePanelLifecycleDuringArrival(kind: WindowSystemEvent.Kind) async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let overlay = try #require(f.overlays.first?.value)
    let window = f.system.windows[0]
    f.switchTo(f.b)
    try await f.settle()
    f.switchTo(f.a)
    if kind == .destroyed { f.system.windows.removeAll() }
    else { f.system.windows[0].isMinimized = true }
    f.system.eventHandler?(WindowSystemEvent(kind: kind, windowID: window.id, processIdentifier: window.processIdentifier))
    #expect(overlay.state.windowIDs.isEmpty, "A lifecycle event delivered during arrival must update retained content now")
    try await f.settle()
    #expect(overlay.state.windowIDs.isEmpty)
}


@Test(.appTestApplication) @MainActor func spacePanelRevalidatesSpaceBeforeFirstOrder() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    var switched = false
    f.system.onWindowNumbers = {
        guard !switched, !f.overlays.isEmpty else { return }
        switched = true
        f.system.desktopObservation?.currentSpaceByDisplay[f.system.mainDisplay.id] = f.b
        f.system.offscreenWindowIDs = Set(f.system.windows.map(\.id))
    }
    defer { f.system.onWindowNumbers = nil }
    f.model.setActiveMode(.tabbed)
    try #require(await waitFor { switched && !f.model.hasPendingTabbedPlacement })
    #expect(!f.panels.contains { $0.firstOrderedSpace == f.b },
            "A's retained panels must not be first ordered on B after pre-order reads")
    f.model.beginActiveSpaceStabilization()
    try await f.settle()
    #expect(!f.panels.contains { $0.firstOrderedSpace == f.b && $0.isVisible },
            "The outgoing A strip must not remain on the current B desktop")
}

@Test(.appTestApplication) @MainActor func spacePanelDirectRefreshAfterObservationLossRebuildsFallback() async throws {
    let f = SpacePanelFixture()
    defer { f.close() }
    try await f.enter()
    let exact = try #require(f.overlays.first?.value)
    let panels = f.panels
    let pane = try #require(exact.state.panes.first?.id)
    f.system.desktopObservation = nil
    // A direct pane action can present before the next topology sweep.
    f.model.performTabbed(.activate(pane))
    let fallback = try #require(f.overlays.last?.value)
    #expect(fallback !== exact)
    #expect(!fallback.keepsPanelsOnSpace)
    #expect(panels.allSatisfy { !$0.isVisible })
    #expect(f.panels.contains { $0.isVisible && $0.collectionBehavior.contains(.moveToActiveSpace) })
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func spacePanelRevalidatesCapabilityBeforeFirstOrder(losesObservation: Bool) async throws {
    let f = SpacePanelFixture(exact: losesObservation)
    defer { f.close() }
    let native = NativeDesktopObservation(
        currentSpaceByDisplay: [f.system.mainDisplay.id: f.a],
        knownSpacesByDisplay: [f.system.mainDisplay.id: [f.a, f.b]],
        windowMembership: [f.system.windows[0].id: [f.a]])
    var changed = false
    f.system.onWindowNumbers = {
        guard !changed, !f.overlays.isEmpty else { return }
        changed = true
        f.system.desktopObservation = losesObservation ? nil : native
    }
    defer { f.system.onWindowNumbers = nil }
    f.model.setActiveMode(.tabbed)
    try #require(await waitFor { changed && !f.model.hasPendingTabbedPlacement })
    #expect(f.panels.allSatisfy { $0.orders == 0 && !$0.isVisible })
    f.model.handleApplicationTopologyChange()
    try await f.settle()
    // A newly observed exact desktop can have its own default mode.
    if f.model.activeLayoutMode != .tabbed { try await f.enter() }
    let overlay = try #require(f.overlays.last?.value)
    #expect(overlay.keepsPanelsOnSpace == !losesObservation)
    #expect(f.panels.contains { $0.isVisible })
}

/// Even a stale or reset source frame must stay in the reserved off-screen
/// range. Synthetic visibility must not make the process audit see a display.
@Test(.appTestApplication, arguments: [0.0, 40000.0]) @MainActor
func spacePanelSyntheticVisibilityUsesOffscreenGeometry(sourceX: Double) {
    _ = NSApplication.shared
    let panel = FakeSpacePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
    defer { panel.orderOut(nil) }
    let requested = NSRect(x: sourceX, y: 0, width: 1000, height: 34)
    panel.setFrame(requested, display: false)
    panel.orderFrontRegardless()
    panel.setFrame(NSRect(x: sourceX, y: 28, width: 1000, height: 6), display: false)
    panel.setFrame(requested, display: true)
    #expect(panel.frame == OffscreenTestWindows.windowFrame(requested))
    OffscreenTestWindows.check(panel)
}
