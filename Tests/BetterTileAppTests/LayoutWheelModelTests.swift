import BetterTileCore
@testable import BetterTileMacOS
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor
final class FakeAppWindowSystem: BetterTileWindowSystem, TabbedWindowSystem, MinimumSizeProbing {
    let mainDisplay = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        isMain: true
    )
    var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy = .disableAndRestore
    var permission = true
    var ignoredFrameWriteWindowIDs: Set<WindowID> = []
    var enforcedMinimumWidths: [WindowID: Double] = [:]
    var enforcedMinimumHeights: [WindowID: Double] = [:]
    /// Measures minimums straight after each write and seeds new windows
    /// from their application, as the Accessibility adapter does.
    var measuresOnWrite = false
    /// Every frame BetterTile asked for, per window, in order.
    var requestedFrames: [WindowID: [BTRect]] = [:]
    /// Simulates an application that resizes in steps, such as Terminal's
    /// character cells: widths round down to a multiple of the step.
    var widthSteps: [WindowID: Double] = [:]
    /// Heights round up to a multiple of the step: an application, such as
    /// Terminal, that settles a row taller than asked.
    var heightSteps: [WindowID: Double] = [:]
    var frameWriteCounts: [WindowID: Int] = [:]
    var failedFrameWriteNumbers: [WindowID: Set<Int>] = [:]
    var completeSweepCount = 0
    var failedVisibleWindowSweeps: Set<Int> = []
    var onVisibleWindowSweep: ((Int) -> Void)?
    var cachedRefreshCount = 0
    var cachedRefreshRequests: [Set<WindowID>] = []
    var cachedSnapshotsAvailable = true
    var cachedRefreshFails = false
    var cachedVisibilityOmittedIDs: Set<WindowID> = []
    var offscreenWindowIDs: Set<WindowID> = []
    var emitsFrameEvents = false
    var desktopObservation: NativeDesktopObservation?
    var frameApplicationDelays: [WindowID: Duration] = [:]
    private var minimumSizeLearner = WindowMinimumSizeLearner()
    var availableDisplays: [DisplaySnapshot]
    var windows: [WindowSnapshot]
    var eventHandler: (@MainActor (WindowSystemEvent) -> Void)?

    init() {
        availableDisplays = [mainDisplay]
        windows = [WindowSnapshot(
            id: WindowID(rawValue: "focused"),
            processIdentifier: 42,
            bundleIdentifier: "com.example.Test",
            frame: BTRect(x: 200, y: 200, width: 600, height: 400),
            displayID: mainDisplay.id
        )]
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool { permission }
    var focusedID: WindowID?
    var focusRequests: [WindowID] = []
    var acceptsFocusRequests = true
    var raiseRequests: [(WindowID, Bool)] = []
    var failingNextRaiseWindowID: WindowID?
    /// Raises of these windows always fail.
    var failingRaiseWindowIDs: Set<WindowID> = []
    /// Like macOS, AXRaise on a window of the frontmost application makes it
    /// that application's key window.
    var raiseFocusesFrontmostApplicationWindow = false
    /// Simulates activation that makes the application's previous main
    /// window key instead of the requested one.
    var activationFocusesInstead: WindowID?
    var windowNumberRequests: [Set<WindowID>] = []
    func windowNumbers(for windows: [WindowSnapshot]) -> [WindowID: Int] {
        windowNumberRequests.append(Set(windows.map(\.id)))
        return [:] // Simulate unavailable exact identities without live AX.
    }
    /// WindowServer order, front to back. Nil simulates unavailable exact
    /// identities. Raises move a window to the front, as AXRaise does.
    var stack: [TabbedStackEntry]?
    var updatesStackOnRaise = true
    func stackingOrder(for windows: [WindowSnapshot], excluding windowNumbers: Set<Int>) -> [TabbedStackEntry]? { stack }
    /// Simulates BetterTile or an unreadable app in front; otherwise the
    /// focused window's app is frontmost.
    var frontmostOverride: Int32?
    var frontmostProcessIdentifier: Int32? {
        frontmostOverride ?? (windows.first { $0.id == focusedID } ?? windows.first)?.processIdentifier
    }
    /// Simulates an application whose focused window, such as a small
    /// popup, `focusedWindow()` cannot report, so it reports another window.
    var focusedWindowIsFallback = false
    /// Simulates an application that reports no focused window.
    var focusedWindowIsUnknown = false
    /// Popups that close when they lose focus, such as browser bubbles.
    var transientPopupIDs: Set<WindowID> = []
    func isTransientPopup(_ window: WindowSnapshot) -> Bool { transientPopupIDs.contains(window.id) }
    func applicationFocus(of window: WindowSnapshot) -> ApplicationFocusMatch {
        if focusedWindowIsUnknown { return .unknown }
        guard !focusedWindowIsFallback else { return .contradicted }
        return window.id == (windows.first { $0.id == focusedID } ?? windows.first)?.id ? .confirmed : .contradicted
    }
    func raiseWindow(_ id: WindowID, activate: Bool) throws {
        if failingNextRaiseWindowID == id || failingRaiseWindowIDs.contains(id) {
            if failingNextRaiseWindowID == id { failingNextRaiseWindowID = nil }
            throw WindowSystemError.operationFailed("Injected window ordering failure.")
        }
        raiseRequests.append((id, activate))
        if activate {
            if let other = activationFocusesInstead {
                activationFocusesInstead = nil
                focusedID = other
            } else if acceptsFocusRequests { focusedID = id }
            focusRequests.append(id)
        } else if raiseFocusesFrontmostApplicationWindow,
                  let process = windows.first(where: { $0.id == id })?.processIdentifier,
                  process == frontmostProcessIdentifier {
            focusedID = id
        }
        if updatesStackOnRaise, let index = stack?.firstIndex(where: { $0.windowID == id }), let entry = stack?.remove(at: index) {
            stack?.insert(entry, at: 0)
        }
    }
    func requestCloseWindow(_ id: WindowID) throws {}
    var focusedWindowReadFails = false
    func focusedWindow() throws -> WindowSnapshot? {
        if focusedWindowReadFails { throw WindowSystemError.operationFailed("Simulated focused-window failure") }
        return windows.first { $0.id == focusedID } ?? windows.first
    }
    func visibleWindows() throws -> [WindowSnapshot] {
        completeSweepCount += 1
        onVisibleWindowSweep?(completeSweepCount)
        if failedVisibleWindowSweeps.contains(completeSweepCount) {
            throw WindowSystemError.operationFailed("Injected visible-window observation failure.")
        }
        refreshLearnedConstraints()
        return windows.filter { !offscreenWindowIDs.contains($0.id) }
    }
    func displays() -> [DisplaySnapshot] { availableDisplays }
    /// Windows that targeted reads leave out once they took this many frame
    /// writes, as for an application that stops answering after a write.
    var unreadableAfterWrites: [WindowID: Int] = [:]
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        refreshLearnedConstraints()
        return windows.filter { window in
            ids.contains(window.id)
                && unreadableAfterWrites[window.id].map { frameWriteCounts[window.id, default: 0] < $0 } ?? true
        }
    }
    private func refreshLearnedConstraints() {
        for index in windows.indices {
            let id = windows[index].id
            minimumSizeLearner.observeAcceptedSize(windowID: id, size: windows[index].frame.size)
            if measuresOnWrite {
                if reportedConstraints[id] == nil { reportedConstraints[id] = windows[index].constraints }
                windows[index].constraints = minimumSizeLearner.merging(
                    reportedConstraints[id]!, for: id, application: windows[index].bundleIdentifier
                )
            } else if let reported = reportedConstraints[id] {
                windows[index].constraints = minimumSizeLearner.merging(reported, for: id)
            }
        }
    }
    func cachedVisibleWindows(refreshing ids: Set<WindowID>) throws -> [WindowSnapshot]? {
        cachedRefreshCount += 1
        cachedRefreshRequests.append(ids)
        if cachedRefreshFails {
            throw WindowSystemError.operationFailed("Injected cached visibility failure.")
        }
        guard cachedSnapshotsAvailable else { return nil }
        let refreshed = try windowSnapshots(ids: ids)
        guard Set(refreshed.map(\.id)) == ids, ids.isDisjoint(with: offscreenWindowIDs) else { return nil }
        return windows.filter { !offscreenWindowIDs.contains($0.id) && !cachedVisibilityOmittedIDs.contains($0.id) }
    }
    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        frameWriteCounts[windowID, default: 0] += 1
        requestedFrames[windowID, default: []].append(frame)
        if failedFrameWriteNumbers[windowID]?.contains(frameWriteCounts[windowID, default: 0]) == true {
            throw WindowSystemError.operationFailed("Injected frame write failure.")
        }
        guard !ignoredFrameWriteWindowIDs.contains(windowID) else { return }
        if let delay = frameApplicationDelays[windowID] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                self?.applyFrame(frame, at: index)
            }
            return
        }
        applyFrame(frame, at: index)
    }
    private func applyFrame(_ frame: BTRect, at index: Int) {
        let windowID = windows[index].id
        let before = windows[index].frame
        defer {
            // Like the Accessibility adapter, read the size straight back.
            if measuresOnWrite {
                if reportedConstraints[windowID] == nil { reportedConstraints[windowID] = windows[index].constraints }
                minimumSizeLearner.observeWriteReadback(
                    windowID: windowID, application: windows[index].bundleIdentifier,
                    requested: frame, previous: before, actual: windows[index].frame
                )
                refreshLearnedConstraints()
            }
        }
        windows[index].frame = frame
        windows[index].frame.size.width = max(frame.size.width, enforcedMinimumWidths[windowID] ?? 0)
        windows[index].frame.size.height = max(frame.size.height, enforcedMinimumHeights[windowID] ?? 0)
        if let step = widthSteps[windowID] {
            windows[index].frame.size.width = (windows[index].frame.size.width / step).rounded(.down) * step
        }
        if let step = heightSteps[windowID] {
            windows[index].frame.size.height = (windows[index].frame.size.height / step).rounded(.up) * step
        }
        // Like the Accessibility adapter, a window belongs to the display
        // that holds most of it.
        let applied = windows[index].frame
        windows[index].displayID = availableDisplays.first {
            ($0.visibleFrame.intersection(applied)?.area ?? 0) > applied.area / 2
        }?.id ?? windows[index].displayID
        if emitsFrameEvents {
            eventHandler?(WindowSystemEvent(kind: .resized, windowID: windowID, processIdentifier: windows[index].processIdentifier))
        }
    }
    /// Windows whose application restores them later than the request.
    var slowRestoreIDs: Set<WindowID> = []
    var failedRestoreWindowIDs: Set<WindowID> = []
    var restoreRequests: [WindowID] = []
    var emitsMinimizationEvents = false
    func setMinimized(_ minimized: Bool, for windowID: WindowID) throws {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        if !minimized {
            restoreRequests.append(windowID)
            if failedRestoreWindowIDs.contains(windowID) {
                throw WindowSystemError.operationFailed("Injected restore failure.")
            }
            if slowRestoreIDs.contains(windowID) { return }
        }
        windows[index].isMinimized = minimized
        if emitsMinimizationEvents {
            let event = WindowSystemEvent(kind: minimized ? .minimized : .restored,
                                          windowID: windowID, processIdentifier: windows[index].processIdentifier)
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.eventHandler?(event)
            }
        }
    }

    func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?) {
        eventHandler = handler
    }
    func startWindowObservation() {}
    func stopWindowObservation() {}
    func refreshApplicationObservers() {}
    func resetCachedWindows() {}
    var quitRestoreCount = 0
    func restoreEnhancedUserInterfaceBeforeQuit() { quitRestoreCount += 1 }
    func nativeDesktopObservation() -> NativeDesktopObservation? { desktopObservation }
    func refreshNativeDesktopObservation() -> NativeDesktopObservation? { desktopObservation }
    func observeApplicationEnforcedMinimum(
        windowID: WindowID,
        requested: BTRect,
        baseline: BTRect,
        actual: BTRect
    ) -> Bool {
        let learned = minimumSizeLearner.observe(
            windowID: windowID, requested: requested, baseline: baseline, actual: actual
        )
        if let index = windows.firstIndex(where: { $0.id == windowID }) {
            if reportedConstraints[windowID] == nil { reportedConstraints[windowID] = windows[index].constraints }
            windows[index].constraints = minimumSizeLearner.merging(windows[index].constraints, for: windowID)
        }
        return learned
    }
    var reportedConstraints: [WindowID: WindowConstraints] = [:]
    var probeRequests: [Set<WindowID>] = []
    /// Windows whose application clamps a size only after a delay, so the
    /// probe's immediate read-back measures nothing.
    var unprobeableWindowIDs: Set<WindowID> = []
    func probeMinimumSizes(for ids: Set<WindowID>) -> Set<WindowID> {
        probeRequests.append(ids)
        guard measuresOnWrite else { return [] }
        for id in ids where !unprobeableWindowIDs.contains(id) {
            guard let index = windows.firstIndex(where: { $0.id == id }) else { continue }
            let frame = windows[index].frame
            let tiny = BTRect(x: frame.minX, y: frame.minY, width: 1, height: 1)
            let clamped = BTRect(x: frame.minX, y: frame.minY,
                                 width: max(1, enforcedMinimumWidths[id] ?? 1),
                                 height: max(1, enforcedMinimumHeights[id] ?? 1))
            if reportedConstraints[id] == nil { reportedConstraints[id] = windows[index].constraints }
            minimumSizeLearner.observeWriteReadback(
                windowID: id, application: windows[index].bundleIdentifier,
                requested: tiny, previous: frame, actual: clamped
            )
        }
        refreshLearnedConstraints()
        // A window left at its probe size.
        let unrestored = unrestoredProbeWindowIDs.intersection(ids)
        for index in windows.indices where unrestored.contains(windows[index].id) {
            windows[index].frame.size = BTSize(width: 1, height: 1)
        }
        return unrestored
    }
    var unrestoredProbeWindowIDs: Set<WindowID> = []
    func startDockFootprintMonitoring(onChange: @escaping () -> Void) {}
    func stopDockFootprintMonitoring() {}
    func triggerDockFootprintCheck() {}
    func startDisplayReconfigurationMonitoring(onChange: @escaping @MainActor () -> Void) {}
    func stopDisplayReconfigurationMonitoring() {}
    func updateManagedWindowIDs(_ ids: Set<WindowID>) {}
}

@MainActor
func makeModel(system: FakeAppWindowSystem) -> BetterTileModel {
    let store = ConfigurationStore(
        fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json")
    )
    let model = BetterTileModel(store: store, system: system, startRuntime: false)
    // Fake-window tests own button state; physical input must not defer work.
    model.primaryButtonIsPressed = { false }
    return model
}

/// A window can arrive with a Space switch, for example dragged there in
/// Mission Control. The switch sweep keeps the stored layout; a follow-up
/// sweep tiles the new window once the switch settles.
@Test @MainActor func aWindowThatArrivesWithASpaceSwitchIsTiled() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let firstSpace = NativeSpaceID(rawValue: 1)
    let secondSpace = NativeSpaceID(rawValue: 2)
    let displayID = system.mainDisplay.id
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 400, height: 300), displayID: displayID
    ))
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [displayID: firstSpace],
        knownSpacesByDisplay: [displayID: [firstSpace, secondSpace]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [firstSpace]) })
    )
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    try await Task.sleep(for: .milliseconds(300))
    let tiled = system.windows
    model.installWorkspaceTriggers()

    system.desktopObservation?.currentSpaceByDisplay[displayID] = secondSpace
    system.windows = []
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(200))

    // The user comes back with a window dragged onto this Space.
    let arrival = WindowSnapshot(id: WindowID(rawValue: "arrival"), processIdentifier: 44,
        frame: BTRect(x: 300, y: 200, width: 300, height: 200), displayID: displayID)
    system.desktopObservation?.windowMembership[arrival.id] = [firstSpace]
    system.desktopObservation?.currentSpaceByDisplay[displayID] = firstSpace
    system.windows = tiled + [arrival]
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    #expect(await waitFor(timeout: .seconds(2)) {
        system.windows.first { $0.id == arrival.id }?.frame != arrival.frame
            && Set(system.windows.map(\.frame)).count == 3
    })
}

@Test(arguments: [0, 4]) @MainActor
func returningToBentoSpaceWithPartialVisibilityDoesNotMoveItsWindows(extraIncompleteSweeps: Int) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let firstSpace = NativeSpaceID(rawValue: 1)
    let secondSpace = NativeSpaceID(rawValue: 2)
    let displayID = system.mainDisplay.id
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: displayID
    ))
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [displayID: firstSpace],
        knownSpacesByDisplay: [displayID: [firstSpace, secondSpace]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [firstSpace]) })
    )
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = .maximize
    model.tileCurrentDisplay()
    try #require(await waitFor { system.cachedRefreshCount >= 2 })
    let firstWindows = system.windows
    model.installWorkspaceTriggers()

    system.desktopObservation?.currentSpaceByDisplay[displayID] = secondSpace
    system.windows = []
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(200))

    // macOS can expose one window before its peers during the transition.
    system.desktopObservation?.currentSpaceByDisplay[displayID] = firstSpace
    system.windows = [firstWindows[0]]
    let writes = system.frameWriteCounts
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.windows[0].frame == firstWindows[0].frame)
    #expect(system.frameWriteCounts == writes)

    for _ in 0..<extraIncompleteSweeps {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: firstWindows[0].id, processIdentifier: 42))
        try await Task.sleep(for: .milliseconds(180))
        #expect(system.frameWriteCounts == writes)
        #expect(system.windows[0].frame == firstWindows[0].frame)
    }

    system.windows.append(firstWindows[1])
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: firstWindows[1].id, processIdentifier: 43))
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.windows.map(\.frame) == firstWindows.map(\.frame))
    #expect(system.frameWriteCounts == writes)

    // Late AX events from the switch read the current frames. They must not
    // reinterpret unchanged left/right panes as a new snap or divider move.
    for window in firstWindows {
        system.eventHandler?(WindowSystemEvent(kind: .resized, windowID: window.id, processIdentifier: window.processIdentifier))
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.windows.map(\.frame) == firstWindows.map(\.frame))
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: [false, true]) @MainActor
func bentoPlacementContainsAnUnreportedApplicationMinimum(automaticArrival: Bool) async {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    if automaticArrival { model.setActiveMode(.bento) }
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    system.enforcedMinimumWidths[peerID] = 600
    system.emitsFrameEvents = true
    if automaticArrival {
        system.eventHandler?(WindowSystemEvent(kind: .created, windowID: peerID, processIdentifier: 43))
    } else {
        model.tileCurrentDisplay()
    }

    let contained = await waitFor {
        let frames = system.windows.map(\.frame)
        return frames.allSatisfy { PlacementBounds.isContained($0, in: system.mainDisplay.visibleFrame) }
            && frames[0].intersection(frames[1]) == nil
    }
    #expect(contained, "Bento must adapt to the app's minimum without leaving it past the display or its neighbor.")
    #expect(system.frameWriteCounts[peerID, default: 0] <= 2)
    let settledFrames = system.windows.map(\.frame)
    try? await Task.sleep(for: .milliseconds(400))
    #expect(system.windows.map(\.frame) == settledFrames)
    #expect(system.frameWriteCounts[peerID, default: 0] <= 2)
}

@Test @MainActor func bentoRepairWaitsForADelayedAppWithoutLearningItsOldSize() async {
    let system = FakeAppWindowSystem()
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    system.frameApplicationDelays[peerID] = .milliseconds(200)
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tileCurrentDisplay()
    let settled = await waitFor {
        abs(system.windows[0].frame.size.width - system.windows[1].frame.size.width) < 1
    }
    #expect(settled)
    #expect(system.windows[1].constraints.minimumSize.width == 120)
    #expect(system.frameWriteCounts[peerID, default: 0] <= 2)
}

@Test(arguments: [true, false]) @MainActor
func snappedBentoLayoutDoesNotResizeAgainAfterItLands(cachedSnapshotsAvailable: Bool) async {
    let system = FakeAppWindowSystem()
    system.cachedSnapshotsAvailable = cachedSnapshotsAvailable
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 6
    model.tileCurrentDisplay()
    model.performLayoutWheel(.windowAction(.rightHalf), for: target(for: system))
    let landedFrames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    let sweeps = system.completeSweepCount
    try? await Task.sleep(for: .milliseconds(500))
    #expect(system.windows.map(\.frame) == landedFrames)
    #expect(system.frameWriteCounts == writes)
    if cachedSnapshotsAvailable {
        #expect(system.completeSweepCount - sweeps <= 2)
    }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func settledWorkAreaChangeDoesNotReapplyOnLaterSweeps(learnMinimum: Bool, delayed: Bool) async throws {
    let system = FakeAppWindowSystem()
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    @MainActor func finishSettlement() async throws {
        // Sampling can replace itself with one authoritative verification task.
        for _ in 0..<2 {
            guard let task = model.settlementTasks[system.mainDisplay.id] else { break }
            await task.value
        }
        try #require(model.settlementTasks[system.mainDisplay.id] == nil)
    }
    model.tileCurrentDisplay()
    try await finishSettlement()
    try #require(system.cachedRefreshCount >= 2)

    // A topology event drives the same ambient reconciliation used for a Dock
    // or display change, without installing live workspace observers.
    let refresh = WindowSystemEvent(kind: .created, windowID: peerID, processIdentifier: 43)
    system.availableDisplays[0].visibleFrame.size.width = 800
    system.availableDisplays[0].visibleFrame.size.height = 700
    if learnMinimum { system.enforcedMinimumWidths[peerID] = 450 }
    if delayed { system.frameApplicationDelays[peerID] = .milliseconds(200) }
    let samples = system.cachedRefreshCount
    system.eventHandler?(refresh)
    let reflow = try #require(model.windowEventTask)
    await reflow.value
    try await finishSettlement()
    #expect(system.cachedRefreshCount >= samples + 2)
    #expect(system.windows[0].frame.intersection(system.windows[1].frame) == nil)
    #expect(system.windows[1].constraints.minimumSize.width == (learnMinimum ? 450 : 120))
    let settledFrames = system.windows.map(\.frame)
    #expect(settledFrames.allSatisfy {
        PlacementBounds.isContained($0, in: system.availableDisplays[0].visibleFrame)
    })
    let writes = system.frameWriteCounts
    let settledSamples = system.cachedRefreshCount

    for _ in 0..<3 {
        let sweeps = system.completeSweepCount
        system.eventHandler?(refresh)
        let sweep = try #require(model.windowEventTask)
        await sweep.value
        try await finishSettlement()
        #expect(system.completeSweepCount > sweeps)
        #expect(system.frameWriteCounts == writes, "A settled work-area change must not apply the layout again.")
    }
    #expect(system.cachedRefreshCount == settledSamples, "Later sweeps must not restart settlement.")
    #expect(system.windows.map(\.frame) == settledFrames)
}

@Test @MainActor func failedWorkAreaSettlementCanRetryOnALaterSweep() async throws {
    let system = FakeAppWindowSystem()
    let peerID = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(
        id: peerID, processIdentifier: 43,
        frame: BTRect(x: 200, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id
    ))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.tileCurrentDisplay()
    try #require(await waitFor { system.cachedRefreshCount >= 2 })

    let refresh = WindowSystemEvent(kind: .created, windowID: peerID, processIdentifier: 43)
    system.availableDisplays[0].visibleFrame.size.height = 700
    system.ignoredFrameWriteWindowIDs.insert(peerID)
    system.eventHandler?(refresh)
    try #require(await waitFor {
        model.statusMessage == "One or more windows did not settle at the requested frame."
    })
    #expect(!PlacementBounds.isContained(system.windows[1].frame, in: system.availableDisplays[0].visibleFrame))

    // A failed settlement must leave the work-area change pending so a later
    // sweep can retry when the app starts accepting frame writes again.
    system.ignoredFrameWriteWindowIDs.remove(peerID)
    let samples = system.cachedRefreshCount
    system.eventHandler?(refresh)
    try #require(await waitFor { system.cachedRefreshCount >= samples + 2 })
    #expect(system.windows.allSatisfy {
        PlacementBounds.isContained($0.frame, in: system.availableDisplays[0].visibleFrame)
    })
    let writes = system.frameWriteCounts
    let sweeps = system.completeSweepCount
    system.eventHandler?(refresh)
    try #require(await waitFor { system.completeSweepCount > sweeps })
    #expect(system.frameWriteCounts == writes)
}

@MainActor
private func target(for system: FakeAppWindowSystem) -> LayoutWheelTarget {
    LayoutWheelTarget(
        windowID: system.windows[0].id,
        displayID: system.windows[0].displayID,
        visibleFrame: system.mainDisplay.visibleFrame
    )
}

/// Waits for a state the model reaches from its delayed verification task.
///
/// A fixed sleep cannot express this wait. The check makes three attempts
/// 120ms apart and each one hops back to the main actor, so its total is set
/// by how loaded the machine is, not by a constant the test can pick. Polling
/// finishes as soon as the state arrives and only spends the timeout when the
/// state never arrives at all.
@MainActor
/// Polls in 20 ms steps. The budget counts steps, not wall-clock time: a
/// loaded test machine can block the main actor for seconds, and the work
/// being waited for needs its turn after such a block too.
func waitFor(
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async -> Bool {
    let step = Duration.milliseconds(20)
    for _ in 0..<Int((timeout / step).rounded(.up)) {
        if condition() { return true }
        try? await Task.sleep(for: step)
    }
    return condition()
}

@Test @MainActor func waitForRetainsPollingStepsWhenMainActorIsBlocked() async {
    var polls = 0
    let reached = await waitFor(timeout: .milliseconds(40)) {
        polls += 1
        if polls == 1 { Thread.sleep(forTimeInterval: 0.1) }
        return polls == 3
    }
    #expect(reached)
    #expect(polls == 3)
}

@Test @MainActor func waitForStopsAfterItsPollingBudgetWhenStateNeverArrives() async {
    var polls = 0
    let reached = await waitFor(timeout: .milliseconds(40)) {
        polls += 1
        return false
    }
    #expect(!reached)
    #expect(polls == 3)
}

@Test @MainActor func manualLayoutWheelPreviewIsPureAndMatchesCommit() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let baseline = system.windows[0].frame

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.leftHalf),
        for: captured
    ) else {
        Issue.record("Expected a Manual Layout Wheel preview")
        return
    }

    #expect(system.windows[0].frame == baseline)
    #expect(placements.count == 1)
    model.performLayoutWheel(.windowAction(.leftHalf), for: captured)
    #expect(system.windows[0].frame == placements[0].frame)
}

@Test @MainActor func movingTheCapturedWindowToAnotherDisplayCancelsTheCommand() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let second = DisplaySnapshot(
        id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)
    )
    system.availableDisplays.append(second)
    system.windows[0].displayID = second.id

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .windowAction(.leftHalf),
        for: captured
    ) else {
        Issue.record("Expected the captured-display change to cancel")
        return
    }

    #expect(reason.contains("window or display"))
}

@Test @MainActor func ignoredApplicationFailsBeforeLayoutWheelMutation() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let baseline = system.windows[0].frame
    model.updateConfiguration {
        $0.applicationRules.set(.ignoreEverywhere, for: "com.example.Test")
    }

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .windowAction(.maximize),
        for: captured
    ) else {
        Issue.record("Expected the application rule to reject the command")
        return
    }

    #expect(reason == "BetterTile is set to ignore this app.")
    #expect(system.windows[0].frame == baseline)
}

@Test @MainActor func bentoLayoutWheelPreviewDoesNotCommitItsProposal() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let captured = target(for: system)
    let baseline = system.windows[0].frame

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.rightHalf),
        for: captured
    ) else {
        Issue.record("Expected a Bento Layout Wheel preview")
        return
    }

    #expect(!placements.isEmpty)
    #expect(system.windows[0].frame == baseline)
    model.performLayoutWheel(.windowAction(.rightHalf), for: captured)
    #expect(system.windows[0].frame == placements.first(where: {
        $0.windowID == captured.windowID
    })?.frame)
}

@Test @MainActor func bentoLayoutWheelFocusActionMatchesKeyboardPolicy() throws {
    let system = FakeAppWindowSystem()
    let peer = WindowSnapshot(
        id: WindowID(rawValue: "peer"),
        processIdentifier: 43,
        bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300),
        displayID: system.mainDisplay.id
    )
    system.windows.append(peer)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let captured = target(for: system)
    let peerBaseline = try #require(system.windows.first(where: { $0.id == peer.id }))

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.maximize),
        for: captured
    ) else {
        Issue.record("Expected a Layout Wheel focus-action preview")
        return
    }

    #expect(placements.map(\.windowID) == [captured.windowID])
    // Focus mode: the window covers the display and its peer is minimized
    // in the same action, exactly as the keyboard shortcut does.
    model.performLayoutWheel(.windowAction(.maximize), for: captured)
    #expect(system.windows.first(where: { $0.id == peer.id })?.isMinimized == true)
    #expect(!peerBaseline.isMinimized)
}

/// Keyboard Maximize on a Bento desktop enters Focus mode at once, and a
/// later sweep does not repeat it. Restore ends it and returns the layout.
@Test @MainActor func bentoMaximizeEntersFocusModeAndRestoreReturnsTheLayout() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    let tiled = system.windows.map(\.frame)
    system.focusedID = system.windows[0].id

    model.perform(.maximize)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
    #expect(system.windows[1].isMinimized)
    #expect(model.lastActionFeedback?.message.hasPrefix("Focus mode · ") == true)
    try await Task.sleep(for: .milliseconds(400)) // Later sweeps leave Focus mode alone.
    #expect(system.windows[1].isMinimized)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)

    model.perform(.restore)
    #expect(!system.windows[1].isMinimized)
    #expect(await waitFor { system.windows.map(\.frame) == tiled })

    // Repair during Focus mode also brings the peers back.
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    model.tileCurrentDisplay()
    #expect(!system.windows[1].isMinimized)
    #expect(await waitFor { system.windows.map(\.frame) == tiled })
}

@Test(arguments: [false, true]) @MainActor
func restoringAFocusModePeerFromTheDockWaitsForTheOtherPeers(rejectLayout: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for name in ["dock-peer", "slow-peer"] {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 43,
            bundleIdentifier: "com.example.Peer", frame: BTRect(x: 0, y: 0, width: 200, height: 300),
            displayID: system.mainDisplay.id))
    }
    system.emitsMinimizationEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.frameWriteCounts.count == system.windows.count })
    try await Task.sleep(for: .milliseconds(350))
    system.focusedID = system.windows[0].id
    model.perform(.leftTwoThirds)
    try await Task.sleep(for: .milliseconds(350))
    try #require(system.windows[0].frame.size.width > 600)
    let tiled = system.windows.map(\.frame)
    let focusedID = system.windows[0].id
    let dockPeer = system.windows[1].id
    let slowPeer = system.windows[2].id
    system.focusedID = focusedID
    model.perform(.maximize)
    try #require(system.windows.dropFirst().allSatisfy { $0.isMinimized })
    try await Task.sleep(for: .milliseconds(350))
    system.slowRestoreIDs = [slowPeer]
    system.focusedID = dockPeer
    try system.setMinimized(false, for: dockPeer)
    try #require(await waitFor { system.restoreRequests.contains(slowPeer) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.windows[2].isMinimized)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
    if rejectLayout {
        system.failedFrameWriteNumbers[focusedID] = [system.frameWriteCounts[focusedID, default: 0] + 1]
    }
    system.slowRestoreIDs = []
    try system.setMinimized(false, for: slowPeer)

    if rejectLayout {
        try #require(await waitFor { model.statusMessage?.contains("Use Repair") == true })
        #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
        let writes = system.frameWriteCounts
        try await Task.sleep(for: .milliseconds(350))
        #expect(system.frameWriteCounts == writes)
    } else {
        #expect(await waitFor { system.windows.map(\.frame) == tiled })
        #expect(system.windows.allSatisfy { !$0.isMinimized })
        system.focusedID = focusedID
        model.perform(.maximize)
        model.perform(.restore)
        #expect(await waitFor { system.windows.map(\.frame) == tiled })
    }
}

/// Repair during Focus mode brings the peers back first. It reports only
/// after the restored layout is verified, never while a peer is still
/// returning. A peer seen back on screen counts even when its restored
/// notification arrives late.
@Test(arguments: [true, false]) @MainActor
func repairDuringFocusModeReportsOnlyAfterThePeersReturn(restoredEventArrives: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    system.emitsMinimizationEvents = restoredEventArrives
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    try await Task.sleep(for: .milliseconds(350))
    let tiled = system.windows.map(\.frame)
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    try await Task.sleep(for: .milliseconds(350))
    let focusFeedback = model.lastActionFeedback

    if !restoredEventArrives {
        // Accessibility notifications lag: the minimize evidence is still
        // fresh, and the restored notification never arrives in time.
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: peer, processIdentifier: 43))
    }
    system.slowRestoreIDs = [peer]
    model.tileCurrentDisplay()
    try #require(system.restoreRequests.contains(peer))
    // Stay well inside the 1.5 s peer wait, even on a loaded runner.
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.lastActionFeedback == focusFeedback, "\(String(describing: model.lastActionFeedback))")
    system.slowRestoreIDs = []
    try system.setMinimized(false, for: peer)
    #expect(await waitFor(timeout: .seconds(2)) {
        model.lastActionFeedback != focusFeedback && model.lastActionFeedback?.kind == .success
            && system.windows.map(\.frame) == tiled
    }, "\(String(describing: model.lastActionFeedback)) \(system.windows.map(\.frame))")
}

/// Each display waits for its own Focus mode peers. Entering Focus mode on
/// another display while the first display's peers are still returning
/// must not cancel the first display's pending command.
@Test @MainActor func focusModeOnAnotherDisplayDoesNotCancelAPendingPartition() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let second = DisplaySnapshot(id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
    system.availableDisplays.append(second)
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    for name in ["b1", "b2"] {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 44,
            bundleIdentifier: "com.example.Second", frame: BTRect(x: 1000, y: 0, width: 300, height: 300),
            displayID: second.id))
    }
    system.emitsMinimizationEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.updateConfiguration { $0.defaultLayoutMode = .bento }
    model.setActiveMode(.bento)
    let onSecond = { system.windows.filter { $0.displayID == second.id } }
    try #require(await waitFor(timeout: .seconds(2)) {
        model.activeMode(for: second.id) == .bento && onSecond().allSatisfy { $0.frame.size.width < 1000 }
            && system.windows[0].frame.size.width < 1000
    }, "\(system.windows.map(\.frame))")
    try await Task.sleep(for: .milliseconds(350))
    let focused = system.windows[0].id
    system.focusedID = focused
    model.perform(.maximize)
    try #require(system.windows.first { $0.id == peer }?.isMinimized == true)
    try await Task.sleep(for: .milliseconds(350))

    // Right Half ends Focus mode and waits for the slow peer.
    system.slowRestoreIDs = [peer]
    model.perform(.rightHalf)
    try #require(system.restoreRequests.contains(peer))
    // Focus mode on the second display while the first one's peer is still returning.
    system.focusedID = WindowID(rawValue: "b1")
    model.perform(.maximize)
    try #require(system.windows.first { $0.id == WindowID(rawValue: "b2") }?.isMinimized == true)
    system.slowRestoreIDs = []
    try system.setMinimized(false, for: peer)

    #expect(await waitFor(timeout: .seconds(2)) {
        let frame = system.windows[0].frame
        return frame.minX > 400 && frame.size.width < 600
    }, "\(system.windows.map(\.frame))")
}

/// A covered peer can close while Focus mode keeps it minimized. Ending
/// Focus mode then lays out the remaining windows without its pane.
@Test @MainActor func endingFocusModeAfterAPeerClosedFillsTheDisplay() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for name in ["kept-peer", "closed-peer"] {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 43,
            bundleIdentifier: "com.example.Peer", frame: BTRect(x: 0, y: 0, width: 200, height: 300),
            displayID: system.mainDisplay.id))
    }
    system.emitsMinimizationEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.frameWriteCounts.count == system.windows.count })
    try await Task.sleep(for: .milliseconds(350))
    let focused = system.windows[0].id
    system.focusedID = focused
    model.perform(.maximize)
    try #require(system.windows.dropFirst().allSatisfy { $0.isMinimized })
    try await Task.sleep(for: .milliseconds(350))

    let closed = WindowID(rawValue: "closed-peer")
    system.windows.removeAll { $0.id == closed }
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: closed, processIdentifier: 43))
    try await Task.sleep(for: .milliseconds(300))
    let writesBefore = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, system.requestedFrames[$0.id]?.count ?? 0) })
    system.focusedID = focused
    model.perform(.restore)

    try #require(await waitFor(timeout: .seconds(3)) {
        system.windows.allSatisfy { !$0.isMinimized }
            && system.windows.allSatisfy { (system.requestedFrames[$0.id]?.count ?? 0) > writesBefore[$0.id]! }
    }, "\(system.windows.map(\.frame))")
    // The first layout after the restore already covers the display.
    let firstFrames = system.windows.map { system.requestedFrames[$0.id]![writesBefore[$0.id]!] }
    let covered = firstFrames.map { $0.size.width * $0.size.height }.reduce(0, +)
    let display = system.mainDisplay.visibleFrame
    #expect(covered >= display.size.width * display.size.height * 0.98, "\(firstFrames)")
}

/// Closing the Focus mode window leaves its peers minimized. Restoring one
/// from the Dock must lay the peers out without the closed window's pane,
/// not leave its area empty until a later sweep notices the window is gone.
@Test @MainActor func restoringAPeerAfterClosingTheFocusModeWindowFillsTheDisplay() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for name in ["dock-peer", "other-peer"] {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 43,
            bundleIdentifier: "com.example.Peer", frame: BTRect(x: 0, y: 0, width: 200, height: 300),
            displayID: system.mainDisplay.id))
    }
    system.emitsMinimizationEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.frameWriteCounts.count == system.windows.count })
    try await Task.sleep(for: .milliseconds(350))
    let focused = system.windows[0]
    system.focusedID = focused.id
    model.perform(.maximize)
    try #require(system.windows.dropFirst().allSatisfy { $0.isMinimized })
    try await Task.sleep(for: .milliseconds(350))

    system.windows.removeFirst()
    system.focusedID = nil
    system.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: focused.id,
                                          processIdentifier: focused.processIdentifier))
    try await Task.sleep(for: .milliseconds(400))
    let peers = system.windows.map(\.id)
    let writesBefore = Dictionary(uniqueKeysWithValues: peers.map { ($0, system.requestedFrames[$0]?.count ?? 0) })
    system.focusedID = peers[0]
    try system.setMinimized(false, for: peers[0])

    try #require(await waitFor(timeout: .seconds(3)) {
        system.windows.allSatisfy { !$0.isMinimized }
            && peers.allSatisfy { (system.requestedFrames[$0]?.count ?? 0) > writesBefore[$0]! }
    })
    // The first layout after the peers return already covers the display.
    let firstFrames = peers.map { system.requestedFrames[$0]![writesBefore[$0]!] }
    let covered = firstFrames.map { $0.size.width * $0.size.height }.reduce(0, +)
    let display = system.mainDisplay.visibleFrame
    #expect(covered >= display.size.width * display.size.height * 0.98, "\(firstFrames)")
}

/// A Focus mode peer that fails to restore stays minimized. The others
/// return and fill the display; it rejoins its place in the grid later.
@Test(arguments: [false, true]) @MainActor
func aFocusModeRestoreReturnsAvailablePeersAfterARestoreFailure(fromDock: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for name in ["dock-peer", "failed-peer"] {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: 43,
            bundleIdentifier: "com.example.Peer", frame: BTRect(x: 0, y: 0, width: 200, height: 300),
            displayID: system.mainDisplay.id))
    }
    system.emitsMinimizationEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.frameWriteCounts.count == system.windows.count })
    try await Task.sleep(for: .milliseconds(350))
    let tiled = system.windows.map(\.frame)
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows.dropFirst().allSatisfy { $0.isMinimized })
    try await Task.sleep(for: .milliseconds(350))
    let dockPeer = system.windows[1].id
    let failedPeer = system.windows[2].id
    system.failedRestoreWindowIDs = [failedPeer]
    if fromDock {
        system.focusedID = dockPeer
        try system.setMinimized(false, for: dockPeer)
    } else {
        model.perform(.restore)
    }

    // The peer that stayed minimized leaves the layout like any minimized
    // window, so the returned windows fill the display without a gap.
    let display = system.mainDisplay.visibleFrame
    let fills = {
        let frames = system.windows.prefix(2).map(\.frame)
        let area = frames.map { $0.size.width * $0.size.height }.reduce(0, +)
        return area >= display.size.width * display.size.height * 0.98
            && BentoLayoutVerifier.overlappingWindowIDs(Dictionary(uniqueKeysWithValues: system.windows.prefix(2).map { ($0.id, $0.frame) })).isEmpty
    }
    #expect(await waitFor(timeout: .seconds(3)) { fills() }, "\(system.windows.map(\.frame))")
    #expect(!system.windows[1].isMinimized)
    #expect(system.windows[2].isMinimized)
    #expect(system.restoreRequests.filter { $0 == failedPeer }.count == 1)
    let writes = system.frameWriteCounts
    try await Task.sleep(for: .milliseconds(350))
    #expect(system.frameWriteCounts == writes)

    // Restored later, it returns to its place in the original grid.
    system.failedRestoreWindowIDs = []
    try system.setMinimized(false, for: failedPeer)
    #expect(await waitFor(timeout: .seconds(3)) { system.windows.map(\.frame) == tiled }, "\(system.windows.map(\.frame))")
}

/// A Layout Wheel half during Focus mode brings the covered windows back,
/// like the keyboard shortcut, instead of leaving them minimized.
@Test(arguments: [false, true]) @MainActor
func aLayoutWheelHalfEndsFocusModeAndReturnsThePeers(focusChangesAfterCapture: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    let captured = try #require(model.captureLayoutWheelTarget())
    if focusChangesAfterCapture { system.focusedID = peer }
    model.performLayoutWheel(.windowAction(.leftHalf), for: captured)
    #expect(!system.windows[1].isMinimized)
    #expect(system.windows[0].frame == BTRect(x: 0, y: 0, width: 500, height: 800))
    #expect(system.windows[1].frame == BTRect(x: 500, y: 0, width: 500, height: 800))
    #expect(model.statusMessage == nil)
    #expect(model.lastActionFeedback?.kind == .success)
}

@MainActor
private func makeFocusPartitionContext(peerCount: Int = 1) async throws -> (
    system: FakeAppWindowSystem, model: BetterTileModel, target: LayoutWheelTarget
) {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for index in 1...peerCount {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer-\(index)"), processIdentifier: 43,
            bundleIdentifier: "com.example.Peer", frame: BTRect(x: 0, y: 0, width: 200, height: 300),
            displayID: system.mainDisplay.id))
    }
    let space = NativeSpaceID(rawValue: 1)
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [system.mainDisplay.id: space],
        knownSpacesByDisplay: [system.mainDisplay.id: [space, NativeSpaceID(rawValue: 2)]],
        windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) })
    )
    system.emitsMinimizationEvents = true
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(await waitFor { system.frameWriteCounts.count == system.windows.count })
    try #require(await waitFor { model.settlementTasks.isEmpty })
    await model.windowEventTask?.value
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows.dropFirst().allSatisfy { $0.isMinimized })
    let sweeps = system.completeSweepCount
    try #require(await waitFor { system.completeSweepCount > sweeps })
    await model.windowEventTask?.value
    try #require(await waitFor { model.settlementTasks.isEmpty })
    system.requestedFrames = [:]
    return (system, model, try #require(model.captureLayoutWheelTarget()))
}

@Test(arguments: [false, true], [false, true]) @MainActor
func aFocusPartitionWaitsForSlowPeers(fromWheel: Bool, focusChangesWhileWaiting: Bool) async throws {
    let (system, model, captured) = try await makeFocusPartitionContext()
    defer { model.shutdown() }
    let peer = system.windows[1].id
    let feedback = model.lastActionFeedback
    system.slowRestoreIDs = [peer]
    if fromWheel { model.performLayoutWheel(.windowAction(.leftHalf), for: captured) }
    else { model.perform(.leftHalf) }
    if focusChangesWhileWaiting { system.focusedID = peer }
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: peer, processIdentifier: 43))
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.requestedFrames.isEmpty)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
    #expect(model.lastActionFeedback == feedback)
    system.slowRestoreIDs = []
    try system.setMinimized(false, for: peer)
    let left = BTRect(x: 0, y: 0, width: 500, height: 800)
    let right = BTRect(x: 500, y: 0, width: 500, height: 800)
    try #require(await waitFor { system.windows.map(\.frame) == [left, right] },
        "Frames: \(system.windows.map(\.frame)); requests: \(system.requestedFrames); status: \(model.statusMessage ?? "none")")
    #expect(model.statusMessage == nil)
    #expect(model.lastActionFeedback?.kind == .success)
    try await Task.sleep(for: .milliseconds(350))
    #expect(system.requestedFrames[captured.windowID] == [left])
    #expect(system.requestedFrames[peer] == nil || system.requestedFrames[peer] == [right])
}

@Test(arguments: [false, true], [false, true]) @MainActor
func aFocusPartitionReturnsAvailablePeersAfterARestoreFailure(fromWheel: Bool, slowPeer: Bool) async throws {
    let (system, model, captured) = try await makeFocusPartitionContext(peerCount: 2)
    defer { model.shutdown() }
    let failedPeer = system.windows[2].id
    let feedback = model.lastActionFeedback
    if slowPeer { system.slowRestoreIDs = [failedPeer] }
    else { system.failedRestoreWindowIDs = [failedPeer] }
    if fromWheel { model.performLayoutWheel(.windowAction(.leftHalf), for: captured) }
    else { model.perform(.leftHalf) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.requestedFrames.isEmpty)
    #expect(model.lastActionFeedback == feedback)
    let left = BTRect(x: 0, y: 0, width: 500, height: 800)
    let right = BTRect(x: 500, y: 0, width: 500, height: 800)
    try #require(await waitFor(timeout: .seconds(3)) { Array(system.windows.prefix(2).map(\.frame)) == [left, right] },
        "Frames: \(system.windows.map(\.frame)); requests: \(system.requestedFrames); status: \(model.statusMessage ?? "none")")
    #expect(system.windows[2].isMinimized)
    #expect(system.restoreRequests.filter { $0 == failedPeer }.count == 1)
    #expect(model.lastActionFeedback?.kind == .success)
    try await Task.sleep(for: .milliseconds(350))
    #expect(system.requestedFrames[captured.windowID] == [left])
    #expect(system.requestedFrames[system.windows[1].id] == [right])
}

@Test(arguments: [false, true]) @MainActor
func aNewerFocusPartitionSupersedesThePendingPartitionAndRepair(fromWheel: Bool) async throws {
    let (system, model, captured) = try await makeFocusPartitionContext()
    defer { model.shutdown() }
    let peer = system.windows[1].id
    system.slowRestoreIDs = [peer]
    if fromWheel {
        model.performLayoutWheel(.windowAction(.leftHalf), for: captured)
        model.performLayoutWheel(.repairBento, for: captured)
    } else {
        model.perform(.leftHalf)
        model.tileCurrentDisplay()
    }
    if fromWheel {
        system.focusedID = peer
        model.performLayoutWheel(.windowAction(.rightHalf), for: captured)
    } else { model.perform(.rightHalf) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.requestedFrames.isEmpty)
    system.slowRestoreIDs = []
    try system.setMinimized(false, for: peer)
    let right = BTRect(x: 500, y: 0, width: 500, height: 800)
    let left = BTRect(x: 0, y: 0, width: 500, height: 800)
    try #require(await waitFor { system.windows.map(\.frame) == [right, left] })
    #expect(model.lastActionFeedback?.kind == .success)
    try await Task.sleep(for: .milliseconds(350))
    #expect(system.requestedFrames[captured.windowID] == [right])
    #expect(system.requestedFrames[peer] == nil || system.requestedFrames[peer] == [left])
}

@Test(arguments: [false, true], ["maximize", "mode", "shutdown", "gesture"]) @MainActor
func aFocusPartitionWaitIsCancelledByNewerWork(fromWheel: Bool, interruption: String) async throws {
    let (system, model, captured) = try await makeFocusPartitionContext()
    defer { model.shutdown() }
    let peer = system.windows[1].id
    system.slowRestoreIDs = [peer]
    if fromWheel { model.performLayoutWheel(.windowAction(.leftHalf), for: captured) }
    else { model.perform(.leftHalf) }
    model.tileCurrentDisplay()
    switch interruption {
    case "maximize": model.perform(.maximize)
    case "mode": model.setActiveMode(.manual)
    case "shutdown": model.shutdown()
    default: model.prepareWindowGesture()
    }
    let writes = system.frameWriteCounts
    let feedback = model.lastActionFeedback
    system.slowRestoreIDs = []
    system.windows[1].isMinimized = false
    try await Task.sleep(for: .milliseconds(1800))
    #expect(system.frameWriteCounts == writes)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
    #expect(model.lastActionFeedback == feedback)
}

@Test(arguments: [false, true], ["rule", "space", "target", "display", "session"]) @MainActor
func aDeferredFocusPartitionRevalidatesItsCapturedContext(fromWheel: Bool, change: String) async throws {
    let (system, model, captured) = try await makeFocusPartitionContext()
    defer { model.shutdown() }
    let peer = system.windows[1].id
    system.slowRestoreIDs = [peer]
    if fromWheel { model.performLayoutWheel(.windowAction(.leftHalf), for: captured) }
    else { model.perform(.leftHalf) }
    switch change {
    case "rule": model.configuration.applicationRules.set(.ignoreEverywhere, for: "com.example.Test")
    case "space", "session":
        system.desktopObservation?.currentSpaceByDisplay[captured.displayID] = NativeSpaceID(rawValue: 2)
        if change == "session" {
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: peer, processIdentifier: 43))
            try #require(await waitFor {
                model.captureLayoutWheelTarget()?.desktopSessionID != captured.desktopSessionID
            })
        }
    case "target": system.windows.removeAll { $0.id == captured.windowID }
    default: system.availableDisplays = []
    }
    system.slowRestoreIDs = []
    let peerIndex = try #require(system.windows.firstIndex { $0.id == peer })
    system.windows[peerIndex].isMinimized = false
    if change != "session" {
        try #require(await waitFor { model.lastActionFeedback?.kind == .failure })
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.requestedFrames.isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func repairQueuedBehindAFocusPartitionRunsAfterItsPlacement(fromWheel: Bool) async throws {
    let (system, model, captured) = try await makeFocusPartitionContext()
    defer { model.shutdown() }
    let peer = system.windows[1].id
    let feedback = model.lastActionFeedback
    system.slowRestoreIDs = [peer]
    model.performLayoutWheel(.windowAction(.leftHalf), for: captured)
    if fromWheel {
        let unavailable = LayoutWheelTarget(windowID: WindowID(rawValue: "missing-repair-target"),
            displayID: captured.displayID, visibleFrame: captured.visibleFrame)
        model.performLayoutWheel(.repairBento, for: unavailable)
    } else {
        model.tileCurrentDisplay()
        system.focusedWindowReadFails = true
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.requestedFrames.isEmpty)
    #expect(model.lastActionFeedback == feedback)
    system.slowRestoreIDs = []
    system.windows[1].isMinimized = false
    let left = BTRect(x: 0, y: 0, width: 500, height: 800)
    let right = BTRect(x: 500, y: 0, width: 500, height: 800)
    try #require(await waitFor { model.lastActionFeedback?.kind == .failure })
    #expect(system.windows.map(\.frame) == [left, right])
    #expect(system.requestedFrames[captured.windowID] == [left])
    #expect(system.requestedFrames[peer] == nil || system.requestedFrames[peer] == [right])
    #expect(model.statusMessage?.contains(fromWheel ? "captured window" : "Simulated focused-window failure") == true)
}

@Test @MainActor func aDeferredFocusPartitionKeepsKeyboardShortcutCycling() async throws {
    let (system, model, captured) = try await makeFocusPartitionContext()
    defer { model.shutdown() }
    let peer = system.windows[1].id
    system.slowRestoreIDs = [peer]
    model.perform(.leftHalf)
    system.slowRestoreIDs = []
    system.windows[1].isMinimized = false
    let half = BTRect(x: 0, y: 0, width: 500, height: 800)
    try #require(await waitFor { system.windows[0].frame == half })
    system.focusedID = captured.windowID
    model.perform(.leftHalf)
    let third = try #require(WindowAction.leftThird.partition).frame(in: system.mainDisplay.visibleFrame)
    #expect(system.windows[0].frame == third)
    #expect(model.lastActionFeedback?.kind == .success)
}

@Test(arguments: [false, true]) @MainActor
func aFocusPartitionReportsPlacementFailureAfterThePeersReturn(fromWheel: Bool) async throws {
    let (system, model, captured) = try await makeFocusPartitionContext()
    defer { model.shutdown() }
    let peer = system.windows[1].id
    system.slowRestoreIDs = [peer]
    if fromWheel { model.performLayoutWheel(.windowAction(.leftHalf), for: captured) }
    else { model.perform(.leftHalf) }
    system.failedFrameWriteNumbers[captured.windowID] = [system.frameWriteCounts[captured.windowID, default: 0] + 1]
    system.slowRestoreIDs = []
    system.windows[1].isMinimized = false
    try #require(await waitFor { model.lastActionFeedback?.kind == .failure })
    #expect(model.statusMessage?.contains("Injected frame write failure") == true)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
    #expect(!system.windows[1].isMinimized)
}

/// Restore waits for the peers to come back before it lays the desktop out.
/// A newer action during that wait wins: Maximize again stays maximized.
@Test @MainActor func aNewerActionCancelsAPendingFocusModeRestore() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    model.perform(.restore)
    model.perform(.maximize)
    try await Task.sleep(for: .milliseconds(1800))
    #expect(system.windows[1].isMinimized)
    #expect(system.windows[0].frame == system.mainDisplay.visibleFrame)
}

/// Repair while Focus mode is ending waits for the covered windows to come
/// back, so it never lays the desktop out without them.
@Test @MainActor func repairWhileFocusModeEndsWaitsForTheReturningPeers() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    let tiled = system.windows.map(\.frame)
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    system.slowRestoreIDs = [peer]
    model.perform(.restore)
    let restoring = model.lastActionFeedback
    model.tileCurrentDisplay()
    try await Task.sleep(for: .milliseconds(300))
    // Repair has not reported a layout while the peer is still minimized.
    #expect(model.lastActionFeedback == restoring)
    system.slowRestoreIDs = []
    system.windows[1].isMinimized = false
    #expect(await waitFor { system.windows.map(\.frame) == tiled })
    #expect(await waitFor { model.lastActionFeedback != restoring })
}

/// Repair Bento from the Layout Wheel waits for a Focus mode restore the
/// same way, instead of cancelling it.
@Test @MainActor func layoutWheelRepairWaitsForAFocusModeRestore() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 0, y: 0, width: 200, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    let tiled = system.windows.map(\.frame)
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    system.slowRestoreIDs = [peer]
    model.perform(.restore)
    model.performLayoutWheel(.repairBento, for: target(for: system))
    try await Task.sleep(for: .milliseconds(300))
    system.slowRestoreIDs = []
    system.windows[1].isMinimized = false
    #expect(await waitFor { system.windows.map(\.frame) == tiled })
}

/// A probe that cannot restore a new window's size puts the window back at
/// its own frame at once; a window that floats gets no other write.
@Test @MainActor func aFailedProbeRestorePutsTheArrivalBack() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    try await Task.sleep(for: .milliseconds(300))
    let arrival = WindowID(rawValue: "arrival")
    let original = BTRect(x: 100, y: 100, width: 400, height: 300)
    system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 81, bundleIdentifier: "com.example.Arrival",
        frame: original, displayID: system.mainDisplay.id))
    system.unrestoredProbeWindowIDs = [arrival]
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival, processIdentifier: 81))
    #expect(await waitFor { system.probeRequests.contains { $0.contains(arrival) } })
    #expect(system.requestedFrames[arrival]?.first == original)
}

@Test @MainActor func repairBentoRequiresBentoAndRunsWhenAvailable() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .repairBento,
        for: captured
    ) else {
        Issue.record("Expected Repair Bento to require a Bento desktop")
        return
    }

    #expect(reason == "Repair Bento is available only on a Bento desktop.")
    model.performLayoutWheel(.repairBento, for: captured)
    #expect(model.lastActionFeedback?.message == "Bento not active")

    model.setActiveMode(.bento)
    guard case let .ready(placements) = model.previewLayoutWheel(
        .repairBento,
        for: captured
    ) else {
        Issue.record("Expected Repair Bento on a Bento desktop")
        return
    }

    #expect(placements.isEmpty)
    model.statusMessage = "Repair did not run."
    model.performLayoutWheel(.repairBento, for: captured)
    #expect(model.statusMessage == nil)
    #expect(model.lastActionFeedback?.kind == .success)
}

@Test func menuBarDefaultOrderMatchesTheNativeCatalogExactly() {
    #expect(WindowActionGroup.flattenedActions == WindowAction.menuBarDefaultOrder)
    #expect(Set(WindowActionGroup.flattenedActions) == Set(WindowAction.allCases))
    #expect(WindowActionGroup.flattenedActions.count == 34)
}

@Test func menuActionOrderingCommitsOneValidatedInsertion() {
    let actions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    #expect(
        MenuActionOrder.moving(.leftHalf, toInsertionIndex: 3, in: actions)
            == [.rightHalf, .topHalf, .leftHalf, .bottomHalf]
    )
    #expect(
        MenuActionOrder.moving(.bottomHalf, toInsertionIndex: 0, in: actions)
            == [.bottomHalf, .leftHalf, .rightHalf, .topHalf]
    )
    #expect(MenuActionOrder.moving(.leftHalf, toInsertionIndex: 0, in: actions) == nil)
    #expect(MenuActionOrder.moving(.leftHalf, toInsertionIndex: 1, in: actions) == nil)
    #expect(MenuActionOrder.moving(.restore, toInsertionIndex: 2, in: actions) == nil)
    #expect(MenuActionOrder.moving(.leftHalf, toInsertionIndex: 99, in: actions) == nil)
}

@Test func menuActionKeyboardMovesRespectRowsAndBounds() {
    let actions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    #expect(MenuActionOrder.moving(.leftHalf, by: -1, in: actions) == nil)
    #expect(MenuActionOrder.moving(.bottomHalf, by: 1, in: actions) == nil)
    #expect(
        MenuActionOrder.moving(.topHalf, by: -2, in: actions)
            == [.topHalf, .leftHalf, .rightHalf, .bottomHalf]
    )
    #expect(
        MenuActionOrder.moving(.rightHalf, by: 2, in: actions)
            == [.leftHalf, .topHalf, .bottomHalf, .rightHalf]
    )
}

@Test func menuPanelHeightTracksItsContentAndCapsToTheDisplay() {
    let empty = MenuPanelMetrics.viewportHeight(actionCount: 0, editing: false, availableHeight: 700, chromeHeight: 280)
    let one = MenuPanelMetrics.viewportHeight(actionCount: 1, editing: false, availableHeight: 700, chromeHeight: 280)
    let three = MenuPanelMetrics.viewportHeight(actionCount: 3, editing: false, availableHeight: 700, chromeHeight: 280)
    let all = MenuPanelMetrics.viewportHeight(actionCount: 34, editing: false, availableHeight: 700, chromeHeight: 280)
    #expect(empty == 72)
    #expect(one == MenuPanelMetrics.tileHeight)
    #expect(three == MenuPanelMetrics.tileHeight * 2 + MenuPanelMetrics.gap)
    #expect(all == MenuPanelMetrics.maximumActionHeight)
    // Additional permission/update/feedback chrome reduces only the scroll area.
    #expect(MenuPanelMetrics.viewportHeight(actionCount: 34, editing: false,
                                           availableHeight: 500, chromeHeight: 350) == 150)
    #expect(MenuPanelMetrics.viewportHeight(actionCount: 34, editing: false,
                                           availableHeight: 200, chromeHeight: 350) == 0)
    #expect(MenuPanelMetrics.actionHeight(actionCount: 3, editing: true) > three)
    #expect(
        MenuPanelMetrics.tileWidth * 2
            + MenuPanelMetrics.gap
            + MenuPanelMetrics.padding * 2
            == MenuPanelMetrics.width
    )
}

@Test func menuDragPreviewsAnOrderWithoutChangingTheSavedOrder() {
    let original: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    var drag = MenuActionDrag(source: .leftHalf, actions: original)
    #expect(drag.move(to: 4)?.to == 3)
    #expect(drag.original == original)
    #expect(drag.committedOrder == [.rightHalf, .topHalf, .bottomHalf, .leftHalf])
    #expect(drag.move(to: 4) == nil)
    #expect(drag.move(to: 0)?.to == 0)
    #expect(drag.committedOrder == nil)
    #expect(drag.move(to: -1) == nil)
}

@Test @MainActor func menuScrollHostOwnsItsGutterAndRetainsItsDocument() throws {
    let scroll = MenuPanelScrollHost(content: Color.clear.frame(height: 600))
    scroll.frame = CGRect(x: 0, y: 0, width: 328, height: 200)
    scroll.layoutSubtreeIfNeeded()
    let document = try #require(scroll.documentView)
    #expect(scroll.scrollerStyle == .overlay)
    #expect(!scroll.hasHorizontalScroller)
    #expect(scroll.contentSize.width == 328)
    #expect(document.frame.width == 328)
    #expect(document.frame.height == 600)
    scroll.update(content: Color.clear.frame(height: 700))
    #expect(scroll.documentView === document)
    #expect(document.frame.height == 700)
}

@Test(arguments: [260.0, 400.0, 619.0, 620.0, 900.0])
func snapZoneLayoutKeepsTheScreenInsideAvailableSpace(width: Double) {
    let layout = SnapZoneLayout(width: width)
    #expect(layout.monitorWidth <= width)
    #expect(layout.monitorWidth > 0)
    #expect(layout.height > layout.monitorWidth / 1.6)
    if layout.isWide { #expect(layout.monitorWidth + 280 <= width) }
}

@Test func snapZoneMarkersStayOnTheirTriggerEdgesAndSeparateFromPlacement() {
    let size = CGSize(width: 360, height: 225)
    let screen = CGRect(origin: .zero, size: size)
    for area in SnapArea.allCases {
        let marker = SnapZonePreviewGeometry.marker(for: area, in: size)
        #expect(screen.contains(marker))
        let target = SnapZonePreviewGeometry.trigger(for: area)
        let targetFrame = CGRect(x: target.x * size.width, y: target.y * size.height,
                                 width: target.width * size.width, height: target.height * size.height)
        #expect(targetFrame.contains(CGPoint(x: marker.midX, y: marker.midY)))
    }
    #expect(SnapZonePreviewGeometry.marker(for: .topLeft, in: size).size == CGSize(width: 22, height: 22))
    #expect(SnapZonePreviewGeometry.trigger(for: .topLeft).width == 0.3)
    #expect(SnapZonePreviewGeometry.trigger(for: .topLeft).height == 0.36)
    #expect(SnapZonePreviewGeometry.marker(for: .right, in: size).maxX == size.width)
    #expect(SnapZonePreviewGeometry.marker(for: .bottom, in: size).maxY == size.height)
}

@Test func snapZonePreviewKeepsCenterDistinctFromCenterResize() throws {
    let centered = try #require(SnapZonePreviewGeometry.placement(for: .center))
    let resized = try #require(SnapZonePreviewGeometry.placement(for: .centerResize))
    #expect(centered.x == 0.3)
    #expect(centered.y == 0.3)
    #expect(centered.width == 0.4)
    #expect(centered.height == 0.4)
    #expect(resized.x == 0.1)
    #expect(resized.y == 0.1)
    #expect(resized.width == 0.8)
    #expect(resized.height == 0.8)
    #expect(SnapZonePreviewGeometry.placement(for: nil) == nil)
}

@Test @MainActor func menuOnlyConfigurationPersistsWithoutWindowWritesOrWheelChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let system = FakeAppWindowSystem()
    let model = BetterTileModel(store: store, system: system, startRuntime: false)
    defer { model.shutdown() }
    let wheel = model.configuration.layoutWheel

    model.updateConfiguration { $0.menuBarActions = [.rightHalf, .leftHalf] }
    model.flushConfiguration()

    #expect(system.frameWriteCounts.isEmpty)
    #expect(model.configuration.layoutWheel == wheel)
    #expect(try store.load().menuBarActions == [.rightHalf, .leftHalf])
}

@Test @MainActor func menuCollectionLaysOutEveryTileAtItsAssignedSize() throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    let host = NSHostingView(rootView:
        MenuActionCollection(actions: actions, shortcuts: [], commit: { _, _ in })
    .frame(width: 328, height: 328)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator)))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 328),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func collection(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { collection(in: $0) }.first
    }
    let view = try #require(collection(in: host))
    view.layoutSubtreeIfNeeded()
    let first = try #require(view.item(at: IndexPath(item: 0, section: 0)))
    let point = try #require(host.superview).convert(CGPoint(x: first.view.frame.midX, y: first.view.frame.midY), from: view)
    let hit = host.hitTest(point)
    #expect(hit === first.view)
    for index in view.indexPathsForVisibleItems().map(\.item) {
        let path = IndexPath(item: index, section: 0)
        let item = try #require(view.item(at: path))
        let attributes = try #require(view.collectionViewLayout?.layoutAttributesForItem(at: path))
        // AppKit aligns item origins to device pixels. A 1x CI display may
        // round the half-point column origin that a 2x display represents exactly.
        let pixelTolerance = 0.5 / window.backingScaleFactor + 0.001
        #expect(abs(item.view.frame.minX - attributes.frame.minX) <= pixelTolerance)
        #expect(abs(item.view.frame.minY - attributes.frame.minY) <= pixelTolerance)
        #expect(item.view.frame.width == MenuPanelMetrics.tileWidth)
        #expect(item.view.frame.height == MenuPanelMetrics.tileHeight)
    }
}

@Test @MainActor func menuKeyboardReorderingRetainsSelectionAfterConfigurationRefresh() throws {
    _ = NSApplication.shared
    var actions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    var commits = 0
    func content() -> some View {
        MenuActionCollection(actions: actions, shortcuts: [], commit: { order, _ in
            actions = order
            commits += 1
        }).frame(width: 328, height: 160)
    }
    let host = NSHostingView(rootView: content())
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 160),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let collection = try #require(find(in: host))
    collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
    collection.moveSelection?(1)
    host.rootView = content()
    host.layoutSubtreeIfNeeded()
    #expect(collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    collection.moveSelection?(1)
    #expect(commits == 2)
    #expect(actions == [.rightHalf, .topHalf, .leftHalf, .bottomHalf])
}

@Test(arguments: [false, true]) @MainActor
func shutdownRemovesApplicationNotificationObservers(queuedBeforeShutdown: Bool) async {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    model.installWorkspaceTriggers()
    if queuedBeforeShutdown {
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    }
    model.shutdown()
    let sweeps = system.completeSweepCount
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(system.completeSweepCount == sweeps)
    model.shutdown()
}

@Test @MainActor func menuConfigurationRefreshCancelsActiveDrag() async throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    let content = MenuActionCollection(actions: actions, shortcuts: [], commit: { _, _ in
        Issue.record("An external configuration refresh must not commit the drag")
    })
    let host = NSHostingView(rootView: content.frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    coordinator.beginDrag(at: 0, in: view)
    let info = MenuTestDraggingInfo(collection: view, point: CGPoint(x: 30, y: 190))
    _ = view.draggingUpdated(info)
    try await Task.sleep(for: .milliseconds(20))
    #expect(view.dragDisplayLink != nil)
    #expect(view.visibleItems().contains { $0.view.alphaValue == 0 })

    var updated = content
    updated.actions = Array(actions.reversed())
    host.rootView = updated.frame(width: 328, height: 200)
    host.layoutSubtreeIfNeeded()
    #expect(coordinator.drag == nil)
    #expect(view.dragDisplayLink == nil)
    #expect(coordinator.displayed == updated.actions)
    #expect(view.visibleItems().allSatisfy { $0.view.alphaValue == 1 })
    _ = view.draggingUpdated(info)
    #expect(view.dragDisplayLink == nil)
    coordinator.endDrag(in: view)
    #expect(coordinator.displayed == updated.actions)
}

@Test(arguments: [false, true]) @MainActor
func shutdownIgnoresPendingWindowEvents(deliveredAfterShutdown: Bool) async throws {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    let callback = try #require(system.eventHandler)
    let event = WindowSystemEvent(kind: .created, windowID: system.windows[0].id, processIdentifier: 42)
    if !deliveredAfterShutdown { callback(event) }
    model.shutdown()
    let sweeps = system.completeSweepCount
    if deliveredAfterShutdown { callback(event) }
    try await Task.sleep(for: WindowEventRetryBackoff.initialDelay + .milliseconds(100))
    #expect(system.completeSweepCount == sweeps)
    #expect(system.frameWriteCounts.isEmpty)
}

@Test @MainActor func menuCollectionScrollsToOffscreenTiles() throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    let host = NSHostingView(rootView:
        MenuActionCollection(actions: actions, shortcuts: [], commit: { _, _ in })
    .frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let last = IndexPath(item: actions.count - 1, section: 0)
    view.layoutSubtreeIfNeeded()
    let lastFrame = try #require(view.layoutAttributesForItem(at: last)).frame
    view.scrollToItems(at: [last], scrollPosition: .bottom)
    #expect(view.visibleRect.contains(lastFrame))
    let first = IndexPath(item: 0, section: 0)
    let firstFrame = try #require(view.layoutAttributesForItem(at: first)).frame
    view.scrollToItems(at: [first], scrollPosition: .top)
    #expect(view.visibleRect.contains(firstFrame))
}

@MainActor private final class MenuTestDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let collection: NSCollectionView
    var draggingLocation: NSPoint
    init(collection: NSCollectionView, point: NSPoint) {
        self.collection = collection
        draggingLocation = collection.convert(point, to: nil)
    }
    var draggingDestinationWindow: NSWindow? { collection.window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: NSPasteboard.Name("BetterTile-menu-test")) }
    var draggingSource: Any? { collection }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Test @MainActor func menuAdjacentDragSwapsOnEnteringItsNeighborAndKeepsTheAcceptedOrder() async throws {
    _ = NSApplication.shared
    var saved: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
    let host = NSHostingView(rootView: MenuActionCollection(actions: saved, shortcuts: [], commit: { order, _ in
        saved = order
    }).frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    let neighbor = try #require(view.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
    let info = MenuTestDraggingInfo(collection: view, point: CGPoint(x: neighbor.minX + 1, y: neighbor.midY))
    coordinator.beginDrag(at: 0, in: view)
    try await Task.sleep(for: .milliseconds(20))
    #expect(view.item(at: IndexPath(item: 0, section: 0))?.view.alphaValue == 0)
    var proposed = NSIndexPath(forItem: 1, inSection: 0)
    var operation = NSCollectionView.DropOperation.before
    #expect(coordinator.collectionView(view, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation) == .move)
    #expect(coordinator.displayed == [.rightHalf, .leftHalf, .topHalf, .bottomHalf])
    #expect(view.item(at: IndexPath(item: 1, section: 0))?.view.alphaValue == 0)
    // Staying over the new slot must not repeatedly flip the two neighbors.
    _ = coordinator.collectionView(view, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation)
    #expect(coordinator.displayed == [.rightHalf, .leftHalf, .topHalf, .bottomHalf])
    #expect(coordinator.collectionView(view, acceptDrop: info, indexPath: proposed as IndexPath, dropOperation: operation))
    #expect(saved == [.rightHalf, .leftHalf, .topHalf, .bottomHalf])
    // The drag-end callback must see the new order before SwiftUI refreshes.
    #expect(coordinator.parent.actions == saved)
    coordinator.endDrag(in: view)
    #expect(coordinator.displayed == saved)
    // A second drag starts from the accepted order, even before a SwiftUI update.
    coordinator.drag = MenuActionDrag(source: .leftHalf, actions: coordinator.parent.actions)
    info.draggingLocation = view.convert(CGPoint(x: 30, y: 30), to: nil)
    _ = coordinator.collectionView(view, validateDrop: info, proposedIndexPath: &proposed, dropOperation: &operation)
    #expect(coordinator.displayed.first == .leftHalf)
    coordinator.endDrag(in: view) // Escape/outside drop: restore the saved order.
    #expect(coordinator.displayed == saved)
    #expect(coordinator.drag == nil)
    #expect(view.visibleItems().allSatisfy { $0.view.alphaValue == 1 })

    coordinator.drag = MenuActionDrag(source: .rightHalf, actions: saved)
    coordinator.previewDrop(at: CGPoint(x: neighbor.midX, y: neighbor.midY), in: view, time: 1)
    let firstPreview = coordinator.displayed
    coordinator.previewDrop(at: CGPoint(x: neighbor.midX, y: 100), in: view, time: 1.01)
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        #expect(coordinator.displayed.last == .rightHalf)
    } else {
        #expect(coordinator.displayed == firstPreview)
    }
    coordinator.previewDrop(at: CGPoint(x: neighbor.midX, y: 100), in: view, time: 1.2)
    #expect(coordinator.displayed.last == .rightHalf)
    coordinator.endDrag(in: view)
    #expect(coordinator.displayed == saved)
}

@Test @MainActor func menuDragAutoscrollUsesTheEdgeVisibleInsideSettings() throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: MenuActionCollection(actions: WindowAction.menuBarDefaultOrder,
        shortcuts: [], commit: { _, _ in }).frame(width: 328, height: 400))
    host.frame = CGRect(x: 0, y: 0, width: 328, height: 400)
    let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 328, height: 200))
    outer.documentView = host
    let window = NSWindow(contentRect: outer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = outer
    outer.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> NSCollectionView? {
        if let found = view as? NSCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host) as? MenuReorderCollectionView)
    let scroll = try #require(view.enclosingScrollView)
    let before = scroll.contentView.bounds.origin
    let visible = view.visibleRect
    #expect(visible.height == 200)
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    coordinator.beginDrag(at: 0, in: view)
    let info = MenuTestDraggingInfo(collection: view,
        point: CGPoint(x: visible.midX, y: visible.maxY - 12))
    #expect(view.wantsPeriodicDraggingUpdates())
    _ = view.draggingUpdated(info)
    #expect(scroll.contentView.bounds.origin == before)
    #expect(view.dragDisplayLink != nil)
    defer { view.stopDragFrames() }
    for step in 0..<900 { view.advanceDragFrame(time: Double(step) / 60) }
    let last = IndexPath(item: WindowAction.menuBarDefaultOrder.count - 1, section: 0)
    let lastFrame = try #require(view.layoutAttributesForItem(at: last)).frame
    #expect(view.visibleRect.contains(lastFrame))
    info.draggingLocation = view.convert(CGPoint(x: view.visibleRect.midX, y: view.visibleRect.minY + 12), to: nil)
    _ = view.draggingUpdated(info)
    for step in 900..<1800 { view.advanceDragFrame(time: Double(step) / 60) }
    let firstFrame = try #require(view.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
    #expect(view.visibleRect.contains(firstFrame))
    info.draggingLocation = view.convert(CGPoint(x: view.visibleRect.midX, y: view.visibleRect.midY), to: nil)
    let centeredOrigin = scroll.contentView.bounds.origin
    _ = view.draggingUpdated(info)
    view.advanceDragFrame(time: 30)
    #expect(scroll.contentView.bounds.origin == centeredOrigin)
    view.draggingExited(info)
    #expect(view.dragDisplayLink != nil) // Leaving the box must not end drag scrolling.
    view.stopDragFrames()
    #expect(view.lastDragScrollTime == nil)
    _ = view.draggingUpdated(info)
    #expect(view.dragDisplayLink != nil)
    window.contentView = nil
    #expect(view.dragDisplayLink == nil)
}

@Test @MainActor func menuDragScrollsTheSettingsPageOutsideTheTileColumn() throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: MenuActionCollection(actions: WindowAction.menuBarDefaultOrder,
        shortcuts: [], commit: { _, _ in }).frame(width: 328, height: 400).frame(width: 600, height: 800))
    host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
    let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
    outer.documentView = host
    let window = NSWindow(contentRect: outer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = outer
    outer.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let inner = try #require(view.enclosingScrollView)
    let initial = outer.contentView.bounds.origin
    let innerInitial = inner.contentView.bounds.origin
    // Well below the window and outside the narrower tile column.
    let bottom = NSPoint(x: 20, y: -150)
    for step in 0..<120 { view.scrollDuringDrag(at: bottom, time: Double(step) / 60) }
    #expect(outer.contentView.bounds.origin != initial)
    #expect(inner.contentView.bounds.origin == innerInitial)
    let middle = NSPoint(x: 20, y: 150)
    let stopped = outer.contentView.bounds.origin
    for step in 120..<180 { view.scrollDuringDrag(at: middle, time: Double(step) / 60) }
    #expect(outer.contentView.bounds.origin == stopped)
    let top = NSPoint(x: 20, y: 450)
    for step in 180..<300 { view.scrollDuringDrag(at: top, time: Double(step) / 60) }
    #expect(outer.contentView.bounds.origin == initial)
}

private final class MenuTestDraggingSession: NSDraggingSession {
    var point: NSPoint = .zero
    override var draggingLocation: NSPoint { point }
}

@Test @MainActor func menuSourceDragScrollsBeyondBothEdgesAndStopsOnCancellation() throws {
    _ = NSApplication.shared
    let actions = WindowAction.menuBarDefaultOrder
    var commits = 0
    let host = NSHostingView(rootView: MenuActionCollection(actions: actions,
        shortcuts: [], commit: { _, _ in commits += 1 }).frame(width: 328, height: 200))
    let window = NSWindow(contentRect: CGRect(x: 300, y: 250, width: 328, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(in view: NSView) -> MenuReorderCollectionView? {
        if let found = view as? MenuReorderCollectionView { return found }
        return view.subviews.compactMap { find(in: $0) }.first
    }
    let view = try #require(find(in: host))
    let coordinator = try #require(view.delegate as? MenuActionCollection.Coordinator)
    let session = MenuTestDraggingSession()
    coordinator.beginDrag(at: 0, in: view)
    view.startDragFrames(session: session)
    defer { view.stopDragFrames() }
    session.point = window.convertPoint(toScreen: NSPoint(x: 100, y: -200))
    view.draggingExited(nil)
    for step in 0..<180 { view.advanceDragFrame(time: Double(step) / 60) }
    let lastFrame = try #require(view.layoutAttributesForItem(at: IndexPath(item: actions.count - 1, section: 0))).frame
    #expect(view.visibleRect.contains(lastFrame))
    #expect(coordinator.displayed == actions) // Outside scrolling does not select an outside drop.
    session.point = window.convertPoint(toScreen: NSPoint(x: 100, y: 400))
    for step in 180..<360 { view.advanceDragFrame(time: Double(step) / 60) }
    let firstFrame = try #require(view.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
    #expect(view.visibleRect.contains(firstFrame))
    coordinator.endDrag(in: view)
    #expect(view.dragDisplayLink == nil)
    #expect(view.lastDragScrollTime == nil)
    session.point = window.convertPoint(toScreen: NSPoint(x: 100, y: -200))
    for step in 360..<540 { view.advanceDragFrame(time: Double(step) / 60) }
    #expect(view.visibleRect.contains(firstFrame))
    #expect(commits == 0)
}

@Test @MainActor func newWindowSideAppliesToFutureWindowsOnASingleWindowDesktop() async throws {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.defaultLayoutMode = .bento
    model.tileCurrentDisplay()
    let frames = system.windows.map(\.frame)
    let writes = system.frameWriteCounts
    model.updateConfiguration { $0.bentoNewWindowSide = .right }
    try await Task.sleep(for: .milliseconds(150))
    #expect(system.windows.map(\.frame) == frames)
    #expect(system.frameWriteCounts == writes)

    let oldID = system.windows[0].id
    let newID = WindowID(rawValue: "new")
    system.windows.insert(WindowSnapshot(
        id: newID, processIdentifier: 43,
        frame: BTRect(x: 100, y: 100, width: 600, height: 600), displayID: system.mainDisplay.id
    ), at: 0) // The newcomer is focused, as a newly opened app normally is.
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: newID, processIdentifier: 43))
    try #require(await waitFor {
        let newFrame = system.windows.first { $0.id == newID }!.frame
        let oldFrame = system.windows.first { $0.id == oldID }!.frame
        return newFrame.minX >= oldFrame.maxX
    })
    let settled = system.windows.map(\.frame)
    model.updateConfiguration { $0.bentoNewWindowSide = .left }
    try await Task.sleep(for: .milliseconds(250))
    #expect(system.windows.map(\.frame) == settled)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func minimizedRightHalfReturnsToItsOriginalSide(nativeMembership: Bool, staleMinimizeSnapshot: Bool) async throws {
    let system = FakeAppWindowSystem()
    system.windows.append(WindowSnapshot(
        id: WindowID(rawValue: "peer"), processIdentifier: 43,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: system.mainDisplay.id
    ))
    system.emitsFrameEvents = true
    if nativeMembership {
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: space],
            knownSpacesByDisplay: [system.mainDisplay.id: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) })
        )
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = .maximize
    model.tileCurrentDisplay()
    model.performLayoutWheel(.windowAction(.rightHalf), for: target(for: system))
    try await Task.sleep(for: .milliseconds(500))
    let originalFrames = system.windows.map(\.frame)
    try #require(originalFrames[0].minX > originalFrames[1].minX)

    let restoredID = system.windows[0].id
    if staleMinimizeSnapshot {
        let sweeps = system.completeSweepCount
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: restoredID, processIdentifier: 42))
        try #require(await waitFor { system.completeSweepCount > sweeps })
    }
    system.windows[0].isMinimized = true
    system.desktopObservation?.windowMembership.removeValue(forKey: restoredID)
    if staleMinimizeSnapshot {
        for _ in 0..<4 {
            let sweeps = system.completeSweepCount
            system.eventHandler?(WindowSystemEvent(kind: .created, windowID: system.windows[1].id, processIdentifier: 43))
            try #require(await waitFor { system.completeSweepCount > sweeps })
        }
    } else {
        system.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: restoredID, processIdentifier: 42))
    }
    try #require(await waitFor { system.windows[1].frame.size.width == 1000 })
    try await Task.sleep(for: .milliseconds(300))
    system.windows[0].isMinimized = false
    if nativeMembership { system.desktopObservation?.windowMembership[restoredID] = [NativeSpaceID(rawValue: 1)] }
    system.eventHandler?(WindowSystemEvent(kind: .restored, windowID: restoredID, processIdentifier: 42))
    #expect(await waitFor(timeout: .seconds(3)) { system.windows.map(\.frame) == originalFrames },
            "\(system.windows.map(\.frame))")
}


/// A new window of an application with a measured minimum starts from that
/// measurement: its first snapshot is seeded, and BetterTile never asks it
/// for a size the application already refused once.
@Test @MainActor func newWindowOfAMeasuredApplicationStartsFromItsMeasurement() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    system.emitsFrameEvents = true
    let first = WindowID(rawValue: "brave-a"), second = WindowID(rawValue: "brave-b")
    system.windows.append(WindowSnapshot(id: first, processIdentifier: 50, bundleIdentifier: "com.brave.Browser",
        frame: BTRect(x: 100, y: 100, width: 700, height: 600), displayID: system.mainDisplay.id))
    system.enforcedMinimumWidths[first] = 520
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    // The first write measures 520 and the layout is solved around it.
    let entered = await waitFor {
        system.windows[1].frame.size.width >= 520 && system.windows[0].frame.intersection(system.windows[1].frame) == nil
    }
    #expect(entered, "\(system.windows.map(\.frame))")

    system.windows.append(WindowSnapshot(id: second, processIdentifier: 50, bundleIdentifier: "com.brave.Browser",
        frame: BTRect(x: 150, y: 150, width: 700, height: 600), displayID: system.mainDisplay.id))
    system.enforcedMinimumWidths[second] = 520
    #expect(try system.windowSnapshots(ids: [second]).first?.constraints.minimumSize.width == 520)
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: second, processIdentifier: 50))
    try await Task.sleep(for: .milliseconds(900))
    #expect((system.requestedFrames[second] ?? []).allSatisfy { $0.size.width >= 520 })
}


/// A window that appears on a Bento desktop is measured before its first
/// placement, so even the first window of an application never receives a
/// size it refuses. Entering Bento measures nothing.
@Test @MainActor func arrivingWindowIsMeasuredBeforeItsFirstPlacement() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    system.emitsFrameEvents = true
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.probeRequests.isEmpty)
    let arrival = WindowID(rawValue: "preview-a")
    system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 60, bundleIdentifier: "com.apple.Preview",
        frame: BTRect(x: 100, y: 100, width: 700, height: 700), displayID: system.mainDisplay.id))
    system.enforcedMinimumHeights[arrival] = 600
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival, processIdentifier: 60))
    #expect(await waitFor { system.frameWriteCounts[arrival, default: 0] > 0 })
    try await Task.sleep(for: .milliseconds(600))
    #expect(system.probeRequests.contains { $0.contains(arrival) })
    #expect((system.requestedFrames[arrival] ?? []).allSatisfy { $0.size.height >= 600 })
}

/// Repair learns a minimum from its own write and must not report success
/// while that window overlaps a neighbour: it plans again with the measured
/// minimum, and only then reports.
@Test @MainActor func repairVerifiesItsLayoutAndReplansAroundMeasuredMinimums() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    let brave = WindowID(rawValue: "brave"), other = WindowID(rawValue: "other")
    system.windows.append(WindowSnapshot(id: brave, processIdentifier: 50, bundleIdentifier: "com.brave.Browser",
        frame: BTRect(x: 100, y: 100, width: 700, height: 600), displayID: system.mainDisplay.id))
    system.windows.append(WindowSnapshot(id: other, processIdentifier: 51, bundleIdentifier: "com.example.Other",
        frame: BTRect(x: 150, y: 150, width: 600, height: 500), displayID: system.mainDisplay.id))
    system.enforcedMinimumWidths[brave] = 520
    let model = makeModel(system: system)
    defer { model.shutdown() }
    system.focusedID = system.windows[0].id

    model.tileCurrentDisplay()
    let frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    #expect(BentoLayoutVerifier.overlappingWindowIDs(frames).isEmpty, "\(frames)")
    #expect(model.lastActionFeedback?.kind == .success, "\(String(describing: model.statusMessage))")
    #expect((frames[brave]?.size.width ?? 0) >= 520)
}

/// Long window titles in result-pill details. CJK characters and emoji are
/// about twice as wide as Latin letters, so a character count cannot tell
/// whether a detail fits.
private let longPillTitles = [
    "Quarterly planning notes and follow-up actions for the platform team – Google Docs – Brave",
    "四半期計画のメモとプラットフォームチームのフォローアップ項目一覧表と予算レビュー資料",
    "📊📈📉🗂️📁📂🗃️🗄️📋📌📍📎🖇️📏📐✂️🗒️🗓️📆📅📇🧾📑🔖🏷️💼📒📓📔📕📗📘📙📚",
    "Budget 2027 予算レビュー 📊 – 프로젝트 계획서 및 후속 조치 항목 – Numbers",
]

/// Repair names the windows that overlap. Long titles are shortened so the
/// reason still fits the result pill.
@Test(arguments: longPillTitles)
func repairOverlapMessageFitsTheResultPillWithLongTitles(title: String) {
    let message = BetterTileModel.overlapMessage([title, title])
    #expect(message.hasSuffix("cannot fit beside each other at their minimum sizes."))
    #expect(ResultPillLayout.detailFits(message), "\(message)")
    #expect(message.hasPrefix(String(title.prefix(4))), "\(message)")
    #expect(BetterTileModel.overlapMessage(["Brave", "Preview"])
        == "Brave and Preview cannot fit beside each other at their minimum sizes.")
}

/// Repair reports success only after it read every placed window back.
@Test @MainActor func repairDoesNotReportSuccessWithoutReadingEveryWindowBack() {
    let system = FakeAppWindowSystem()
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "second"), processIdentifier: 43,
        frame: BTRect(x: 800, y: 200, width: 400, height: 400), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    model.setActiveMode(.bento)
    let second = system.windows[1].id
    system.unreadableAfterWrites[second] = system.frameWriteCounts[second, default: 0] + 1
    model.performLayoutWheel(.repairBento, for: captured)
    #expect(model.lastActionFeedback?.kind != .success)
    #expect(model.statusMessage == "BetterTile could not read the repaired windows back to confirm the layout.",
            "\(String(describing: model.statusMessage))")
}

/// The seventh window on a Bento desktop floats where it opened. BetterTile
/// says so at once and names the window, instead of leaving it over the
/// tiles without a word.
@Test @MainActor func seventhBentoWindowIsAnnouncedWhenItFloats() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.availableDisplays = [DisplaySnapshot(id: system.mainDisplay.id,
        frame: BTRect(x: 0, y: 0, width: 1800, height: 1000), visibleFrame: BTRect(x: 0, y: 0, width: 1800, height: 1000),
        isMain: true)]
    for index in 1...5 {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "w\(index)"), processIdentifier: Int32(60 + index),
            title: "Window \(index)", frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { Set(system.windows.map(\.frame)).count == 6 })
    try await Task.sleep(for: .milliseconds(300))
    let seventh = WindowID(rawValue: "seventh")
    system.windows.append(WindowSnapshot(id: seventh, processIdentifier: 90, title: "Report",
        frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: seventh, processIdentifier: 90))
    #expect(await waitFor { model.lastActionFeedback?.message == "Bento is full" })
    #expect(model.lastActionFeedback?.detail?.contains("Report") == true)
}

/// A long window title is shortened so the overflow instruction still fits
/// the result pill.
@Test(arguments: longPillTitles) @MainActor
func seventhBentoWindowAnnouncementKeepsItsInstructionWithALongTitle(title: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.availableDisplays = [DisplaySnapshot(id: system.mainDisplay.id,
        frame: BTRect(x: 0, y: 0, width: 1800, height: 1000), visibleFrame: BTRect(x: 0, y: 0, width: 1800, height: 1000),
        isMain: true)]
    for index in 1...5 {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "w\(index)"), processIdentifier: Int32(60 + index),
            title: "Window \(index)", frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { Set(system.windows.map(\.frame)).count == 6 })
    try await Task.sleep(for: .milliseconds(300))
    let seventh = WindowID(rawValue: "seventh")
    system.windows.append(WindowSnapshot(id: seventh, processIdentifier: 90, title: title,
        frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id))
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: seventh, processIdentifier: 90))
    try #require(await waitFor(timeout: .seconds(2)) { model.lastActionFeedback?.message == "Bento is full" })
    let detail = try #require(model.lastActionFeedback?.detail)
    #expect(detail.hasSuffix("switch this desktop to Tabbed."))
    #expect(detail.contains("“\(title.prefix(4))"))
    #expect(!detail.contains(title))
    #expect(ResultPillLayout.detailFits(detail), "\(detail)")
}

/// A closed document window that its application keeps alive off screen
/// sends no destroyed event. Its pane must still close within a second,
/// not wait for the watchdog's sweeps.
@Test(arguments: [false, true]) @MainActor
func silentlyClosedWindowLeavesItsPaneWithinASecond(nilFocusID: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for index in 1...2 {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "doc\(index)"), processIdentifier: 70,
            frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { Set(system.windows.map(\.frame)).count == 3 })
    try await Task.sleep(for: .milliseconds(300))
    let closed = system.windows.removeLast()
    system.focusedID = system.windows[0].id
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nilFocusID ? nil : system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    let reflowed = await waitFor(timeout: .seconds(3)) {
        system.windows.allSatisfy { $0.frame.size.height == 800 } && Set(system.windows.map(\.frame)).count == 2
    }
    #expect(reflowed, "\(system.windows.map(\.frame)) after closing \(closed.id), sweeps \(system.completeSweepCount)")
}

/// A focus change to an unrelated application right after a silent close
/// must not erase the pending check: the closed pane still leaves promptly.
@Test(arguments: [false, true]) @MainActor
func unrelatedFocusAfterASilentCloseKeepsThePendingCheck(nilFocusID: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for index in 1...2 {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "doc\(index)"), processIdentifier: 70,
            frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { Set(system.windows.map(\.frame)).count == 3 })
    try await Task.sleep(for: .milliseconds(300))
    let closed = system.windows.removeLast()
    system.focusedID = system.windows[0].id
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nilFocusID ? nil : system.windows[0].id,
                                          processIdentifier: system.windows[0].processIdentifier))
    // The user clicks another application before the event pass runs.
    system.focusedID = WindowID(rawValue: "finder")
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nilFocusID ? nil : WindowID(rawValue: "finder"),
                                          processIdentifier: 99))
    let reflowed = await waitFor(timeout: .seconds(3)) {
        system.windows.allSatisfy { $0.frame.size.height == 800 } && Set(system.windows.map(\.frame)).count == 2
    }
    #expect(reflowed, "\(system.windows.map(\.frame)) after closing \(closed.id), sweeps \(system.completeSweepCount)")
}

/// Closing a document on one display can move focus to the same
/// application's window on another display. The focus check covers every
/// Bento layout, so the closed pane still leaves.
@Test @MainActor func silentlyClosedWindowOnAnotherDisplayLeavesItsPane() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let second = DisplaySnapshot(id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800))
    system.availableDisplays.append(second)
    let sibling = WindowID(rawValue: "sibling")
    system.windows.append(WindowSnapshot(id: sibling, processIdentifier: 70,
        frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    for index in 1...2 {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: "doc\(index)"), processIdentifier: 70,
            frame: BTRect(x: 1000, y: 0, width: 400, height: 300), displayID: second.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.updateConfiguration { $0.defaultLayoutMode = .bento }
    model.setActiveMode(.bento)
    let onSecond = { system.windows.filter { $0.displayID == second.id } }
    try #require(await waitFor(timeout: .seconds(2)) {
        model.activeMode(for: second.id) == .bento && Set(onSecond().map(\.frame)).count == 2
            && onSecond().allSatisfy { $0.frame.size.width < 1000 }
    }, "\(system.windows.map(\.frame))")
    try await Task.sleep(for: .milliseconds(300))
    system.windows.removeAll { $0.id == WindowID(rawValue: "doc2") }
    system.focusedID = sibling
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: 70))
    let reflowed = await waitFor(timeout: .seconds(3)) {
        onSecond().first?.frame == second.visibleFrame
    }
    #expect(reflowed, "\(system.windows.map(\.frame)), sweeps \(system.completeSweepCount)")
}

@Test(arguments: [false, true]) @MainActor
func repeatedBentoFocusChecksPeersWithoutSweepingOrWriting(nilFocusID: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 70,
        frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } && model.settlementTasks.isEmpty })
    try await Task.sleep(for: .milliseconds(300))
    let sweeps = system.completeSweepCount
    let writes = system.frameWriteCounts
    let checks = system.cachedRefreshRequests.count
    let expected = Set(system.windows.map(\.id))
    for round in 1...3 {
        for _ in 0..<5 {
            system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nilFocusID ? nil : system.windows[0].id,
                                                  processIdentifier: 42))
        }
        // Each burst coalesces into one check; wait for it under a loaded runner.
        try #require(await waitFor(timeout: .seconds(2)) { system.cachedRefreshRequests.count >= checks + round })
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(Array(system.cachedRefreshRequests.dropFirst(checks)) == Array(repeating: expected, count: 3))
    #expect(system.completeSweepCount == sweeps)
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: [false, true]) @MainActor
func offscreenReadableBentoPeerFallsBackWithoutPrematureRemoval(nativeMembership: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 70,
        frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    if nativeMembership {
        let space = NativeSpaceID(rawValue: 1)
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [system.mainDisplay.id: space],
            knownSpacesByDisplay: [system.mainDisplay.id: [space]],
            windowMembership: Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, [space]) })
        )
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } && model.settlementTasks.isEmpty })
    try await Task.sleep(for: .milliseconds(300))
    let sweeps = system.completeSweepCount
    let writes = system.frameWriteCounts
    system.offscreenWindowIDs.insert(peer)
    #expect(try system.windowSnapshots(ids: [peer]).count == 1)
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: 42))
    try #require(await waitFor(timeout: .seconds(2)) { system.completeSweepCount > sweeps })
    #expect(system.frameWriteCounts == writes)
    if nativeMembership {
        try await Task.sleep(for: .milliseconds(1100))
        #expect(system.frameWriteCounts == writes)
    }
    system.offscreenWindowIDs.remove(peer)
    try await Task.sleep(for: .milliseconds(600))
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: ["missingCache", "readFailure", "incomplete", "ineligible"]) @MainActor
func uncertainBentoFocusVisibilityPreservesFullSweepRetry(failure: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 70,
        frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } && model.settlementTasks.isEmpty })
    try await Task.sleep(for: .milliseconds(300))
    let sweeps = system.completeSweepCount
    let writes = system.frameWriteCounts
    switch failure {
    case "missingCache": system.cachedSnapshotsAvailable = false
    case "readFailure": system.cachedRefreshFails = true
    case "incomplete": system.cachedVisibilityOmittedIDs = [peer]
    default: system.windows[1].isHidden = true
    }
    system.failedVisibleWindowSweeps = [sweeps + 1]
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: 42))
    try #require(await waitFor(timeout: .seconds(2)) { system.completeSweepCount >= sweeps + 1 })
    #expect(system.frameWriteCounts == writes)
    system.cachedSnapshotsAvailable = true
    system.cachedRefreshFails = false
    system.cachedVisibilityOmittedIDs.removeAll()
    system.windows[1].isHidden = false
    try #require(await waitFor(timeout: .seconds(2)) { system.completeSweepCount >= sweeps + 2 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.completeSweepCount == sweeps + 2)
    #expect(system.frameWriteCounts == writes)
}

@Test(arguments: ["wrongPID", "unmanaged", "manual", "unreadable"]) @MainActor
func unrelatedBentoFocusDoesNotReadPeers(focus: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    if focus != "manual" { model.setActiveMode(.bento) }
    try #require(await waitFor { model.settlementTasks.isEmpty })
    try await Task.sleep(for: .milliseconds(300))
    let sweeps = system.completeSweepCount
    let checks = system.cachedRefreshRequests.count
    let writes = system.frameWriteCounts
    system.focusedWindowReadFails = focus == "unreadable"
    system.eventHandler?(WindowSystemEvent(kind: .focused,
        windowID: focus == "unmanaged" ? WindowID(rawValue: "unmanaged") : nil,
        processIdentifier: focus == "wrongPID" ? 70 : 42))
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.cachedRefreshRequests.count == checks)
    #expect(system.completeSweepCount == sweeps)
    #expect(system.frameWriteCounts == writes)
}

@Test @MainActor func bentoFocusCheckExcludesFocusCoveredPeers() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let peer = WindowID(rawValue: "peer")
    system.windows.append(WindowSnapshot(id: peer, processIdentifier: 70,
        frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } && model.settlementTasks.isEmpty })
    system.focusedID = system.windows[0].id
    model.perform(.maximize)
    try #require(system.windows[1].isMinimized)
    try await Task.sleep(for: .milliseconds(400))
    let sweeps = system.completeSweepCount
    let writes = system.frameWriteCounts
    let checks = system.cachedRefreshRequests.count
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: 42))
    try #require(await waitFor(timeout: .seconds(2)) { system.cachedRefreshRequests.count > checks })
    try await Task.sleep(for: .milliseconds(300))
    #expect(Array(system.cachedRefreshRequests.dropFirst(checks)) == [Set([system.windows[0].id])])
    #expect(system.completeSweepCount == sweeps)
    #expect(system.frameWriteCounts == writes)
    #expect(system.windows[1].isMinimized)
}

@Test(arguments: ["gesture", "space"]) @MainActor
func bentoFocusCheckWaitsForDesktopInteraction(interaction: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "peer"), processIdentifier: 70,
        frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } && model.settlementTasks.isEmpty })
    try await Task.sleep(for: .milliseconds(300))
    let checks = system.cachedRefreshRequests.count
    if interaction == "gesture" {
        try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: system.windows[0].id))
    } else {
        model.beginActiveSpaceStabilization()
        try #require(model.isStabilizingSpace)
    }
    system.eventHandler?(WindowSystemEvent(kind: .focused, windowID: nil, processIdentifier: 42))
    try await Task.sleep(for: .milliseconds(40))
    #expect(system.cachedRefreshRequests.count == checks)
    if interaction == "gesture" {
        try await Task.sleep(for: .milliseconds(200))
        #expect(system.cachedRefreshRequests.count == checks)
        model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: system.windows[0].id, outcome: .restore)
    }
    #expect(await waitFor(timeout: .seconds(2)) { system.cachedRefreshRequests.count > checks })
    #expect(system.cachedRefreshRequests.last == Set(system.windows.map(\.id)))
}

/// A neighbour whose minimum is not yet measured clamps during a new
/// window's placement. The correction lands in the same pass, so the first
/// observable layout already has no overlap; it is not a later second jump.
@Test @MainActor func measuredClampIsCorrectedInTheSamePlacement() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    system.emitsFrameEvents = true
    let wide = WindowID(rawValue: "wide")
    system.windows.append(WindowSnapshot(id: wide, processIdentifier: 80, bundleIdentifier: "com.example.Wide",
        frame: BTRect(x: 0, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id))
    system.enforcedMinimumHeights[system.windows[0].id] = 560
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    try await Task.sleep(for: .milliseconds(400))
    let writes = system.frameWriteCounts.values.reduce(0, +)
    let arrival = WindowID(rawValue: "arrival")
    system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 81, bundleIdentifier: "com.example.Arrival",
        frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id))
    // The probe finds nothing for the arrival; the neighbour's height limit is unknown.
    system.focusedID = wide
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival, processIdentifier: 81))
    var firstObservation: [WindowID: BTRect] = [:]
    _ = await waitFor(timeout: .seconds(3)) {
        guard system.frameWriteCounts.values.reduce(0, +) > writes else { return false }
        firstObservation = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        return true
    }
    #expect(BentoLayoutVerifier.overlappingWindowIDs(firstObservation).isEmpty, "\(firstObservation)")
}

/// A clamp correction that fails, and whose rollback fails too, leaves the
/// windows in a mixed state. The placement reports that instead of success,
/// so automatic writes stop until the user repairs the layout.
@Test @MainActor func failedClampCorrectionWithAFailedRollbackIsNotASuccess() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    let wide = WindowID(rawValue: "wide")
    system.windows.append(WindowSnapshot(id: wide, processIdentifier: 80, bundleIdentifier: "com.example.Wide",
        frame: BTRect(x: 0, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    try await Task.sleep(for: .milliseconds(400))
    let arrival = WindowID(rawValue: "arrival")
    system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 81, bundleIdentifier: "com.example.Arrival",
        frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id))
    // The wide window refuses its new pane width, so the correction moves
    // both right-hand windows. The arrival moves first; the other window's
    // write fails, and so does the rollback of the arrival.
    system.enforcedMinimumWidths[wide] = 600
    for window in system.windows {
        let next = system.frameWriteCounts[window.id, default: 0] + (window.id == arrival ? 3 : 2)
        system.failedFrameWriteNumbers[window.id] = Set(next...(next + 20))
    }
    system.focusedID = wide
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival, processIdentifier: 81))
    let suspended = await waitFor(timeout: .seconds(3)) {
        model.statusMessage?.hasSuffix("Use Repair to rebuild Bento.") == true
    }
    #expect(suspended, "\(String(describing: model.statusMessage)) \(system.requestedFrames.mapValues { $0.map { "\($0.minX),\($0.minY) \($0.size.width)x\($0.size.height)" } })")
}

/// A clamp correction that fails, but whose rollback succeeds, keeps the
/// first placement. The placement still counts as committed, so no Repair is
/// requested and automatic writes continue: settlement corrects the clamp
/// later.
@Test @MainActor func failedClampCorrectionWithACleanRollbackKeepsTheFirstPlacement() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    let wide = WindowID(rawValue: "wide")
    system.windows.append(WindowSnapshot(id: wide, processIdentifier: 80, bundleIdentifier: "com.example.Wide",
        frame: BTRect(x: 0, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    try await Task.sleep(for: .milliseconds(400))
    let arrival = WindowID(rawValue: "arrival")
    system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 81, bundleIdentifier: "com.example.Arrival",
        frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: system.mainDisplay.id))
    // The wide window refuses its new pane width, so the correction moves
    // both right-hand windows. The arrival moves first; only the wide
    // window's correction write fails, so the arrival rolls back cleanly.
    system.enforcedMinimumWidths[wide] = 600
    let correction = system.frameWriteCounts[wide, default: 0] + 2
    system.failedFrameWriteNumbers[wide] = [correction]
    let arrivalWrites = system.requestedFrames[arrival]?.count ?? 0
    system.focusedID = wide
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival, processIdentifier: 81))
    // Placement, correction, then the rollback to the first placement.
    try #require(await waitFor(timeout: .seconds(3)) {
        (system.requestedFrames[arrival]?.count ?? 0) >= arrivalWrites + 3
    }, "\(system.requestedFrames.mapValues { $0.map { "\($0.minX),\($0.minY) \($0.size.width)x\($0.size.height)" } })")
    let requested = try #require(system.requestedFrames[arrival])
    let first = requested[arrivalWrites]
    #expect(requested[arrivalWrites + 1] != first)
    #expect(requested[arrivalWrites + 2] == first)
    let corrected = requested[arrivalWrites + 1]
    #expect(await waitFor(timeout: .seconds(3)) { system.windows.first { $0.id == arrival }?.frame == corrected })
    #expect(model.statusMessage?.contains("Use Repair") != true, "\(String(describing: model.statusMessage))")
}

/// A clamp correction can move a window that the first write left alone.
/// Undo must still return that window to its frame from before the action.
@Test @MainActor func undoRestoresAWindowThatOnlyTheClampCorrectionMoved() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    for name in ["top", "bottom"] {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: name == "top" ? 80 : 81,
            bundleIdentifier: "com.example.\(name)", frame: BTRect(x: 0, y: 0, width: 400, height: 300),
            displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { Set(system.windows.map(\.frame)).count == 3 && model.settlementTasks.isEmpty })
    try await Task.sleep(for: .milliseconds(400))
    let lead = try #require(system.windows.max { $0.frame.size.height < $1.frame.size.height })
    let before = lead.frame
    let narrow = try #require(system.windows.first { $0.id != lead.id })
    // A right-hand window now refuses its width; Repair rewrites the same
    // frames, the window clamps, and the correction narrows the lead pane.
    system.enforcedMinimumWidths[narrow.id] = narrow.frame.size.width + 150
    system.focusedID = lead.id
    model.tileCurrentDisplay()
    try #require(await waitFor(timeout: .seconds(3)) {
        (system.windows.first { $0.id == lead.id }?.frame.size.width ?? 0) < before.size.width - 100
    }, "\(system.windows.map(\.frame))")
    try await Task.sleep(for: .milliseconds(400))

    system.focusedID = lead.id
    model.perform(.restore)
    #expect(await waitFor(timeout: .seconds(2)) { system.windows.first { $0.id == lead.id }?.frame == before },
            "\(system.windows.map(\.frame)) \(String(describing: model.statusMessage))")
}

/// A clamp correction widens a neighbour beyond the frame first planned for
/// it. Settlement compares that neighbour with the frame finally written, so
/// its accepted width is not learned as a minimum.
@Test @MainActor func settlementAfterAClampCorrectionLearnsNoFalseMinimum() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    let wide = WindowID(rawValue: "wide")
    system.windows.append(WindowSnapshot(id: wide, processIdentifier: 80, bundleIdentifier: "com.example.Wide",
        frame: BTRect(x: 0, y: 0, width: 800, height: 800), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    try #require(await waitFor { system.windows.allSatisfy { $0.frame.size.height == 800 } })
    try await Task.sleep(for: .milliseconds(400))
    let focused = system.windows[0].id
    system.enforcedMinimumWidths[focused] = 600
    let arrival = WindowID(rawValue: "arrival")
    system.windows.append(WindowSnapshot(id: arrival, processIdentifier: 81, bundleIdentifier: "com.example.Arrival",
        frame: BTRect(x: 100, y: 100, width: 800, height: 300), displayID: system.mainDisplay.id))
    system.focusedID = focused
    system.eventHandler?(WindowSystemEvent(kind: .created, windowID: arrival, processIdentifier: 81))
    try #require(await waitFor { (system.windows.first { $0.id == focused }?.frame.size.width ?? 0) >= 599 })
    try await Task.sleep(for: .milliseconds(1000))
    let learned = system.windows.first { $0.id == arrival }?.constraints.minimumSize.width ?? 0
    #expect(learned < 590, "arrival learned a minimum width of \(learned): \(system.windows.map(\.frame))")
}

/// The re-solve after a drop can fail with a failed rollback too. The drop
/// then reports the mixed layout and asks for Repair; it does not restore
/// the drag over it, and automatic writes stop.
@Test @MainActor func aDegradedDropCorrectionAsksForRepairAndStopsWrites() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    for (index, name) in ["swap-b", "swap-c"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: Int32(43 + index),
            bundleIdentifier: "com.example.\(name)", frame: BTRect(x: 300 + Double(index) * 40, y: 300, width: 500, height: 400),
            displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    try #require(await waitFor {
        system.windows.contains { $0.frame.size.height > visible.size.height * 0.75 }
            && system.windows.filter { $0.frame.size.height < visible.size.height * 0.6 }.count == 2
    })
    try await Task.sleep(for: .milliseconds(400))
    let tall = try #require(system.windows.first { $0.frame.size.height > visible.size.height * 0.75 })
    let short = try #require(system.windows.first { $0.frame.size.height < visible.size.height * 0.6 })
    system.enforcedMinimumHeights[tall.id] = visible.size.height * 0.7
    // The drop's writes succeed. The correction moves "swap-c" first; the
    // next window's write fails, and so does the rollback of "swap-c".
    let corrected = WindowID(rawValue: "swap-c")
    for window in system.windows {
        let next = system.frameWriteCounts[window.id, default: 0] + (window.id == corrected ? 3 : 2)
        system.failedFrameWriteNumbers[window.id] = Set(next...(next + 20))
    }
    let before = system.frameWriteCounts
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: tall.id))
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: tall.id, outcome: .swap(targetWindowID: short.id))
    #expect(model.statusMessage?.hasSuffix("Use Repair to rebuild Bento.") == true, "\(model.statusMessage ?? "nil")")
    // The window the correction never touched got only the drop's write: the
    // drag was not restored over the mixed layout.
    let untouched = WindowID(rawValue: "swap-b")
    #expect(system.frameWriteCounts[untouched] == (before[untouched] ?? 0) + 1)
    // Automatic writes stay stopped for a later event.
    system.failedFrameWriteNumbers = [:]
    let writes = system.frameWriteCounts
    system.eventHandler?(WindowSystemEvent(kind: .moved, windowID: untouched, processIdentifier: 43))
    try await Task.sleep(for: .milliseconds(400))
    #expect(system.frameWriteCounts == writes)
}

/// A swap can put a window into a pane smaller than a minimum it never
/// reported. The drop's own write measures the refusal, and the layout is
/// solved again before the drop returns, so no overlap waits for settlement.
@Test @MainActor func dragSwapSolvesAgainWhenTheMovedWindowRefusesItsPane() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    for (index, name) in ["swap-b", "swap-c"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: Int32(43 + index),
            bundleIdentifier: "com.example.\(name)", frame: BTRect(x: 300 + Double(index) * 40, y: 300, width: 500, height: 400),
            displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    // Bento tiles the three windows: one full-height pane and two half-height ones.
    try #require(await waitFor {
        system.windows.contains { $0.frame.size.height > visible.size.height * 0.75 }
            && system.windows.filter { $0.frame.size.height < visible.size.height * 0.6 }.count == 2
    })
    let tall = try #require(system.windows.first { $0.frame.size.height > visible.size.height * 0.75 })
    let short = try #require(system.windows.first { $0.frame.size.height < visible.size.height * 0.6 })
    system.enforcedMinimumHeights[tall.id] = visible.size.height * 0.7
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: tall.id))
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: tall.id, outcome: .swap(targetWindowID: short.id))
    let frames = system.windows.map(\.frame)
    for (i, a) in frames.enumerated() {
        for b in frames.dropFirst(i + 1) {
            #expect((a.intersection(b)?.area ?? 0) < 1, "\(frames)")
        }
    }
    #expect(try #require(system.windows.first { $0.id == tall.id }).frame.size.height >= visible.size.height * 0.7)
}

/// A fixed-size window, such as Calculator, floats instead of joining Bento.
/// Otherwise every placement asks it for a frame it refuses, and Bento
/// retries a rejected layout forever.
@Test @MainActor func fixedSizeWindowFloatsInsteadOfBlockingBento() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let fixed = WindowID(rawValue: "calculator")
    system.windows.append(WindowSnapshot(id: fixed, processIdentifier: 77, bundleIdentifier: "com.apple.calculator",
        frame: BTRect(x: 500, y: 500, width: 230, height: 408), displayID: system.mainDisplay.id,
        constraints: WindowConstraints(isResizable: false)))
    let other = system.windows[0].id
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    // The resizable window is placed; the fixed one keeps its frame.
    #expect(await waitFor { system.frameWriteCounts[other, default: 0] > 0 })
    try await Task.sleep(for: .milliseconds(300))
    #expect(system.frameWriteCounts[fixed, default: 0] == 0)
    #expect(system.windows.first { $0.id == fixed }?.frame == BTRect(x: 500, y: 500, width: 230, height: 408))
    #expect(model.statusMessage == nil)
}

/// The drop's correction can move a window the swap left alone. Undo
/// returns that window to its frame from before the drag.
@Test @MainActor func undoAfterADropCorrectionRestoresAWindowOnlyTheCorrectionMoved() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.measuresOnWrite = true
    for (index, name) in ["swap-b", "swap-c"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: Int32(43 + index),
            bundleIdentifier: "com.example.\(name)", frame: BTRect(x: 300 + Double(index) * 40, y: 300, width: 500, height: 400),
            displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    try #require(await waitFor {
        system.windows.contains { $0.frame.size.height > visible.size.height * 0.75 }
            && system.windows.filter { $0.frame.size.height < visible.size.height * 0.6 }.count == 2
    })
    try await Task.sleep(for: .milliseconds(400))
    let tall = try #require(system.windows.first { $0.frame.size.height > visible.size.height * 0.75 })
    let short = try #require(system.windows.first { $0.frame.size.height < visible.size.height * 0.6 })
    let other = try #require(system.windows.first { $0.id != tall.id && $0.id != short.id })
    let before = other.frame
    system.enforcedMinimumHeights[tall.id] = visible.size.height * 0.7
    try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: tall.id))
    model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: tall.id, outcome: .swap(targetWindowID: short.id))
    try #require(system.windows.first { $0.id == other.id }?.frame != before, "the correction moved the third window")
    try await Task.sleep(for: .milliseconds(400))

    system.focusedID = other.id
    model.perform(.restore)
    #expect(await waitFor(timeout: .seconds(2)) { system.windows.first { $0.id == other.id }?.frame == before },
            "\(system.windows.map(\.frame)) \(String(describing: model.statusMessage))")
}

/// A user layout change makes every arrangement remembered at an earlier
/// minimize out of date. B leaves a 2x2 grid, the user rearranges the other
/// three, and C is minimized and restored. C must return to the user's
/// arrangement, not to the larger grid remembered when B left.
@Test(arguments: ["swap", "shortcut", "divider", "edgeResize"]) @MainActor
func restoringAWindowKeepsAUserChangeMadeAfterAnEarlierMinimize(change: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    system.emitsMinimizationEvents = true
    let (a, b, c, d) = (WindowID(rawValue: "a"), WindowID(rawValue: "b"), WindowID(rawValue: "c"), WindowID(rawValue: "d"))
    system.windows = [a, b, c, d].enumerated().map { index, id in
        WindowSnapshot(id: id, processIdentifier: Int32(60 + index), bundleIdentifier: "com.example.\(id.rawValue)",
            frame: BTRect(x: 100 + Double(index) * 20, y: 100, width: 400, height: 300),
            displayID: system.mainDisplay.id)
    }
    system.focusedID = a
    let model = makeModel(system: system)
    defer { model.shutdown() }
    func tiled(_ count: Int) -> Bool {
        let visible = system.windows.filter { !$0.isMinimized }
        return visible.count == count && Set(visible.map(\.frame)).count == count
            && visible.reduce(0) { $0 + $1.frame.area } > system.mainDisplay.visibleFrame.area * 0.99
    }
    func frames() -> [WindowID: BTRect] {
        Dictionary(uniqueKeysWithValues: system.windows.filter { !$0.isMinimized }.map { ($0.id, $0.frame) })
    }
    func settle() async throws {
        await model.windowEventTask?.value
        try #require(await waitFor { model.settlementTasks.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
    }
    model.setActiveMode(.bento)
    try #require(await waitFor { tiled(4) }, "\(frames())")
    try await settle()

    try system.setMinimized(true, for: b)
    try #require(await waitFor { tiled(3) }, "\(frames())")
    try await settle()
    let beforeChange = frames()

    switch change {
    case "swap":
        try #require(model.beginBentoDrag(displayID: system.mainDisplay.id, sourceID: a))
        model.finishBentoDrag(displayID: system.mainDisplay.id, sourceID: a, outcome: .swap(targetWindowID: d))
    case "shortcut":
        // A already fills the left half, so moving it right changes the layout.
        model.perform(.rightHalf)
    case "edgeResize":
        // A native resize of A's right edge, outside BetterTile, moves the
        // divider beside the C/D column. The first event ends BetterTile's
        // ownership of the frame it wrote, so the second one is the user's.
        let index = try #require(system.windows.firstIndex { $0.id == a })
        let event = WindowSystemEvent(kind: .resized, windowID: a,
                                      processIdentifier: system.windows[index].processIdentifier)
        system.eventHandler?(event)
        try await settle()
        system.windows[index].frame.size.width += 100
        system.eventHandler?(event)
    default:
        // Drag the divider between A and the C/D column 100 points right.
        let start = BTPoint(x: 500, y: 200)
        let presentation = model.dividerPresentation(windows: system.windows)
        model.dividerResize.refresh(boundaries: presentation.boundaries, obscuringFrames: [])
        let interaction = try #require(DividerInteractionResolver.resolve(
            at: start, in: presentation.boundaries, hitWidth: 18,
            adjacencyTolerance: 6, paneGap: model.configuration.bentoInnerGap
        ))
        let screen = try #require(NSScreen.screens.first)
        let release = CGPoint(x: start.x + 100, y: screen.frame.maxY - start.y)
        model.dividerResize.beginGesture(interaction: interaction, at: start)
        try #require(model.dividerResize.isDragging)
        model.dividerResize.drag(to: release)
        model.dividerResize.displayTick()
        model.dividerResize.end(at: release)
    }
    try #require(await waitFor { tiled(3) && frames() != beforeChange }, "\(frames())")
    try await settle()
    let changed = frames()

    try system.setMinimized(true, for: c)
    try #require(await waitFor { tiled(2) }, "\(frames())")
    try await settle()
    try system.setMinimized(false, for: c)
    try #require(await waitFor { tiled(3) }, "\(frames())")
    try await settle()
    #expect(frames() == changed, "before the change: \(beforeChange)")
}

/// A shortcut that cannot read the front window says why, so a hung front
/// application is named instead of reported as having no window.
@Test @MainActor func aShortcutNamesWhyItCouldNotReadTheFrontWindow() async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let before = system.windows.map(\.frame)
    system.focusedWindowReadFails = true
    model.perform(.leftHalf)
    #expect(model.statusMessage?.contains("Simulated focused-window failure") == true)
    #expect(system.windows.map(\.frame) == before)
    system.focusedWindowReadFails = false
    model.perform(.leftHalf)
    #expect(await waitFor { system.windows[0].frame != before[0] })
}

/// The ungated enhanced-accessibility restore can wait out a hung
/// application, so only shutdown makes it.
@Test @MainActor func shutdownMakesTheLastEnhancedAccessibilityRestore() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    #expect(system.quitRestoreCount == 0)
    model.shutdown()
    #expect(system.quitRestoreCount == 1)
}

/// The dragged window's center can cross to the neighbouring display while
/// the pointer stays on the Bento display. A drop lands on the Bento display,
/// a restore returns the window there, and a restore that fails leaves the
/// window away from its pane, so it is reported and asks for Repair.
@Test(arguments: ["swap", "restore", "restore-fails"]) @MainActor
func bentoDropLandsOnItsDisplayAfterTheSourceCenterCrossed(entry: String) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for (index, name) in ["swap-b", "swap-c"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: Int32(43 + index),
            bundleIdentifier: "com.example.\(name)", frame: BTRect(x: 300 + Double(index) * 40, y: 300, width: 500, height: 400),
            displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    try #require(await waitFor {
        system.windows.contains { $0.frame.size.height > visible.size.height * 0.75 }
            && system.windows.filter { $0.frame.size.height < visible.size.height * 0.6 }.count == 2
    })
    try await Task.sleep(for: .milliseconds(400))
    let second = DisplayID(rawValue: "second")
    system.availableDisplays.append(DisplaySnapshot(id: second,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)))
    let tall = try #require(system.windows.first { $0.frame.size.height > visible.size.height * 0.75 })
    let short = try #require(system.windows.first { $0.frame.size.height < visible.size.height * 0.6 })
    let main = system.mainDisplay.id
    try #require(model.beginBentoDrag(displayID: main, sourceID: tall.id))
    let index = try #require(system.windows.firstIndex { $0.id == tall.id })
    system.windows[index].frame.origin.x = 1050 - tall.frame.size.width / 2
    system.windows[index].displayID = second
    if entry == "restore-fails" {
        system.failedFrameWriteNumbers[tall.id] = [system.frameWriteCounts[tall.id, default: 0] + 1]
    }
    model.finishBentoDrag(displayID: main, sourceID: tall.id,
                          outcome: entry == "swap" ? .swap(targetWindowID: short.id) : .restore)
    let placed = try #require(system.windows.first { $0.id == tall.id })
    switch entry {
    case "swap":
        #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
        #expect(placed.frame.approximatelyEquals(short.frame, tolerance: 1), "\(placed.frame)")
        #expect(placed.displayID == main)
    case "restore":
        #expect(placed.frame == tall.frame)
        #expect(placed.displayID == main)
    default:
        #expect(placed.displayID == second)
        #expect(model.statusMessage?.hasPrefix("The dragged window could not return to its pane.") == true,
                "\(model.statusMessage ?? "nil")")
        #expect(model.statusMessage?.hasSuffix("Use Repair to rebuild Bento.") == true)
    }
}

/// Release commits the plan the overlay showed. A plan prepared by another
/// drag is not this drop: it fails with a reason and the window returns,
/// instead of a different arrangement being chosen.
@Test(arguments: [false, true]) @MainActor
func bentoReleaseCommitsOnlyThePlanItsOverlayShowed(stale: Bool) async throws {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for (index, name) in ["swap-b", "swap-c"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: Int32(43 + index),
            bundleIdentifier: "com.example.\(name)", frame: BTRect(x: 300 + Double(index) * 40, y: 300, width: 500, height: 400),
            displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    try #require(await waitFor {
        system.windows.contains { $0.frame.size.height > visible.size.height * 0.75 }
            && system.windows.filter { $0.frame.size.height < visible.size.height * 0.6 }.count == 2
    })
    try await Task.sleep(for: .milliseconds(400))
    let tall = try #require(system.windows.first { $0.frame.size.height > visible.size.height * 0.75 })
    let short = try #require(system.windows.first { $0.frame.size.height < visible.size.height * 0.6 })
    let main = system.mainDisplay.id
    try #require(model.beginBentoDrag(displayID: main, sourceID: tall.id))
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: tall.id,
                                                          outcome: .swap(targetWindowID: short.id)) else {
        Issue.record("Expected a swap plan"); return
    }
    if stale {
        model.finishBentoDrag(displayID: main, sourceID: tall.id, end: .restore)
        try #require(model.beginBentoDrag(displayID: main, sourceID: tall.id))
    }
    let index = try #require(system.windows.firstIndex { $0.id == tall.id })
    system.windows[index].frame.origin.x += 40
    let writes = system.frameWriteCounts
    model.finishBentoDrag(displayID: main, sourceID: tall.id, end: .commit(plan))
    if stale {
        #expect(model.statusMessage?.hasPrefix("The layout changed during the drag.") == true, "\(model.statusMessage ?? "nil")")
        #expect(system.windows.first { $0.id == tall.id }?.frame == tall.frame)
        // Only the dragged window was written: it returned to its pane.
        #expect(system.windows.filter { system.frameWriteCounts[$0.id] != writes[$0.id] }.map(\.id) == [tall.id])
    } else {
        #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
        for placement in plan.placements {
            #expect(system.windows.first { $0.id == placement.windowID }?.frame == placement.frame)
        }
    }
}

/// Three windows tiled by Bento: one full-height pane and two half-height ones.
@MainActor private func tiledBentoTrio() async throws -> (FakeAppWindowSystem, BetterTileModel, WindowSnapshot, WindowSnapshot) {
    _ = NSApplication.shared
    let system = FakeAppWindowSystem()
    for (index, name) in ["swap-b", "swap-c"].enumerated() {
        system.windows.append(WindowSnapshot(id: WindowID(rawValue: name), processIdentifier: Int32(43 + index),
            bundleIdentifier: "com.example.\(name)", frame: BTRect(x: 300 + Double(index) * 40, y: 300, width: 500, height: 400),
            displayID: system.mainDisplay.id))
    }
    let model = makeModel(system: system)
    model.setActiveMode(.bento)
    let visible = system.mainDisplay.visibleFrame
    try #require(await waitFor {
        system.windows.contains { $0.frame.size.height > visible.size.height * 0.75 }
            && system.windows.filter { $0.frame.size.height < visible.size.height * 0.6 }.count == 2
    })
    try await Task.sleep(for: .milliseconds(400))
    let tall = try #require(system.windows.first { $0.frame.size.height > visible.size.height * 0.75 })
    let short = try #require(system.windows.first { $0.frame.size.height < visible.size.height * 0.6 })
    return (system, model, tall, short)
}

/// A plan the overlay showed before the layout changed under the drag, such
/// as a partition shortcut run while the button is held, writes nothing. The
/// dragged window takes its slot in the current layout, no other window is
/// written, and the pill says the layout changed.
/// A release over nothing after the change also puts the window in its
/// current slot, without a pill.
@Test(arguments: ["commit", "restore"]) @MainActor
func aStaleBentoPlanWritesNothingButTheDraggedWindowsReturn(end: String) async throws {
    let (system, model, tall, short) = try await tiledBentoTrio()
    defer { model.shutdown() }
    let main = system.mainDisplay.id
    try #require(model.beginBentoDrag(displayID: main, sourceID: tall.id))
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: tall.id,
                                                          outcome: .swap(targetWindowID: short.id)) else {
        Issue.record("Expected a swap plan"); return
    }
    // The shortcut acts on the dragged window, as when the user presses it
    // during the drag.
    system.focusedID = tall.id
    let tallIsLeft = tall.frame.minX < system.mainDisplay.visibleFrame.midX
    model.perform(tallIsLeft ? .rightHalf : .leftHalf)
    let index = try #require(system.windows.firstIndex { $0.id == tall.id })
    let slot = system.windows[index].frame
    try #require(slot != tall.frame)
    let writes = system.frameWriteCounts, frames = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    // macOS keeps moving the window with the pointer until release.
    system.windows[index].frame.origin.x += 140
    model.finishBentoDrag(displayID: main, sourceID: tall.id, end: end == "commit" ? .commit(plan) : .restore)
    if end == "commit" {
        #expect(model.statusMessage?.hasPrefix("The layout changed during the drag.") == true, "\(model.statusMessage ?? "nil")")
    }
    #expect(system.windows[index].frame == slot)
    for window in system.windows where window.id != tall.id {
        #expect(system.frameWriteCounts[window.id] == writes[window.id])
        #expect(window.frame == frames[window.id])
    }
    // Settlement keeps the window in its slot.
    try await Task.sleep(for: .milliseconds(600))
    #expect(system.windows[index].frame == slot)
}

/// A Bento drop commits with the minimum sizes its overlay planned with. A
/// larger minimum read at release cannot veto it.
@Test @MainActor func aBentoDropIsNotVetoedByAMinimumReadAtRelease() async throws {
    let (system, model, tall, short) = try await tiledBentoTrio()
    defer { model.shutdown() }
    let main = system.mainDisplay.id
    try #require(model.beginBentoDrag(displayID: main, sourceID: tall.id))
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: tall.id,
                                                          outcome: .swap(targetWindowID: short.id)) else {
        Issue.record("Expected a swap plan"); return
    }
    let index = try #require(system.windows.firstIndex { $0.id == tall.id })
    system.windows[index].constraints.minimumSize.height = 700
    model.finishBentoDrag(displayID: main, sourceID: tall.id, end: .commit(plan))
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
    for placement in plan.placements {
        #expect(system.windows.first { $0.id == placement.windowID }?.frame == placement.frame)
    }
}

/// A floating window in a Bento desktop that is released or cancelled
/// without a drop stays floating where it is. Only a drop the overlay showed
/// adds it to the layout.
@Test @MainActor func aFloatingBentoWindowReleasedWithoutADropStaysWhereItIs() async throws {
    let (system, model, _, _) = try await tiledBentoTrio()
    defer { model.shutdown() }
    let main = system.mainDisplay.id
    let floating = WindowID(rawValue: "floating")
    system.windows.append(WindowSnapshot(id: floating, processIdentifier: 77, bundleIdentifier: "com.example.floating",
        frame: BTRect(x: 120, y: 140, width: 300, height: 200), displayID: main))
    try #require(model.beginBentoDrag(displayID: main, sourceID: floating))
    let index = try #require(system.windows.firstIndex { $0.id == floating })
    system.windows[index].frame.origin.x += 60
    let dropped = system.windows[index].frame
    let writes = system.frameWriteCounts
    model.finishBentoDrag(displayID: main, sourceID: floating, end: .restore)
    #expect(system.windows[index].frame == dropped)
    #expect(system.frameWriteCounts == writes)
}

/// Release over invalid feedback for a tiled Bento window applies nothing:
/// the window returns to its slot and the reason is reported.
@Test @MainActor func aFailedBentoDropReturnsATiledWindowToItsSlot() async throws {
    let (system, model, tall, _) = try await tiledBentoTrio()
    defer { model.shutdown() }
    let main = system.mainDisplay.id
    try #require(model.beginBentoDrag(displayID: main, sourceID: tall.id))
    let index = try #require(system.windows.firstIndex { $0.id == tall.id })
    system.windows[index].frame.origin.x += 140
    let others = system.windows.filter { $0.id != tall.id }
    model.finishBentoDrag(displayID: main, sourceID: tall.id, end: .failed(reason: "Peers cannot fit."))
    #expect(model.statusMessage == "Peers cannot fit.")
    #expect(system.windows[index].frame == tall.frame)
    for window in others { #expect(system.windows.first { $0.id == window.id }?.frame == window.frame) }
}

/// A Focus mode drop lands on the display the overlay showed it on, even
/// when the dragged window's center crossed to the other display.
@Test @MainActor func aFocusDropLandsOnItsDisplayAfterTheSourceCenterCrossed() async throws {
    let (system, model, tall, short) = try await tiledBentoTrio()
    defer { model.shutdown() }
    let main = system.mainDisplay.id, second = DisplayID(rawValue: "second")
    system.availableDisplays.append(DisplaySnapshot(id: second,
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)))
    try #require(model.beginBentoDrag(displayID: main, sourceID: tall.id))
    let visible = system.mainDisplay.visibleFrame
    guard case let .ready(plan)? = model.previewBentoDrag(displayID: main, sourceID: tall.id,
                                                          outcome: .snap(action: .maximize, frame: visible)),
          let focus = plan.bentoPlan, focus.isFocusDrop else {
        Issue.record("Expected a Focus mode plan"); return
    }
    let index = try #require(system.windows.firstIndex { $0.id == tall.id })
    system.windows[index].frame.origin.x = 1050 - tall.frame.size.width / 2
    system.windows[index].displayID = second
    model.finishBentoDrag(displayID: main, sourceID: tall.id, end: .commit(plan))
    #expect(model.statusMessage == nil, "\(model.statusMessage ?? "")")
    #expect(system.windows[index].frame == focus.placements.first?.frame)
    #expect(system.windows[index].displayID == main)
    #expect(system.windows.first { $0.id == short.id }?.isMinimized == true)
}
