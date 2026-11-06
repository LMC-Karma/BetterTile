import BetterTileCore
import BetterTileMacOS
import Testing
@testable import BetterTileApp

/// Hidden applications leave the AX inventory but retain their pane positions.
@Suite(.appTestApplication, .serialized, .timeLimit(.minutes(1))) @MainActor
struct AdaptiveHiddenWindowReturnTests {
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
    @Test(arguments: [[3], [2, 3], [0, 1, 2, 3, 4]])
    func hiddenPanesReturnToTheirOriginalFramesAfterOtherFocus(hiddenIndexes: [Int]) async throws {
        let (s, m) = try await fixture(5); defer { m.shutdown() }
        let before = frames(s)
        let hiddenIDs = Set(hiddenIndexes.map { s.windows[$0].id })
        for i in hiddenIndexes { s.windows[i].isHidden = true }
        // The real adapter skips hidden applications rather than reporting
        // their windows as minimized. Keep those identities out of inventories.
        s.offscreenWindowIDs.formUnion(hiddenIDs)
        s.focusedWindowIsUnknown = hiddenIndexes.count == s.windows.count
        for _ in 0..<3 {
            m.handleApplicationTopologyChange()
            await s.advance(by: .milliseconds(250))
            try await settle(s, m)
        }
        #expect(Set(try state(s, m).root?.windowIDs ?? []).isDisjoint(with: hiddenIDs))
        s.focusedID = s.windows.first { !hiddenIDs.contains($0.id) }?.id
        m.configuration.bentoNewWindowSide = .left
        for i in hiddenIndexes.reversed() {
            s.windows[i].isHidden = false
            s.offscreenWindowIDs.remove(s.windows[i].id)
            s.focusedWindowIsUnknown = false
            if s.focusedID == nil { s.focusedID = s.windows[i].id }
            m.handleApplicationTopologyChange()
            try await settle(s, m)
        }
        try await quiet(s, m)
        #expect(frames(s) == before)
    }
}
