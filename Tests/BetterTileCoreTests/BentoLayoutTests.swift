import Testing
@testable import BetterTileCore

private let bentoBounds = BTRect(x: 0, y: 0, width: 1200, height: 800)

@Test func bentoInsertionIsDeterministicAndGapless() {
    var first = BentoLayoutState()
    var second = BentoLayoutState()
    let ids = ["a", "b", "c", "d"].map { WindowID(rawValue: $0) }
    for id in ids {
        first.insert(id, in: bentoBounds)
        second.insert(id, in: bentoBounds)
    }
    #expect(first == second)
    let placements = first.placements(in: bentoBounds)
    #expect(placements.count == 4)
    #expect(abs(placements.reduce(0) { $0 + $1.frame.area } - bentoBounds.area) < 0.01)
}

@Test func bentoRemoveCollapsesParentAndSwapPreservesFrames() {
    var state = BentoLayoutState()
    let a = WindowID(rawValue: "a")
    let b = WindowID(rawValue: "b")
    state.insert(a, in: bentoBounds)
    state.insert(b, in: bentoBounds)
    let before = Dictionary(uniqueKeysWithValues: state.placements(in: bentoBounds).map { ($0.windowID, $0.frame) })
    state.swap(a, b)
    let after = Dictionary(uniqueKeysWithValues: state.placements(in: bentoBounds).map { ($0.windowID, $0.frame) })
    #expect(after[a] == before[b])
    #expect(after[b] == before[a])
    state.remove(a)
    #expect(state.root?.windowIDs == [b])
}
