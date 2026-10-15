import Testing
@testable import BetterTileCore

private let request = BTRect(x: 0, y: 64, width: 957, height: 934)

@Test func steppedAcceptanceTreatsTheWriteToleranceAsExact() {
    #expect(SteppedSizeAcceptance.evaluate(requested: request, actual: request) == .exact)
    #expect(SteppedSizeAcceptance.evaluate(requested: request,
        actual: BTRect(x: 1, y: 65, width: 955, height: 936)) == .exact)
}

@Test func steppedAcceptanceAcceptsAShortfallBelowOneStep() {
    // Terminal settles on whole character cells: 957 becomes 954.
    #expect(SteppedSizeAcceptance.evaluate(requested: request,
        actual: BTRect(x: 0, y: 64, width: 954, height: 925)) == .stepped)
}

@Test func steppedAcceptanceRejectsMovesGrowthAndLargeShortfalls() {
    // A larger frame is a minimum-size refusal, not a step.
    #expect(SteppedSizeAcceptance.evaluate(requested: request,
        actual: BTRect(x: 0, y: 64, width: 1000, height: 934)) == .rejected)
    #expect(SteppedSizeAcceptance.evaluate(requested: request,
        actual: BTRect(x: 0, y: 64, width: 900, height: 934)) == .rejected)
    #expect(SteppedSizeAcceptance.evaluate(requested: request,
        actual: BTRect(x: 30, y: 64, width: 954, height: 934)) == .rejected)
}

@Test func steppedAcceptanceCanAcceptGrowthBelowOneStep() {
    // Terminal rounded 934 up to the next row, 938.
    let rounded = BTRect(x: 0, y: 64, width: 958, height: 938)
    #expect(SteppedSizeAcceptance.evaluate(requested: request, actual: rounded) == .rejected)
    #expect(SteppedSizeAcceptance.evaluate(requested: request, actual: rounded, allowsGrowth: true) == .stepped)
    #expect(SteppedSizeAcceptance.evaluate(requested: request,
        actual: BTRect(x: 0, y: 64, width: 1000, height: 934), allowsGrowth: true) == .rejected)
}
