import Testing
@testable import BetterTileCore

@Test func verifierReportsOnlyRealOverlaps() {
    let a = WindowID(rawValue: "a"), b = WindowID(rawValue: "b"), c = WindowID(rawValue: "c")
    // Adjacent panes and a 1 pt rounding overlap are not overlaps.
    #expect(BentoLayoutVerifier.overlappingWindowIDs([
        a: BTRect(x: 0, y: 0, width: 961, height: 500), b: BTRect(x: 960, y: 0, width: 960, height: 500),
    ]).isEmpty)
    // Brave held at 500 pt over its neighbour's column.
    #expect(BentoLayoutVerifier.overlappingWindowIDs([
        a: BTRect(x: 1225, y: 30, width: 500, height: 484), b: BTRect(x: 778, y: 30, width: 501, height: 968),
        c: BTRect(x: 0, y: 30, width: 600, height: 968),
    ]) == [a, b])
}
