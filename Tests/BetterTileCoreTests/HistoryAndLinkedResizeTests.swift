import Testing
@testable import BetterTileCore

@Test func historyIsBoundedAndRestoresNewestFirst() {
    let id = WindowID(rawValue: "window")
    var history = FrameHistory(capacity: 3)
    for index in 0..<5 { history.record(BTRect(x: Double(index), y: 0, width: 100, height: 100), for: id) }
    #expect(history.count(for: id) == 3)
    #expect(history.restore(for: id)?.minX == 4)
    #expect(history.restore(for: id)?.minX == 3)
    #expect(history.restore(for: id)?.minX == 2)
    #expect(history.restore(for: id) == nil)
}

@Test func adjacencyAndLinkedResize() {
    let display = DisplayID(rawValue: "main")
    let left = WindowSnapshot(id: WindowID(rawValue: "left"), processIdentifier: 1, frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display)
    let right = WindowSnapshot(id: WindowID(rawValue: "right"), processIdentifier: 2, frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: display)
    let engine = LinkedResizeEngine(tolerance: 6)
    #expect(engine.adjacencies(in: [left, right]).count == 1)
    let result = engine.resize(windowID: left.id, edge: .right, delta: 100, windows: [left, right], bounds: BTRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(result?.appliedDelta == 100)
    #expect(result?.placements.first(where: { $0.windowID == left.id })?.frame.size.width == 600)
    #expect(result?.placements.first(where: { $0.windowID == right.id })?.frame.minX == 600)
    #expect(result?.placements.first(where: { $0.windowID == right.id })?.frame.size.width == 400)
}

@Test func linkedResizeClampsEntireTransactionAtMinimumSize() {
    let display = DisplayID(rawValue: "main")
    let left = WindowSnapshot(id: WindowID(rawValue: "left"), processIdentifier: 1, frame: BTRect(x: 0, y: 0, width: 500, height: 800), displayID: display)
    let right = WindowSnapshot(
        id: WindowID(rawValue: "right"), processIdentifier: 2,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800), displayID: display,
        constraints: WindowConstraints(minimumSize: BTSize(width: 450, height: 80))
    )
    let result = LinkedResizeEngine().resize(windowID: left.id, edge: .right, delta: 200, windows: [left, right], bounds: BTRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(result?.appliedDelta == 50)
    #expect(result?.placements.first(where: { $0.windowID == right.id })?.frame.size.width == 450)
}

@Test func linkedResizeNeverCrossesDisplays() {
    let main = DisplayID(rawValue: "main")
    let external = DisplayID(rawValue: "external")
    let left = WindowSnapshot(
        id: WindowID(rawValue: "left"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800),
        displayID: main
    )
    let right = WindowSnapshot(
        id: WindowID(rawValue: "right"),
        processIdentifier: 2,
        frame: BTRect(x: 500, y: 0, width: 500, height: 800),
        displayID: external
    )
    let engine = LinkedResizeEngine()

    #expect(engine.adjacencies(in: [left, right]).isEmpty)
    #expect(engine.resize(
        windowID: left.id,
        edge: .right,
        delta: 100,
        windows: [left, right],
        bounds: BTRect(x: 0, y: 0, width: 1000, height: 800)
    ) == nil)
}
