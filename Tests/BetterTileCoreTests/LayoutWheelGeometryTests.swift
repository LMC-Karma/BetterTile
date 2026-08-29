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
