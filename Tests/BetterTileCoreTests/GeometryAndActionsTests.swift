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
    let actions = WindowAction.allCases.filter { !$0.isDisplayTransfer && !$0.isRestore && !$0.isTabCommand && $0 != .showTabBar }
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

@Test(arguments: [1.0, 5, 40], [16.0, 64, 160])
func snapActivationBandsKeepExactBoundariesAndCornerPriority(edgeWidth: Double, cornerExtension: Double) {
    let detector = SnapZoneDetector(edgeActivationDistance: edgeWidth, cornerActivationSize: cornerExtension)
    let bounds = BTRect(x: -1200, y: 200, width: 1200, height: 800)
    let reach = edgeWidth + cornerExtension
    for (x, y, dx, dy, area) in [
        (bounds.minX, bounds.minY, 1.0, 1.0, SnapArea.topLeft),
        (bounds.maxX, bounds.minY, -1.0, 1.0, SnapArea.topRight),
        (bounds.minX, bounds.maxY, 1.0, -1.0, SnapArea.bottomLeft),
        (bounds.maxX, bounds.maxY, -1.0, -1.0, SnapArea.bottomRight),
    ] {
        #expect(detector.area(at: BTPoint(x: x + dx * reach, y: y + dy * reach), in: bounds) == area)
        #expect(detector.area(at: BTPoint(x: x + dx * (reach + 1), y: y + dy * reach), in: bounds) == nil)
        #expect(detector.area(at: BTPoint(x: x + dx * reach, y: y + dy * (reach + 1)), in: bounds) == nil)
        #expect(detector.area(at: BTPoint(x: x + dx * edgeWidth, y: y + dy * reach), in: bounds) == area)
        #expect(detector.area(at: BTPoint(x: x + dx * reach, y: y + dy * edgeWidth), in: bounds) == area)
    }
    for (point, outside, area) in [
        (BTPoint(x: bounds.minX + edgeWidth, y: bounds.midY), BTPoint(x: bounds.minX + edgeWidth + 1, y: bounds.midY), SnapArea.left),
        (BTPoint(x: bounds.maxX - edgeWidth, y: bounds.midY), BTPoint(x: bounds.maxX - edgeWidth - 1, y: bounds.midY), SnapArea.right),
        (BTPoint(x: bounds.midX, y: bounds.minY + edgeWidth), BTPoint(x: bounds.midX, y: bounds.minY + edgeWidth + 1), SnapArea.top),
        (BTPoint(x: bounds.midX, y: bounds.maxY - edgeWidth), BTPoint(x: bounds.midX, y: bounds.maxY - edgeWidth - 1), SnapArea.bottom),
    ] {
        #expect(detector.area(at: point, in: bounds) == area)
        #expect(detector.isInEdgeBand(at: point, in: bounds))
        #expect(detector.area(at: outside, in: bounds) == nil)
        #expect(!detector.isInEdgeBand(at: outside, in: bounds))
    }
    #expect(!detector.isInEdgeBand(at: BTPoint(x: bounds.minX - 1, y: bounds.midY), in: bounds))
}

@Test func wideSnapBandsUseFullDisplayBoundsAndPlaceInsideMenuBarAndDockInsets() {
    let display = DisplaySnapshot(
        id: testDisplay.id,
        frame: testDisplay.frame,
        visibleFrame: BTRect(x: 60, y: 24, width: 1080, height: 816)
    )
    let detector = SnapZoneDetector(edgeActivationDistance: 40, cornerActivationSize: 160)
    let bindings = SnapArea.allCases.map { SnapAreaBinding(area: $0, action: .maximize) }
    for point in [BTPoint(x: 600, y: 30), BTPoint(x: 600, y: 870),
                  BTPoint(x: 30, y: 450), BTPoint(x: 1170, y: 450)] {
        #expect(detector.target(at: point, display: display, snapAreas: bindings)?.frame == display.visibleFrame)
        #expect(SnapZoneDetector().target(at: point, display: display, snapAreas: bindings) == nil)
    }
    // The work-area edge is not an additional activation band.
    #expect(detector.target(at: BTPoint(x: 600, y: 840), display: display, snapAreas: bindings) == nil)
    #expect(detector.target(at: BTPoint(x: 60, y: 450), display: display, snapAreas: bindings) == nil)
}

@Test(arguments: [false, true])
func wideSnapBandsFollowThePointerAcrossSharedDisplayEdges(stacked: Bool) throws {
    let first = DisplaySnapshot(id: .init(rawValue: "first"),
        frame: BTRect(x: -1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: -1000, y: 24, width: 1000, height: 776))
    let second = DisplaySnapshot(id: .init(rawValue: "second"),
        frame: first.frame.offsetBy(dx: stacked ? 0 : 1000, dy: stacked ? 800 : 0),
        visibleFrame: first.visibleFrame.offsetBy(dx: stacked ? 0 : 1000, dy: stacked ? 800 : 0))
    let detector = SnapZoneDetector(edgeActivationDistance: 40, cornerActivationSize: 160)
    let bindings = SnapArea.allCases.map { SnapAreaBinding(area: $0, action: $0 == .bottom ? .bottomHalf : .maximize) }
    for (distance, expectedDisplay, expectedArea) in [
        (-40.0, first, stacked ? SnapArea.bottom : .right),
        (0, second, stacked ? .top : .left),
        (40, second, stacked ? .top : .left),
    ] {
        let point = stacked ? BTPoint(x: -500, y: 800 + distance) : BTPoint(x: distance, y: 400)
        let display = try #require(PointerDisplay.display(at: point, in: [first, second]))
        #expect(display.id == expectedDisplay.id)
        #expect(detector.area(at: point, in: display.frame) == expectedArea)
        #expect(detector.target(at: point, display: display, snapAreas: bindings) != nil)
    }
    let point = stacked ? BTPoint(x: -500, y: 799) : BTPoint(x: -1, y: 400)
    #expect(detector.target(at: point, display: second, snapAreas: bindings) == nil)
}
