import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// Compound user actions beyond the individual arrival and settlement cases.
@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(1))) @MainActor
struct AdaptiveCompoundScenarioTests {
    private func fixture(_ count: Int = 4) async throws -> (FakeAppWindowSystem, BetterTileModel) {
        let s = makeManualWindowSystem(drivingPolicyDeadlines: true)
        s.windows = (0..<count).map { window($0, s) }
        let m = makeModel(system: s)
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

    @Test func burstWithReversedInventoryKeepsAllThreeArrivals() async throws {
        let (s, m) = try await fixture(3); defer { m.shutdown() }
        let added = (3...5).map { window($0, s) }
        s.windows.append(contentsOf: added.reversed())
        for w in added { s.eventHandler?(WindowSystemEvent(kind: .created, windowID: w.id, processIdentifier: w.processIdentifier)) }
        try await quiet(s, m)
        #expect(Set(try state(s, m).root?.windowIDs ?? []) == Set(s.windows.map(\.id)))
        try disjoint(s, m)
    }

    @Test func arrivalWhileRepairSettlesIsPlacedAndBecomesQuiet() async throws {
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
        try #require(try state(s, m).root?.windowIDs.contains(id) == false)
        #expect(s.windows[4].frame != before[s.windows[4].id])
        m.configuration.bentoNewWindowSide = .left
        s.windows[3].isMinimized = false
        s.eventHandler?(WindowSystemEvent(kind: .restored, windowID: id, processIdentifier: 83))
        try await quiet(s, m)
        #expect(frames(s) == before)
    }

    @Test func twoOverflowWindowsAreAdmittedInCreationOrder() async throws {
        let (s, m) = try await fixture(6); defer { m.shutdown() }
        let departures = [s.windows[2].id, s.windows[1].id]
        let first = arrive(8, s)
        try await settle(s, m)
        let second = arrive(7, s) // Lexically before the first arrival.
        try await settle(s, m)
        try #require(try state(s, m).floatingWindowIDs == [first, second])
        // Inventory order and ID order both oppose creation order.
        let secondIndex = try #require(s.windows.firstIndex { $0.id == second })
        s.windows.insert(s.windows.remove(at: secondIndex), at: 0)
        try #require(try #require(s.windows.firstIndex { $0.id == second })
            < #require(s.windows.firstIndex { $0.id == first }))
        close(departures[0], s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(first) == true)
        #expect(try state(s, m).floatingWindowIDs.contains(second))
        close(departures[1], s)
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(second) == true)
        #expect(try state(s, m).floatingWindowIDs.isEmpty)
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
        let ids = (0..<4).map { WindowID(rawValue: "pane-\($0)") }
        let target: WindowID
        let arrivalFrame: BTRect
        let targetFrame: BTRect
        switch side {
        case .left:
            target = ids[0]
            arrivalFrame = BTRect(x: 0, y: 0, width: 300, height: 320)
            targetFrame = BTRect(x: 300, y: 0, width: 300, height: 320)
        case .right:
            target = ids[2]
            arrivalFrame = BTRect(x: 800, y: 0, width: 200, height: 400)
            targetFrame = BTRect(x: 600, y: 0, width: 200, height: 400)
        case .top:
            target = ids[0]
            arrivalFrame = BTRect(x: 0, y: 0, width: 600, height: 160)
            targetFrame = BTRect(x: 0, y: 160, width: 600, height: 160)
        case .bottom:
            target = ids[1]
            arrivalFrame = BTRect(x: 0, y: 560, width: 600, height: 240)
            targetFrame = BTRect(x: 0, y: 320, width: 600, height: 240)
        case .automatic:
            target = ids[3] // The focused square pane splits side by side.
            arrivalFrame = BTRect(x: 800, y: 400, width: 200, height: 400)
            targetFrame = BTRect(x: 600, y: 400, width: 200, height: 400)
        }
        let current = frames(s)
        #expect(current[id] == arrivalFrame)
        #expect(current[target] == targetFrame)
        for oldID in ids where oldID != target { #expect(current[oldID] == before[oldID]) }
        try disjoint(s, m)
    }

    @Test(arguments: [3, 4, 5]) func balanceOnArrivalEqualizesCustomPartitionsAndBecomesQuiet(count: Int) async throws {
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

    @Test func arrivalStaysTiledInsideAWorkAreaThatShrinksDuringSettlement() async throws {
        let (s, m) = try await fixture(); defer { m.shutdown() }
        let id = arrive(4, s)
        await s.joinWindowEvent(on: m)
        try #require(!m.settlementTasks.isEmpty)
        s.availableDisplays[0].visibleFrame.size.height = 700
        m.handleApplicationTopologyChange()
        try await quiet(s, m)
        #expect(try state(s, m).root?.windowIDs.contains(id) == true)
        let area = s.availableDisplays[0].visibleFrame
        for w in s.windows {
            #expect(w.frame.minY >= area.minY - 0.5 && w.frame.maxY <= area.maxY + 0.5, "\(w.id) \(w.frame)")
        }
        try disjoint(s, m)
    }

    @Test func repairKeepsSpatialOrderDespiteReversedInventory() async throws {
        let (s, m) = try await fixture(5); defer { m.shutdown() }
        let ids = s.windows.map(\.id), before = frames(s), writes = s.frameWriteCounts
        s.windows.reverse()
        m.repairCurrentLayout()
        #expect(!m.settlementTasks.isEmpty)
        try await quiet(s, m)
        let f = frames(s)
        try #require(f != before, "Repair must replace the customized unequal shares")
        #expect(s.frameWriteCounts != writes)
        #expect(m.statusMessage == nil)
        #expect(m.lastActionFeedback?.kind == .success)
        #expect(try #require(f[ids[0]]).maxY <= #require(f[ids[1]]).minY)
        #expect(try #require(f[ids[2]]).maxY <= #require(f[ids[3]]).minY)
        #expect(try #require(f[ids[3]]).maxY <= #require(f[ids[4]]).minY)
        #expect(try #require(f[ids[0]]).maxX <= #require(f[ids[2]]).minX)
        try disjoint(s, m)
    }

    @Test func repeatedRepairWithSteppedWidthsDoesNotDriftOrLoop() async throws {
        let (s, m) = try await fixture(4); defer { m.shutdown() }
        let steppedID = s.windows[2].id
        s.widthSteps[steppedID] = 3
        let writesBefore = s.requestedFrames[steppedID, default: []].count
        m.repairCurrentLayout()
        try #require(!m.settlementTasks.isEmpty)
        try await settle(s, m)
        let first = frames(s)
        let requested = try #require(s.requestedFrames[steppedID, default: []].dropFirst(writesBefore).last)
        let actual = try #require(first[steppedID])
        try #require(requested.size.width != actual.size.width, "The application must round a Repair write")
        #expect(actual.size.width == (requested.size.width / 3).rounded(.down) * 3)
        #expect(m.statusMessage == nil)
        #expect(m.lastActionFeedback?.kind == .success)
        for _ in 0..<3 {
            m.repairCurrentLayout()
            try #require(!m.settlementTasks.isEmpty)
            try await settle(s, m)
            #expect(m.statusMessage == nil)
            #expect(m.lastActionFeedback?.kind == .success)
        }
        try await quiet(s, m)
        #expect(frames(s) == first)
        #expect(m.statusMessage == nil)
        try disjoint(s, m)
    }
}

extension AdaptiveCompoundScenarioTests {
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
        #expect(current[source[2].id] == BTRect(x: 600, y: 0, width: 400, height: 400))
        #expect(current[source[4].id] == BTRect(x: 600, y: 400, width: 400, height: 400))
        #expect(try state(s, m).root?.windowIDs.contains(source[3].id) == false)
        #expect(m.dividerResize.bentoStateProvider?(dest[0].displayID)?.root?.windowIDs.contains(source[3].id) == true)
        #expect(m.statusMessage == nil)
        #expect(m.lastActionFeedback?.kind == .success)
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
            #expect(!m.settlementTasks.isEmpty)
            try await settle(s, m)
            try #require(s.windows.first { $0.id == id }?.displayID == dest[0].displayID)
            #expect(m.dividerResize.bentoStateProvider?(dest[0].displayID)?.root?.windowIDs.contains(id) == true)
            #expect(try state(s, m).root?.windowIDs.contains(id) == false)
            #expect(m.statusMessage == nil)
            #expect(m.lastActionFeedback?.kind == .success)
            m.perform(.previousDisplay)
            #expect(!m.settlementTasks.isEmpty)
            try await settle(s, m)
            #expect(try state(s, m).root?.windowIDs.contains(id) == true)
            #expect(m.dividerResize.bentoStateProvider?(dest[0].displayID)?.root?.windowIDs.contains(id) == false)
            #expect(m.statusMessage == nil)
            #expect(m.lastActionFeedback?.kind == .success)
            for w in dest { #expect(s.windows.first { $0.id == w.id }?.frame == w.frame) }
            #expect(s.windows.first { $0.id == id }?.displayID == s.mainDisplay.id)
            #expect(BentoLayoutVerifier.overlappingWindowIDs(frames(s)).isEmpty)
        }
        try await quiet(s, m)
    }
}
