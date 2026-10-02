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

@Test func standardCatalogUsesTheExpectedFramesInsideVisibleFrame() throws {
    let window = WindowSnapshot(
        id: WindowID(rawValue: "w"), processIdentifier: 1,
        frame: BTRect(x: 100, y: 100, width: 500, height: 400), displayID: testDisplay.id
    )
    let expected: [WindowAction: BTRect] = [
        .leftHalf: BTRect(x: 0, y: 24, width: 600, height: 876),
        .rightHalf: BTRect(x: 600, y: 24, width: 600, height: 876),
        .topHalf: BTRect(x: 0, y: 24, width: 1200, height: 438),
        .bottomHalf: BTRect(x: 0, y: 462, width: 1200, height: 438),
        .leftThird: BTRect(x: 0, y: 24, width: 400, height: 876),
        .centerThird: BTRect(x: 400, y: 24, width: 400, height: 876),
        .rightThird: BTRect(x: 800, y: 24, width: 400, height: 876),
        .leftTwoThirds: BTRect(x: 0, y: 24, width: 800, height: 876),
        .rightTwoThirds: BTRect(x: 400, y: 24, width: 800, height: 876),
        .topLeftQuarter: BTRect(x: 0, y: 24, width: 600, height: 438),
        .topRightQuarter: BTRect(x: 600, y: 24, width: 600, height: 438),
        .bottomLeftQuarter: BTRect(x: 0, y: 462, width: 600, height: 438),
        .bottomRightQuarter: BTRect(x: 600, y: 462, width: 600, height: 438),
        .topLeftSixth: BTRect(x: 0, y: 24, width: 400, height: 438),
        .topCenterSixth: BTRect(x: 400, y: 24, width: 400, height: 438),
        .topRightSixth: BTRect(x: 800, y: 24, width: 400, height: 438),
        .bottomLeftSixth: BTRect(x: 0, y: 462, width: 400, height: 438),
        .bottomCenterSixth: BTRect(x: 400, y: 462, width: 400, height: 438),
        .bottomRightSixth: BTRect(x: 800, y: 462, width: 400, height: 438),
        .maximize: testDisplay.visibleFrame,
        .almostMaximize: BTRect(x: 24, y: 48, width: 1152, height: 828),
        .center: BTRect(x: 350, y: 262, width: 500, height: 400),
        .centerResize: BTRect(x: 120, y: 111.6, width: 960, height: 700.8),
        .moveLeft: BTRect(x: 60, y: 100, width: 500, height: 400),
        .moveRight: BTRect(x: 140, y: 100, width: 500, height: 400),
        .moveUp: BTRect(x: 100, y: 60, width: 500, height: 400),
        .moveDown: BTRect(x: 100, y: 140, width: 500, height: 400),
        .growWidth: BTRect(x: 100, y: 100, width: 540, height: 400),
        .shrinkWidth: BTRect(x: 100, y: 100, width: 460, height: 400),
        .growHeight: BTRect(x: 100, y: 100, width: 500, height: 440),
        .shrinkHeight: BTRect(x: 100, y: 100, width: 500, height: 360),
    ]
    let actions = WindowAction.allCases.filter { !$0.isDisplayTransfer && !$0.isRestore }
    #expect(Set(expected.keys) == Set(actions))
    for action in actions {
        let target = try #require(StandardActionEngine().targetFrame(for: action, window: window, display: testDisplay))
        let frame = try #require(expected[action])
        #expect(target.approximatelyEquals(frame, tolerance: 0.001), "Incorrect frame for \(action)")
        #expect(target.minX >= testDisplay.visibleFrame.minX)
        #expect(target.minY >= testDisplay.visibleFrame.minY)
        #expect(target.maxX <= testDisplay.visibleFrame.maxX + 0.001)
        #expect(target.maxY <= testDisplay.visibleFrame.maxY + 0.001)
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

@Test func snapZoneCornersHaveAGenerousTriggerRegion() {
    let detector = SnapZoneDetector()
    #expect(detector.target(at: BTPoint(x: 1, y: 25), display: testDisplay)?.action == .topLeftQuarter)
    // Exercise both axes and translated display coordinates at every corner.
    let bounds = BTRect(x: -1200, y: 200, width: 1200, height: 800)
    for (x, y, dx, dy, area) in [
        (bounds.minX, bounds.minY, 1.0, 1.0, SnapArea.topLeft),
        (bounds.maxX, bounds.minY, -1.0, 1.0, SnapArea.topRight),
        (bounds.minX, bounds.maxY, 1.0, -1.0, SnapArea.bottomLeft),
        (bounds.maxX, bounds.maxY, -1.0, -1.0, SnapArea.bottomRight),
    ] {
        #expect(detector.area(at: BTPoint(x: x + dx * 69, y: y + dy * 69), in: bounds) == area)
        #expect(detector.area(at: BTPoint(x: x + dx * 70, y: y + dy * 69), in: bounds) == nil)
        #expect(detector.area(at: BTPoint(x: x + dx * 69, y: y + dy * 70), in: bounds) == nil)
        #expect(detector.area(at: BTPoint(x: x - dx, y: y - dy), in: bounds) == nil)
    }
    #expect(detector.target(at: BTPoint(x: 69, y: 2), display: testDisplay)?.action == .topLeftQuarter)
    #expect(detector.target(at: BTPoint(x: 70, y: 2), display: testDisplay)?.action == .almostMaximize)
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
