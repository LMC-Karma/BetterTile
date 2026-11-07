import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// Compound user actions beyond the individual arrival and settlement cases.
@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(1))) @MainActor
struct AdaptiveRegressionProbeTests {
    private func fixture(_ count: Int = 4) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let s = makeManualWindowSystem(drivingPolicyDeadlines: true)
        s.windows = (0..<count).map { window($0, s) }
        let m = makeModel(system: s)
        let drag = try #require(Mirror(reflecting: m).children.first {
            $0.label?.hasSuffix("dragSnap") == true
        }?.value as? DragSnapController)
        drag.primaryButtonIsPressed = { false }
        m.configuration.bentoInnerGap = 0
        m.configuration.singleWindowPlacement = .maximize
        m.setActiveMode(.bento)
        try await settle(s, m)
        if count >= 3 && count <= 5 {
            let ids = s.windows.map(\.id)
            let right = ids.dropFirst(2).map { BentoNode.leaf($0) }
            let state = BentoLayoutState(root: .partition(BentoPartition(axis: .vertical, weight: 0.6,
                first: .partition(BentoPartition(axis: .horizontal, weight: 0.4,
                    first: .leaf(ids[0]), second: .leaf(ids[1]))),
                second: right.count == 1 ? right[0] : .partition(BentoPartition(axis: .horizontal, children: right)))))
            let before = frames(s)
            let expected = Dictionary(uniqueKeysWithValues: state.placements(in: s.mainDisplay.visibleFrame).map { ($0.windowID, $0.frame) })
            for i in s.windows.indices { s.windows[i].frame = try #require(expected[s.windows[i].id]) }
            m.dividerResize.bentoStateChangedHandler?(s.mainDisplay.id, state, expected, before)
            try await settle(s, m)
        }
        s.focusedID = s.windows.last?.id
        return (s, m)
    }

    private func window(_ index: Int, _ s: FakeAppWindowSystem, pid: Int32? = nil) -> WindowSnapshot {
        WindowSnapshot(id: WindowID(rawValue: "pane-\(index)"), processIdentifier: pid ?? Int32(80 + index),
            bundleIdentifier: pid == nil ? "com.example.Pane\(index)" : "com.example.Shared", frame: BTRect(x: 100, y: 100, width: 300, height: 200),
            displayID: s.mainDisplay.id, constraints: WindowConstraints(minimumSize: BTSize(width: 80, height: 60)))
    }
    private func frames(_ s: FakeAppWindowSystem) -> [WindowID: BTRect] {
        Dictionary(uniqueKeysWithValues: s.windows.map { ($0.id, $0.frame) })
    }
    private func state(_ s: FakeAppWindowSystem, _ m: BetterTileModel) throws -> BentoLayoutState {
        try #require(m.dividerResize.bentoStateProvider?(s.mainDisplay.id))
    }
    private func settle(_ s: FakeAppWindowSystem, _ m: BetterTileModel) async throws {
        for _ in 0..<6 {
            await s.joinWindowEvent(on: m, budget: .seconds(3))
            for task in Array(m.settlementTasks.values) { await s.joinSettlement(task, on: m, budget: .seconds(3)) }
            if m.windowEventTask == nil && m.settlementTasks.isEmpty { return }
        }
        #expect(m.windowEventTask == nil && m.settlementTasks.isEmpty)
    }
    private func quiet(_ s: FakeAppWindowSystem, _ m: BetterTileModel) async throws {
        try await settle(s, m)
        let writes = s.frameWriteCounts, before = frames(s)
        await s.advance(by: .milliseconds(600))
        try await settle(s, m)
        #expect(s.frameWriteCounts == writes)
        #expect(frames(s) == before)
    }
    private func disjoint(_ s: FakeAppWindowSystem, _ m: BetterTileModel) throws {
        let ids = Set(try state(s, m).root?.windowIDs ?? [])
        let tiled = frames(s).filter { ids.contains($0.key) }
        #expect(BentoLayoutVerifier.overlappingWindowIDs(tiled).isEmpty)
        #expect(tiled.values.allSatisfy { PlacementBounds.isContained($0, in: s.displays()[0].visibleFrame) })
    }
    @discardableResult private func arrive(_ index: Int, _ s: FakeAppWindowSystem, pid: Int32? = nil) -> WindowID {
        let w = window(index, s, pid: pid)
        s.windows.append(w)
        s.eventHandler?(WindowSystemEvent(kind: .created, windowID: w.id, processIdentifier: w.processIdentifier))
        return w.id
    }
    private func close(_ id: WindowID, _ s: FakeAppWindowSystem) {
        guard let pid = s.windows.first(where: { $0.id == id })?.processIdentifier else {
            Issue.record("The departing fixture window must exist"); return
        }
        s.windows.removeAll { $0.id == id }
        s.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: id, processIdentifier: pid))
    }

    @Test func readableArrivalAfterDividerResizeNeedsNoNudge() async throws {
        let (s, m) = try await fixture(); defer { m.shutdown() }
        let original = frames(s), clock = try #require(s.manualClock), start = clock.now
        var lastWrite = start
        s.onFrameWrite = { id, _ in if id.rawValue == "pane-4" { lastWrite = clock.now } }
        let id = arrive(4, s)
        try #require(await s.waitFor(timeout: .milliseconds(200)) { s.frameWriteCounts[id, default: 0] > 0 })
        try await quiet(s, m)
        #expect(start.duration(to: lastWrite) <= .milliseconds(200))
        #expect(s.windows[0].frame == original[s.windows[0].id])
        #expect(s.windows[1].frame == original[s.windows[1].id])
        try disjoint(s, m)
    }

    @Test func lateReadyArrivalKeepsTheDividerAndTilesWithoutSecondEvent() async throws {
        let (s, m) = try await fixture(); defer { m.shutdown() }
        let original = frames(s), w = window(4, s), clock = try #require(s.manualClock)
        let start = clock.now
        var lastWrite = start
        s.onFrameWrite = { id, _ in if id == w.id { lastWrite = clock.now } }
        s.createdWindowsByToken[17] = w.id
        s.notReadyReads[17] = 4
        s.windows.append(w)
        s.eventHandler?(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: w.processIdentifier, creationToken: 17))
        try #require(await s.waitFor(timeout: .milliseconds(400)) { s.frameWriteCounts[w.id, default: 0] > 0 })
        try await quiet(s, m)
        #expect(s.createdReadCount >= 5)
        #expect(start.duration(to: lastWrite) <= .milliseconds(400))
        #expect(s.windows[0].frame == original[s.windows[0].id])
        #expect(s.windows[1].frame == original[s.windows[1].id])
        try disjoint(s, m)
    }

    @Test func threeSameAppArrivalsPreserveTheCustomizedOppositeColumn() async throws {
        let (s, m) = try await fixture(3); defer { m.shutdown() }
        let original = frames(s)
        let ids = (3...5).map { arrive($0, s, pid: 99) }
        try await quiet(s, m)
        #expect(ids.allSatisfy { s.frameWriteCounts[$0, default: 0] > 0 })
        #expect(try state(s, m).root?.windowIDs.count == 6)
        #expect(s.windows[0].frame == original[s.windows[0].id])
        #expect(s.windows[1].frame == original[s.windows[1].id])
        try disjoint(s, m)
    }

    @Test func burstNotificationsInReverseOrderKeepAllThreeArrivals() async throws {
        let (s, m) = try await fixture(3); defer { m.shutdown() }
        let added = (3...5).map { window($0, s) }
        s.windows.append(contentsOf: added.reversed())
        for w in added { s.eventHandler?(WindowSystemEvent(kind: .created, windowID: w.id, processIdentifier: w.processIdentifier)) }
        try await quiet(s, m)
        #expect(Set(try state(s, m).root?.windowIDs ?? []) == Set(s.windows.map(\.id)))
        try disjoint(s, m)
    }

    @Test func arrivalWhileRepairSettlesIsEventuallyPlacedOnce() async throws {
        let (s, m) = try await fixture(); defer { m.shutdown() }
        m.repairCurrentLayout()
        try #require(!m.settlementTasks.isEmpty)
        let id = arrive(4, s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(id) == true)
        #expect(s.frameWriteCounts[id, default: 0] > 0)
        try disjoint(s, m)
    }

    @Test(arguments: [3, 4, 5]) func closingLowerLeftPreservesTheEntireRightColumn(count: Int) async throws {
        let (s, m) = try await fixture(count); defer { m.shutdown() }
        let original = frames(s), survivor = s.windows[0].id
        close(s.windows[1].id, s)
        try await quiet(s, m)
        #expect(s.windows.first { $0.id == survivor }?.frame == BTRect(x: 0, y: 0, width: 600, height: 800))
        for w in s.windows where w.id != survivor { #expect(w.frame == original[w.id]) }
    }

    @Test func minimizedMiddlePaneReturnsToItsRatioAfterSideSettingChanges() async throws {
        let (s, m) = try await fixture(5); defer { m.shutdown() }
        let before = frames(s), id = s.windows[3].id
        s.windows[3].isMinimized = true
        s.eventHandler?(WindowSystemEvent(kind: .minimized, windowID: id, processIdentifier: 83))
        try await settle(s, m)
        m.configuration.bentoNewWindowSide = .left
        s.windows[3].isMinimized = false
        s.eventHandler?(WindowSystemEvent(kind: .restored, windowID: id, processIdentifier: 83))
        try await quiet(s, m)
        #expect(frames(s) == before)
    }

    @Test func seventhWindowJoinsAfterMiddlePaneCloses() async throws {
        let (s, m) = try await fixture(6); defer { m.shutdown() }
        let id = arrive(6, s)
        try await settle(s, m)
        try #require(try state(s, m).floatingWindowIDs.contains(id))
        close(s.windows[2].id, s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(id) == true)
        #expect(try state(s, m).floatingWindowIDs.isEmpty)
        try disjoint(s, m)
    }

    @Test func twoOverflowWindowsAreAdmittedInCreationOrder() async throws {
        let (s, m) = try await fixture(6); defer { m.shutdown() }
        let first = arrive(8, s)
        try await settle(s, m)
        let second = arrive(7, s) // Lexically before the first arrival.
        try await settle(s, m)
        close(s.windows[2].id, s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(first) == true)
        #expect(try state(s, m).floatingWindowIDs.contains(second))
        close(s.windows[1].id, s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(second) == true)
        try disjoint(s, m)
    }

    @Test(arguments: [BentoNewWindowSide.left, .right, .top, .bottom, .automatic])
    func sidePreferenceAfterDividerResizeKeepsUnrelatedPanes(side: BentoNewWindowSide) async throws {
        let (s, m) = try await fixture(); defer { m.shutdown() }
        m.configuration.bentoNewWindowSide = side
        let before = frames(s)
        let id = arrive(4, s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(id) == true)
        // Explicit sides can choose another pane; the existing root divider
        // remains a boundary rather than balancing the whole desktop.
        #expect(s.windows.filter { $0.id != id }.allSatisfy { $0.frame.maxX <= 600 || $0.frame.minX >= 600 })
        #expect(s.windows.contains { $0.id != id && $0.frame == before[$0.id] })
        try disjoint(s, m)
    }

    @Test(arguments: [2, 3, 4, 5]) func balanceOnArrivalStopsAfterOneSettledArrangement(count: Int) async throws {
        let (s, m) = try await fixture(count); defer { m.shutdown() }
        m.configuration.bentoBalancesNewWindows = true
        let id = arrive(count, s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(id) == true)
        let current = try state(s, m)
        func balanced(_ node: BentoNode) {
            guard case let .partition(p) = node else { return }
            for ratio in p.ratios { #expect(abs(ratio - 1 / Double(p.children.count)) < 0.0001) }
            for child in p.children { balanced(child) }
        }
        if let root = current.root { balanced(root) }
        try disjoint(s, m)
    }

    @Test func repeatedWorkAreaShrinkAndGrowPreservesCustomRatios() async throws {
        let (s, m) = try await fixture(5); defer { m.shutdown() }
        let before = frames(s)
        for _ in 0..<3 {
            s.availableDisplays[0].visibleFrame = BTRect(x: 0, y: 24, width: 1000, height: 696)
            m.handleApplicationTopologyChange()
            try await settle(s, m)
            try disjoint(s, m)
            s.availableDisplays[0] = s.mainDisplay
            m.handleApplicationTopologyChange()
            try await settle(s, m)
        }
        try await quiet(s, m)
        #expect(frames(s) == before)
    }

    @Test func workAreaShrinksWhileArrivalSettlementOwnsTheLayout() async throws {
        let (s, m) = try await fixture(); defer { m.shutdown() }
        let id = arrive(4, s)
        await s.joinWindowEvent(on: m)
        try #require(!m.settlementTasks.isEmpty)
        s.availableDisplays[0].visibleFrame.size.height = 700
        m.handleApplicationTopologyChange()
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(id) == true)
        try disjoint(s, m)
    }

    @Test func repairKeepsSpatialOrderDespiteReversedInventory() async throws {
        let (s, m) = try await fixture(5); defer { m.shutdown() }
        let ids = s.windows.map(\.id)
        s.windows.reverse()
        m.repairCurrentLayout()
        try await quiet(s, m)
        let f = frames(s)
        #expect(try #require(f[ids[0]]).maxY <= #require(f[ids[1]]).minY)
        #expect(try #require(f[ids[2]]).maxY <= #require(f[ids[3]]).minY)
        #expect(try #require(f[ids[3]]).maxY <= #require(f[ids[4]]).minY)
        #expect(try #require(f[ids[0]]).maxX <= #require(f[ids[2]]).minX)
        try disjoint(s, m)
    }

    @Test func lateMinimumDuringBalancedArrivalSettlesWithoutRepeatedWrites() async throws {
        let (s, m) = try await fixture(3); defer { m.shutdown() }
        s.measuresOnWrite = true
        m.configuration.bentoBalancesNewWindows = true
        let constrained = s.windows[2].id
        s.enforcedMinimumWidths[constrained] = 430
        _ = arrive(3, s)
        try await quiet(s, m)
        #expect(s.windows.first { $0.id == constrained }?.frame.size.width ?? 0 >= 430)
        #expect(m.statusMessage?.contains("Use Repair") != true)
        try disjoint(s, m)
    }

    @Test func repeatedRepairWithSteppedWidthsDoesNotDriftOrLoop() async throws {
        let (s, m) = try await fixture(4); defer { m.shutdown() }
        s.widthSteps[s.windows[2].id] = 3
        m.repairCurrentLayout()
        try await settle(s, m)
        let first = frames(s)
        for _ in 0..<3 { m.repairCurrentLayout(); try await settle(s, m) }
        try await quiet(s, m)
        #expect(frames(s) == first)
        #expect(m.statusMessage?.contains("Use Repair") != true)
        try disjoint(s, m)
    }

    @Test func closedUnreadArrivalNeverReappearsWhenItsTokenBecomesReady() async throws {
        let (s, m) = try await fixture(); defer { m.shutdown() }
        let before = frames(s), w = window(4, s)
        s.createdWindowsByToken[19] = w.id
        s.notReadyReads[19] = 50
        s.eventHandler?(WindowSystemEvent(kind: .created, windowID: w.id, processIdentifier: w.processIdentifier, creationToken: 19))
        await s.joinWindowEvent(on: m)
        s.eventHandler?(WindowSystemEvent(kind: .destroyed, windowID: w.id, processIdentifier: w.processIdentifier))
        s.notReadyReads[19] = 0
        try await quiet(s, m)
        #expect(frames(s) == before)
        #expect(s.frameWriteCounts[w.id, default: 0] == 0)
    }
}

extension AdaptiveRegressionProbeTests {
    private func destination(_ s: FakeAppWindowSystem, _ m: BetterTileModel) async throws -> [WindowSnapshot] {
        let bounds = BTRect(x: 1000, y: 0, width: 1000, height: 800)
        let display = DisplaySnapshot(id: DisplayID(rawValue: "second"), frame: bounds, visibleFrame: bounds)
        s.availableDisplays.append(display)
        let windows = [
            WindowSnapshot(id: WindowID(rawValue: "destination-left"), processIdentifier: 97,
                frame: BTRect(x: 1000, y: 0, width: 400, height: 800), displayID: display.id),
            WindowSnapshot(id: WindowID(rawValue: "destination-right"), processIdentifier: 98,
                frame: BTRect(x: 1400, y: 0, width: 600, height: 800), displayID: display.id)
        ]
        s.windows.append(contentsOf: windows)
        m.configuration.defaultLayoutMode = .bento
        m.handleApplicationTopologyChange()
        try await settle(s, m)
        try #require(m.activeMode(for: display.id) == .bento)
        return s.windows.filter { $0.displayID == display.id }
    }

    @Test func nextDisplayKeepsSourceSiblingOrderAndDestinationDivider() async throws {
        let (s, m) = try await fixture(5); defer { m.shutdown() }
        let source = s.windows, dest = try await destination(s, m)
        s.focusedID = source[3].id
        m.perform(.nextDisplay)
        try await quiet(s, m)
        let current = frames(s)
        #expect(current[source[0].id] == source[0].frame)
        #expect(current[source[1].id] == source[1].frame)
        #expect(try #require(current[source[2].id]).maxY <= #require(current[source[4].id]).minY)
        // With no focused destination pane, insertion minimizes disruption.
        // Splitting the narrower left pane preserves the wider right pane.
        #expect(current[dest[1].id] == dest[1].frame)
        #expect(current[dest[0].id]?.minX == dest[0].frame.minX)
        #expect(current[dest[0].id]?.size.width == dest[0].frame.size.width)
        #expect(s.windows.first { $0.id == source[3].id }?.displayID == dest[0].displayID)
        #expect(BentoLayoutVerifier.overlappingWindowIDs(current).isEmpty)
    }

    @Test func displayRoundTripsLeaveDestinationRatiosUnchanged() async throws {
        let (s, m) = try await fixture(4); defer { m.shutdown() }
        let id = s.windows[3].id, dest = try await destination(s, m)
        for _ in 0..<3 {
            s.focusedID = id
            m.perform(.nextDisplay)
            try await settle(s, m)
            m.perform(.previousDisplay)
            try await settle(s, m)
            for w in dest { #expect(s.windows.first { $0.id == w.id }?.frame == w.frame) }
            #expect(s.windows.first { $0.id == id }?.displayID == s.mainDisplay.id)
            #expect(BentoLayoutVerifier.overlappingWindowIDs(frames(s)).isEmpty)
        }
        try await quiet(s, m)
    }
}
