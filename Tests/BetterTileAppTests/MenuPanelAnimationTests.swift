import AppKit
import BetterTileCore
import BetterTileMacOS
import BetterTileTestSupport
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct MenuPanelAnimationTests {
    private let anchor = NSRect(x: 600, y: 1056, width: 24, height: 24)
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1056)

    @Test func openingInstallsAnAnchoredLayerTransitionOffscreen() {
        _ = NSApplication.shared
        let controller = MenuPanelController(rootView: Text("Menu").frame(width: 332, height: 300),
            appearance: .init(), presentWindow: { _ in }, reduceMotion: { false })
        defer { controller.dismiss(); controller.panel.close() }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        #expect(controller.animationLayer?.animationKeys()?.isEmpty == false)
    }

    @Test func panelRetainsItsBorderlessKeyBehavior() {
        _ = NSApplication.shared
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in })
        defer { controller.panel.close() }
        #expect(controller.panel.styleMask == [.borderless])
        #expect(controller.panel.canBecomeKey)
        #expect(!controller.panel.becomesKeyOnlyIfNeeded)
    }
    @Test func reopeningDuringCloseRejectsBothSupersededCompletions() {
        _ = NSApplication.shared
        var completions: [@MainActor () -> Void] = []
        var dismissals = 0
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(),
            presentWindow: { _ in }, onDismiss: { dismissals += 1 },
            animate: { _, done in completions.append(done) })
        defer { controller.panel.close() }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        #expect(controller.phase == .opening && controller.isShown)
        completions[0]()
        #expect(controller.phase == .shown)
        controller.dismiss(reason: .outsideClick)
        #expect(controller.phase == .closing && !controller.isShown)
        #expect(controller.panel.ignoresMouseEvents && dismissals == 1)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        let window = controller.panel
        #expect(controller.phase == .opening && controller.isShown)
        #expect(!controller.panel.ignoresMouseEvents)
        completions[1]() // The old close must not hide the replacement presentation.
        completions[0]() // Nor may an old open finish the replacement open.
        #expect(controller.phase == .opening && controller.isShown)
        #expect(controller.panel === window)
        completions[2]()
        #expect(controller.phase == .shown && controller.closeReason == nil)
        controller.dismiss()
        completions[3]()
        #expect(controller.phase == .hidden && !controller.isShown)
    }

    @Test(arguments: MenuPanelCloseReason.allCases)
    func everyCloseReasonAnimatesOnceAndReleasesInputImmediately(reason: MenuPanelCloseReason) {
        _ = NSApplication.shared
        var transitions: [MenuPanelAnimation] = []
        var completions: [@MainActor () -> Void] = []
        var dismissals = 0
        var closed: [MenuPanelCloseReason] = []
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: { dismissals += 1 }, onDidClose: { closed.append($0) }, reduceMotion: { false },
            animate: { transitions.append($0); completions.append($1) })
        defer { controller.panel.close() }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        controller.dismiss(reason: reason) // Closing during opening is supported too.
        controller.dismiss(reason: .programmatic)
        #expect(controller.closeReason == reason && transitions.count == 2 && dismissals == 1)
        #expect(transitions.map(\.opening) == [true, false])
        #expect(controller.panel.ignoresMouseEvents && !controller.isShown)
        #expect(closed.isEmpty)
        completions[0]()
        #expect(controller.phase == .closing)
        completions[1]()
        #expect(controller.phase == .hidden)
        #expect(closed == [reason])
    }

    @Test func reduceMotionUsesOnlyAFadeInBothDirections() {
        _ = NSApplication.shared
        var transitions: [MenuPanelAnimation] = []
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            reduceMotion: { true }, animate: { transition, done in transitions.append(transition); done() })
        defer { controller.panel.close() }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        #expect(controller.phase == .shown)
        controller.dismiss()
        #expect(controller.phase == .hidden && transitions.count == 2)
        #expect(transitions.allSatisfy { $0.reduceMotion && $0.hiddenScale == 1 && $0.duration == 0.12 })
        #expect(CATransform3DIsIdentity(controller.glass.layer!.transform))
    }

    @Test func reentrantDismissalCallbackCannotStartAnOldCloseAfterReopening() {
        _ = NSApplication.shared
        var transitions: [Bool] = []
        var reopen: (() -> Void)?
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: { reopen?() }, animate: { transition, _ in transitions.append(transition.opening) })
        defer { controller.panel.close() }
        reopen = { controller.show(relativeTo: anchor, visibleFrame: screen) }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        controller.dismiss()
        #expect(transitions == [true, true] && controller.isShown)
        reopen = nil
    }

    @Test(arguments: [CGFloat(0), 0.5, 1])
    func scaleKeepsTheTopStatusItemPivotFixed(layerAnchor: CGFloat) {
        for x in [8.0, 166, 324] {
            let pivot = NSPoint(x: x, y: 600)
            let origin = NSPoint(x: 332 * layerAnchor, y: 600 * layerAnchor)
            let t = MenuPanelAnimation.transform(scale: 0.25, pivot: pivot, origin: origin)
            #expect(abs(origin.x + (pivot.x - origin.x) * t.m11 + t.m41 - pivot.x) < 0.000001)
            #expect(abs(origin.y + (pivot.y - origin.y) * t.m22 + t.m42 - pivot.y) < 0.000001)
        }
    }

    @Test(arguments: [false, true])
    func adaptiveToTabbedKeepsMenuFocusWithoutChangingPlacement(menuShown: Bool) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        system.frontmostOverride = 999_999 // BetterTile is frontmost; focusedWindow reports the last managed app.
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        try #require(await waitFor { model.activeLayoutMode == .bento })
        var shown = menuShown
        model.menuPanelIsShown = { shown }
        system.focusRequests.removeAll()
        system.raiseRequests.removeAll()
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
        // Wait for the placement and its background stacking to finish, then for queued window events.
        try #require(await waitFor {
            !model.hasPendingTabbedPlacement && !system.raiseRequests.isEmpty
                && (menuShown || !system.focusRequests.isEmpty)
        })
        try await waitForWindowEventsToDrain(model)
        // macOS reports the placed window's focus, which schedules the Tabbed focus refresh at least
        // 80 ms later. That refresh must not take focus from the menu either.
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.windows[0].id,
                                               processIdentifier: system.windows[0].processIdentifier))
        let focusRefresh = try #require(model.tabbedFocusTask, "A focus change on a Tabbed desktop schedules a refresh")
        await focusRefresh.value
        try await waitForWindowEventsToDrain(model)
        #expect(model.activeLayoutMode == .tabbed)
        #expect(!system.requestedFrames.isEmpty)
        #expect(!system.raiseRequests.isEmpty) // Background stacking still runs.
        #expect(system.focusRequests.isEmpty == menuShown)
        shown = false
        model.menuPanelDidDismiss()
        #expect(system.focusRequests.last == system.windows[0].id)
        let requests = system.focusRequests.count
        model.menuPanelDidDismiss()
        #expect(system.focusRequests.count == requests)
    }

    @Test func arrivingTabbedWindowGetsDeferredFocusWhenMenuCloses() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
        var shown = true
        model.menuPanelIsShown = { shown }
        system.frontmostOverride = 999_999
        system.focusRequests.removeAll()
        var arrival = system.windows[0]
        arrival.id = WindowID(rawValue: "arrived-under-menu")
        arrival.processIdentifier += 1
        system.windows.append(arrival)
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival.id,
                                              processIdentifier: arrival.processIdentifier))
        try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(arrival.id) == true })
        #expect(system.focusRequests.isEmpty)
        shown = false
        model.menuPanelDidDismiss()
        #expect(system.focusRequests.last == arrival.id)
    }

    @Test(arguments: ["unchanged", "spaceBeforeDismiss", "capabilityLost", "capabilityGained",
                      "membershipChanged", "unknownMembership", "multiSpace", "fullscreen", "disconnected",
                      "stabilizing", "permissionLost"])
    func deferredFocusRevalidatesDesktopAtDismissal(change: String) async throws {
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1)
        let second = NativeSpaceID(rawValue: 2)
        let target = system.windows[0].id
        let native = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]], windowMembership: [target: [first]])
        system.desktopObservation = change == "capabilityGained" ? nil : native
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var completions: [@MainActor () -> Void] = []
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: { model.menuPanelDidDismiss() },
            animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { panel.isShown }
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && !model.hasPendingTabbedPlacement })
        #expect(system.focusRequests.isEmpty)
        switch change {
        case "spaceBeforeDismiss": system.physicalSpace = second
        case "capabilityLost": system.desktopObservation = nil
        case "capabilityGained": system.desktopObservation = native
        case "membershipChanged": system.desktopObservation?.windowMembership[target] = [second]
        case "unknownMembership": system.desktopObservation?.windowMembership[target] = nil
        case "multiSpace": system.desktopObservation?.windowMembership[target] = [first, second]
        case "fullscreen": system.desktopObservation?.fullscreenSpaceIDs = [first]
        case "disconnected": system.availableDisplays = []
        case "stabilizing": model.beginActiveSpaceStabilization()
        case "permissionLost": system.permission = false; model.recheckAccessibilityPermission()
        default: break
        }
        let reads = system.nativeDesktopRefreshCount
        panel.dismiss()
        let expected = change == "unchanged" ? [target] : []
        #expect(system.focusRequests == expected, "Focus is revalidated and replayed at the dismissal")
        if change == "unchanged" { #expect(system.nativeDesktopRefreshCount > reads) }
        completions[1]()
        #expect(system.focusRequests == expected, "The completed fade replays nothing")
        model.menuPanelDidDismiss()
        #expect(system.focusRequests == expected, "A dismissal consumes the target once")
    }

    /// Escape and a Space switch in one burst: macOS reports the new Space only after its animation,
    /// later than the panel's fade. Focus returns at Escape, before the switch, and never during it.
    @Test func escapeThenSpaceSwitchActivatesNothingDuringTheSwitch() async throws {
        let system = FakeAppWindowSystem()
        let display = system.mainDisplay.id
        let first = NativeSpaceID(rawValue: 1)
        let second = NativeSpaceID(rawValue: 2)
        let target = system.windows[0].id
        system.desktopObservation = NativeDesktopObservation(currentSpaceByDisplay: [display: first],
            knownSpacesByDisplay: [display: [first, second]], windowMembership: [target: [first]])
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var completions: [@MainActor () -> Void] = []
        let callbacks = MenuPanelCloseCallbacks(model: model, closeReason: { .escape }, applicationIsActive: { true })
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: callbacks.onDismiss,
            animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { [weak panel] in panel?.isShown == true }
        model.menuPanelWillOpen()
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && !model.hasPendingTabbedPlacement })
        panel.dismiss(reason: .escape)
        let beforeSwitch = system.focusRequests
        // The switch key follows Escape. macOS still reports the old Space while it animates.
        completions[1]()
        #expect(system.focusRequests == beforeSwitch, "No activation while the switch animates")
        system.physicalSpace = second
        model.beginActiveSpaceStabilization()
        #expect(system.focusRequests == beforeSwitch, "No activation after the switch either")
        #expect(beforeSwitch == [target], "Focus returned at Escape, on the desktop that was current then")
    }

    @Test(arguments: MenuPanelCommand.allCases)
    func panelCommandHandlerDiscardsFocusBeforeItsCloseCompletes(command: MenuPanelCommand) async throws {
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var completions: [@MainActor () -> Void] = []
        let callbacks = MenuPanelCloseCallbacks(model: model, closeReason: { .command }, applicationIsActive: { true })
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: callbacks.onDismiss,
            animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { [weak panel] in panel?.isShown == true }
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && !model.hasPendingTabbedPlacement })
        let delegate = BetterTileAppDelegate(model: model) { reason in
            panel.dismiss(reason: reason)
        }
        let selector: Selector
        switch command {
        case .showTabBar: selector = NSSelectorFromString("showTabBar")
        case .repairLayout: selector = NSSelectorFromString("repairCurrentLayout")
        }
        try #require(delegate.responds(to: selector))
        _ = delegate.perform(selector)
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        #expect(panel.closeReason == .command)
        let requests = system.focusRequests
        completions[1]()
        #expect(system.focusRequests == requests, "Panel completion must preserve the command's focus")
    }

    @Test(arguments: MenuPanelCloseReason.allCases, [false, true])
    func deferredFocusCloseRuleAllowsOnlyActiveUserDismissals(reason: MenuPanelCloseReason, active: Bool) {
        let userDismissal = reason == .statusItem || reason == .escape
        #expect(reason.restoresDeferredFocus == userDismissal)
        #expect(reason.allowsDeferredFocus(applicationIsActive: active) == (active && userDismissal))
    }

    @Test(arguments: MenuPanelCloseReason.allCases, [false, true])
    func productionCloseCallbacksApplyTheRuleAtDismissal(reason: MenuPanelCloseReason, active: Bool) {
        var currentReason: MenuPanelCloseReason? = reason
        var isActive = active
        var authorizations: [() -> Bool] = []
        var dismissCount = 0
        let callbacks = MenuPanelCloseCallbacks(closeReason: { currentReason },
            applicationIsActive: { isActive }, onDismiss: { dismissCount += 1 },
            didDismiss: { authorizations.append($0) })
        let expected = active && (reason == .statusItem || reason == .escape)
        callbacks.onDismiss()
        #expect(authorizations.map { $0() } == [expected])
        #expect(dismissCount == 1)
        currentReason = nil
        #expect(authorizations.map { $0() } == [expected], "The rule keeps the reason of its own dismissal")
        isActive = false
        #expect(authorizations.map { $0() } == [false], "The rule reads the activity again at a late replay")
        isActive = active
        callbacks.onDismiss()
        #expect(authorizations.map { $0() } == [expected, false], "A missing close reason must fail closed")
    }

    @Test(arguments: MenuPanelCloseReason.allCases, [false, true])
    func dismissalReplaysFocusOnlyForStatusItemAndEscape(reason: MenuPanelCloseReason, active: Bool) async throws {
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var completions: [@MainActor () -> Void] = []
        var dismissed = false
        let callbacks = MenuPanelCloseCallbacks(model: model, closeReason: { reason },
            applicationIsActive: { active }, onDismiss: { dismissed = true })
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: callbacks.onDismiss,
            animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { [weak panel] in panel?.isShown == true }
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && !model.hasPendingTabbedPlacement })
        let target = system.windows[0].id
        #expect(system.focusRequests.isEmpty)
        panel.dismiss(reason: reason)
        #expect(dismissed)
        let expected = active && (reason == .statusItem || reason == .escape) ? [target] : []
        #expect(system.focusRequests == expected, "Focus replays at the dismissal, before the fade")
        completions[1]()
        #expect(system.focusRequests == expected, "Closing for another action must preserve that action's focus")
    }

    /// A placement that commits after the dismissal waits for the Space to settle, then revalidates
    /// and focuses once. A Space change, another app's activation, a command, a reopened panel, an
    /// inactive BetterTile or a click outside cancels it. The fade's completion plays no part.
    @Test(arguments: ["duringFade", "afterFade"],
          ["active", "inactive", "outsideClick", "command", "otherAppDuringWait", "spaceChangeDuringWait",
           "reopenedDuringWait"])
    func latePlacementAfterDismissalWaitsForTheSpaceToSettle(release: String, change: String) async throws {
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let wait = ManualClock()
        model.menuPanelClock = wait.clock
        var active = true
        let reason: MenuPanelCloseReason = change == "outsideClick" ? .outsideClick : .escape
        var completions: [@MainActor () -> Void] = []
        let callbacks = MenuPanelCloseCallbacks(model: model, closeReason: { reason }, applicationIsActive: { active })
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: callbacks.onDismiss,
            animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { [weak panel] in panel?.isShown == true }
        model.menuPanelWillOpen()
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        let target = system.windows[0].id
        var held = false
        var pendingWhenHeld = false
        // The first read after Tabbed writes the window runs before its placement commits.
        system.onWindowSnapshots = { [weak system, weak model, weak panel] in
            guard let system, let model, let panel, !held, system.frameWriteCounts[target, default: 0] > 0 else { return }
            held = true
            pendingWhenHeld = model.hasPendingTabbedPlacement
            panel.dismiss(reason: reason)
            if release == "afterFade" { completions[1]() }
            switch change {
            case "inactive": active = false
            case "command": model.perform(.showTabBar)
            default: break
            }
        }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { held && !model.hasPendingTabbedPlacement })
        system.onWindowSnapshots = nil
        #expect(pendingWhenHeld)
        #expect(model.activeTabbedState?.windowIDs == [target])
        #expect(system.focusRequests.isEmpty, "A placement that commits after the dismissal waits")
        let replays = change == "active" ? [target] : []
        if let late = model.menuPanelLateFocusTask {
            await wait.waitForSleepers(count: 1)
            switch change {
            case "otherAppDuringWait": model.requestApplicationActivated("com.example.Other")
            case "spaceChangeDuringWait": model.beginActiveSpaceStabilization()
            case "reopenedDuringWait":
                model.menuPanelWillOpen()
                panel.show(relativeTo: anchor, visibleFrame: screen)
            default: break
            }
            wait.advance(by: model.menuPanelLateFocusDelay - .milliseconds(1))
            #expect(system.focusRequests.isEmpty, "Focus waits for the whole settle interval")
            wait.advance(by: .milliseconds(1))
            await late.value
        } else {
            #expect(replays.isEmpty, "A replayable late placement schedules its wait")
        }
        #expect(system.focusRequests == replays)
        if change == "reopenedDuringWait" {
            panel.dismiss(reason: .escape)
        } else if release == "duringFade" {
            completions[1]()
        }
        #expect(system.focusRequests == replays, "Neither the fade nor a later dismissal focuses again")
    }

    /// User commands that bypass `perform` and `performTabbed` also end the late focus wait: a tab-strip
    /// intent, the pane's add-application button, a Saved Layout (shortcut, chooser or wheel), opening the
    /// Layout Wheel, a window or tab drag, and a divider or linked-resize gesture.
    @Test(arguments: ["tabStrip", "addApplication", "savedLayout", "layoutWheelOpened", "bentoDrag", "windowGesture"])
    func userCommandsCancelTheLateFocusWait(action: String) async throws {
        let system = FakeAppWindowSystem()
        // The tab strip exists only with Tabbed chrome. The offscreen factories keep it off the user's screens.
        let model = makeOffscreenModel(
            store: ConfigurationStore(fileURL: URL(filePath: "/private/tmp/BetterTileMenuFocusTests-\(UUID().uuidString)/configuration.json")),
            system: system, startRuntime: false, presentsTabbedChrome: true)
        model.primaryButtonIsPressed = { false }
        defer { model.shutdown() }
        var overlays: [TabbedOverlayController] = []
        let makeOverlay = model.tabbedOverlayFactory
        model.tabbedOverlayFactory = { let overlay = makeOverlay(); overlays.append(overlay); return overlay }
        let wait = ManualClock()
        model.menuPanelClock = wait.clock
        var completions: [@MainActor () -> Void] = []
        let callbacks = MenuPanelCloseCallbacks(model: model, closeReason: { .escape }, applicationIsActive: { true })
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: callbacks.onDismiss, animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { [weak panel] in panel?.isShown == true }
        model.menuPanelWillOpen()
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        let target = system.windows[0].id
        var held = false
        // Escape arrives after Tabbed writes the window and before its placement commits.
        system.onWindowSnapshots = { [weak system, weak panel] in
            guard let system, let panel, !held, system.frameWriteCounts[target, default: 0] > 0 else { return }
            held = true
            panel.dismiss(reason: .escape)
            completions[1]()
        }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { held && !model.hasPendingTabbedPlacement })
        system.onWindowSnapshots = nil
        let late = try #require(model.menuPanelLateFocusTask, "The late placement waits")
        await wait.waitForSleepers(count: 1)
        let overlay = try #require(overlays.last)
        switch action {
        case "tabStrip": overlay.onIntent?(.select(target))
        case "addApplication":
            let pane = try #require(model.activeTabbedState?.panes.first?.id)
            overlay.onAddApplication?(pane, NSView(), .zero)
        case "savedLayout": _ = model.applySavedLayoutAction("missing.json")
        case "layoutWheelOpened": model.layoutWheelDidOpen()
        case "bentoDrag":
            if model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: target) {
                model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: target, end: .restore)
            }
        default: model.prepareWindowGesture()
        }
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        let afterAction = system.focusRequests
        wait.advance(by: model.menuPanelLateFocusDelay)
        await late.value
        #expect(late.isCancelled, "The user's command ends the wait")
        #expect(system.focusRequests == afterAction, "The old target is not focused after a user command")
        model.cancelPaneApplicationRequest()
    }

    /// Two placements in one presentation: the first commits under the panel and focuses at the dismissal,
    /// and the second commits after it. The dismissal's single focus is spent, so the second focuses nothing.
    @Test func aSecondPlacementAfterTheDismissalFocusDoesNotFocusAgain() async throws {
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let wait = ManualClock()
        model.menuPanelClock = wait.clock
        var completions: [@MainActor () -> Void] = []
        let callbacks = MenuPanelCloseCallbacks(model: model, closeReason: { .escape }, applicationIsActive: { true })
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: callbacks.onDismiss, animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { [weak panel] in panel?.isShown == true }
        model.menuPanelWillOpen()
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        system.frontmostOverride = 999_999
        model.setActiveMode(.tabbed)
        try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 && !model.hasPendingTabbedPlacement })
        let first = system.windows[0].id
        var arrival = system.windows[0]
        arrival.id = WindowID(rawValue: "second-placement")
        arrival.processIdentifier += 1
        arrival.frame = BTRect(x: 100, y: 100, width: 300, height: 200) // Its placement writes a frame.
        system.windows.append(arrival)
        var held = false
        // The arrival's placement is still running when Escape focuses the first target.
        system.onWindowSnapshots = { [weak system, weak panel] in
            guard let system, let panel, !held, system.frameWriteCounts[arrival.id, default: 0] > 0 else { return }
            held = true
            panel.dismiss(reason: .escape)
        }
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival.id,
                                              processIdentifier: arrival.processIdentifier))
        try #require(await waitFor { held && model.activeTabbedState?.windowIDs.contains(arrival.id) == true
            && !model.hasPendingTabbedPlacement })
        system.onWindowSnapshots = nil
        #expect(system.focusRequests == [first], "Escape focuses the target that committed under the panel")
        if let late = model.menuPanelLateFocusTask {
            await wait.waitForSleepers(count: 1)
            wait.advance(by: model.menuPanelLateFocusDelay)
            await late.value
        }
        completions[1]()
        #expect(system.focusRequests == [first], "One dismissal focuses once")
    }

    /// A size retry keeps the focus deferral of its placement request. After Escape and an app switch
    /// during the first attempt, the retry focuses nothing. Otherwise the late placement focuses once,
    /// after its settle interval.
    @Test(arguments: ["duringFade", "afterFade"], ["switchedApp", "stayedActive"])
    func placementRetryKeepsDeferredFocusAuthorization(release: String, change: String) async throws {
        let system = FakeAppWindowSystem()
        system.measuresOnWrite = true
        system.frontmostOverride = 999_999 // BetterTile is frontmost while its menu is shown.
        let target = system.windows[0].id
        // The minimum appears only when a write is refused, so the first attempt fails and a fitted retry runs.
        system.windows[0].frame = BTRect(x: 0, y: 0, width: 600, height: 800)
        system.enforcedMinimumWidths[target] = 600
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.configuration.singleWindowPlacement = nil
        model.configuration.defaultTabbedPreset = .columns
        let wait = ManualClock()
        model.menuPanelClock = wait.clock
        var active = true
        var completions: [@MainActor () -> Void] = []
        let callbacks = MenuPanelCloseCallbacks(model: model, closeReason: { .escape }, applicationIsActive: { active })
        let panel = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onDismiss: callbacks.onDismiss,
            animate: { _, done in completions.append(done) })
        defer { panel.panel.close() }
        model.menuPanelIsShown = { [weak panel] in panel?.isShown == true }
        model.menuPanelWillOpen()
        panel.show(relativeTo: anchor, visibleFrame: screen)
        completions[0]()
        var writesAtDismissal: Int?
        var pendingWhenDismissed = false
        // The first read after the first write belongs to the first attempt.
        system.onWindowSnapshots = { [weak system, weak model, weak panel] in
            guard let system, let model, let panel, writesAtDismissal == nil,
                  let writes = system.requestedFrames[target]?.count, writes > 0 else { return }
            writesAtDismissal = writes
            pendingWhenDismissed = model.hasPendingTabbedPlacement
            panel.dismiss(reason: .escape)
            if release == "afterFade" { completions[1]() }
            if change == "switchedApp" {
                active = false
                model.requestApplicationActivated("com.example.Other")
            }
        }
        model.setActiveMode(.tabbed)
        try #require(await waitFor { writesAtDismissal != nil && !model.hasPendingTabbedPlacement })
        system.onWindowSnapshots = nil
        #expect(pendingWhenDismissed)
        let requests = system.requestedFrames[target] ?? []
        let dismissedAt = try #require(writesAtDismissal)
        #expect(requests.first.map { $0.size.width < 600 } == true, "The first attempt asks for less than the minimum")
        #expect(requests.dropFirst(dismissedAt).contains { $0.size.width >= 600 }, "A fitted retry wrote after dismissal")
        #expect(model.activeTabbedState?.panes.count == 2, "\(String(describing: model.statusMessage))")
        #expect(system.windows[0].frame.size.width == 600)
        let replays = change == "stayedActive" ? [target] : []
        #expect(system.focusRequests.isEmpty, "A retry must not turn the deferred focus into an immediate one")
        if let late = model.menuPanelLateFocusTask {
            await wait.waitForSleepers(count: 1)
            wait.advance(by: model.menuPanelLateFocusDelay)
            await late.value
        }
        #expect(system.focusRequests == replays)
        if release == "duringFade" { completions[1]() }
        model.menuPanelDidDismiss()
        #expect(system.focusRequests == replays, "One placement focuses at most once")
    }

    @Test func closeClearsKeyboardResponderAndReopenDuringFadeRestoresIt() throws {
        _ = NSApplication.shared
        var completions: [@MainActor () -> Void] = []
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(),
            presentWindow: { _ in }, animate: { _, done in completions.append(done) })
        defer { controller.panel.close() }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        let responder = PanelKeyboardResponder(frame: .zero)
        controller.glass.addSubview(responder)
        let action = PanelKeyboardAction()
        let button = NSButton(title: "Confirm", target: action, action: #selector(PanelKeyboardAction.confirm))
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        button.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        controller.glass.addSubview(button)
        try #require(controller.panel.makeFirstResponder(responder))
        controller.dismiss()
        #expect(controller.panel.firstResponder !== responder)
        #expect(!controller.panel.acceptsControlInput)
        for key: UInt16 in [36, 49] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil,
                characters: key == 36 ? "\r" : " ", charactersIgnoringModifiers: key == 36 ? "\r" : " ", isARepeat: false, keyCode: key))
            controller.panel.sendEvent(event)
            #expect(controller.panel.performKeyEquivalent(with: event))
        }
        #expect(responder.keyDownCount == 0)
        #expect(action.count == 0)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        #expect(controller.panel.firstResponder === responder)
        #expect(controller.panel.acceptsControlInput)
    }

    @Test func reopenAfterCompletedCloseUsesNormalInitialResponder() throws {
        _ = NSApplication.shared
        var completions: [@MainActor () -> Void] = []
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(),
            presentWindow: { _ in }, animate: { _, done in completions.append(done) })
        defer { controller.panel.close() }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        let initialResponder = try #require(controller.panel.firstResponder)
        completions[0]()
        let responder = PanelKeyboardResponder(frame: .zero)
        controller.glass.addSubview(responder)
        try #require(controller.panel.makeFirstResponder(responder))
        controller.dismiss()
        completions[1]()
        #expect(controller.phase == .hidden)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        #expect(controller.panel.firstResponder === initialResponder)
        #expect(controller.panel.firstResponder !== responder)
        #expect(controller.panel.acceptsControlInput)
    }

    @Test(arguments: ["command", "leftTabbed", "closedTarget", "failedPlacement"])
    func closeDiscardsUnwantedOrInvalidDeferredFocus(reason: String) async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.bento)
        var shown = true
        model.menuPanelIsShown = { shown }
        system.focusRequests.removeAll()
        model.statusMessage = nil
        if reason == "failedPlacement" { system.ignoredFrameWriteWindowIDs.insert(system.windows[0].id) }
        model.setActiveMode(.tabbed)
        if reason == "failedPlacement" {
            try #require(await waitFor { model.statusMessage != nil })
        } else {
            try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 1 })
        }
        if reason == "leftTabbed" {
            model.setActiveMode(.manual)
            try #require(await waitFor { model.activeLayoutMode == .manual })
        }
        if reason == "closedTarget" { system.windows.removeAll() }
        let requests = system.focusRequests.count
        shown = false
        model.menuPanelDidDismiss(authorization: { reason != "command" })
        #expect(system.focusRequests.count == requests)
    }

    @Test(arguments: [false, true])
    func windowFadeKeepsLayerOpacityOneAndReduceMotionOmitsScale(reduced: Bool) async throws {
        _ = NSApplication.shared
        let controller = MenuPanelController(rootView: Text("Menu").frame(width: 332, height: 300),
            appearance: .init(), presentWindow: { _ in }, reduceMotion: { reduced })
        defer { controller.panel.close() }
        controller.show(relativeTo: anchor, visibleFrame: screen)
        let opening = controller.animationLayer?.animation(forKey: "menuPanelTransition") as? CAAnimationGroup
        #expect(opening?.animations?.compactMap { ($0 as? CABasicAnimation)?.keyPath } == (reduced ? nil : ["transform"]))
        #expect(controller.glass.layer?.opacity == 1)
        #expect(CATransform3DIsIdentity(controller.glass.layer!.transform))
        #expect(controller.glass.layer?.animationKeys()?.isEmpty != false)
        #expect(await waitFor { controller.panel.alphaValue == 1 })
        controller.dismiss()
        let closing = controller.animationLayer?.animation(forKey: "menuPanelTransition") as? CAAnimationGroup
        #expect(closing?.animations?.compactMap { ($0 as? CABasicAnimation)?.keyPath } == (reduced ? nil : ["transform"]))
        #expect(controller.glass.layer?.opacity == 1)
        #expect(await waitFor { controller.panel.alphaValue == 0 })
        if reduced { #expect(CATransform3DIsIdentity(controller.glass.layer!.transform)) }
    }

}

@MainActor private final class PanelKeyboardResponder: NSView {
    var keyDownCount = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keyDownCount += 1 }
}

@MainActor private final class PanelKeyboardAction: NSObject {
    var count = 0
    @objc func confirm() { count += 1 }
}
