import AppKit
import BetterTileCore
import Testing
@testable import BetterTileApp

@MainActor private func displayTransferFixture(
    count: Int = 2, destinationCount: Int = 2, sourceCount: Int = 2, minimumSize: BTSize = BTSize(width: 120, height: 80),
    stacked: Bool = false, drivingPolicyDeadlines: Bool = false
) async throws -> (FakeAppWindowSystem, BetterTileModel) {
    _ = NSApplication.shared
    let system = makeManualWindowSystem(drivingPolicyDeadlines: drivingPolicyDeadlines)
    system.availableDisplays = (0..<count).map { index in
        let frame = BTRect(x: stacked ? -800 : Double(index) * 2560, y: stacked ? Double(index - 1) * 1440 : 0, width: index == 2 ? 1920 : 2560, height: index == 2 ? 1080 : 1440)
        return DisplaySnapshot(id: DisplayID(rawValue: "display-\(index)"), frame: frame,
            visibleFrame: BTRect(x: frame.minX, y: frame.minY + 30, width: frame.size.width, height: frame.size.height - (index == 0 ? 110 : 30)),
            scaleFactor: index == 0 ? 2 : 1, isMain: index == 0)
    }
    system.windows = system.availableDisplays.enumerated().flatMap { index, display in
        let panes = index == 1 ? destinationCount : (index == 0 ? sourceCount : 2)
        return (0..<panes).map { pane in
            WindowSnapshot(id: WindowID(rawValue: "window-\(index)-\(pane)"),
                processIdentifier: Int32(42 + index * 2 + pane),
                frame: BTRect(x: display.visibleFrame.minX + Double(pane) * display.visibleFrame.size.width / Double(panes), y: display.visibleFrame.minY,
                              width: display.visibleFrame.size.width / Double(panes), height: display.visibleFrame.size.height), displayID: display.id,
                constraints: WindowConstraints(minimumSize: minimumSize, minimumSizeSource: .hint))
        }
    }
    system.focusedID = system.windows[0].id
    let model = makeModel(system: system)
    model.configuration.defaultLayoutMode = .bento
    model.configuration.bentoInnerGap = 0
    model.setActiveMode(.bento)
    try #require(system.availableDisplays.allSatisfy { model.activeMode(for: $0.id) == .bento })
    await system.advance(by: .milliseconds(350))
    system.requestedFrames = [:]
    system.frameWriteCounts = [:]
    return (system, model)
}

@Test(.appTestApplication, arguments: [LayoutMode.manual, .tabbed]) @MainActor
func bentoDisplayTransferClosesTheSourceForNativeAndKeepsTabbedBehavior(mode: LayoutMode) async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    system.focusedID = system.windows[2].id
    model.setActiveMode(mode)
    if mode == .tabbed {
        try #require(await system.waitFor { model.activeTabbedState?.windowIDs.count == 2 })
    }
    await system.advance(by: .milliseconds(350))
    system.focusedID = system.windows[0].id
    let before = system.windows
    let expected = StandardActionEngine().transferFrame(before[0].frame,
        from: system.availableDisplays[0], to: system.availableDisplays[1])
    model.perform(.nextDisplay)
    #expect(system.windows[0].frame == expected)
    #expect(model.activeMode(for: system.availableDisplays[1].id) == mode)
    for peer in before.dropFirst() {
        let expectedPeer = mode == .manual && peer.displayID == before[0].displayID
            ? system.availableDisplays[0].visibleFrame : peer.frame
        #expect(system.windows.first { $0.id == peer.id }?.frame == expectedPeer)
    }
}

@Test(.appTestApplication, arguments: ["mode", "workArea"]) @MainActor
func bentoDisplayTransferRetryKeepsBothDesktopOwners(change: String) async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    system.frameReadbackTransform = { _, requested in
        var actual = requested
        actual.size.height -= 3
        return actual
    }
    let source = system.availableDisplays[0], destination = system.availableDisplays[1]
    model.perform(.nextDisplay)
    let sampling = try #require(model.settlementTasks[destination.id])
    await system.joinSettlement(sampling, on: model)
    let retry = try #require(model.settlementTasks[destination.id])
    let writes = system.frameWriteCounts
    if change == "mode" {
        system.focusedID = system.windows[1].id
        model.setActiveMode(.manual)
        try #require(model.activeMode(for: source.id) == .manual)
    } else {
        system.availableDisplays[0].visibleFrame.size.height -= 50
    }
    await system.joinSettlement(retry, on: model)
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication, arguments: [WindowAction.center, nil]) @MainActor
func bentoDisplayTransferHonorsSingleWindowPlacementOnBothDisplays(singlePlacement: WindowAction?) async throws {
    let (system, model) = try await displayTransferFixture(destinationCount: 0)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = singlePlacement
    let source = system.availableDisplays[0], destination = system.availableDisplays[1]
    let peer = system.windows[1]
    var moved = system.windows[0]
    moved.frame = StandardActionEngine().transferFrame(moved.frame, from: source, to: destination)
    moved.displayID = destination.id
    let expectedSource = singlePlacement.flatMap {
        StandardActionEngine().targetFrame(for: $0, window: peer, display: source)
    } ?? peer.frame
    let expectedDestination = singlePlacement.flatMap {
        StandardActionEngine().targetFrame(for: $0, window: moved, display: destination)
    } ?? moved.frame
    model.perform(.nextDisplay)
    #expect(system.windows[0].frame == expectedDestination)
    #expect(system.windows[1].frame == expectedSource)
}

@Test(.appTestApplication, arguments: [2, 6]) @MainActor
func bentoDisplayTransferDoesNotRefitSourceUntilTheWindowHasLeft(destinationCount: Int) async throws {
    let (system, model) = try await displayTransferFixture(destinationCount: destinationCount)
    defer { model.shutdown() }
    let before = system.windows
    system.ignoredFrameWriteWindowIDs = [before[0].id]
    model.perform(.nextDisplay)
    #expect(model.statusMessage != nil)
    #expect(system.requestedFrames[before[1].id] == nil)
    #expect(system.windows == before)
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func bentoDisplayTransferFloatsWhenDestinationCannotAddAPane(full: Bool) async throws {
    let (system, model) = try await displayTransferFixture(destinationCount: full ? 6 : 2,
        minimumSize: full ? BTSize(width: 120, height: 80) : BTSize(width: 1200, height: 1000))
    defer { model.shutdown() }
    let moved = system.windows[0], destination = system.availableDisplays[1]
    let peers = system.windows.filter { $0.displayID == destination.id }
    model.perform(.nextDisplay)
    let sourceState = try #require(model.dividerResize.bentoStateProvider?(moved.displayID))
    let destinationState = try #require(model.dividerResize.bentoStateProvider?(destination.id))
    #expect(sourceState.root?.windowIDs.contains(moved.id) != true)
    #expect(destinationState.floatingWindowIDs.contains(moved.id))
    #expect(destinationState.root?.windowIDs.count == peers.count)
    #expect(system.windows.first { $0.id == moved.id }?.displayID == destination.id)
    #expect(model.statusMessage?.contains("floating") == true)
    for peer in peers { #expect(system.windows.first { $0.id == peer.id }?.frame.approximatelyEquals(peer.frame) == true) }
    #expect(system.windows[1].frame == system.availableDisplays[0].visibleFrame)
    let floatingMessage = model.statusMessage
    for _ in 0..<4 {
        let tasks = Array(model.settlementTasks.values)
        if tasks.isEmpty { break }
        for task in tasks { await system.joinSettlement(task, on: model) }
    }
    #expect(model.settlementTasks.isEmpty)
    #expect(model.statusMessage == floatingMessage)
    #expect(model.statusMessage?.contains("floating") == true)
    model.watchdog()
    #expect(model.dividerResize.bentoStateProvider?(destination.id)?.floatingWindowIDs.contains(moved.id) == true)
}

@Test(.appTestApplication, arguments: ["destination", "moving", "source"]) @MainActor
func bentoDisplayTransferRollsBackBothLayoutsOnWriteFailure(failure: String) async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    let before = system.windows
    let states = system.availableDisplays.map { model.dividerResize.bentoStateProvider?($0.id) }
    let failingID = failure == "moving" ? before[0].id : failure == "source" ? before[1].id : before[2].id
    system.failedFrameWriteNumbers[failingID] = [1]
    model.perform(.nextDisplay)
    #expect(model.statusMessage?.contains("Injected frame write failure") == true)
    #expect(system.windows == before)
    #expect(system.availableDisplays.map { model.dividerResize.bentoStateProvider?($0.id) } == states)
    if failure == "destination" { #expect(system.requestedFrames[before[0].id] == nil) }
}

@Test(.appTestApplication) @MainActor func bentoDisplayTransferWaitsForDestinationWritesToBeAccepted() async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    let moved = system.windows[0].id
    let neighbours = Set(system.windows.dropFirst(2).map(\.id))
    var accepted: Set<WindowID> = []
    system.onFrameWrite = { id, _ in
        if id == moved { #expect(accepted == neighbours) }
        if neighbours.contains(id) { accepted.insert(id) }
    }
    model.perform(.nextDisplay)
    #expect(model.statusMessage == nil)
    #expect(system.windows[0].displayID == system.availableDisplays[1].id)
}

@Test(.appTestApplication, arguments: ["neighbour-grid", "moved-grid", "neighbour-delay"]) @MainActor
func bentoDisplayTransferAcceptsSizesThatHaveNotSettled(application: String) async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    let moved = system.windows[0].id
    let neighbour = system.windows[2].id
    if application == "neighbour-delay" {
        system.frameApplicationDelays[neighbour] = .milliseconds(30)
    } else {
        system.sizeGrids[application == "moved-grid" ? moved : neighbour] = (
            BTSize(width: 7, height: 15), BTSize(width: 0, height: 0))
    }
    model.perform(.nextDisplay)
    #expect(model.statusMessage == nil)
    #expect(model.dividerResize.bentoStateProvider?(system.availableDisplays[1].id)?.root?.windowIDs.contains(moved) == true)
    #expect(system.windows[1].frame == system.availableDisplays[0].visibleFrame)
    await system.advance(by: .milliseconds(60))
    #expect(system.windows[0].displayID == system.availableDisplays[1].id)
}

@Test(.appTestApplication, arguments: [2, 6]) @MainActor
func bentoDisplayTransferRollsBackALateWriteAfterPositionCheckFails(destinationCount: Int) async throws {
    let (system, model) = try await displayTransferFixture(destinationCount: destinationCount)
    defer { model.shutdown() }
    let before = system.windows
    system.frameApplicationDelays[before[0].id] = .milliseconds(30)
    model.perform(.nextDisplay)
    #expect(model.statusMessage?.contains("did not move") == true)
    #expect(system.requestedFrames[before[0].id]?.last == before[0].frame)
    #expect(system.requestedFrames[before[1].id] == nil)
    for task in system.delayedFrameWrites { await system.join(task) }
    #expect(system.windows == before)
}

@Test(.appTestApplication) @MainActor func bentoDisplayTransferSuspendsBothDesktopsIfRollbackFails() async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    let moved = system.windows[0].id
    system.failedFrameWriteNumbers[system.windows[1].id] = [1]
    system.failedFrameWriteNumbers[moved] = [2]
    model.perform(.nextDisplay)
    #expect(model.statusMessage?.contains("Repair") == true)
    let writes = system.frameWriteCounts
    model.watchdog()
    #expect(system.frameWriteCounts == writes)
}

@Test(.appTestApplication) @MainActor func layoutWheelDisplayTransferUsesTheSameBentoTransaction() async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    let moved = system.windows[0], target = try #require(model.captureLayoutWheelTarget())
    model.performLayoutWheel(.windowAction(.nextDisplay), for: target)
    #expect(model.dividerResize.bentoStateProvider?(system.availableDisplays[1].id)?.root?.windowIDs.contains(moved.id) == true)
    #expect(system.windows[1].frame == system.availableDisplays[0].visibleFrame)
    await system.advance(by: .milliseconds(500))
    #expect(model.statusMessage == nil)
}

@Test(.appTestApplication, arguments: [2, 3], [WindowAction.nextDisplay, .previousDisplay]) @MainActor
func bentoDisplayTransferPlansBothLayoutsBeforeWriting(displayCount: Int, action: WindowAction) async throws {
    let (system, model) = try await displayTransferFixture(count: displayCount)
    defer { model.shutdown() }
    // Previous wraps from the first display to the last; next visits each
    // pair and wraps back. A third display must keep its layout and frames.
    for sourceIndex in 0..<displayCount {
        let destinationIndex = (sourceIndex + (action == .nextDisplay ? 1 : displayCount - 1)) % displayCount
        let source = system.availableDisplays[sourceIndex], destination = system.availableDisplays[destinationIndex]
        let moved = try #require(system.windows.first { $0.displayID == source.id })
        system.focusedID = moved.id
        let before = system.windows
        let sourcePeers = before.filter { $0.displayID == source.id && $0.id != moved.id }
        let destinationPeers = before.filter { $0.displayID == destination.id }
        var overlappingWrites: [BTRect] = []
        system.onFrameWrite = { id, frame in
            if id == moved.id, frame.intersection(destination.visibleFrame) != nil,
               system.windows.contains(where: { peer in
                   destinationPeers.contains { $0.id == peer.id } && peer.frame.intersection(frame) != nil
               }) { overlappingWrites.append(frame) }
        }
        model.perform(action)
        system.onFrameWrite = nil

        #expect(overlappingWrites.isEmpty, "The moved window was written over a destination neighbour: \(overlappingWrites)")
        let sourceState = try #require(model.dividerResize.bentoStateProvider?(source.id))
        let destinationState = try #require(model.dividerResize.bentoStateProvider?(destination.id))
        #expect(sourceState.root?.windowIDs.contains(moved.id) != true, "Source membership must commit in the command")
        #expect(destinationState.root?.windowIDs.contains(moved.id) == true, "Destination membership must commit in the command")
        #expect(system.windows.first { $0.id == moved.id }?.displayID == destination.id)
        for display in [source, destination] {
            let windows = system.windows.filter { $0.displayID == display.id }
            #expect(windows.allSatisfy { PlacementBounds.isContained($0.frame, in: display.visibleFrame) })
            for first in windows.indices {
                for second in windows.indices where first < second {
                    #expect(windows[first].frame.intersection(windows[second].frame) == nil,
                            "Destination re-layout must finish in the command")
                }
            }
        }
        if sourcePeers.count == 1 {
            #expect(system.windows.first { $0.id == sourcePeers[0].id }?.frame == source.visibleFrame,
                    "The source gap must close in the command")
        }
        for untouched in before where untouched.displayID != source.id && untouched.displayID != destination.id {
            #expect(system.windows.first { $0.id == untouched.id } == untouched)
        }
    }
}

@Test(.appTestApplication) @MainActor func nativeDisplayTransferInsertsIntoTheBentoDestination() async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    model.setActiveMode(.manual)
    await system.advance(by: .milliseconds(350))
    let sourcePeer = system.windows[1]
    let moved = system.windows[0].id
    model.perform(.nextDisplay)
    #expect(model.statusMessage == nil)
    let destination = system.availableDisplays[1]
    #expect(model.dividerResize.bentoStateProvider?(destination.id)?.root?.windowIDs.contains(moved) == true)
    #expect(system.windows[1] == sourcePeer)
    let arrivals = system.windows.filter { $0.displayID == destination.id }
    for first in arrivals.indices {
        for second in arrivals.indices where first < second {
            #expect(arrivals[first].frame.intersection(arrivals[second].frame) == nil)
        }
    }
}

@Test(.appTestApplication, arguments: [false, true]) @MainActor
func bentoDisplayTransferLeavesFocusModePeersMinimized(focusOnDestination: Bool) async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    let focusIndex = focusOnDestination ? 2 : 0
    system.focusedID = system.windows[focusIndex].id
    model.perform(.maximize)
    let covered = system.windows[focusIndex + 1].id
    try #require(system.windows[focusIndex + 1].isMinimized)
    await system.advance(by: .milliseconds(350))
    system.requestedFrames = [:]
    system.focusedID = system.windows[0].id
    model.perform(.nextDisplay)
    #expect(model.statusMessage == nil)
    #expect(system.requestedFrames[covered] == nil)
    #expect(system.windows[focusIndex + 1].isMinimized)
    #expect(system.windows[0].displayID == system.availableDisplays[1].id)
}

@Test(.appTestApplication, arguments: [WindowAction.nextDisplay, .previousDisplay]) @MainActor
func bentoDisplayTransferHandlesStackedNegativeOriginDisplays(action: WindowAction) async throws {
    let (system, model) = try await displayTransferFixture(count: 3, stacked: true)
    defer { model.shutdown() }
    let target = try #require(model.captureLayoutWheelTarget())
    guard case let .ready(preview) = model.previewLayoutWheel(.windowAction(action), for: target) else {
        Issue.record("Expected a transfer preview"); return
    }
    let moved = system.windows[0].id
    model.performLayoutWheel(.windowAction(action), for: target)
    #expect(model.statusMessage == nil)
    let destination = system.availableDisplays[action == .nextDisplay ? 1 : 2]
    #expect(system.windows[0].displayID == destination.id)
    #expect(preview.first { $0.windowID == moved }?.frame == system.windows[0].frame)
    let peers = system.windows.filter { $0.displayID == destination.id }
    #expect(peers.allSatisfy { PlacementBounds.isContained($0.frame, in: destination.visibleFrame) })
    for first in peers.indices {
        for second in peers.indices where first < second {
            #expect(peers[first].frame.intersection(peers[second].frame) == nil)
        }
    }
    #expect(system.windows[1].frame == system.availableDisplays[0].visibleFrame)
}

@Test(.appTestApplication) @MainActor func bentoDisplayTransferKeepsTheExistingFullscreenDestinationPath() async throws {
    let (system, model) = try await displayTransferFixture()
    defer { model.shutdown() }
    let destination = system.availableDisplays[1]
    let fullscreen = NativeSpaceID(rawValue: 99)
    system.desktopObservation = NativeDesktopObservation(
        currentSpaceByDisplay: [destination.id: fullscreen],
        knownSpacesByDisplay: [destination.id: [fullscreen]],
        fullscreenSpaceIDs: [fullscreen])
    let before = system.windows
    let expected = StandardActionEngine().transferFrame(before[0].frame,
        from: system.availableDisplays[0], to: destination)
    model.perform(.nextDisplay)
    #expect(model.statusMessage == nil)
    #expect(system.windows[0].frame == expected)
    for peer in before.dropFirst() {
        #expect(system.windows.first { $0.id == peer.id } == peer)
    }
}

@Test(.appTestApplication) @MainActor
func displayTransferMinimumCorrectionKeepsTheOtherDisplayRetryOwned() async throws {
    let (system, model) = try await displayTransferFixture(sourceCount: 3)
    defer { model.shutdown() }
    let source = system.availableDisplays[0], destination = system.availableDisplays[1]
    system.measuresOnWrite = true
    let moved = system.windows[0].id
    let peer = try #require(system.windows.first { $0.displayID == source.id && $0.id != moved }?.id)
    let destinationPeer = try #require(system.windows.first { $0.displayID == destination.id }?.id)
    system.onFrameWrite = { id, frame in
        guard id == peer, system.frameWriteCounts[id] == 1 else { return }
        guard let index = system.windows.firstIndex(where: { $0.id == id }) else { return }
        // The adapter learns this application's minimum from the write readback.
        if frame.size.height < source.visibleFrame.size.height - 100 {
            system.enforcedMinimumHeights[id] = frame.size.height + 100
            system.windows[index].constraints.minimumSize.height = frame.size.height + 100
        } else {
            system.enforcedMinimumWidths[id] = frame.size.width + 100
            system.windows[index].constraints.minimumSize.width = frame.size.width + 100
        }
    }
    system.frameReadbackTransform = { id, frame in
        guard id == destinationPeer else { return frame }
        var unsettled = frame
        unsettled.size.height -= 3
        return unsettled
    }
    model.perform(.nextDisplay)
    for _ in 0..<6 {
        let tasks = Array(model.settlementTasks.values)
        if tasks.isEmpty { break }
        for task in tasks { await system.joinSettlement(task, on: model) }
    }
    #expect(system.frameWriteCounts[peer, default: 0] > 1, "The source must commit its learned-minimum correction")
    #expect(system.frameWriteCounts[destinationPeer, default: 0] == 3, "The other display must complete its two-retry verification budget")
    #expect(model.settlementTasks.isEmpty)
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func bentoDisplayTransferRetriesALoneAuthoritativeParticipant(destinationIsLone: Bool) async throws {
    let (system, model) = try await displayTransferFixture(destinationCount: destinationIsLone ? 0 : 2, drivingPolicyDeadlines: true)
    defer { model.shutdown() }
    model.configuration.singleWindowPlacement = .maximize
    let participant = system.windows[destinationIsLone ? 0 : 1]
    if destinationIsLone {
        system.frameReadbackTransform = { id, frame in
            guard id == participant.id, system.frameWriteCounts[id] == 1 else { return frame }
            var actual = frame
            actual.size = participant.frame.size // Origin lands, but the application ignores the new size.
            return actual
        }
    } else {
        system.ignoredFrameWriteWindowIDs = [participant.id]
    }
    model.perform(.nextDisplay)
    let expected = try #require(system.requestedFrames[participant.id]?.last)
    try #require(system.windows.first { $0.id == participant.id }?.frame != expected)
    system.ignoredFrameWriteWindowIDs = []
    system.frameReadbackTransform = nil
    for _ in 0..<6 {
        let tasks = Array(model.settlementTasks.values)
        if tasks.isEmpty { break }
        for task in tasks { await system.joinSettlement(task, on: model) }
    }
    #expect(model.settlementTasks.isEmpty)
    #expect(system.frameWriteCounts[participant.id] == 2)
    #expect(system.windows.first { $0.id == participant.id }?.frame == expected)
    #expect(model.statusMessage == nil)
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: ["correction", "retry"]) @MainActor
func bentoDisplayTransferSettlementDegradationSuspendsBothCapturedOwners(stage: String) async throws {
    let (system, model) = try await displayTransferFixture(drivingPolicyDeadlines: true)
    defer { system.onFrameWrite = nil; model.shutdown() }
    let store = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    let owners = try system.availableDisplays.map { display in try #require(store.session(for: display.id)) }
    let destination = system.availableDisplays[1]
    model.perform(.nextDisplay)
    let initialWrites = system.frameWriteCounts
    // Disturb only destination readback after the initial transaction succeeds.
    // The correction variant also reports a proven minimum that requires a solve.
    for index in system.windows.indices where system.windows[index].displayID == destination.id {
        system.windows[index].frame.size.height -= 3
    }
    if stage == "correction" {
        let index = try #require(system.windows.firstIndex {
            $0.displayID == destination.id && $0.frame.size.width < destination.visibleFrame.size.width - 100
        })
        system.windows[index].frame.size.width += 100
        system.windows[index].constraints.minimumSize.width = system.windows[index].frame.size.width
    }
    var firstWrite: WindowID?
    var injected = false
    system.onFrameWrite = { id, _ in
        guard system.windows.first(where: { $0.id == id })?.displayID == destination.id,
              system.frameWriteCounts[id, default: 0] > initialWrites[id, default: 0] else { return }
        if firstWrite == nil {
            firstWrite = id
            // The first forward write succeeds, but cannot be rolled back.
            system.failedFrameWriteNumbers[id, default: []].insert(system.frameWriteCounts[id, default: 0] + 1)
        } else if !injected, id != firstWrite {
            injected = true
            system.failedFrameWriteNumbers[id, default: []].insert(system.frameWriteCounts[id, default: 0])
        }
    }
    for _ in 0..<6 {
        let tasks = Array(model.settlementTasks.values)
        if tasks.isEmpty { break }
        for task in tasks { await system.joinSettlement(task, on: model) }
    }
    try #require(injected, "The failure must happen in settlement after a successful transfer")
    let sessions = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    for owner in owners {
        #expect(sessions.allSessions(for: owner.displayID).first { $0.id == owner.id }?.automaticWritesSuspended == true)
    }
    #expect(model.statusMessage?.contains("both affected desktops") == true)
    #expect(model.lastActionFeedback?.kind == .failure)
    system.onFrameWrite = nil
    system.failedFrameWriteNumbers = [:]
    let writes = system.frameWriteCounts
    let source = system.availableDisplays[0]
    system.windows.append(WindowSnapshot(id: WindowID(rawValue: "later-source-arrival"), processIdentifier: 99,
        frame: BTRect(x: 100, y: 100, width: 400, height: 300), displayID: source.id))
    model.watchdog()
    await system.joinWindowEvent(on: model)
    for task in Array(model.settlementTasks.values) { await system.joinSettlement(task, on: model) }
    #expect(system.frameWriteCounts == writes, "A later sweep must not write on either degraded transfer owner")
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func bentoDisplayTransferVerifiesSuccessfulMinimumCorrection(correctionLands: Bool) async throws {
    let (system, model) = try await displayTransferFixture(sourceCount: 3, drivingPolicyDeadlines: true)
    defer { system.onFrameWrite = nil; system.frameReadbackTransform = nil; model.shutdown() }
    let store = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    let owners = try system.availableDisplays.map { try #require(store.session(for: $0.id)) }
    let source = system.availableDisplays[0]
    model.perform(.nextDisplay)
    try #require(model.statusMessage == nil)
    let peers = system.windows.filter { $0.displayID == source.id }.sorted { $0.frame.minX < $1.frame.minX }
    try #require(peers.count == 2)
    let growing = peers[0], neighbour = peers[1]
    try #require(growing.frame.maxX == neighbour.frame.minX)
    let initialWrites = system.frameWriteCounts
    // A delayed readback reveals a real minimum after the transfer committed.
    let index = try #require(system.windows.firstIndex { $0.id == growing.id })
    system.windows[index].frame.size.width += 100
    system.windows[index].constraints.minimumSize.width = system.windows[index].frame.size.width
    system.enforcedMinimumWidths[growing.id] = system.windows[index].frame.size.width
    system.reportedConstraints[growing.id] = system.windows[index].constraints
    if correctionLands {
        // Immediate readback raises the minimum once more during correction.
        // Verification must use the final clamp solve, not its first requests.
        system.onFrameWrite = { id, _ in
            guard id == growing.id, system.frameWriteCounts[id] == initialWrites[id, default: 0] + 1 else { return }
            system.enforcedMinimumWidths[id] = growing.frame.size.width + 150
            system.windows[index].constraints.minimumSize.width = growing.frame.size.width + 150
            system.reportedConstraints[id] = system.windows[index].constraints
        }
    } else {
        // The neighbour accepts every call but keeps its old, overlapping frame.
        system.frameReadbackTransform = { id, frame in id == neighbour.id ? neighbour.frame : frame }
    }
    for _ in 0..<6 {
        let tasks = Array(model.settlementTasks.values)
        if tasks.isEmpty { break }
        for task in tasks { await system.joinSettlement(task, on: model) }
    }
    #expect(model.settlementTasks.isEmpty, "Verification must exhaust a bounded retry budget")
    #expect(system.frameWriteCounts[neighbour.id, default: 0] == initialWrites[neighbour.id, default: 0] + (correctionLands ? 2 : 3),
        "A refused correction must receive exactly two authoritative retries")
    let actual = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
    if correctionLands {
        #expect(actual[growing.id]?.size.width == growing.frame.size.width + 150)
        #expect(actual[growing.id]?.maxX == actual[neighbour.id]?.minX)
        #expect(actual[neighbour.id]?.maxX == source.visibleFrame.maxX)
        #expect(model.statusMessage == nil)
        #expect(model.lastActionFeedback?.kind == .success)
    } else {
        #expect(actual[growing.id]?.intersection(try #require(actual[neighbour.id]))?.size.width == 100)
        #expect(model.statusMessage?.contains("both affected desktops") == true)
        #expect(model.lastActionFeedback?.kind == .failure)
    }
    let settledStore = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    for owner in owners {
        #expect(settledStore.allSessions(for: owner.displayID).first { $0.id == owner.id }?.automaticWritesSuspended == !correctionLands)
    }
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: ["none", "source", "destination"]) @MainActor
func bentoDisplayTransferReportsRejectedMinimumCorrectionOnlyForCurrentOwners(superseded: String) async throws {
    let (system, model) = try await displayTransferFixture(sourceCount: 3, drivingPolicyDeadlines: true)
    defer { system.onFrameWrite = nil; model.shutdown() }
    let store = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    let owners = try system.availableDisplays.map { try #require(store.session(for: $0.id)) }
    let source = system.availableDisplays[0], destination = system.availableDisplays[1]
    model.perform(.nextDisplay)
    try #require(model.lastActionFeedback?.kind == .success)
    let peers = system.windows.filter { $0.displayID == source.id }.sorted { $0.frame.minX < $1.frame.minX }
    try #require(peers.count == 2)
    let growing = peers[0], neighbour = peers[1]
    try #require(growing.frame.maxX == neighbour.frame.minX)
    let initialWrites = system.frameWriteCounts
    if superseded != "none" {
        let displayID = superseded == "source" ? source.id : destination.id
        system.focusedID = system.windows.first { $0.displayID == displayID }?.id
        let replacementTarget = try #require(model.captureLayoutWheelTarget())
        // Supersede the owner before delayed settlement dispatches a correction.
        model.setActiveMode(.manual)
        #expect(model.activeMode(for: replacementTarget.displayID) == .manual)
    }
    let index = try #require(system.windows.firstIndex { $0.id == growing.id })
    // Settlement discovers a minimum that overlaps the neighbour by 100 points.
    system.windows[index].frame.size.width += 100
    system.windows[index].constraints.minimumSize.width = system.windows[index].frame.size.width
    system.enforcedMinimumWidths[growing.id] = system.windows[index].frame.size.width
    system.reportedConstraints[growing.id] = system.windows[index].constraints
    let overlappingBaseline = system.windows.map(\.frame)
    let rejectedWrite = initialWrites[neighbour.id, default: 0] + 1
    system.failedFrameWriteNumbers[neighbour.id] = [rejectedWrite]
    var correctionAttempted = false
    system.onFrameWrite = { id, _ in
        guard id == neighbour.id, system.frameWriteCounts[id] == rejectedWrite else { return }
        correctionAttempted = true
    }
    for _ in 0..<6 {
        let tasks = Array(model.settlementTasks.values)
        if tasks.isEmpty { break }
        for task in tasks { await system.joinSettlement(task, on: model) }
    }
    #expect(correctionAttempted == (superseded == "none"),
        "A superseded transfer must not dispatch the delayed correction")
    #expect(model.settlementTasks.isEmpty)
    #expect(system.frameWriteCounts[neighbour.id] == initialWrites[neighbour.id, default: 0] + (superseded == "none" ? 1 : 0))
    #expect(system.requestedFrames[neighbour.id]?.last?.size.width == neighbour.frame.size.width - (superseded == "none" ? 100 : 0))
    #expect(system.windows.map(\.frame) == overlappingBaseline,
        "The rejected correction rolls back completely to an already overlapping baseline")
    let actualGrowing = try #require(system.windows.first { $0.id == growing.id })
    let actualNeighbour = try #require(system.windows.first { $0.id == neighbour.id })
    #expect(actualGrowing.frame.intersection(actualNeighbour.frame)?.size.width == 100)
    let settledStore = try #require(Mirror(reflecting: model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    for owner in owners {
        #expect(settledStore.allSessions(for: owner.displayID).first { $0.id == owner.id }?.automaticWritesSuspended == (superseded == "none"))
    }
    if superseded == "none" {
        #expect(model.lastActionFeedback?.kind == .failure,
            "The earlier transfer success must not survive an overlapping rejected correction")
        #expect(model.statusMessage?.contains("both affected desktops") == true)
    } else {
        let displayID = superseded == "source" ? source.id : destination.id
        #expect(model.activeMode(for: displayID) == .manual)
        #expect(model.lastActionFeedback?.kind != .failure)
        #expect(model.statusMessage?.contains("both affected desktops") != true)
    }
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func displayTransferTerminalFixtureDrivesRegisteredDeadlines() async throws {
    let (system, model) = try await displayTransferFixture(drivingPolicyDeadlines: true)
    model.shutdown()
    let clock = try #require(system.manualClock)
    try #require(clock.pendingSleepCount == 0)
    let start = clock.now
    var completed = false
    let operation = Task { @MainActor in
        try? await clock.sleep(for: .milliseconds(1500))
        try? await clock.sleep(for: .milliseconds(50))
        completed = true
    }
    defer { operation.cancel() }
    try #require(await clock.waitForSleepers(count: 1, timeout: .seconds(45)))
    var observed: Set<Duration> = []
    try #require(await system.waitFor {
        observed.insert(clock.now - start)
        return completed
    })
    let policyInstants: Set<Duration> = [.zero, .milliseconds(1500), .milliseconds(1550)]
    #expect(observed.subtracting(policyInstants).isEmpty,
        "The terminal transfer fixture must advance policy deadlines without one-millisecond virtual polling")
    #expect(observed.contains(.milliseconds(1500)))
    #expect(observed.contains(.milliseconds(1550)))
    await operation.value
}
