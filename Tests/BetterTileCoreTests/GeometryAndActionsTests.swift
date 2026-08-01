import Testing
@testable import BetterTileCore

private let testDisplay = DisplaySnapshot(
    id: DisplayID(rawValue: "main"),
    frame: BTRect(x: 0, y: 0, width: 1200, height: 900),
    visibleFrame: BTRect(x: 0, y: 24, width: 1200, height: 876),
    isMain: true
)

@Test func normalizedRectRoundTrip() throws {
    let frame = BTRect(x: 300, y: 243, width: 600, height: 438)
    let normalized = NormalizedRect(frame: frame, in: testDisplay.visibleFrame)
    #expect(normalized.frame(in: testDisplay.visibleFrame).approximatelyEquals(frame, tolerance: 0.001))
    _ = try normalized.validated()
}

@Test func invalidNormalizedRectIsRejected() {
    #expect(throws: GeometryError.invalidNormalizedRect) {
        try NormalizedRect(x: 0.8, y: 0, width: 0.4, height: 1).validated()
    }
}

@Test func standardCatalogStaysInsideVisibleFrame() {
    let window = WindowSnapshot(
        id: WindowID(rawValue: "w"), processIdentifier: 1,
        frame: BTRect(x: 100, y: 100, width: 500, height: 400), displayID: testDisplay.id
    )
    let engine = StandardActionEngine()
    for action in WindowAction.allCases where !action.isDisplayTransfer && !action.isRestore {
        let target = engine.targetFrame(for: action, window: window, display: testDisplay)
        #expect(target != nil, "Missing frame for \(action)")
        if let target {
            #expect(target.minX >= testDisplay.visibleFrame.minX)
            #expect(target.minY >= testDisplay.visibleFrame.minY)
            #expect(target.maxX <= testDisplay.visibleFrame.maxX + 0.001)
            #expect(target.maxY <= testDisplay.visibleFrame.maxY + 0.001)
        }
    }
}

@Test func displayTransferPreservesNormalizedPlacement() {
    let second = DisplaySnapshot(
        id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1200, y: 0, width: 1800, height: 1200),
        visibleFrame: BTRect(x: 1200, y: 30, width: 1800, height: 1170)
    )
    let expected = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
    let source = expected.frame(in: testDisplay.visibleFrame)
    let transferred = StandardActionEngine().transferFrame(source, from: testDisplay, to: second)
    #expect(NormalizedRect(frame: transferred, in: second.visibleFrame) == expected)
}

@Test func snapZonesPreferCorners() {
    #expect(SnapZoneDetector().target(at: BTPoint(x: 1, y: 25), display: testDisplay)?.action == .topLeftQuarter)
}

@Test func snapZonesWaitForThePhysicalScreenEdge() {
    let detector = SnapZoneDetector()
    #expect(detector.target(at: BTPoint(x: 600, y: testDisplay.visibleFrame.minY), display: testDisplay) == nil)
    #expect(detector.target(at: BTPoint(x: 600, y: 4), display: testDisplay)?.action == .almostMaximize)
}

@Test func snapZoneActionsAreConfigurableAndCanBeDisabled() {
    var bindings = BetterTileConfiguration.defaultSnapAreaBindings
    let topIndex = bindings.firstIndex(where: { $0.area == .top })!
    bindings[topIndex].action = .topHalf
    #expect(SnapZoneDetector().target(at: BTPoint(x: 600, y: 2), display: testDisplay, snapAreas: bindings)?.action == .topHalf)

    bindings[topIndex].action = nil
    #expect(SnapZoneDetector().target(at: BTPoint(x: 600, y: 2), display: testDisplay, snapAreas: bindings) == nil)
}
