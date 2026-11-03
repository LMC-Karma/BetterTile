import AppKit
import BetterTileCore
import BetterTileTestSupport
@testable import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor private final class FakePaneApplicationLauncher: PaneApplicationLaunching {
    var instances: [String: [PaneApplicationInstance]] = [:]
    var launches: [ApplicationChoice] = []
    var reopens: [Int32] = []
    var reopenActivations: [Bool] = []
    var failure = false
    var runningInstanceReadCount = 0
    func runningApplicationBundleIdentifiers() -> Set<String> { Set(instances.filter { !$0.value.isEmpty }.map(\.key)) }
    func runningInstances(of application: ApplicationChoice) -> [PaneApplicationInstance] {
        runningInstanceReadCount += 1
        return instances[application.id] ?? []
    }
    func reopen(_ application: ApplicationChoice, instance: PaneApplicationInstance, activating: Bool, timeout: TimeInterval) async throws {
        reopens.append(instance.processIdentifier)
        reopenActivations.append(activating)
        if failure { throw CocoaError(.executableNotLoadable) }
    }
    func launch(_ application: ApplicationChoice) async throws -> PaneApplicationInstance {
        launches.append(application)
        try Task.checkCancellation()
        if failure { throw CocoaError(.executableNotLoadable) }
        let instance = PaneApplicationInstance(processIdentifier: 701, launchDate: Date(timeIntervalSince1970: 1))
        instances[application.id] = [instance]
        return instance
    }
}

private let paneTestApp = ApplicationChoice(bundleIdentifier: "com.example.Launcher", name: "Fixture Application",
                                             url: URL(filePath: "/fixture/Launcher.app"))

/// Running-app menu discovery now suspends. Launch tests keep their existing
/// scheduling so they can still cancel while NSWorkspace launch is in flight.
@MainActor private func waitForPaneMenuRequest(_ model: BetterTileModel, expireReopen: Bool = true) async {
    guard let request = model.paneApplicationRequest, let app = request.application,
          let launcher = model.paneApplicationLauncher as? FakePaneApplicationLauncher,
          !launcher.runningInstances(of: app).isEmpty else { return }
    await model.paneApplicationLaunchTask?.value
    if expireReopen, !launcher.reopens.isEmpty, request.phase == .waiting {
        request.deadline = model.paneApplicationUptime()
        model.advancePaneApplicationRequest()
    }
}

// Integration coverage: readiness discovers windows without claiming a pane request's arrivals.
@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherReadinessDiscoversReservedAndOrdinaryArrivals(cancelled: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    try await waitForWindowEventsToDrain(model)
    let clock = WindowArrivalTestClock(model)
    // Under full-suite load the main actor can stall for longer than the 30-second arrival guard.
    _ = PaneApplicationTestClock(model)
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    if cancelled { model.cancelPaneApplicationRequest() }
    let reserved = WindowID(rawValue: "delayed-reserved")
    let ordinary = WindowID(rawValue: "delayed-ordinary")
    let original = BTRect(x: -50, y: 150, width: 320, height: 240)
    system.windows.append(WindowSnapshot(id: reserved, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: original, displayID: system.mainDisplay.id))
    system.windows.append(WindowSnapshot(id: ordinary, processIdentifier: 702, bundleIdentifier: "com.example.Ordinary",
        frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    system.offscreenWindowIDs.formUnion([reserved, ordinary])
    for (id, pid) in [(reserved, Int32(701)), (ordinary, Int32(702))] {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: pid))
    }
    await model.windowEventTask?.value
    #expect(model.windowEventTask != nil, "The picker reservation must not discard readiness scheduling")
    clock.elapsed = 0.24
    system.offscreenWindowIDs.subtract([reserved, ordinary])
    await model.windowEventTask?.value
    try await waitForWindowEventsToDrain(model)
    try #require(await waitFor { !model.hasPendingTabbedPlacement && model.activeTabbedState?.windowIDs.contains(ordinary) == true })
    #expect(system.frameWriteCounts[ordinary, default: 0] > 0)
    #expect(system.probeRequests.contains { $0.contains(ordinary) })
    if cancelled {
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(reserved) == true)
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs.contains(reserved) == false)
    #expect(system.frameWriteCounts[reserved, default: 0] == 0)
    #expect(system.probeRequests.allSatisfy { !$0.contains(reserved) })
    #expect(system.windows.first { $0.id == reserved }?.frame == original)
    }
    if cancelled {
        #expect(model.paneApplicationRequest == nil)
    } else {
        model.advancePaneApplicationRequest()

        try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.paneID(containing: reserved) == right)
        model.performTabbed(.undo)
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        #expect(system.windows.first { $0.id == reserved }?.frame == original)
    }
}

@Test(.appTestApplication, arguments: ["manual", "space", "reset", "shutdown"]) @MainActor
func paneLauncherReadinessLifecycleKeepsOnlyCurrentDestinations(interruption: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    try await waitForWindowEventsToDrain(model)
    let clock = WindowArrivalTestClock(model)
    // Under full-suite load the main actor can stall for longer than the 30-second arrival guard.
    _ = PaneApplicationTestClock(model)
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let late = appendPaneArrival(system, id: "invalidated-delayed")
    system.offscreenWindowIDs.insert(late)
    await model.windowEventTask?.value
    #expect(model.windowEventTask != nil)
    clock.elapsed = 0.1
    let pendingReadiness = model.windowEventTask
    switch interruption {
    case "manual": model.setActiveMode(.manual)
    case "space":
        system.offscreenWindowIDs = Set(system.windows.map(\.id))
        system.focusedWindowIsAbsent = true
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: NativeSpaceID(rawValue: 2)],
            knownSpacesByDisplay: [system.mainDisplay.id: [NativeSpaceID(rawValue: 1), NativeSpaceID(rawValue: 2)]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [NativeSpaceID(rawValue: 1)]) }))
        model.beginActiveSpaceStabilization()
        #expect(model.paneApplicationRequest == nil, "Space cleanup must cancel the captured pane destination immediately")
        try #require(await waitFor { !model.isStabilizingSpace })
    case "reset": model.handleApplicationTopologyChange()
    default: model.shutdown()
    }
    model.advancePaneApplicationRequest()
    if interruption != "reset" { #expect(model.paneApplicationRequest == nil) }
    if interruption == "manual" {
        clock.elapsed = 0.24
        system.offscreenWindowIDs.remove(late)
    }
    try await waitForWindowEventsToDrain(model)
    let sweeps = system.completeSweepCount
    system.offscreenWindowIDs.remove(late)
    // A late callback must still respect the cancelled destination or its reservation guard.
    if interruption != "space" {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: late, processIdentifier: 701))
        await model.windowEventTask?.value
        try await waitForWindowEventsToDrain(model)
    }
    if interruption == "reset" {
        // Refreshing app observers does not invalidate the still-running process or
        // the pane. A fresh creation callback can complete this current request.
        try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.paneID(containing: late) == right)
    } else {
        #expect(system.frameWriteCounts[late, default: 0] == 0)
        #expect(model.activeTabbedState?.paneID(containing: late) != right)
    }
    #expect(system.probeRequests.allSatisfy { !$0.contains(late) })
    if interruption == "space" || interruption == "shutdown" {
        await pendingReadiness?.value
        #expect(system.completeSweepCount == sweeps)
    }
}

@Test(.appTestApplication) @MainActor func paneLauncherReadinessDragReplayKeepsReservationAndDiscovery() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    try await waitForWindowEventsToDrain(model)
    let clock = WindowArrivalTestClock(model)
    // Under full-suite load the main actor can stall for longer than the 30-second arrival guard.
    _ = PaneApplicationTestClock(model)
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let late = appendPaneArrival(system, id: "drag-delayed-reserved")
    system.offscreenWindowIDs.insert(late)
    let queued = try #require(model.windowEventTask)
    let source = system.windows[0].id
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: source))
    await queued.value
    #expect(queued.isCancelled)
    #expect(model.paneApplicationRequest == nil)
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: source, end: .restore)
    try #require(await waitFor { model.settlementTasks.isEmpty && !model.hasPendingTabbedPlacement })
    await model.windowEventTask?.value
    #expect(model.windowEventTask != nil)
    clock.elapsed = 0.24
    system.offscreenWindowIDs.remove(late)
    await model.windowEventTask?.value
    try await waitForWindowEventsToDrain(model)
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(late) == true)
    #expect(system.frameWriteCounts[late, default: 0] == 0)
    #expect(system.probeRequests.allSatisfy { !$0.contains(late) })
}

@MainActor private func paneLauncherFixture(populated: Bool = false, native: Bool = false,
                                           gestureEvents: SharedGestureEventMonitor? = nil) async throws
    -> (FakeAppWindowSystem, BetterTileModel, FakePaneApplicationLauncher, UUID) {
    let fixture = try await paneLauncherFixtureWithClock(populated: populated, native: native, gestureEvents: gestureEvents)
    return (fixture.0, fixture.1, fixture.2, fixture.3)
}

/// The fixture and the test clock that already drives the model's pane deadlines. A test that moves time
/// advances this clock. A second clock would replace it and restart time at the real uptime.
@MainActor private func paneLauncherFixtureWithClock(populated: Bool = false, native: Bool = false,
                                                    gestureEvents: SharedGestureEventMonitor? = nil) async throws
    -> (FakeAppWindowSystem, BetterTileModel, FakePaneApplicationLauncher, UUID, PaneApplicationTestClock) {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    if populated {
        var window = system.windows[0]
        window.id = WindowID(rawValue: "peer")
        window.processIdentifier = 51
        system.windows.append(window)
    }
    if native {
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: space],
            knownSpacesByDisplay: [system.mainDisplay.id: [space, NativeSpaceID(rawValue: 2)]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) }))
    }
    let model = makeModel(system: system, gestureEvents: gestureEvents)
    let launcher = FakePaneApplicationLauncher()
    model.paneApplicationLauncher = launcher
    model.paneApplicationTimeout = 60
    // Full-suite load can hold the main actor for longer than any runtime budget. Pane deadlines, click
    // limits, and arrival guards read test time, which moves only when a test advances it.
    let clock = PaneApplicationTestClock(model)
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == system.windows.count && !model.hasPendingTabbedPlacement })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    if populated {
        model.performTabbed(.move(WindowID(rawValue: "peer"), pane: right, index: nil))
        try #require(await waitFor { !model.hasPendingTabbedPlacement && model.activeTabbedState?.panes[1].selected?.rawValue == "peer" })
        model.performTabbed(.select(system.windows[0].id))
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
    }
    return (system, model, launcher, right, clock)
}

@MainActor private func appendPaneArrival(_ system: FakeAppWindowSystem, id: String, app: ApplicationChoice = paneTestApp,
                                         pid: Int32 = 701) -> WindowID {
    let id = WindowID(rawValue: id)
    system.windows.append(WindowSnapshot(id: id, processIdentifier: pid, bundleIdentifier: app.id, title: id.rawValue,
        frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: pid))
    return id
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherDispatchRechecksRunningStateAndCreationEvidence(initiallyRunning: Bool) async throws {
    let (system, model, launcher, right, clock) = try await paneLauncherFixtureWithClock(native: true)
    defer { model.shutdown() }
    clock.now = 1_000
    model.paneApplicationTimeout = 10
    system.newWindowRequestResult = .requested
    let instance = PaneApplicationInstance(processIdentifier: 701, launchDate: Date(timeIntervalSince1970: 1))
    launcher.instances[paneTestApp.id] = initiallyRunning ? [instance] : []
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    // The dispatch task has not resumed. A different process snapshot is now authoritative.
    launcher.instances[paneTestApp.id] = initiallyRunning ? [] : [instance]
    clock.now += 3
    await model.paneApplicationLaunchTask?.value
    #expect(request.launching == initiallyRunning)
    #expect(request.deadline == clock.now + (initiallyRunning ? 30 : 10))
    #expect(launcher.launches.count == (initiallyRunning ? 1 : 0))
    #expect(system.newWindowRequests.count == (initiallyRunning ? 0 : 1))
    let id = WindowID(rawValue: "arrival-without-creation")
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    system.desktopObservation?.windowMembership[id] = [.init(rawValue: 1)]
    model.advancePaneApplicationRequest()
    if !initiallyRunning {
        #expect(model.paneApplicationRequest?.id == request.id)
        // Reserving the unverified arrival can reconcile the other tabs. Wait for that
        // bookkeeping before checking that this window received no automatic placement.
        try #require(await waitFor { !model.hasPendingTabbedPlacement })
        model.advancePaneApplicationRequest()
        #expect(!request.automaticPlacement)
        #expect(system.frameWriteCounts[id, default: 0] == 0, "A running app needs exact creation evidence")
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 701))
        await model.windowEventTask?.value
        model.advancePaneApplicationRequest()
    }
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherStoppedAppAutoFillsCapturedPaneAndSelects(populated: Bool) async throws {
    let (system, model, launcher, right, clock) = try await paneLauncherFixtureWithClock(populated: populated)
    defer { model.shutdown() }
    let baseline = try #require(model.activeTabbedState)
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    try #require(await waitFor { launcher.launches.count == 1 && request.instance != nil })
    #expect(model.activeTabbedState == baseline)
    // Process launch is not window arrival. Let 0.65 s of pane time pass without a window, as for a slow first
    // window. Pane time moves only when the test moves it, so real elapsed time cannot change this.
    clock.now += 0.65
    model.advancePaneApplicationRequest()
    #expect(request.phase == .waiting)
    let id = appendPaneArrival(system, id: "launched")
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.pane(containing: id)?.id == right)
    #expect(model.activeTabbedState?.pane(containing: id)?.selected == id)
    #expect(model.activeTabbedState?.panes[0] == baseline.panes[0])
    model.performTabbed(.undo)
    try #require(await waitFor { !model.hasPendingTabbedPlacement && model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    #expect(system.windows.first(where: { $0.id == id })?.frame == BTRect(x: 80, y: 150, width: 320, height: 240))
    #expect(launcher.launches.count == 1) // Undo leaves the launched process available.
}

@Test(.appTestApplication) @MainActor func paneLauncherRunningUnsupportedRequiresExplicitExistingChoiceAndUndo() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let existing = system.windows[0].id
    let application = ApplicationChoice(bundleIdentifier: "com.example.Test", name: "Existing App", url: URL(filePath: "/fixture/Test.app"))
    launcher.instances[application.id] = [PaneApplicationInstance(processIdentifier: 42, launchDate: nil)]
    let baseline = try #require(model.activeTabbedState)
    let writes = system.frameWriteCounts
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(application, requestID: request.id)
    await waitForPaneMenuRequest(model)
    guard case .fallback = request.phase else { Issue.record("Unsupported app must offer explicit existing choices"); return }
    #expect(request.existingWindows.map(\.id) == [existing])
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == baseline)
    #expect(launcher.launches.isEmpty)
    #expect(system.newWindowRequests.count == 1)
    model.useExistingPaneApplicationWindow(existing, requestID: request.id)
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.panes[1].selected == existing)
    model.performTabbed(.undo)
    #expect(await waitFor { model.activeTabbedState == baseline && !model.hasPendingTabbedPlacement })
}

@Test(.appTestApplication) @MainActor func paneLauncherRunningSupportedAutoPlacesAndExcludesUnrelatedApp() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.windows[0].bundleIdentifier = paneTestApp.id
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 42, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let other = ApplicationChoice(bundleIdentifier: "com.example.Other", name: "Other", url: URL(filePath: "/fixture/Other.app"))
    let unrelated = appendPaneArrival(system, id: "unrelated", app: other, pid: 810)
    let arrived = appendPaneArrival(system, id: "new-window", pid: 42)
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: arrived) == right)
    #expect(model.activeTabbedState?.paneID(containing: system.windows[0].id) != right)
    #expect(model.activeTabbedState?.paneID(containing: unrelated) != right)
    #expect(launcher.launches.isEmpty)
}

@Test(.appTestApplication) @MainActor func paneLauncherMultipleArrivalsAutoPlacesOneAndGuardsTheRest() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let first = appendPaneArrival(system, id: "z-earliest")
    let second = appendPaneArrival(system, id: "a-later")
    try #require(await waitFor { model.advancePaneApplicationRequest(); return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: first) == right)
    #expect(model.activeTabbedState?.floatingWindowIDs.contains(second) == true)
    #expect(system.frameWriteCounts[second, default: 0] == 0)
}

@Test(.appTestApplication) @MainActor func paneLauncherCompetingIntentAndStaleCallbacksCannotTakeDestination() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let first = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: first.id)
    await waitForPaneMenuRequest(model)
    try #require(await waitFor { requestInstance(first) })
    let left = try #require(model.activeTabbedState?.panes[0].id)
    let second = try #require(model.beginPaneApplicationPicker(paneID: left, on: system.mainDisplay.id))
    let other = ApplicationChoice(bundleIdentifier: "com.example.Other", name: "Other", url: URL(filePath: "/fixture/Other.app"))
    model.choosePaneApplication(other, requestID: second.id)
    await waitForPaneMenuRequest(model)
    model.choosePaneApplication(paneTestApp, requestID: first.id)
    await waitForPaneMenuRequest(model)
    #expect(second.application == other)
    let late = appendPaneArrival(system, id: "old-arrival")
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(late) == true })
    #expect(system.frameWriteCounts[late, default: 0] == 0)
    #expect(first.onChoose == nil)
    await model.paneApplicationLaunchTask?.value
    #expect(launcher.launches.count == 2)
}

@MainActor private func requestInstance(_ request: PaneApplicationRequest) -> Bool { request.instance != nil }

@Test(.appTestApplication, arguments: ["cancel", "space", "permission", "owner", "shutdown", "work-area"]) @MainActor
func paneLauncherInvalidatedQueuedLaunchMustNotDispatch(ending: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let launchTask = try #require(model.paneApplicationLaunchTask)
    #expect(launcher.launches.isEmpty)
    // Invalidate synchronously, before the queued MainActor task can start.
    switch ending {
    case "space": model.beginActiveSpaceStabilization()
    case "permission": model.hasAccessibilityPermission = false; system.permission = false
    case "owner":
        let replacement = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
        #expect(replacement.id != request.id)
    case "shutdown": model.shutdown()
    case "work-area":
        let display = system.availableDisplays[0]
        system.availableDisplays[0] = DisplaySnapshot(id: display.id, frame: display.frame,
            visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 750), isMain: true)
    default: model.cancelPaneApplicationRequest()
    }
    let writes = system.frameWriteCounts // Shutdown can restore frames synchronously.
    await launchTask.value
    #expect(launcher.launches.isEmpty, "An invalidated request dispatched its stopped-app launch: \(ending)")
    #expect(request.instance == nil)
    #expect(system.newWindowRequests.isEmpty)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication) @MainActor func paneLauncherCurrentQueuedLaunchDispatchesOnceWithoutPlacement() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    let state = model.activeTabbedState
    let writes = system.frameWriteCounts
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let launchTask = try #require(model.paneApplicationLaunchTask)
    #expect(launcher.launches.isEmpty)
    await launchTask.value
    #expect(launcher.launches == [paneTestApp])
    #expect(request.instance == PaneApplicationInstance(processIdentifier: 701, launchDate: Date(timeIntervalSince1970: 1)))
    #expect(model.paneApplicationRequest?.id == request.id)
    #expect(request.phase == .waiting)
    #expect(system.newWindowRequests.isEmpty)
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState == state)
}

@Test(.appTestApplication) @MainActor func paneLauncherTimeoutNeverUsesExistingOrLateWindow() async throws {
    let (system, model, launcher, right, clock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    model.paneApplicationTimeout = 0.3
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    let writes = system.frameWriteCounts
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    clock.now += model.paneApplicationTimeout
    try #require(await waitFor { if case .fallback = request.phase { return true }; return false })
    #expect(system.frameWriteCounts == writes)
    let late = appendPaneArrival(system, id: "late")
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(late) == true })
    #expect(system.frameWriteCounts[late, default: 0] == 0)
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    #expect(system.newWindowRequests.count == 1) // A retry cannot confuse two outstanding same-app operations.
}

@Test(.appTestApplication, arguments: ["cancel", "pane", "space", "mode", "permission", "preflight"]) @MainActor
func paneLauncherCancellationInvalidatesOwner(ending: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    if ending == "preflight" {
        system.newWindowRequestResult = .requested
        launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
        system.onNewWindowPreflight = { model.beginActiveSpaceStabilization() }
    }
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    if ending != "preflight" { try #require(await waitFor { request.instance != nil }) }
    switch ending {
    case "pane": model.performTabbed(.removePane(right))
    case "space": model.beginActiveSpaceStabilization()
    case "mode": model.setActiveMode(.manual)
    case "permission": model.hasAccessibilityPermission = false; system.permission = false; model.advancePaneApplicationRequest()
    default: model.cancelPaneApplicationRequest()
    }
    #expect(model.paneApplicationRequest == nil)
    #expect(request.onChoose == nil)
    model.useExistingPaneApplicationWindow(system.windows[0].id, requestID: request.id)
    #expect(model.paneApplicationRequest == nil)
    if ending == "preflight" { #expect(system.newWindowRequests.isEmpty) }
}

@Test(.appTestApplication) @MainActor func paneLauncherLaunchFailureAndMultipleProcessesOfferFallbackWithoutMutation() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.failure = true
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    let writes = system.frameWriteCounts
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    try #require(await waitFor { if case .fallback = request.phase { return true }; return false })
    #expect(system.frameWriteCounts == writes)
    #expect(request.existingWindows.isEmpty)
    model.cancelPaneApplicationRequest()
    let other = ApplicationChoice(bundleIdentifier: "com.example.Multiple", name: "Multiple", url: URL(filePath: "/fixture/Multi.app"))
    launcher.instances[other.id] = [PaneApplicationInstance(processIdentifier: 800, launchDate: nil),
                                  PaneApplicationInstance(processIdentifier: 801, launchDate: nil)]
    let next = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(other, requestID: next.id)
    await waitForPaneMenuRequest(model)
    guard case .fallback = next.phase else { Issue.record("Multiple instances need explicit choice"); return }
    #expect(system.newWindowRequests.isEmpty)
    #expect(next.fallbackReason == .severalCopies)
    #expect(launcher.launches.count == 1)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication) @MainActor func paneLauncherOffDesktopExistingChoiceIsRejected() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let app = ApplicationChoice(bundleIdentifier: "com.example.Test", name: "Test", url: URL(filePath: "/fixture/Test.app"))
    launcher.instances[app.id] = [PaneApplicationInstance(processIdentifier: 42, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(app, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let existing = system.windows[0].id
    system.offscreenWindowIDs = [existing]
    let writes = system.frameWriteCounts
    model.useExistingPaneApplicationWindow(existing, requestID: request.id)
    #expect(model.paneApplicationRequest?.id == request.id)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherPlacementFailurePreservesMembershipAndRecordsDegradation(rollbackFails: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(populated: true)
    defer { model.shutdown() }
    // Leave one tab selected in the source after moving its current selection.
    var sibling = system.windows[0]
    sibling.id = WindowID(rawValue: "a-sibling")
    system.windows.append(sibling)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: sibling.id, processIdentifier: sibling.processIdentifier))
    try #require(await waitFor { model.activeTabbedState?.windowIDs.count == 3 && !model.hasPendingTabbedPlacement })
    let source = system.windows[0].id
    model.performTabbed(.select(source))
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    let application = ApplicationChoice(bundleIdentifier: "com.example.Test", name: "Test", url: URL(filePath: "/fixture/Test.app"))
    launcher.instances[application.id] = [PaneApplicationInstance(processIdentifier: 42, launchDate: nil)]
    let baseline = try #require(model.activeTabbedState)
    let siblingIndex = try #require(system.windows.firstIndex(where: { $0.id == sibling.id }))
    system.windows[siblingIndex].frame.origin.x += 40
    let frames = system.windows.map(\.frame)
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(application, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let sourceCount = system.frameWriteCounts[source, default: 0]
    let siblingCount = system.frameWriteCounts[sibling.id, default: 0]
    system.failedFrameWriteNumbers[source] = [sourceCount + 1]
    if rollbackFails { system.failedFrameWriteNumbers[sibling.id] = Set((siblingCount + 2)...(siblingCount + 50)) }
    model.useExistingPaneApplicationWindow(source, requestID: request.id)
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState == baseline)
    if rollbackFails {
        #expect(model.statusMessage?.contains("Repair") == true, "\(model.statusMessage as Any) counts=\(system.frameWriteCounts) writes=\(system.requestedFrames)")
        #expect(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id) == nil)
    } else {
        #expect(system.windows.map(\.frame) == frames)
        model.advancePaneApplicationRequest()
        guard case .fallback = request.phase else { Issue.record("Failed placement must show fallback"); return }
    }
}

@Test(.appTestApplication) @MainActor func paneLauncherNativeMembershipChangeDuringPreflightCannotTransferWindow() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    let application = ApplicationChoice(bundleIdentifier: "com.example.Test", name: "Test", url: URL(filePath: "/fixture/Test.app"))
    launcher.instances[application.id] = [PaneApplicationInstance(processIdentifier: 42, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(application, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let writes = system.frameWriteCounts
    let existing = system.windows[0].id
    system.onWindowSnapshots = {
        system.desktopObservation?.windowMembership[existing] = [NativeSpaceID(rawValue: 2)]
    }
    model.useExistingPaneApplicationWindow(existing, requestID: request.id)
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(system.frameWriteCounts == writes)
    #expect(model.activeTabbedState?.paneID(containing: existing) != right)
}

@Test(.appTestApplication) @MainActor func paneLauncherRunningAppDoesNotClaimRestoredOldWindow() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let old = WindowID(rawValue: "restored-old")
    system.windows.append(WindowSnapshot(id: old, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 50, y: 40, width: 300, height: 200), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .restored, windowID: old, processIdentifier: 701))
    request.deadline = model.paneApplicationUptime()
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        if case .fallback = request.phase { return !model.hasPendingTabbedPlacement }
        return false
    })
    #expect(model.paneApplicationRequest?.id == request.id)
    #expect(request.existingWindows.map(\.id) == [old])
    #expect(system.frameWriteCounts[old, default: 0] == 0)
    #expect(model.activeTabbedState?.paneID(containing: old) == nil)
}

@Test(.appTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_PANE_LAUNCHER_RENDER_DIR"] != nil)) @MainActor
func paneLauncherPickerOffscreenRenders() async throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_PANE_LAUNCHER_RENDER_DIR"])
    _ = NSApplication.shared
    let longApp = ApplicationChoice(bundleIdentifier: "com.example.LongName", name: "Fixture Editor with a deliberately long application name",
        url: URL(filePath: "/fixture/Long.app"))
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        for phase in ["choosing", "waiting", "fallback", "empty", "placing"] {
            let request = PaneApplicationRequest(paneID: UUID(), paneNumber: 3, displayID: DisplayID(rawValue: "fixture"),
                sessionID: DesktopSessionID(rawValue: UUID()), spaceID: nil, generation: 0,
                workArea: BTRect(x: 0, y: 0, width: 1000, height: 800))
            request.application = longApp
            switch phase {
            case "waiting": request.phase = .waiting
            case "placing": request.phase = .placing(WindowID(rawValue: "fixture"))
            case "fallback", "empty":
                request.phase = .fallback("A window is available. Choose the window to add.")
                if phase == "fallback" {
                    request.existingWindows = (1...4).map {
                        WindowSnapshot(id: WindowID(rawValue: "choice-\($0)"), processIdentifier: 701,
                            bundleIdentifier: longApp.id, title: "Quarterly research notes — long fixture title number \($0)",
                            frame: BTRect(x: 0, y: 0, width: 300, height: 200), displayID: request.displayID)
                    }
                }
            default: break
            }
            let content = PaneApplicationPicker(request: request, installedApplications: { [paneTestApp, longApp] },
                runningApplications: { [paneTestApp] }, recentApplications: RecentApplications(defaults: MemoryDefaults()))
            let host = NSHostingView(rootView: content
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            let panel = OffscreenTestPanel(contentRect: NSRect(x: 12000, y: 0, width: 360, height: 440),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.appearance = NSAppearance(named: appearanceName)
            panel.contentView = host
            host.appearance = panel.appearance
            panel.setFrame(NSRect(x: 12000, y: 0, width: 360, height: 440), display: false)
            defer { panel.orderOutForTesting() }
            try await Task.sleep(for: .milliseconds(150)) // real-time: opt-in snapshot export waits for SwiftUI hosting layout
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            panel.appearance!.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(filePath: directory).appending(path: "picker-\(name)-\(phase).png"))
        }
    }
}

@Test(.appTestApplication) @MainActor func paneLauncherFirstWindowOnEmptyDesktopUsesCapturedPane() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows = []
    let model = makeModel(system: system)
    defer { model.shutdown() }
    _ = PaneApplicationTestClock(model)
    let launcher = FakePaneApplicationLauncher()
    model.paneApplicationLauncher = launcher
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 && !model.hasPendingTabbedPlacement })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    try #require(request.instance != nil)
    let arrived = appendPaneArrival(system, id: "first-desktop-window")
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    })
    #expect(model.activeTabbedState?.panes[1].selected == arrived)
    #expect(model.activeTabbedState?.panes[0].tabs.isEmpty == true)
}

@Test(.appTestApplication) @MainActor func paneLauncherPermissionFailureNeverLaunchesOrMovesExistingWindow() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    model.hasAccessibilityPermission = false
    #expect(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id) == nil)
    #expect(model.statusMessage?.contains("Accessibility") == true)
    #expect(launcher.launches.isEmpty)
    model.hasAccessibilityPermission = true
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .failed("Accessibility permission is unavailable.")
    let writes = system.frameWriteCounts
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    guard case let .fallback(reason) = request.phase else { Issue.record("Permission failure needs an explicit fallback"); return }
    #expect(reason.contains("Accessibility"))
    #expect(system.frameWriteCounts == writes)
    #expect(launcher.launches.isEmpty)
}


// Actual request-path regressions from independent review.
@Test(.appTestApplication) @MainActor func paneLauncherNewSameProcessCreationWithinRequestIntervalQualifies() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    // The dispatched operation is delayed; a user/script creates a different window first.
    let unrelated = appendPaneArrival(system, id: "independent-same-app-window")
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        if model.paneApplicationRequest == nil { return !model.hasPendingTabbedPlacement }
        if case .fallback = request.phase { return !model.hasPendingTabbedPlacement }
        return false
    })
    #expect(system.frameWriteCounts[unrelated, default: 0] > 0)
    #expect(model.activeTabbedState?.paneID(containing: unrelated) == right)
}

@Test(.appTestApplication) @MainActor func paneLauncherPopupCreationMustNotAuthorizeRestoredExistingWindow() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    // A previously off-screen/minimized, never-observed window is restored.
    let old = WindowID(rawValue: "restored-preexisting-window")
    system.windows.append(WindowSnapshot(id: old, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 50, y: 40, width: 300, height: 200), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .restored, windowID: old, processIdentifier: 701))
    // A distinct popup created by the same process is not an eligible layout arrival.
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: WindowID(rawValue: "unrelated-popup"), processIdentifier: 701))
    request.deadline = model.paneApplicationUptime()
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        if model.paneApplicationRequest == nil { return !model.hasPendingTabbedPlacement }
        if case .fallback = request.phase { return !model.hasPendingTabbedPlacement }
        return false
    })
    #expect(system.frameWriteCounts[old, default: 0] == 0)
    #expect(model.activeTabbedState?.paneID(containing: old) != right)
}

@Test(.appTestApplication) @MainActor func paneLauncherExistingChoiceMovingDisplaysDuringPreflightMustNotTransfer() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let second = DisplaySnapshot(id: DisplayID(rawValue: "second"), frame: BTRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
    system.availableDisplays.append(second)
    let app = ApplicationChoice(bundleIdentifier: "com.example.Test", name: "Existing", url: URL(filePath: "/fixture/Test.app"))
    launcher.instances[app.id] = [PaneApplicationInstance(processIdentifier: 42, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(app, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let existing = system.windows[0].id
    let writes = system.frameWriteCounts[existing, default: 0]
    var preflightMoved = false
    system.onWindowSnapshots = {
        preflightMoved = true
        system.onWindowSnapshots = nil
        system.windows[0].displayID = second.id
        system.windows[0].frame = BTRect(x: 1100, y: 100, width: 300, height: 200)
    }
    model.useExistingPaneApplicationWindow(existing, requestID: request.id)
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(preflightMoved)
    #expect(system.frameWriteCounts[existing, default: 0] == writes)
    #expect(system.windows[0].frame == BTRect(x: 1100, y: 100, width: 300, height: 200))
    #expect(model.activeTabbedState?.paneID(containing: existing) != right)
}

@Test(.appTestApplication) @MainActor func paneLauncherExitedInstanceCannotPlaceRelaunchArrival() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: Date(timeIntervalSince1970: 1))]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 702, launchDate: Date(timeIntervalSince1970: 2))]
    let id = appendPaneArrival(system, id: "relaunched", pid: 702)
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true && !model.hasPendingTabbedPlacement })
    request.deadline = model.paneApplicationUptime() - 1
    model.advancePaneApplicationRequest()
    request.deadline = model.paneApplicationUptime()
    model.advancePaneApplicationRequest()
    guard case .fallback = request.phase else { Issue.record("Relaunch must require choice"); return }
    #expect(system.frameWriteCounts[id, default: 0] == 0)
    #expect(model.activeTabbedState?.paneID(containing: id) != right)
}


@Test(.appTestApplication, arguments: [false, true]) @MainActor func paneLauncherConfirmedArrivalRetainsPlacementAndUndo(running: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    if running {
        system.newWindowRequestResult = .requested
        launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    }
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    try #require(await waitFor { request.instance != nil })
    let id = appendPaneArrival(system, id: "confirmed-arrival")
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    model.performTabbed(.undo)
    try #require(await waitFor { !model.hasPendingTabbedPlacement && model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    #expect(system.windows.first { $0.id == id }?.frame == BTRect(x: 80, y: 150, width: 320, height: 240))
}

@Test(.appTestApplication, arguments: ["cancel", "timeout", "choice"]) @MainActor
func paneLauncherLateOutOfBoundsArrivalRemainsUntouched(ending: String) async throws {
    let (system, model, launcher, right, paneClock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    // Keep the cancelled request's arrival guard alive while other main-actor
    // tests run. This test advances its phases explicitly, not by elapsed time.
    _ = WindowArrivalTestClock(model)
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    switch ending {
    case "cancel": model.cancelPaneApplicationRequest()
    case "timeout":
        request.deadline = paneClock.now - 1
        model.advancePaneApplicationRequest()
        guard case .fallback = request.phase else { Issue.record("Timeout must offer choice"); return }
    default:
        let selected = appendPaneArrival(system, id: "explicitly-selected")
        try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.paneID(containing: selected) == right)
    }
    let late = appendPaneArrival(system, id: "late-out-of-bounds")
    let index = try #require(system.windows.firstIndex { $0.id == late })
    system.windows[index].frame.origin.x = -50
    let frame = system.windows[index].frame
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(late) == true && !model.hasPendingTabbedPlacement },
                 "floating=\(model.activeTabbedState?.floatingWindowIDs ?? []), pending=\(model.hasPendingTabbedPlacement), phase=\(request.phase), sweeps=\(system.completeSweepCount)")
    #expect(system.frameWriteCounts[late, default: 0] == 0)
    #expect(system.probeRequests.allSatisfy { !$0.contains(late) })
    #expect(system.windows[index].frame == frame)
    #expect(model.activeTabbedState?.automaticallyFloatingWindowIDs.contains(late) == false)
    #expect(model.statusMessage?.contains("fit") != true)
    #expect(model.lastActionFeedback?.detail?.contains("fit") != true)
}

@Test(.appTestApplication) @MainActor func paneLauncherChoiceMovingDisplaysDuringSettlementStopsFurtherWrites() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let second = DisplaySnapshot(id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
    system.availableDisplays.append(second)
    let app = ApplicationChoice(bundleIdentifier: "com.example.Test", name: "Existing", url: URL(filePath: "/fixture/Test.app"))
    launcher.instances[app.id] = [PaneApplicationInstance(processIdentifier: 42, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(app, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let existing = system.windows[0].id
    let writes = system.frameWriteCounts[existing, default: 0]
    let relocated = BTRect(x: 1100, y: 100, width: 300, height: 200)
    var moved = false
    system.onFrameWrite = { id, _ in
        guard id == existing else { return }
        // The fake applies the frame after this callback. Relocate on the next
        // read so the external move happens after the first completed write.
        system.onWindowSnapshots = {
            system.onWindowSnapshots = nil
            moved = true
            system.windows[0].displayID = second.id
            system.windows[0].frame = relocated
        }
    }
    model.useExistingPaneApplicationWindow(existing, requestID: request.id)
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    #expect(moved)
    #expect(system.frameWriteCounts[existing, default: 0] == writes + 1)
    #expect(system.windows[0].frame == relocated)
    #expect(model.activeTabbedState?.paneID(containing: existing) != right)
    // A write happened before ownership changed; report that incomplete placement.
    #expect(model.statusMessage?.contains("Repair") == true)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherUnrelatedManualDisplayCannotCancelPicker(peerPreviouslyTabbed: Bool) async throws {
    _ = NSApplication.shared
    let s = FakeAppWindowSystem()
    // Keep real test-owned panels away from other fake models' divider handles.
    let offset = 12000.0
    s.availableDisplays[0].frame.origin.x += offset
    s.availableDisplays[0].visibleFrame.origin.x += offset
    s.windows[0].frame.origin.x += offset
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pane-owner-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appendingPathComponent("configuration.json"))
    let m = makeOffscreenModel(store: store, system: s, startRuntime: false, presentsTabbedChrome: true)
    m.primaryButtonIsPressed = { false }
    let launcher = FakePaneApplicationLauncher()
    m.paneApplicationLauncher = launcher
    m.paneApplicationTimeout = 60
    m.configuration.defaultTabbedPreset = .columns
    m.setActiveMode(.tabbed)
    defer { m.shutdown() }
    try #require(await waitFor { !m.hasPendingTabbedPlacement && m.activeTabbedState?.panes.count == 2 })
    let right = try #require(m.activeTabbedState?.panes[1].id)
    let ownedPanels = NSApp.windows.filter { ($0.contentView as? TabbedPaneView)?.pane.id == right }
    try #require(ownedPanels.count == 1 && ownedPanels[0].isVisible)
    let screen = try #require(NSScreen.screens.first)
    let concurrentHandle = CoordinateConverter.toAppKit(
        BTRect(x: 488, y: 372, width: 24, height: 56), mainScreenFrame: screen.frame)
    #expect(!DividerOverlayController.ownWindowCoversHandle(concurrentHandle, windows: ownedPanels, excluding: []),
        "This test's empty-pane chrome must not cover concurrent divider fixtures")
    let mainWindow = s.windows[0].id
    let peerDisplay = DisplaySnapshot(id: DisplayID(rawValue: "picker-peer-display"),
        frame: BTRect(x: offset + 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: offset + 1000, y: 0, width: 1000, height: 800), isMain: false)
    let peerWindow = WindowID(rawValue: "picker-peer-window")
    s.availableDisplays.append(peerDisplay)
    s.windows.append(WindowSnapshot(id: peerWindow, processIdentifier: 900, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: offset + 1100, y: 100, width: 500, height: 500), displayID: peerDisplay.id))
    s.focusedID = peerWindow
    if peerPreviouslyTabbed {
        m.setActiveMode(.tabbed)
        try #require(await waitFor { !m.hasPendingTabbedPlacement && m.activeMode(for: peerDisplay.id) == .tabbed })
        #expect(m.presentedTabbedState(on: peerDisplay.id) != nil)
    }
    m.setActiveMode(.manual)
    try #require(await waitFor { !m.hasPendingTabbedPlacement && m.activeMode(for: peerDisplay.id) == .manual })
    s.focusedID = mainWindow
    m.setActiveMode(.tabbed)
    try #require(await waitFor { !m.hasPendingTabbedPlacement && m.activeMode(for: s.mainDisplay.id) == .tabbed })
    try await waitForWindowEventsToDrain(m)
    let clock = WindowArrivalTestClock(m)
    launcher.instances[paneTestApp.id] = [PaneApplicationInstance(processIdentifier: 701, launchDate: nil)]
    s.newWindowRequestResult = .requested
    let request = try #require(m.beginPaneApplicationPicker(paneID: right, on: s.mainDisplay.id))
    m.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(m)
    #expect(s.newWindowRequests.count == 1)
    let late = appendPaneArrival(s, id: "picker-cross-display-arrival")
    let lateIndex = try #require(s.windows.firstIndex { $0.id == late })
    s.windows[lateIndex].frame.origin.x += offset
    s.offscreenWindowIDs.insert(late)
    await m.windowEventTask?.value
    #expect(m.paneApplicationRequest?.id == request.id,
        "An inventory pass on another display's old hidden overlay must not cancel the current destination")
    clock.elapsed = 0.24
    s.offscreenWindowIDs.remove(late)
    await m.windowEventTask?.value
    try await waitForWindowEventsToDrain(m)
    try #require(await waitFor { !m.hasPendingTabbedPlacement })
    m.advancePaneApplicationRequest()
    try #require(await waitFor { m.advancePaneApplicationRequest(); return !m.hasPendingTabbedPlacement && m.paneApplicationRequest == nil })
    #expect(m.activeTabbedState?.paneID(containing: late) == right)
    // The same callback must still cancel immediately when its own display is removed.
    _ = try #require(m.beginPaneApplicationPicker(paneID: right, on: s.mainDisplay.id))
    s.availableDisplays.removeAll { $0.id == s.mainDisplay.id }
    s.windows.removeAll { $0.displayID == s.mainDisplay.id }
    s.focusedID = peerWindow
    m.handleApplicationTopologyChange()
    #expect(m.paneApplicationRequest == nil)
}

@Test(.appTestApplication, arguments: ["same", "other-display", "other-desktop"]) @MainActor
func paneLauncherChoosingExistingWindowRevalidatesDestination(location: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    let app = ApplicationChoice(bundleIdentifier: "com.example.Test", name: "Test", url: URL(filePath: "/fixture/Test.app"))
    launcher.instances[app.id] = [.init(processIdentifier: 42, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    let id = system.windows[0].id
    #expect(request.windows?(app)?.map(\.id) == [id.rawValue])
    if location == "other-display" {
        let second = DisplaySnapshot(id: DisplayID(rawValue: "another"), frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800), isMain: false)
        system.availableDisplays.append(second)
        system.windows[0].displayID = second.id
        system.windows[0].frame = BTRect(x: 1100, y: 100, width: 300, height: 200)
    }
    if location == "other-desktop" { system.desktopObservation?.windowMembership[id] = [NativeSpaceID(rawValue: 2)] }
    let writes = system.frameWriteCounts
    model.useChoosingPaneApplicationWindow(id, application: app, requestID: request.id)
    if location == "same" {
        #expect(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.pane(containing: id)?.id == right)
    } else {
        #expect(request.phase == .choosing)
        #expect(system.frameWriteCounts == writes)
    }
    #expect(system.newWindowRequests.isEmpty)
    #expect(launcher.launches.isEmpty)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherPopoverDismissalCancelsOnlyChoosing(chosen: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    if chosen {
        model.choosePaneApplication(paneTestApp, requestID: request.id)
        await waitForPaneMenuRequest(model)
        try #require(await waitFor { !launcher.launches.isEmpty })
    }
    model.dismissPaneApplicationPicker(requestID: request.id)
    #expect((model.paneApplicationRequest != nil) == chosen)
    #expect(system.frameWriteCounts[WindowID(rawValue: "arrival"), default: 0] == 0)
}

/// A click on the new window places it: mouse-down on it, mouse-up within the drag threshold, and then that window is
/// focused. "already-focused": the app focused its new window before the click, so the click sends no focus event.
/// "slow-click": the button is held well past the confirmation delay without moving; nothing happens until mouse-up.
/// "drag": the user drags the new window; neither holding nor releasing places it.

@Test(.appTestApplication) @MainActor func paneLauncherTimeoutRetryDispatchesOnlyAfterExplicitAction() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    request.deadline = 0
    model.advancePaneApplicationRequest()
    #expect(request.fallbackReason == .timedOut)
    #expect(system.newWindowRequests.count == 1)
    model.handlePaneRequestAction(.showWindows, requestID: request.id)
    #expect(request.showingWindows)
    model.handlePaneRequestAction(.tryAgain, requestID: request.id)
    await waitForPaneMenuRequest(model)
    #expect(system.newWindowRequests.count == 2)
    #expect(request.phase == .waiting)
}


@Test(.appTestApplication) @MainActor func paneLauncherUnsupportedListKeepsNewWindowsOutsideLayoutUntilChosen() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    #expect(request.fallbackReason == .timedOut)
    request.showingWindows = true
    let id = appendPaneArrival(system, id: "opened-after-show-app")
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return request.existingWindows.contains { $0.id == id }
    })
    #expect(system.frameWriteCounts[id, default: 0] == 0)
    #expect(model.activeTabbedState?.pane(containing: id) == nil)
    try #require(await waitFor { model.activeTabbedState?.floatingWindowIDs.contains(id) == true })
    #expect(system.frameWriteCounts[id, default: 0] == 0)
    model.handlePaneRequestAction(.useWindow(id), requestID: request.id)
    #expect(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.pane(containing: id)?.id == right)
}


@Test(.appTestApplication) @MainActor func paneLauncherJustWorksPlacesRequestedArrivalWithoutClick() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let id = appendPaneArrival(system, id: "just-works")
    system.desktopObservation?.windowMembership[id] = [.init(rawValue: 1)]
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    }, "phase=\(request.phase), arrivals=\(request.arrivals), baseline=\(request.baseline), status=\(model.statusMessage ?? "nil")")
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(model.activeTabbedState?.pane(containing: id)?.selected == id)
}

@Test(.appTestApplication) @MainActor func paneLauncherJustWorksOpeningIsImmediateAndOneClickDispatchesOnce() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    var operations: [String] = []
    system.onVisibleWindowSweep = { _ in
        #expect(request.status?.kind == .opening(launching: false), "Progress precedes inventory")
        operations.append("inventory")
    }
    system.onNewWindowPreflight = {
        #expect(request.status?.kind == .opening(launching: false), "Progress precedes menu discovery")
        operations.append("menu")
    }
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    #expect(request.status?.kind == .opening(launching: false))
    #expect(operations.isEmpty, "Choosing publishes progress synchronously and defers inventory and discovery")
    #expect(system.newWindowRequests.isEmpty, "Progress precedes AX discovery")
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    model.handlePaneRequestAction(.tryAgain, requestID: request.id)
    await waitForPaneMenuRequest(model)
    model.advancePaneApplicationRequest()
    #expect(system.newWindowRequests.count == 1)
    #expect(operations.first == "inventory")
    #expect(operations.filter { $0 == "menu" }.count == 1)
    #expect(launcher.reopens.isEmpty, "A dispatched command is never followed by reopen")
}

@Test(.appTestApplication) @MainActor func paneLauncherJustWorksReopensOnceThenOffersDesktopWindows() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model, expireReopen: false)
    #expect(request.phase == .waiting)
    #expect(launcher.reopens == [701])
    model.advancePaneApplicationRequest(); model.advancePaneApplicationRequest()
    #expect(launcher.reopens == [701])
    request.deadline = model.paneApplicationUptime()
    model.advancePaneApplicationRequest()
    #expect(request.fallbackReason == .timedOut)
    model.handlePaneRequestAction(.showWindows, requestID: request.id)
    #expect(request.showingWindows)
}

@Test(.appTestApplication) @MainActor func paneLauncherJustWorksChoosesFrontmostInstance() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 800, launchDate: nil),
                                        .init(processIdentifier: 701, launchDate: nil, isActive: true)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    #expect(system.newWindowRequests.map(\.0) == [701])
    let id = appendPaneArrival(system, id: "frontmost-instance")
    try #require(await waitFor { model.advancePaneApplicationRequest(); return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
}

@Test(.appTestApplication, arguments: ["preexisting", "other-desktop", "other-display", "dialog", "fixed", "stale-desktop", "late"])
@MainActor func paneLauncherJustWorksNeverAutoPlacesUnsafeWindow(reason: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let id = WindowID(rawValue: "unsafe-window")
    var window = WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: .init(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id)
    if reason == "preexisting" {
        system.windows.append(window)
        system.desktopObservation?.windowMembership[id] = [.init(rawValue: 1)]
    }
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    if reason != "preexisting" {
        if reason == "dialog" { window.isFloating = true }
        if reason == "fixed" { window.constraints.isResizable = false }
        if reason == "other-display" { window.displayID = .init(rawValue: "elsewhere") }
        system.windows.append(window)
        system.desktopObservation?.windowMembership[id] = [.init(rawValue: reason == "other-desktop" ? 2 : 1)]
        if reason == "other-desktop" { system.offscreenWindowIDs.insert(id) }
        if reason == "stale-desktop" {
            system.desktopObservation?.currentSpaceByDisplay[system.mainDisplay.id] = .init(rawValue: 2)
            model.beginActiveSpaceStabilization()
        }
        if reason == "late" { request.deadline = model.paneApplicationUptime() - 1 }
        system.eventHandler?(.init(kind: .created, windowID: id, processIdentifier: 701))
    }
    let writes = system.frameWriteCounts[id, default: 0]
    try await waitForWindowEventsToDrain(model)
    model.advancePaneApplicationRequest()
    #expect(model.activeTabbedState?.paneID(containing: id) != right)
    #expect(system.frameWriteCounts[id, default: 0] == writes)
    if reason == "stale-desktop" { #expect(model.paneApplicationRequest == nil) }
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherJustWorksRespectsAppSwitchBeforeAndDuringPlacement(duringWrite: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    if duringWrite { system.onFrameWrite = { _, _ in request.focusIntent?.activated("com.example.MovedOn") } }
    else { request.focusIntent?.activated("com.example.MovedOn") }
    let id = appendPaneArrival(system, id: "place-without-raising")
    try #require(await waitFor { model.advancePaneApplicationRequest(); return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(system.raiseRequests.allSatisfy { $0.0 != id })
}

@Test(.appTestApplication) @MainActor func paneLauncherReturnToSourcePlacesWithoutRaising() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var front = "Source"
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    let intent = ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    intent.requested = [paneTestApp.id]
    request.focusIntent = intent
    await waitForPaneMenuRequest(model, expireReopen: false)
    #expect(launcher.reopenActivations == [false])
    front = paneTestApp.id; intent.activated(front)
    #expect(intent.allowsRaising)
    front = "Source"; intent.activated(front)
    #expect(intent.movedOn)
    #expect(!intent.allowsRaising)
    let id = appendPaneArrival(system, id: "return-to-source")
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(system.frameWriteCounts[id, default: 0] > 0)
    #expect(system.raiseRequests.allSatisfy { $0.0 != id })
}

@Test(.appTestApplication) @MainActor func paneLauncherJustWorksFocusIntentRemembersAnInterveningAppSwitch() {
    var front = "Source"
    let intent = ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    intent.requested = ["Target"]
    #expect(!intent.prepareReopen(of: "Target"))
    front = "Target"; intent.activated(front)
    #expect(intent.allowsRaising)
    front = "Other"; intent.activated(front)
    front = "Source"; intent.activated(front)
    #expect(!intent.allowsRaising)
}

@Test(.appTestApplication) @MainActor func paneLauncherJustWorksReopenDoesNotActivateAfterAppSwitch() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    system.onNewWindowPreflight = { request.focusIntent?.activated("Other") }
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model, expireReopen: false)
    #expect(launcher.reopens == [701])
    #expect(launcher.reopenActivations == [false])
}

@Test(.appTestApplication) @MainActor func paneLauncherJustWorksFallbackDoesNotRaiseAfterAppSwitch() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    request.focusIntent?.activated("Other")
    // The public fallback discovers this window without an exact creation callback.
    let id = WindowID(rawValue: "unconfirmed")
    system.windowNumberMap[id] = 901
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    try #require(await waitFor { model.advancePaneApplicationRequest(); return request.fallbackReason == .arrived })
    system.raiseRequests.removeAll()
    model.advancePaneApplicationRequest()
    #expect(request.arrivals.contains(id))
    #expect(system.raiseRequests.isEmpty)
    #expect(request.revealedWindowID == nil)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherJustWorksColdLaunchWaitsThirtySecondsAndKeepsLateSuccess(running: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    model.paneApplicationTimeout = 10
    var now = 1_000.0
    model.paneApplicationUptime = { now }
    if running { launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)] }
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    #expect(request.deadline == now + (running ? 10 : 30))
    await model.paneApplicationLaunchTask?.value
    now += 11
    model.advancePaneApplicationRequest()
    if running {
        #expect(request.fallbackReason == .timedOut)
        #expect(request.status?.headline == "Fixture Application didn't open a window")
    } else {
        #expect(request.phase == .waiting)
        #expect(request.status?.headline == "Still opening Fixture Application…")
        #expect(request.status?.message.isEmpty == true)
        now += 10
        let id = appendPaneArrival(system, id: "cold-window-after-twenty-seconds")
        try #require(await waitFor {
            model.advancePaneApplicationRequest()
            return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
        })
        #expect(model.activeTabbedState?.paneID(containing: id) == right)
    }
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherJustWorksSeveralCopiesNeedsFrontmostEvidence(frontmost: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 800, launchDate: nil),
        .init(processIdentifier: 701, launchDate: nil, isFrontmost: frontmost)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    if frontmost {
        #expect(request.phase == .waiting)
        #expect(system.newWindowRequests.map(\.0) == [701])
    } else {
        #expect(request.fallbackReason == .severalCopies)
        #expect(request.status?.headline == "Several copies are running")
        #expect(system.newWindowRequests.isEmpty)
        #expect(launcher.launches.isEmpty)
    }
}

@Test(.appTestApplication) @MainActor func paneLauncherSecurityReopenTargetsRunningCopy() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func bundle(_ name: String, identifier: String = "test.reopen") throws -> URL {
        let url = root.appending(path: name + ".app")
        let contents = url.appending(path: "Contents")
        let executable = contents.appending(path: "MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        return url
    }
    let selected = try bundle("Selected")
    let running = try bundle("Running")
    let other = try bundle("Other", identifier: "test.other")
    let app = ApplicationChoice(bundleIdentifier: "test.reopen", name: "Fixture", url: selected)
    #expect(try WorkspacePaneApplicationLauncher.reopenURL(for: app, runningBundleURL: running) == running)
    #expect(throws: CocoaError.self) { try WorkspacePaneApplicationLauncher.reopenURL(for: app, runningBundleURL: nil) }
    #expect(throws: CocoaError.self) { try WorkspacePaneApplicationLauncher.reopenURL(for: app, runningBundleURL: other) }
    try FileManager.default.removeItem(at: selected)
    #expect(try WorkspacePaneApplicationLauncher.reopenURL(for: app, runningBundleURL: running) == running)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherDelayedCreationReevaluatesReadiness(ineligible: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    try await waitForWindowEventsToDrain(model)
    let clock = WindowArrivalTestClock(model)
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    var now = 1_000.0
    model.paneApplicationUptime = { now }
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    now += 1.2; clock.elapsed = 1.2
    let id = WindowID(rawValue: "safari-delayed-readable")
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 0, y: 148, width: 930, height: 675), displayID: system.mainDisplay.id,
        isFloating: ineligible))
    system.desktopObservation?.windowMembership[id] = [.init(rawValue: 1)]
    system.createdWindowsByToken[88] = id
    system.notReadyReads[88] = ineligible ? 0 : 2
    system.eventHandler?(.init(kind: .created, windowID: nil, processIdentifier: 701, creationToken: 88))
    model.processPendingWindowEvents()
    model.advancePaneApplicationRequest()
    #expect(system.frameWriteCounts[id, default: 0] == 0)
    if ineligible {
        #expect(request.creationTokens.contains(88), "Keep the AX element so a provisional popup verdict can be re-read")
    }
    // Readiness can expire before the AX element exposes its standard-window attributes.
    clock.elapsed += 0.6; now += 0.6
    system.windows[system.windows.firstIndex { $0.id == id }!].isFloating = false
    system.notReadyReads[88] = 0
    model.processPendingWindowEvents()
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    }, "phase=\(request.phase), arrivals=\(request.arrivals), baseline=\(request.baseline), status=\(model.statusMessage ?? "nil")")
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(model.activeTabbedState?.pane(containing: id)?.selected == id)
}

@Test(.appTestApplication) @MainActor func paneLauncherFirstReadableFrameWritesFinalPaneOnce() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    try await waitForWindowEventsToDrain(model)
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let state = try #require(model.activeTabbedState)
    let expected = state.windowArea(try #require(state.frames(in: system.mainDisplay.visibleFrame)[right]))
    let id = WindowID(rawValue: "textedit-first-frame")
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 63, y: 301, width: 576, height: 480), displayID: system.mainDisplay.id))
    system.desktopObservation?.windowMembership[id] = [.init(rawValue: 1)]
    system.createdWindowsByToken[89] = id
    system.eventHandler?(.init(kind: .created, windowID: nil, processIdentifier: 701, creationToken: 89))
    model.processPendingWindowEvents()
    #expect(system.requestedFrames[id] == [expected], "The first readable event pass writes the final pane frame once")
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    })
    try await waitForWindowEventsToDrain(model)
    #expect(system.requestedFrames[id] == [expected])
    #expect(system.frameWriteCounts[id] == 1)
    #expect(!system.probeRequests.contains { $0.contains(id) })
}

@Test(.appTestApplication) @MainActor func paneLauncherFocusSelectionKeepsRequestedDestination() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(populated: true, native: true)
    defer { model.shutdown() }
    model.performTabbed(.activate(right))
    try #require(await waitFor { !model.hasPendingTabbedPlacement })
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let source = system.windows[0]
    request.focusIntent?.activated(source.bundleIdentifier)
    system.focusedID = source.id
    system.eventHandler?(.init(kind: .focused, windowID: source.id, processIdentifier: source.processIdentifier))
    await model.tabbedFocusTask?.value
    #expect(model.paneApplicationRequest?.id == request.id)
    let id = appendPaneArrival(system, id: "finder-switch-keeps-pane")
    system.desktopObservation?.windowMembership[id] = [.init(rawValue: 1)]
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    })
    let state = try #require(model.activeTabbedState)
    #expect(state.paneID(containing: id) == right)
    #expect(state.pane(containing: id)?.selected == id)
    #expect(system.windows.first { $0.id == id }?.frame == state.frames(in: system.mainDisplay.visibleFrame)[right].map { state.windowArea($0) })
    #expect(system.raiseRequests.allSatisfy { $0.0 != id })
    #expect(system.focusedID == source.id)
}

@Test(.appTestApplication) @MainActor func paneLauncherTimeoutRetryLateArrivalCanOpenPickerRepeatedly() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    for index in 0..<3 {
        let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
        model.choosePaneApplication(paneTestApp, requestID: request.id, retry: true)
        await waitForPaneMenuRequest(model)
        request.deadline = model.paneApplicationUptime() - 1
        model.advancePaneApplicationRequest()
        #expect(request.fallbackReason == .timedOut)
        model.handlePaneRequestAction(.tryAgain, requestID: request.id)
        model.handlePaneRequestAction(.tryAgain, requestID: request.id)
        await waitForPaneMenuRequest(model)
        #expect(system.newWindowRequests.count == (index + 1) * 2)
        let late = appendPaneArrival(system, id: "retry-late-\(index)")
        system.desktopObservation?.windowMembership[late] = [.init(rawValue: 1)]
        try #require(await waitFor {
            model.advancePaneApplicationRequest()
            return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
        })
        #expect(model.activeTabbedState?.paneID(containing: late) == right)
        #expect(model.paneApplicationPopover == nil)
    }
    let picker = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    #expect(picker.phase == .choosing)
    model.cancelPaneApplicationRequest()
    #expect(model.paneApplicationRequest == nil && model.paneApplicationLaunchTask == nil)
}

/// Fake ordering keeps this full model/overlay/chooser lifecycle offscreen.
@MainActor private final class PaneLauncherTestPanel: OffscreenTestPanel {
    var shown = false
    override var isVisible: Bool { shown }
    override var screen: NSScreen? { NSScreen.screens.first }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { shown = place != .out }
    override func makeKey() {}
}

@Test(.appTestApplication, .settingsUI) @MainActor func paneLauncherNativeControlsSurviveTimeoutRetryAndClosedLateArrival() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.availableDisplays[0].frame.origin.x = 40000
    system.availableDisplays[0].visibleFrame.origin.x = 40000
    system.windows[0].frame.origin.x += 40000
    let space = NativeSpaceID(rawValue: 1)
    system.desktopObservation = .init(currentSpaceByDisplay: [system.mainDisplay.id: space],
        knownSpacesByDisplay: [system.mainDisplay.id: [space]], windowMembership: [system.windows[0].id: [space]])
    let root = FileManager.default.temporaryDirectory.appending(path: "PaneLauncherControls-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeOffscreenModel(store: ConfigurationStore(fileURL: root.appending(path: "configuration.json")),
        system: system, startRuntime: false, presentsTabbedChrome: true)
    defer { model.shutdown() }
    let clock = PaneApplicationTestClock(model)
    model.primaryButtonIsPressed = { false }
    let launcher = FakePaneApplicationLauncher()
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    model.paneApplicationLauncher = launcher
    var panels: [PaneLauncherTestPanel] = []
    let overlay = TabbedOverlayController(panelFactory: {
        let panel = PaneLauncherTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panels.append(panel); return panel
    }, addGlobalKeyMonitor: { _ in nil }, addLocalKeyMonitor: { _ in nil }, primaryButtonIsPressed: { false })
    model.tabbedOverlayFactory = { overlay }
    model.paneApplicationPopoverFactory = { request, appearance in
        PaneApplicationPopover(request: request, recentApplications: RecentApplications(defaults: MemoryDefaults()),
            appearance: appearance, presenterFactory: { content, size in
                TabbedChooserPresenter(content: content, size: size, panel: PaneLauncherTestPanel(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false))
            })
    }
    model.configuration.defaultTabbedPreset = .columns
    model.setActiveMode(.tabbed)
    try #require(await waitFor { model.activeTabbedState?.panes.count == 2 && !model.hasPendingTabbedPlacement })
    let right = try #require(model.activeTabbedState?.panes[1].id)
    let view = try #require(panels.compactMap { $0.contentView as? TabbedPaneView }.first { $0.pane.id == right })
    func open(_ button: NSButton) throws -> PaneApplicationRequest {
        #expect(overlay.acceptsTabDrags && !overlay.isDropPending && !overlay.isInteracting)
        // Native button action used by pointer clicks and AXPress, without cell tracking.
        try #require(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        let request = try #require(model.paneApplicationRequest)
        #expect(request.phase == .choosing)
        #expect(model.paneApplicationPopover?.presenter.isPresented == true)
        return request
    }
    system.newWindowRequestResult = .requested
    for index in 0..<3 {
        let request = try open(index == 0 ? view.content.emptyAddButton : view.content.addButton)
        model.choosePaneApplication(paneTestApp, requestID: request.id, retry: true)
        await waitForPaneMenuRequest(model)
        clock.now = try #require(request.deadline)
        model.advancePaneApplicationRequest()
        #expect(request.fallbackReason == .timedOut)
        model.handlePaneRequestAction(.tryAgain, requestID: request.id)
        #expect(request.phase == .waiting)
        model.handlePaneRequestAction(.tryAgain, requestID: request.id)
        await waitForPaneMenuRequest(model)
        #expect(system.newWindowRequests.count == (index + 1) * 2, "index=\(index), phase=\(request.phase), busy=\(model.hasPendingTabbedPlacement), owner=\(model.paneApplicationRequest?.id == request.id), retry=\(request.onRetry != nil)")
        let late = appendPaneArrival(system, id: "ui-late-\(index)")
        let wi = try #require(system.windows.firstIndex { $0.id == late })
        system.windows[wi].frame.origin.x += 40000
        system.desktopObservation?.windowMembership[late] = [space]
        try #require(await waitFor {
            model.advancePaneApplicationRequest()
            return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
        })
        #expect(overlay.acceptsTabDrags)
        #expect(model.activeTabbedState?.paneID(containing: late) == right)
        system.windows.removeAll { $0.id == late }
        system.eventHandler?(.init(kind: .destroyed, windowID: late, processIdentifier: 701))
        try #require(await waitFor { model.activeTabbedState?.windowIDs.contains(late) == false && !model.hasPendingTabbedPlacement })
        let next = try open(view.content.emptyAddButton)
        model.cancelPaneApplicationRequest(id: next.id)
        #expect(model.paneApplicationPopover == nil)
    }
    model.performTabbed(.preset(.rows))
    try #require(model.hasPendingTabbedPlacement)
    #expect(!overlay.acceptsTabDrags)
    try #require(NSApp.sendAction(try #require(view.content.addButton.action),
        to: view.content.addButton.target, from: view.content.addButton))
    try #require(await waitFor { model.paneApplicationPopover?.presenter.isPresented == true })
    #expect(model.paneApplicationRequest?.phase == .choosing)
    model.cancelPaneApplicationRequest()
}

@Test(.appTestApplication, arguments: ["New Recording", "New Event", "New Card", "New Note", "New Message"]) @MainActor
func paneLauncherSecurityUnlistedCommandReopensThenOffersDesktopChoice(title: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let command = NewWindowMenuCommand(title: title, role: "AXMenuItem", enabled: true, actions: ["AXPress"],
        commandCharacter: "n", commandModifiers: 0)
    system.newWindowRequestResult = command.canRequestWindow(bundleIdentifier: paneTestApp.id, language: "en") ? .requested : .unsupported
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model, expireReopen: false)
    #expect(launcher.reopens == [701])
    #expect(launcher.launches.isEmpty)
    request.deadline = model.paneApplicationUptime() - 1
    model.advancePaneApplicationRequest()
    #expect(request.status?.message.contains("Use a window from this desktop") == true)
}

@Test(.appTestApplication, arguments: ["Source", "Target"]) @MainActor
func paneLauncherUserActivationWithoutReopenSuppressesRaising(destination: String) {
    var front = "Source"
    let intent = ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    intent.requested = ["Target"]
    front = destination; intent.activated(front)
    #expect(intent.movedOn)
    #expect(!intent.allowsRaising)
}

@Test(.appTestApplication) @MainActor func paneLauncherReopenExemptsOnlyOneActivation() {
    var front = "Source"
    let intent = ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    intent.requested = ["Target"]
    #expect(!intent.prepareReopen(of: "Target"))
    front = "Target"; intent.activated(front)
    #expect(intent.allowsRaising)
    intent.activated(front)
    #expect(intent.movedOn)
    #expect(!intent.allowsRaising)
}


@Test(.appTestApplication) @MainActor func paneLauncherFailedReopenDoesNotExemptLaterUserActivation() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var front = "Source"
    model.paneApplicationUptime = { 1000 }
    model.paneApplicationRequestFocusFactory = { ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in Issue.record("Unexpected focus restoration") }) }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    launcher.failure = true
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    let intent = try #require(request.focusIntent)
    await model.paneApplicationLaunchTask?.value
    #expect(launcher.reopenActivations == [false])
    #expect(request.fallbackReason == .failed)
    #expect(model.registeredApplicationRequestFocusCount == 0)
    #expect(!intent.movedOn)
    front = paneTestApp.id
    intent.activated(front)
    #expect(!intent.movedOn)
    #expect(!intent.allowsRaising)
    #expect(system.newWindowRequests.count == 1)
}


@Test(.appTestApplication, arguments: ["click-source", "return-source", "later-other", "click-target", "keyboard-target", "target-only"])
@MainActor func paneLauncherPreservesLatestUserAppAfterTargetActivation(sequence: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var front = "Source"
    var restorations: [String] = []
    var keyEvents: UInt32 = 0
    model.paneApplicationUptime = { 1000 }
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { keyEvents }, restoreFrontmost: { restorations.append($0); front = $0 })
    }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    let intent = try #require(request.focusIntent)
    let source = WindowSnapshot(id: .init(rawValue: "source-choice"), processIdentifier: 999,
        bundleIdentifier: "Source", frame: .init(x: 10, y: 10, width: 200, height: 200), displayID: system.mainDisplay.id)
    request.windowAtPoint = { _ in source }
    let click = GlobalGestureEvent(kind: .leftMouseDown, position: .init(x: 50, y: 50), button: 0,
        modifiers: [], timestamp: 1_000_000_000_000)
    if sequence == "click-source" {
        model.receivePaneApplicationMouseEvent(click)
        #expect(intent.movedOn)
    }
    front = paneTestApp.id; intent.activated(front)
    if sequence != "click-source", sequence != "target-only" {
        front = "Source"; intent.activated(front)
        front = paneTestApp.id; intent.activated(front)
    }
    if sequence == "later-other" { front = "Other"; intent.activated(front) }
    if sequence == "keyboard-target" { keyEvents += 1 }
    if sequence == "click-target" {
        var target = source; target.bundleIdentifier = paneTestApp.id
        request.windowAtPoint = { _ in target }
        model.receivePaneApplicationMouseEvent(click)
    }
    let id = appendPaneArrival(system, id: "focus-after-activation")
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(system.frameWriteCounts[id] == 1)
    if sequence == "click-source" || sequence == "return-source" {
        #expect(front == "Source")
        #expect(restorations == ["Source"])
        #expect(system.raiseRequests.allSatisfy { $0.0 != id })
    } else {
        #expect(front == (sequence == "later-other" ? "Other" : paneTestApp.id))
        #expect(restorations.isEmpty)
    }
}

@Test(.appTestApplication) @MainActor func paneLauncherReopenRequestsBackgroundActivationOnly() {
    let intent = ApplicationRequestFocus(frontmost: { "Source" }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    intent.requested = ["Target"]
    #expect(!intent.prepareReopen(of: "Target"))
    // The app may activate itself despite a background reopen.
    intent.activated("Target")
    #expect(!intent.movedOn)
}

@Test(.appTestApplication) @MainActor func paneLauncherFallbackFeedRecordsSourceChoice() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    model.updateConfiguration { $0.snappingEnabled = false; $0.linkedResizeEnabled = false }
    model.paneApplicationUptime = { 1000 }
    let intent = ApplicationRequestFocus(frontmost: { "Source" }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    model.paneApplicationRequestFocusFactory = { intent }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    request.windowAtPoint = { _ in WindowSnapshot(id: .init(rawValue: "source-choice"), processIdentifier: 999,
        bundleIdentifier: "Source", frame: .init(x: 10, y: 10, width: 200, height: 200), displayID: system.mainDisplay.id) }
    #expect(model.observesApplicationRequestMouseDown, "Pending request keeps observation after picker dismissal")
    model.receiveFallbackRequestMouseEvent(GlobalGestureEvent(kind: .leftMouseDown, position: .init(x: 50, y: 50),
        button: 0, modifiers: [], timestamp: 1_000_000_000_000))
    #expect(intent.movedOn)
    model.cancelPaneApplicationRequest()
    #expect(!model.observesApplicationRequestMouseDown)
}


@Test(.appTestApplication) @MainActor
func paneLauncherTimeoutUnregistersFocusIntent() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    model.paneApplicationUptime = { 1_000 }
    let focus = ApplicationRequestFocus(frontmost: { "Source" }, keyboardEventCount: { 0 },
        restoreFrontmost: { _ in })
    model.paneApplicationRequestFocusFactory = { focus }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    #expect(model.registeredApplicationRequestFocusCount == 1)
    request.deadline = 999
    model.advancePaneApplicationRequest()
    #expect(request.fallbackReason == .timedOut)
    #expect(model.paneApplicationRequest === request, "The explicit-choice fallback remains visible")
    #expect(model.registeredApplicationRequestFocusCount == 0)
    focus.activated("Other")
    #expect(!focus.movedOn, "The timed-out opening should no longer participate in shared focus intent")
}

@Test(.appTestApplication) @MainActor
func paneLauncherTimedOutTargetDoesNotHideLaterUserChoice() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var front = "Source"
    var restored: [String] = []
    model.paneApplicationUptime = { 1_000 }
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 },
            restoreFrontmost: { app in restored.append(app); front = app })
    }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    request.deadline = 999
    model.advancePaneApplicationRequest()
    #expect(request.fallbackReason == .timedOut)
    let peer = model.makeApplicationRequestFocus()
    defer { peer.finish() }
    peer.requested = ["B"]
    peer.expectActivation(of: "B")
    front = paneTestApp.id
    model.requestApplicationActivated(front)
    #expect(peer.movedOn)
    front = "B"
    model.requestApplicationActivated(front)
    peer.restoreUserFocusIfNeeded()
    #expect(front == paneTestApp.id)
    #expect(restored == [paneTestApp.id])
}

@Test(.appTestApplication) @MainActor
func paneLauncherArrivedFallbackReleasesFocusAtOpeningDeadline() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var now: TimeInterval = 1_000
    model.paneApplicationUptime = { now }
    model.paneApplicationTimeout = 10 // Opening expires before the separate 60-second click deadline.
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { "Source" }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    let id = WindowID(rawValue: "unconfirmed")
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    try #require(await waitFor { model.advancePaneApplicationRequest(); return request.fallbackReason == .arrived })
    #expect(request.fallbackReason == .arrived)
    #expect(model.registeredApplicationRequestFocusCount == 1)
    now = try #require(request.deadline) + 1
    model.advancePaneApplicationRequest()
    #expect(model.paneApplicationRequest === request, "Use here stays available until the separate click deadline")
    #expect(request.existingWindows.contains { $0.id == id })
    #expect(model.registeredApplicationRequestFocusCount == 0)
    #expect(request.focusIntent == nil)
}

@Test(.appTestApplication) @MainActor
func paneLauncherLateUseHerePreservesNewerAppChoice() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var now: TimeInterval = 1_000
    var front = "Source"
    var restorations: [String] = []
    model.paneApplicationUptime = { now }
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 },
            restoreFrontmost: { app in restorations.append(app); front = app })
    }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    now = try #require(request.deadline) + 1
    model.advancePaneApplicationRequest()
    #expect(request.fallbackReason == .timedOut)
    let late = appendPaneArrival(system, id: "late")
    model.advancePaneApplicationRequest()
    system.raiseRequests.removeAll()
    system.onFrameWrite = { id, _ in
        guard id == late else { return }
        front = "Other"
        model.requestApplicationActivated(front)
    }
    model.handlePaneRequestAction(.useWindow(late), requestID: request.id)
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: late) == right)
    #expect(system.frameWriteCounts[late, default: 0] > 0)
    #expect(!system.raiseRequests.contains { $0.0 == late })
    #expect(front == "Other")
    #expect(restorations.isEmpty)
    #expect(model.registeredApplicationRequestFocusCount == 1)
    now += 2.5
    model.requestApplicationActivated(nil)
    #expect(model.registeredApplicationRequestFocusCount == 0)
}

@Test(.appTestApplication) @MainActor
func paneLauncherLateUseHereRaisesAlreadyFrontmostTarget() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var now: TimeInterval = 1_000
    var front = "Source"
    model.paneApplicationUptime = { now }
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    now = try #require(request.deadline) + 1
    model.advancePaneApplicationRequest()
    let late = appendPaneArrival(system, id: "frontmost")
    model.advancePaneApplicationRequest()
    front = paneTestApp.id
    model.requestApplicationActivated(front)
    system.raiseRequests.removeAll()
    model.handlePaneRequestAction(.useWindow(late), requestID: request.id)
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: late) == right)
    #expect(system.raiseRequests.contains { $0.0 == late })
    #expect(model.registeredApplicationRequestFocusCount == 1)
    now += 2.5
    model.requestApplicationActivated(nil)
    #expect(model.registeredApplicationRequestFocusCount == 0)
}

@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: ["late40", "late100", "early", "late2500", "target-click", "target-click-after-placement", "click-after-placement", "keyboard"])
@MainActor func paneLauncherActivationAfterPlacementRestoresClickedSourceOnce(order: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var front = "Source"
    var restored: [String] = []
    var keys: UInt32 = 0
    let clock = ManualClock()
    let start = clock.now
    model.paneApplicationClock = clock.clock
    model.paneApplicationUptime = { 1_000 + start.duration(to: clock.now) / .seconds(1) }
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { keys },
            restoreFrontmost: { app in restored.append(app); front = app })
    }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    let polling = try #require(model.paneApplicationTask)
    clock.advance(by: .milliseconds(10))
    request.windowAtPoint = { _ in WindowSnapshot(id: .init(rawValue: "source-choice"),
        processIdentifier: 999, bundleIdentifier: "Source", frame: .init(x: 10, y: 10, width: 200, height: 200),
        displayID: system.mainDisplay.id) }
    if order != "click-after-placement" {
        model.receivePaneApplicationMouseEvent(GlobalGestureEvent(kind: .leftMouseDown,
            position: .init(x: 50, y: 50), button: 0, modifiers: [],
            timestamp: UInt64(model.paneApplicationUptime() * 1_000_000_000)))
    }
    if order == "early" || order == "target-click" {
        front = paneTestApp.id
        model.requestApplicationActivated(front)
    }
    if order == "target-click" {
        clock.advance(by: .milliseconds(10))
        request.windowAtPoint = { _ in WindowSnapshot(id: .init(rawValue: "target-choice"),
            processIdentifier: 701, bundleIdentifier: paneTestApp.id,
            frame: .init(x: 10, y: 10, width: 200, height: 200), displayID: system.mainDisplay.id) }
        model.receivePaneApplicationMouseEvent(GlobalGestureEvent(kind: .leftMouseDown,
            position: .init(x: 50, y: 50), button: 0, modifiers: [],
            timestamp: UInt64(model.paneApplicationUptime() * 1_000_000_000)))
    }
    let id = appendPaneArrival(system, id: "late-activation")
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    })
    await polling.value // Completion cancels the poll; do not leave it competing with the expiry timer.
    try await waitForWindowEventsToDrain(model)
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    if order != "early" {
        // The only remaining pane-clock sleeper is the completed request's two-second expiry timer.
        // Policy uptime and its expiry timer must share time, even across a delayed test turn.
        await clock.waitForSleepers(count: 1)
        #expect(model.registeredApplicationRequestFocusCount == 1)
    }
    if order == "click-after-placement" {
        clock.advance(by: .milliseconds(10))
        model.applicationRequestWindowAtPoint = { _ in WindowSnapshot(id: .init(rawValue: "source-choice"),
            processIdentifier: 999, bundleIdentifier: "Source",
            frame: .init(x: 10, y: 10, width: 200, height: 200), displayID: system.mainDisplay.id) }
        model.receivePaneApplicationMouseEvent(GlobalGestureEvent(kind: .leftMouseDown,
            position: .init(x: 50, y: 50), button: 0, modifiers: [],
            timestamp: UInt64(model.paneApplicationUptime() * 1_000_000_000)))
    }
    if order == "target-click-after-placement" {
        clock.advance(by: .milliseconds(10))
        model.applicationRequestWindowAtPoint = { _ in WindowSnapshot(id: id,
            processIdentifier: 701, bundleIdentifier: paneTestApp.id,
            frame: .init(x: 10, y: 10, width: 200, height: 200), displayID: system.mainDisplay.id) }
        model.receivePaneApplicationMouseEvent(GlobalGestureEvent(kind: .leftMouseDown,
            position: .init(x: 50, y: 50), button: 0, modifiers: [],
            timestamp: UInt64(model.paneApplicationUptime() * 1_000_000_000)))
    }
    if order == "keyboard" { keys += 1 }
    if order != "early" {
        clock.advance(by: order == "late2500" ? .milliseconds(2_500)
            : order == "late100" ? .milliseconds(100) : .milliseconds(40))
        if order == "late2500" {
            try #require(await waitFor { model.registeredApplicationRequestFocusCount == 0 })
        }
        front = paneTestApp.id
        model.requestApplicationActivated(front)
    }
    if ["late40", "late100", "early", "click-after-placement"].contains(order) {
        #expect(front == "Source")
        #expect(restored == ["Source"])
    } else {
        #expect(front == paneTestApp.id)
        #expect(restored.isEmpty)
    }
    if order != "early" { model.requestApplicationActivated(paneTestApp.id) }
    #expect(restored.count <= 1)
    clock.advance(by: .milliseconds(2_500))
    // Observe the expiry task itself, without a notification that would expire the deadline for it.
    try #require(await waitFor { model.registeredApplicationRequestFocusCount == 0 })
    #expect(restored.count <= 1)
}

@Test(.appTestApplication) @MainActor
func paneLauncherArrivedDeadlineUseHerePlacesWithoutChangingNewerFocus() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var now: TimeInterval = 1_000
    var front = "Source"
    model.paneApplicationUptime = { now }
    model.paneApplicationTimeout = 10 // Opening expires before the separate 60-second click deadline.
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { 0 },
            restoreFrontmost: { _ in Issue.record("Unexpected focus restoration") })
    }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    let id = WindowID(rawValue: "arrived-use-here")
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    try #require(await waitFor { model.advancePaneApplicationRequest(); return request.fallbackReason == .arrived })
    now = try #require(request.deadline) + 1
    model.advancePaneApplicationRequest()
    #expect(model.paneApplicationRequest === request)
    #expect(request.focusIntent == nil)
    system.onFrameWrite = { written, _ in
        guard written == id else { return }
        front = "Other"
        model.requestApplicationActivated(front)
    }
    model.handlePaneRequestAction(.useWindow(id), requestID: request.id)
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(system.frameWriteCounts[id, default: 0] > 0)
    #expect(!system.raiseRequests.contains { $0.0 == id })
    #expect(front == "Other")
    now += 2.5
    model.requestApplicationActivated(nil)
    #expect(model.registeredApplicationRequestFocusCount == 0)
}

@Test(.appTestApplication, arguments: ["success", "failure", "cancel", "retry", "desktop", "pane", "layout", "mode"])
@MainActor func paneLauncherTerminalPathsEmptySharedIntent(path: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var now: TimeInterval = 1_000
    model.paneApplicationUptime = { now }
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { "Source" }, keyboardEventCount: { 0 }, restoreFrontmost: { _ in })
    }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    launcher.failure = path == "failure"
    system.newWindowRequestResult = path == "failure" ? .unsupported : .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    if path != "failure" { #expect(model.registeredApplicationRequestFocusCount == 1) }
    switch path {
    case "success":
        let id = appendPaneArrival(system, id: "success")
        try #require(await waitFor {
            model.advancePaneApplicationRequest()
            return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
        })
        #expect(model.activeTabbedState?.paneID(containing: id) == right)
    case "retry":
        request.deadline = 999
        model.advancePaneApplicationRequest()
        #expect(model.registeredApplicationRequestFocusCount == 0)
        model.handlePaneRequestAction(.tryAgain, requestID: request.id)
        #expect(model.registeredApplicationRequestFocusCount == 1)
        model.cancelPaneApplicationRequest()
    case "desktop": model.beginActiveSpaceStabilization()
    case "pane": model.performTabbed(.removePane(right))
    case "layout": model.performTabbed(.preset(.rows))
    case "mode": model.setActiveMode(.manual)
    case "cancel": model.cancelPaneApplicationRequest()
    default: break
    }
    if path == "success" {
        #expect(model.registeredApplicationRequestFocusCount == 1)
        now += 2.5
        model.requestApplicationActivated(nil)
    }
    #expect(model.registeredApplicationRequestFocusCount == 0, "path=\(path)")
}

// Reuses the review's two-helper A/B sequence through the model's production factory.
@Test(.appTestApplication, arguments: [false, true]) @MainActor
func paneLauncherConcurrentRequestsDoNotReplaceUserChoice(reverseCompletion: Bool) async throws {
    let (_, model, _, _) = try await paneLauncherFixture()
    defer { model.shutdown() }
    var front = "Source"
    var restored: [String] = []
    var keys: UInt32 = 0
    model.paneApplicationRequestFocusFactory = {
        ApplicationRequestFocus(frontmost: { front }, keyboardEventCount: { keys }, restoreFrontmost: { [weak model] app in
            restored.append(app)
            front = app
            model?.requestApplicationActivated(app)
        })
    }
    let pane = model.makeApplicationRequestFocus()
    let peer = model.makeApplicationRequestFocus()
    defer { pane.finish(); peer.finish() }
    pane.requested = ["A"]; peer.requested = ["B"]
    pane.expectActivation(of: "A"); peer.expectActivation(of: "B")
    // Each target's expected activation belongs to the same record, including
    // when the other request receives the notification first.
    front = "A"; peer.activated(front)
    front = "B"; pane.activated(front)
    #expect(!pane.movedOn && !peer.movedOn)
    pane.userChose("Source")
    front = "A"; model.requestApplicationActivated(front)
    front = "B"; model.requestApplicationActivated(front)
    let first = reverseCompletion ? pane : peer
    let second = reverseCompletion ? peer : pane
    first.restoreUserFocusIfNeeded()
    #expect(front == "Source")
    #expect(restored == ["Source"])
    // The same choice cannot authorize a second restoration even if another
    // target activates after the first request completes.
    first.finish()
    front = reverseCompletion ? "B" : "A"
    model.requestApplicationActivated(front)
    second.restoreUserFocusIfNeeded()
    #expect(restored == ["Source"])
    // A genuinely newer app choice permits one new restoration.
    front = "Other"; model.requestApplicationActivated(front)
    front = reverseCompletion ? "B" : "A"; model.requestApplicationActivated(front)
    second.restoreUserFocusIfNeeded()
    #expect(restored == ["Source", "Other"])
    // A keyboard switch to the target is also a genuine choice.
    front = "Source"; second.userChose(front)
    keys += 1
    front = reverseCompletion ? "B" : "A"; model.requestApplicationActivated(front)
    second.restoreUserFocusIfNeeded()
    #expect(restored == ["Source", "Other"])
    #expect(front == (reverseCompletion ? "B" : "A"))
}

/// Stands in for the tap thread only. Delivery uses the production callback's conversion and handler.
private final class FakeGestureTapWorker: GestureEventTapWorking, @unchecked Sendable {
    let handler: @Sendable (GestureEventTapMessage) -> Void
    private(set) var started = false
    init(handler: @escaping @Sendable (GestureEventTapMessage) -> Void) { self.handler = handler }
    func start() -> Bool { started = true; return true }
    func stop() { started = false }
    func post(_ event: CGEvent, type: CGEventType) {
        guard started, let gesture = GlobalGestureEvent(tapEvent: event, type: type) else { return }
        handler(.event(gesture))
    }
}

private final class FakeKeyDownCounter: KeyboardEventCounting {
    var count: UInt32 = 0
    func keyDownCount() -> UInt32 { count }
}

/// This generic body must compile from the app seam alone, so removing either
/// inherited capability fails even if the concrete adapters still conform.
@Test(.appTestApplication) @MainActor func paneLauncherWindowSystemRequiresRequestCapabilities() {
    func requireCapabilities<System: BetterTileWindowSystem>(_: System.Type) {
        let _: any WindowHitTesting.Type = System.self
        let _: any ApplicationActivating.Type = System.self
        let _: any ApplicationWindowRequesting.Type = System.self
    }
    requireCapabilities(AccessibilityWindowSystem.self)
    requireCapabilities(FakeAppWindowSystem.self)
}

/// Live case C through the production adapters: TextEdit-like Source is frontmost, the target is requested,
/// the user clicks Source while Opening, and the target activates before its window is placed.
/// A real CGEvent click, stamped with injected uptime nanoseconds, passes through the shared
/// tap's conversion, `SharedGestureEventMonitor`, the model's production hit test, request clocks and helper
/// factory. Accessibility, time, the frontmost app and the key-down count use their injected seams.
@Test(.appTestApplication, arguments: ["tap", "fallback", "keys-before-click", "two-copies", "keys-after-click", "keyboard-switch", "target-click", "newer-app"])
@MainActor func paneLauncherLiveOrderRestoresClickedSourceThroughCoordinator(variant: String) async throws {
    // Check the production conformance table without constructing an AX adapter
    // or reading live windows. The generic test above checks the app seam.
    let productionAdapter: Any.Type = AccessibilityWindowSystem.self
    try #require(productionAdapter is any WindowHitTesting.Type,
                 "The real adapter must expose its hit test through the request's protocol")
    var worker: FakeGestureTapWorker?
    let monitor = SharedGestureEventMonitor(disabled: false, makeWorker: { handler in
        let fake = FakeGestureTapWorker(handler: handler)
        worker = fake
        return fake
    })
    let (system, model, launcher, right, clock) = try await paneLauncherFixtureWithClock(gestureEvents: monitor)
    defer { model.shutdown() }
    clock.now = 1_000 // Exact nanosecond round-trip through CGEvent and NSEvent.
    // The pane handler runs before drag snapping; keep the gesture controllers out of this test.
    model.updateConfiguration { $0.snappingEnabled = false; $0.linkedResizeEnabled = false }
    system.hitTestsWindows = true
    // An off-centre hit region rejects an accidental AppKit/CG Y flip.
    system.windows[0].frame = BTRect(x: 10, y: 60, width: 350, height: 150)
    let source = try #require(system.windows.first)
    let sourceApp = try #require(source.bundleIdentifier)
    if variant == "two-copies" { system.additionalProcesses[sourceApp] = [source.processIdentifier + 1] }
    var front = sourceApp
    let keys = FakeKeyDownCounter()
    model.applicationRequestFrontmost = { front }
    model.applicationRequestKeyboard = keys
    system.onApplicationActivation = { [unowned system] pid in
        front = system.windows.first { $0.processIdentifier == pid }?.bundleIdentifier ?? front
    }
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    #expect(system.newWindowRequests.count == 1)
    let tap = try #require(worker)
    #expect(tap.started, "A pending request keeps the shared tap running with snapping off")
    if variant == "keys-before-click" { keys.count += 3 } // Typing before the click, such as picker search.

    func click(_ point: BTPoint) async throws {
        clock.now += 1 // Distinct clicks have distinct timestamps in the shared intent record.
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: point.x, y: point.y), mouseButton: .left))
            // The tap copies uptime nanoseconds; stamp the fixture with the request's injected time.
            event.timestamp = UInt64(model.paneApplicationUptime() * 1_000_000_000)
            if variant == "fallback" {
                // The AppKit monitor reports bottom-left screen points; the event converts them back.
                if type == .leftMouseDown {
                    let appKit = try #require(NSEvent(cgEvent: event))
                    model.receiveFallbackRequestMouseEvent(try #require(GlobalGestureEvent(appKit, kind: .leftMouseDown)))
                }
            } else {
                tap.post(event, type: type)
            }
        }
        // The monitor hops to the main queue, as it does from the tap thread. The queue is FIFO.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    let sourcePoint = BTPoint(x: source.frame.minX + 10, y: source.frame.midY)
    try await click(sourcePoint)
    #expect(request.focusIntent?.movedOn == true, "The Source click is recorded although Source is already frontmost")
    // The target activates after the click and before its window reaches the pane.
    if variant == "keyboard-switch" { keys.count += 1 }
    front = paneTestApp.id
    model.requestApplicationActivated(paneTestApp.id)
    if variant == "keys-after-click" { keys.count += 1 }
    if variant == "newer-app" { front = "com.example.Other"; model.requestApplicationActivated(front) }
    let id: WindowID
    if variant == "target-click" {
        // Click the new window where it is, before its created event can start placement.
        id = WindowID(rawValue: "arrival")
        let arrival = WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id, title: id.rawValue,
            frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id)
        system.windows.append(arrival)
        try await click(BTPoint(x: arrival.frame.midX, y: arrival.frame.midY))
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: id, processIdentifier: 701))
    } else {
        id = appendPaneArrival(system, id: "arrival")
    }
    try #require(await waitFor {
        model.advancePaneApplicationRequest()
        return model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement
    })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(system.frameWriteCounts[id] == 1)
    #expect(!system.raiseRequests.contains { $0.0 == id })
    if ["tap", "fallback", "keys-before-click", "two-copies"].contains(variant) {
        #expect(system.applicationActivations == [source.processIdentifier], "Restore the clicked Source process once")
        #expect(front == sourceApp)
        #expect(model.registeredApplicationRequestFocusCount == 0)
        // A later target activation cannot restore the same choice again.
        front = paneTestApp.id
        model.requestApplicationActivated(paneTestApp.id)
        #expect(system.applicationActivations.count == 1)
    } else {
        #expect(system.applicationActivations.isEmpty)
        #expect(front == (variant == "newer-app" ? "com.example.Other" : paneTestApp.id))
        let later = model.paneApplicationUptime() + 2.5
        model.paneApplicationUptime = { later }
        model.requestApplicationActivated(nil)
        #expect(model.registeredApplicationRequestFocusCount == 0)
    }
}

@Test(.appTestApplication) func paneLauncherSessionKeyDownCounterReadsPublicAggregate() {
    let before = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    let read = SessionKeyDownCounter().keyDownCount()
    let after = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    #expect(before <= read && read <= after)
}


@Test(.appTestApplication) @MainActor func paneLauncherPickerRowsReadOneWindowSnapshot() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    let source = try #require(system.windows.first)
    let sourceApp = ApplicationChoice(bundleIdentifier: try #require(source.bundleIdentifier), name: "Source",
        url: URL(filePath: "/fixture/Source.app"))
    launcher.instances[sourceApp.id] = [.init(processIdentifier: source.processIdentifier, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    let apps = [sourceApp] + (1..<150).map {
        ApplicationChoice(bundleIdentifier: "com.example.Installed\($0)", name: "App \($0)",
                          url: URL(filePath: "/fixture/App\($0).app"))
    }
    let sections = ApplicationPickerModel.sections(installed: apps, running: [sourceApp])
    let refreshes = system.nativeDesktopRefreshCount
    let instanceReads = launcher.runningInstanceReadCount
    for _ in 0..<3 {
        _ = ApplicationPickerModel.windowSections(sections, expansion: .init(), windows: request.windows)
    }
    #expect(request.windows?(sourceApp)?.map(\.id) == [source.id.rawValue])
    #expect(system.nativeDesktopRefreshCount == refreshes, "Rendering rows must not refresh Spaces")
    #expect(launcher.runningInstanceReadCount == instanceReads, "Rendering rows must not query each app")
    print("PANE_PICKER_READS rows=150 redraws=3 spaceRefreshes=\(system.nativeDesktopRefreshCount - refreshes) instanceReads=\(launcher.runningInstanceReadCount - instanceReads)")

    let added = appendPaneArrival(system, id: "picker-window", app: sourceApp, pid: source.processIdentifier)
    try #require(await waitFor {
        Set(request.windows?(sourceApp)?.map(\.id) ?? []) == [source.id.rawValue, added.rawValue]
    })
    system.windows.removeAll { $0.id == added }
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: added, processIdentifier: source.processIdentifier))
    try #require(await waitFor { request.windows?(sourceApp)?.map(\.id) == [source.id.rawValue] })
    // The event-driven owner check also handles permission loss.
    system.permission = false
    model.refreshPermission(recoverWindows: false)
    #expect(model.paneApplicationRequest == nil)
}

@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: ["choosing", "unsupported", "timedOut", "failed", "other", "severalCopies"])
@MainActor func paneLauncherIdleStatesDoNotPoll(state: String) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    let manual = ManualClock()
    model.paneApplicationClock = manual.clock
    var poll: Task<Void, Never>?
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    if state != "choosing" {
        if state == "severalCopies" {
            launcher.instances[paneTestApp.id]?.append(.init(processIdentifier: 702, launchDate: nil))
        }
        if state == "failed" { launcher.failure = true }
        model.choosePaneApplication(paneTestApp, requestID: request.id)
        poll = model.paneApplicationTask
        await model.paneApplicationLaunchTask?.value
        if state == "timedOut" {
            request.deadline = model.paneApplicationUptime()
            model.advancePaneApplicationRequest()
        } else if state == "unsupported" || state == "other" {
            // These two fallbacks remain supported even when an adapter supplies them directly.
            request.phase = .fallback("Use a window")
            request.fallbackReason = state == "unsupported" ? .unsupported : .other
            model.advancePaneApplicationRequest()
        }
    }
    #expect(!model.isPollingPaneApplicationRequest, "No recurring task is retained in \(state)")
    let refreshes = system.nativeDesktopRefreshCount
    manual.advance(by: .seconds(1))
    await poll?.value
    #expect(system.nativeDesktopRefreshCount == refreshes, "An idle request must not refresh desktop ownership")
    #expect(model.paneApplicationRequest?.id == request.id)
    model.beginActiveSpaceStabilization()
    #expect(model.paneApplicationRequest == nil)
    #expect(!model.isPollingPaneApplicationRequest)
}


@Test(.appTestApplication) @MainActor func paneLauncherBoundedStatesKeepPollingAndReleaseIt() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    #expect(model.isPollingPaneApplicationRequest)
    await model.paneApplicationLaunchTask?.value
    let id = WindowID(rawValue: "unconfirmed")
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    // Let the real 200 ms poll discover the unconfirmed window and expire the click wait.
    try #require(await waitFor { request.fallbackReason == .arrived })
    #expect(model.isPollingPaneApplicationRequest)
    request.clickDeadline = model.paneApplicationUptime() - 1
    try #require(await waitFor { model.paneApplicationRequest == nil })
    #expect(!model.isPollingPaneApplicationRequest)
    #expect(model.registeredApplicationRequestFocusCount == 0)
}

@Test(.appTestApplication) @MainActor func paneLauncherIdleFallbackUpdatesFromWindowEventsAndPlaces() async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    request.deadline = model.paneApplicationUptime()
    model.advancePaneApplicationRequest()
    #expect(!model.isPollingPaneApplicationRequest)
    let id = appendPaneArrival(system, id: "idle-late")
    // No manual request advance: the normal window event refreshes the fallback list.
    try #require(await waitFor { request.existingWindows.contains { $0.id == id } })
    #expect(!model.isPollingPaneApplicationRequest)
    system.onFrameWrite = { written, _ in
        if written == id { #expect(model.isPollingPaneApplicationRequest, "Placement retains its bounded poll") }
    }
    model.useExistingPaneApplicationWindow(id, requestID: request.id)
    try #require(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.paneID(containing: id) == right)
    #expect(!model.isPollingPaneApplicationRequest)
}

@Test(.appTestApplication, arguments: ["pane", "layout", "mode", "permission", "bounds", "desktop"])
@MainActor func paneLauncherIdlePickerEndsOnOwnerEvents(event: String) async throws {
    let (system, model, _, right) = try await paneLauncherFixture()
    defer { model.shutdown() }
    _ = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    #expect(!model.isPollingPaneApplicationRequest)
    switch event {
    case "pane": model.performTabbed(.removePane(right))
    case "layout": model.performTabbed(.preset(.rows))
    case "mode": model.setActiveMode(.manual)
    case "permission": system.permission = false; model.refreshPermission(recoverWindows: false)
    case "bounds":
        system.availableDisplays[0].visibleFrame.size.height -= 50
        model.watchdog()
    default: model.beginActiveSpaceStabilization()
    }
    #expect(model.paneApplicationRequest == nil)
    #expect(!model.isPollingPaneApplicationRequest)
}

/// Both a clock behind and ahead of real uptime must own the entire waiting deadline.
@Test(.appTestApplication, arguments: [0.0, 1_000_000_000.0], [29.999, 30.0, 30.001]) @MainActor
func paneLauncherWaitingDeadlineUsesInjectedClock(start: Double, elapsed: Double) async throws {
    let (system, model, launcher, right, clock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    clock.now = start
    model.paneApplicationTimeout = 30
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    #expect(request.phase == .waiting)
    #expect(request.deadline == start + 30)
    let writes = system.frameWriteCounts

    clock.now = start + elapsed
    model.advancePaneApplicationRequest()
    if elapsed < 30 {
        #expect(request.phase == .waiting)
    } else {
        guard case .fallback = request.phase else {
            Issue.record("The injected deadline must end the waiting phase")
            return
        }
        #expect(request.fallbackReason == .timedOut)
    }
    #expect(system.newWindowRequests.count == 1)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [29.999, 30.0, 30.001]) @MainActor
func paneLauncherCancelledArrivalGuardExpiresAtThirtySeconds(elapsed: Double) async throws {
    let (system, model, launcher, right, clock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    clock.now = 1_000
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let first = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: first.id)
    await waitForPaneMenuRequest(model)
    model.cancelPaneApplicationRequest()

    clock.now += elapsed
    let next = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: next.id)
    await waitForPaneMenuRequest(model)
    if elapsed < 30 {
        guard case .fallback = next.phase else {
            Issue.record("The cancelled request must guard arrivals until 30 seconds")
            return
        }
        #expect(system.newWindowRequests.count == 1)
    } else {
        #expect(next.phase == .waiting)
        #expect(system.newWindowRequests.count == 2)
    }
}

// Unconfirmed arrivals keep the explicit click fallback after automatic placement.
@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: ["click", "already-focused", "slow-click", "focus-only", "other-window", "expired", "other-focus",
                  "focus-moves-away", "drag", "drag-back"]) @MainActor
func paneLauncherClickRequiresArrivedWindowMouseDownAndUp(evidence: String) async throws {
    let (system, model, launcher, right, clickClock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    clickClock.now = 1_000
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let id = appendUnconfirmedPaneArrival(system, id: "click-arrival")
    try #require(await waitFor { request.fallbackReason == .arrived })
    model.advancePaneApplicationRequest() // Refresh the unconfirmed fallback's click candidates.
    #expect(system.frameWriteCounts[id, default: 0] == 0)
    request.windowAtPoint = { _ in system.windows.first { $0.id == (evidence == "other-window" ? system.windows[0].id : id) } }
    let manual = ManualClock()
    model.paneApplicationClock = manual.clock
    model.paneApplicationClickConfirmDelay = .milliseconds(50)
    func mouse(_ kind: GlobalGestureEventKind, x: Double = 100, age: Double = 0) {
        model.receivePaneApplicationMouseEvent(GlobalGestureEvent(kind: kind, position: BTPoint(x: x, y: 180), button: 0,
            modifiers: [], timestamp: UInt64((model.paneApplicationUptime() - age) * 1_000_000_000)))
    }
    func unplaced() {
        model.advancePaneApplicationRequest()
        #expect(request.fallbackReason == .arrived)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        #expect(model.activeTabbedState?.pane(containing: id) == nil)
    }
    if ["already-focused", "slow-click", "focus-moves-away", "drag", "drag-back"].contains(evidence) {
        // The app focused its own new window when it appeared, before any click.
        system.focusedID = id
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: id, processIdentifier: 701))
        unplaced()
    }
    switch evidence {
    case "focus-only":
        system.focusedID = id
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: id, processIdentifier: 701))
    case "expired":
        mouse(.leftMouseDown, age: 2)
        mouse(.leftMouseUp)
    case "other-focus":
        mouse(.leftMouseDown)
        system.focusedID = system.windows[0].id
        system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: system.focusedID, processIdentifier: 42))
        mouse(.leftMouseUp)
    case "focus-moves-away":
        mouse(.leftMouseDown)
        mouse(.leftMouseUp)
        // The click landed on the window, but focus is elsewhere when the model confirms it.
        system.focusedID = system.windows[0].id
    case "slow-click":
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged, x: 102)
        manual.advance(by: .milliseconds(300))
        unplaced()
        mouse(.leftMouseUp, x: 101)
    case "drag":
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged, x: 140)
        manual.advance(by: .milliseconds(300))
        unplaced()
        mouse(.leftMouseUp, x: 140)
    case "drag-back":
        // Moving away and back to the start is still a drag.
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged, x: 140)
        mouse(.leftMouseDragged, x: 100)
        mouse(.leftMouseUp)
    default:
        mouse(.leftMouseDown)
        if evidence == "click" {
            system.focusedID = id
            system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: id, processIdentifier: 701))
        }
        mouse(.leftMouseUp)
    }
    if let confirmation = model.paneApplicationClickTask {
        await manual.waitForSleepers(count: 1)
        manual.advance(by: .milliseconds(50))
        await confirmation.value
    }
    if ["click", "already-focused", "slow-click"].contains(evidence) {
        #expect(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.pane(containing: id)?.id == right)
    } else {
        // Any scheduled confirmation has completed, so a late confirmation cannot pass unnoticed.
        unplaced()
    }
}

// Without the shared tap, the AppKit fallback carries the whole click to the request, with or without snapping.
@Test(.appTestApplication, .timeLimit(.minutes(5)), arguments: [false, true], ["click", "drag-back"]) @MainActor
func paneLauncherFallbackCompletesArrivedWindowClick(snapping: Bool, gesture: String) async throws {
    let (system, model, launcher, right, clickClock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    model.updateConfiguration { $0.snappingEnabled = snapping }
    clickClock.now = 1_000
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let id = appendUnconfirmedPaneArrival(system, id: "fallback-click-arrival")
    try #require(await waitFor { request.fallbackReason == .arrived })
    model.advancePaneApplicationRequest() // Refresh the unconfirmed fallback's click candidates.
    #expect(system.frameWriteCounts[id, default: 0] == 0)
    #expect(model.observesApplicationRequestMouseDown && model.observesApplicationRequestMouseSequence)
    request.windowAtPoint = { _ in system.windows.first { $0.id == id } }
    let manual = ManualClock()
    model.paneApplicationClock = manual.clock
    model.paneApplicationClickConfirmDelay = .milliseconds(50)
    func mouse(_ kind: GlobalGestureEventKind, x: Double = 100) {
        model.receiveFallbackRequestMouseEvent(GlobalGestureEvent(kind: kind, position: BTPoint(x: x, y: 180), button: 0,
            modifiers: [], timestamp: UInt64(model.paneApplicationUptime() * 1_000_000_000)))
    }
    mouse(.leftMouseDown)
    if gesture == "drag-back" {
        // Moving away and back to the start is still a drag.
        mouse(.leftMouseDragged, x: 140)
        mouse(.leftMouseDragged, x: 100)
    }
    system.focusedID = id
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: id, processIdentifier: 701))
    mouse(.leftMouseUp)
    if gesture == "click" {
        let confirmation = try #require(model.paneApplicationClickTask, "The fallback mouse-up schedules the confirmation")
        await manual.waitForSleepers(count: 1)
        manual.advance(by: .milliseconds(50))
        await confirmation.value
        #expect(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState?.pane(containing: id)?.id == right)
        #expect(!model.observesApplicationRequestMouseSequence)
    } else {
        #expect(model.paneApplicationClickTask == nil)
        model.advancePaneApplicationRequest()
        #expect(request.fallbackReason == .arrived)
        #expect(system.frameWriteCounts[id, default: 0] == 0)
        #expect(model.activeTabbedState?.pane(containing: id) == nil)
    }
}

// Unconfirmed arrivals keep the explicit click fallback after automatic placement.
@Test(.appTestApplication) @MainActor func paneLauncherRaisesOnlyTheArrivedWindowOnceForTheClick() async throws {
    let (system, model, launcher, right, clickClock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    clickClock.now = 1_000
    // The fake-window test must not depend on the desktop's frontmost application.
    model.applicationRequestFrontmost = { "com.example.Source" }
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let id = appendUnconfirmedPaneArrival(system, id: "raise-arrival")
    system.windowNumberMap = [id: 9001]
    let raisesBefore = system.raiseRequests.count
    try #require(await waitFor { request.fallbackReason == .arrived })
    model.advancePaneApplicationRequest() // Refresh the unconfirmed fallback's click candidates.
    model.advancePaneApplicationRequest()
    model.advancePaneApplicationRequest()
    // Tabbed's own stacking may raise its tabs; the arrived window is raised exactly once, without activation.
    let raised = system.raiseRequests.dropFirst(raisesBefore).filter { $0.0 == id }
    #expect(raised.count == 1)
    #expect(raised.allSatisfy { !$0.1 })
    #expect(request.revealedWindowID == id)
    #expect(system.frameWriteCounts[id, default: 0] == 0) // Raised, never moved or placed.
}

// Unconfirmed arrivals keep the explicit click fallback after automatic placement.
@Test(.appTestApplication) @MainActor func paneLauncherStopsWaitingForAClickAfterTheTimeout() async throws {
    let (system, model, launcher, right, clickClock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    clickClock.now = 1_000
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    model.paneApplicationClickTimeout = 0.3
    let clock = clickClock
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let id = appendUnconfirmedPaneArrival(system, id: "unclicked-arrival")
    try #require(await waitFor { request.fallbackReason == .arrived })
    model.advancePaneApplicationRequest() // Refresh the unconfirmed fallback's click candidates.
    #expect(request.clickDeadline != nil)
    #expect(model.paneApplicationRequest != nil, "The request waits until the click timeout passes")
    clock.now += model.paneApplicationClickTimeout
    #expect(await waitFor { model.paneApplicationRequest == nil })
    #expect(model.lastActionFeedback?.message == "Stopped waiting for a click")
    #expect(system.frameWriteCounts[id, default: 0] == 0)
    #expect(model.activeTabbedState?.pane(containing: id) == nil)
}

// Unconfirmed arrivals keep the explicit click fallback after automatic placement.
@Test(.appTestApplication) @MainActor func paneLauncherTimeoutWaitsForAClickInProgress() async throws {
    let (system, model, launcher, right, clickClock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    clickClock.now = 1_000
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    model.paneApplicationClickTimeout = 0.3
    model.paneApplicationClickConfirmDelay = .milliseconds(50)
    let uptime = clickClock
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let id = appendUnconfirmedPaneArrival(system, id: "late-click-arrival")
    try #require(await waitFor { request.fallbackReason == .arrived })
    model.advancePaneApplicationRequest() // Refresh the unconfirmed fallback's click candidates.
    request.windowAtPoint = { _ in system.windows.first { $0.id == id } }
    system.focusedID = id
    func mouse(_ kind: GlobalGestureEventKind) {
        model.receivePaneApplicationMouseEvent(GlobalGestureEvent(kind: kind, position: BTPoint(x: 100, y: 180), button: 0,
            modifiers: [], timestamp: uptime.timestamp))
    }
    mouse(.leftMouseDown)
    uptime.now += 0.5 // Past the timeout, with the button still down.
    model.advancePaneApplicationRequest()
    #expect(model.paneApplicationRequest?.id == request.id)
    mouse(.leftMouseUp)
    #expect(await waitFor { model.paneApplicationRequest == nil && !model.hasPendingTabbedPlacement })
    #expect(model.activeTabbedState?.pane(containing: id)?.id == right)
}

// Unconfirmed arrivals keep the explicit click fallback after automatic placement.
@Test(.appTestApplication) @MainActor func paneLauncherTimeoutIgnoresAClickThatLostItsMouseUp() async throws {
    let (system, model, launcher, right, clickClock) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    clickClock.now = 1_000
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    system.newWindowRequestResult = .requested
    model.paneApplicationClickTimeout = 0.2
    model.paneApplicationPendingClickLimit = 0.4
    let uptime = clickClock
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    let id = appendUnconfirmedPaneArrival(system, id: "lost-up-arrival")
    try #require(await waitFor { request.fallbackReason == .arrived })
    model.advancePaneApplicationRequest() // Refresh the unconfirmed fallback's click candidates.
    request.windowAtPoint = { _ in system.windows.first { $0.id == id } }
    system.focusedID = id
    model.receivePaneApplicationMouseEvent(GlobalGestureEvent(kind: .leftMouseDown, position: BTPoint(x: 100, y: 180),
        button: 0, modifiers: [], timestamp: uptime.timestamp))
    try #require(request.clickCandidate != nil)
    // Past the timeout but within the pending-click limit: the press still holds the request open.
    uptime.now += 0.3
    model.advancePaneApplicationRequest()
    #expect(model.paneApplicationRequest?.id == request.id)
    // Past the limit with no mouse-up: the request ends without placing the window.
    uptime.now += 0.2
    model.advancePaneApplicationRequest()
    #expect(model.paneApplicationRequest == nil)
    #expect(model.lastActionFeedback?.message == "Stopped waiting for a click")
    #expect(system.frameWriteCounts[id, default: 0] == 0)
}

@MainActor private func appendUnconfirmedPaneArrival(_ system: FakeAppWindowSystem, id: String) -> WindowID {
    let id = WindowID(rawValue: id)
    system.windows.append(WindowSnapshot(id: id, processIdentifier: 701, bundleIdentifier: paneTestApp.id,
        title: id.rawValue, frame: BTRect(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id))
    return id
}

/// Click timestamps come from the event tap's uptime clock, and pane deadlines compare them with the model's
/// clock. Tests move both by hand, so this is the one place that checks the real clocks share a time base.
/// The model reads before and after the tap clock, so the result cannot depend on load.
@Test(.appTestApplication) @MainActor func clickTimestampsAndThePaneClockShareOneTimeBase() {
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    let before = model.paneApplicationUptime()
    let stamp = Double(GestureEventClock.uptimeNanoseconds) / 1_000_000_000
    let after = model.paneApplicationUptime()
    #expect(stamp >= before - 0.001, "The tap clock is behind the model clock: \(stamp) < \(before)")
    #expect(stamp <= after + 0.001, "The tap clock is ahead of the model clock: \(stamp) > \(after)")
}

@Test(.appTestApplication, arguments: [false, true], [false, true]) @MainActor
func paneRequestArrivalSurvivesOtherSavedLayoutApplies(previousApply: Bool, cancelled: Bool) async throws {
    let (system, model, launcher, right) = try await paneLauncherFixture(native: true)
    defer { model.shutdown() }
    try await waitForWindowEventsToDrain(model)
    _ = PaneApplicationTestClock(model)
    let applier = try #require(model.savedLayoutApplier)
    applier.observesKeyboard = false
    applier.feedback = { _ in }
    applier.application = { _ in paneTestApp }


    let document = SavedLayoutDocument(name: "Other owner", mode: .tabbed, layout: .group("g"),
        slots: [.init(id: "slot", bundleID: paneTestApp.id)],
        groups: [.init(id: "g", slots: ["slot"], selected: "slot")])
    if previousApply { _ = await applier.apply(document) }
    let pane = model.activeTabbedState?.panes.first?.id ?? right
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: pane, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await waitForPaneMenuRequest(model)
    if cancelled { model.cancelPaneApplicationRequest() }
    let window = WindowSnapshot(id: .init(rawValue: "reserved-for-plus"), processIdentifier: 701,
        bundleIdentifier: paneTestApp.id, frame: .init(x: 80, y: 150, width: 320, height: 240), displayID: system.mainDisplay.id)
    system.windows.append(window)
    let space = system.desktopObservation!.currentSpace(on: system.mainDisplay.id)!
    system.desktopObservation?.windowMembership[window.id] = [space]
    _ = await applier.apply(document)
    #expect(system.windows.first { $0.id == window.id }?.frame == window.frame)
    // Saved Layout Apply may fill the slot from another eligible app. The reserved arrival stays untouched.
    #expect(system.frameWriteCounts[window.id, default: 0] == 0)
}

@Test(.appTestApplication, .timeLimit(.minutes(5))) @MainActor
func paneLauncherPollingUsesInjectedClock() async throws {
    let (system, model, launcher, right, uptime) = try await paneLauncherFixtureWithClock()
    defer { model.shutdown() }
    let manual = ManualClock()
    model.paneApplicationClock = manual.clock
    system.newWindowRequestResult = .requested
    launcher.instances[paneTestApp.id] = [.init(processIdentifier: 701, launchDate: nil)]
    let request = try #require(model.beginPaneApplicationPicker(paneID: right, on: system.mainDisplay.id))
    model.choosePaneApplication(paneTestApp, requestID: request.id)
    await model.paneApplicationLaunchTask?.value
    let poll = try #require(model.paneApplicationTask)
    await manual.waitForSleepers(count: 1)
    request.deadline = uptime.now
    manual.advance(by: .milliseconds(199))
    #expect(request.phase == .waiting)
    manual.advance(by: .milliseconds(1))
    await poll.value
    #expect(request.fallbackReason == .timedOut)
    #expect(!model.isPollingPaneApplicationRequest)
}
