import Foundation
import Testing
@testable import BetterTileCore

private let wheelGeometry = LayoutWheelGeometry(
    hubRadius: 30,
    innerRingOuterRadius: 78,
    outerRingInnerRadius: 86
)!

private func wheelVector(angle: Double, radius: Double = 60) -> BTPoint {
    BTPoint(x: sin(angle) * radius, y: -cos(angle) * radius)
}

@Test func wheelDirectionsMapClockwiseFromTop() {
    let directions: [(BTPoint, LayoutWheelSector)] = [
        (BTPoint(x: 0, y: -60), .top),
        (BTPoint(x: 60, y: -60), .topRight),
        (BTPoint(x: 60, y: 0), .right),
        (BTPoint(x: 60, y: 60), .bottomRight),
        (BTPoint(x: 0, y: 60), .bottom),
        (BTPoint(x: -60, y: 60), .bottomLeft),
        (BTPoint(x: -60, y: 0), .left),
        (BTPoint(x: -60, y: -60), .topLeft),
    ]

    for (vector, sector) in directions {
        #expect(
            wheelGeometry.selection(for: vector, levelCount: .one)
                == LayoutWheelSelection(ring: .inner, sector: sector)
        )
    }
}

@Test func wheelSectorBoundariesBelongToClockwiseSector() {
    let sectorWidth = Double.pi / 4
    let epsilon = 0.000_001

    for index in LayoutWheelSector.allCases.indices {
        let boundary = (Double(index) + 0.5) * sectorWidth
        let next = LayoutWheelSector(rawValue: (index + 1) % LayoutWheelSector.allCases.count)!

        #expect(
            wheelGeometry.selection(
                for: wheelVector(angle: boundary - epsilon),
                levelCount: .one
            )?.sector.rawValue == index
        )
        #expect(
            wheelGeometry.selection(
                for: wheelVector(angle: boundary + epsilon),
                levelCount: .one
            )?.sector == next
        )
        #expect(
            wheelGeometry.selection(
                for: wheelVector(angle: boundary),
                levelCount: .one
            )?.sector == next
        )
    }
}

@Test func wheelAngleWraparoundStaysInTopSector() {
    let justClockwise = wheelVector(angle: -.pi / 8 + 0.000_001)
    let justCounterclockwise = wheelVector(angle: 2 * .pi - .pi / 8 - 0.000_001)

    #expect(wheelGeometry.selection(for: justClockwise, levelCount: .one)?.sector == .top)
    #expect(wheelGeometry.selection(for: justCounterclockwise, levelCount: .one)?.sector == .topLeft)
}

@Test func wheelTwoLevelRadiiHaveExplicitOwnership() {
    #expect(wheelGeometry.selection(for: BTPoint(x: 0, y: -30), levelCount: .two) == nil)
    #expect(
        wheelGeometry.selection(for: BTPoint(x: 0, y: -30.001), levelCount: .two)?.ring == .inner
    )
    #expect(
        wheelGeometry.selection(for: BTPoint(x: 0, y: -78), levelCount: .two)?.ring == .inner
    )
    #expect(wheelGeometry.selection(for: BTPoint(x: 0, y: -82), levelCount: .two) == nil)
    #expect(
        wheelGeometry.selection(for: BTPoint(x: 0, y: -86), levelCount: .two)?.ring == .outer
    )
    #expect(
        wheelGeometry.selection(for: BTPoint(x: 0, y: -10_000), levelCount: .two)?.ring == .outer
    )
}

@Test func wheelOneLevelIgnoresOuterRingDistances() {
    #expect(
        wheelGeometry.selection(for: BTPoint(x: 0, y: -82), levelCount: .one)?.ring == .inner
    )
    #expect(
        wheelGeometry.selection(for: BTPoint(x: 0, y: -10_000), levelCount: .one)?.ring == .inner
    )
}

@Test func wheelRejectsInvalidGeometryAndVectors() {
    #expect(LayoutWheelGeometry(
        hubRadius: -.leastNonzeroMagnitude,
        innerRingOuterRadius: 78,
        outerRingInnerRadius: 86
    ) == nil)
    #expect(LayoutWheelGeometry(
        hubRadius: 30,
        innerRingOuterRadius: 30,
        outerRingInnerRadius: 86
    ) == nil)
    #expect(LayoutWheelGeometry(
        hubRadius: 30,
        innerRingOuterRadius: 78,
        outerRingInnerRadius: 78
    ) == nil)
    #expect(LayoutWheelGeometry(
        hubRadius: .nan,
        innerRingOuterRadius: 78,
        outerRingInnerRadius: 86
    ) == nil)

    #expect(
        wheelGeometry.selection(for: BTPoint(x: .infinity, y: 0), levelCount: .two) == nil
    )
    #expect(
        wheelGeometry.selection(for: BTPoint(x: 0, y: .nan), levelCount: .two) == nil
    )
}

private let wheelDisplay = BTRect(x: 0, y: 0, width: 1600, height: 1000)

@Test func wheelOpensUnderThePointerWhenThereIsRoom() {
    let placement = LayoutWheelPlacement.clamped(
        anchor: BTPoint(x: 800, y: 500),
        diameter: 356,
        visibleFrame: wheelDisplay
    )

    #expect(placement.center == BTPoint(x: 800, y: 500))
    #expect(placement.anchor == placement.center)
}

/// Clamping moves only the drawing. If it moved the anchor too, a wheel opened
/// near a corner would rotate every direction toward the middle of the display
/// and the sector under the pointer would stop matching the one drawn there.
@Test func clampingKeepsTheAngularAnchorWherePointerWas() {
    let anchor = BTPoint(x: 12, y: 990)
    let placement = LayoutWheelPlacement.clamped(
        anchor: anchor,
        diameter: 356,
        visibleFrame: wheelDisplay
    )
    let geometry = wheelGeometry

    #expect(placement.anchor == anchor)
    #expect(placement.center != anchor)
    #expect(placement.frame.minX >= wheelDisplay.minX)
    #expect(placement.frame.minY >= wheelDisplay.minY)
    #expect(placement.frame.maxX <= wheelDisplay.maxX)
    #expect(placement.frame.maxY <= wheelDisplay.maxY)

    // A pointer directly above the anchor is still the top sector.
    let above = BTPoint(x: anchor.x - placement.anchor.x, y: anchor.y - 60 - placement.anchor.y)
    #expect(geometry.selection(for: above, levelCount: .two)?.sector == .top)
}

/// A second display has its own origin. Clamping has to use that display's own
/// frame rather than assuming the wheel sits near zero.
@Test func clampingUsesTheDisplayTheWheelOpenedOn() {
    let secondary = BTRect(x: 1600, y: -200, width: 1280, height: 800)
    let placement = LayoutWheelPlacement.clamped(
        anchor: BTPoint(x: 2870, y: 580),
        diameter: 356,
        visibleFrame: secondary
    )

    #expect(placement.frame.maxX <= secondary.maxX)
    #expect(placement.frame.maxY <= secondary.maxY)
    #expect(placement.frame.minY >= secondary.minY)
    #expect(placement.anchor == BTPoint(x: 2870, y: 580))
}

/// A display smaller than the wheel cannot hold it. Centring keeps as much
/// visible as possible instead of pinning it to one edge.
@Test func aDisplaySmallerThanTheWheelCentresIt() {
    let small = BTRect(x: 0, y: 0, width: 300, height: 240)
    let placement = LayoutWheelPlacement.clamped(
        anchor: BTPoint(x: 10, y: 10),
        diameter: 356,
        visibleFrame: small
    )

    #expect(placement.center == small.center)
    #expect(placement.anchor == BTPoint(x: 10, y: 10))
}

@Test func keyboardEntersTheWheelAtTheTopOfTheInnerRing() {
    for key in [LayoutWheelKey.nextSector, .previousSector, .switchRing, .outerRing, .innerRing] {
        #expect(
            LayoutWheelKeyboard.selection(for: key, from: nil, levelCount: .two)
                == LayoutWheelSelection(ring: .inner, sector: .top)
        )
    }
    #expect(LayoutWheelKeyboard.selection(for: .escape, from: nil, levelCount: .two) == nil)
    #expect(LayoutWheelKeyboard.selection(for: .commit, from: nil, levelCount: .two) == nil)
}

@Test func keyboardStepsAroundTheRingAndWrapsBothWays() {
    let top = LayoutWheelSelection(ring: .inner, sector: .top)

    #expect(LayoutWheelKeyboard.selection(for: .previousSector, from: top, levelCount: .two)
        == LayoutWheelSelection(ring: .inner, sector: .topLeft))
    #expect(LayoutWheelKeyboard.selection(for: .nextSector, from: top, levelCount: .two)
        == LayoutWheelSelection(ring: .inner, sector: .topRight))

    let topLeft = LayoutWheelSelection(ring: .inner, sector: .topLeft)
    #expect(LayoutWheelKeyboard.selection(for: .nextSector, from: topLeft, levelCount: .two) == top)
}

/// One Level hides the outer ring, so no key may select it.
@Test func keyboardCannotReachTheOuterRingWithOneLevel() {
    let inner = LayoutWheelSelection(ring: .inner, sector: .right)

    #expect(LayoutWheelKeyboard.selection(for: .switchRing, from: inner, levelCount: .one) == inner)
    #expect(LayoutWheelKeyboard.selection(for: .outerRing, from: inner, levelCount: .one) == inner)
    #expect(LayoutWheelKeyboard.selection(for: .switchRing, from: inner, levelCount: .two)
        == LayoutWheelSelection(ring: .outer, sector: .right))
}

@Test func commandLookupSurvivesAShortSlotList() {
    var configuration = LayoutWheelConfiguration()
    #expect(configuration.command(at: .init(ring: .inner, sector: .top)) == .windowAction(.topHalf))
    #expect(configuration.command(at: .init(ring: .outer, sector: .topLeft)) == .repairBento)

    configuration.innerSlots = []
    #expect(configuration.command(at: .init(ring: .inner, sector: .top)) == nil)
}
