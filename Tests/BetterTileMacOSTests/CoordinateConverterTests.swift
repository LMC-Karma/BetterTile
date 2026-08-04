import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Display arrangements that have historically produced coordinate bugs in
/// window managers: a secondary display to the left (negative origins), above,
/// below, and a taller main display than the one being converted against.
private let mainScreenFrames: [(name: String, frame: CGRect)] = [
    ("single 1080p", CGRect(x: 0, y: 0, width: 1920, height: 1080)),
    ("retina main", CGRect(x: 0, y: 0, width: 3456, height: 2234)),
    ("short main", CGRect(x: 0, y: 0, width: 1440, height: 900)),
]

private let rects: [(name: String, rect: CGRect)] = [
    ("origin", CGRect(x: 0, y: 0, width: 100, height: 100)),
    ("offset", CGRect(x: 320, y: 180, width: 640, height: 480)),
    ("negative x, display to the left", CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
    ("negative y, display below", CGRect(x: 0, y: -1080, width: 1920, height: 1080)),
    ("display above", CGRect(x: 0, y: 1080, width: 1920, height: 1080)),
    ("fractional", CGRect(x: 10.5, y: 20.25, width: 300.75, height: 200.125)),
    ("zero height", CGRect(x: 5, y: 5, width: 100, height: 0)),
]

@Test func appKitAndTopLeftConversionRoundTripsForEveryArrangement() {
    for main in mainScreenFrames {
        for candidate in rects {
            let topLeft = CoordinateConverter.toTopLeft(candidate.rect, mainScreenFrame: main.frame)
            let restored = CoordinateConverter.toAppKit(topLeft, mainScreenFrame: main.frame)
            #expect(
                restored.minX == candidate.rect.minX,
                "x drifted for \(candidate.name) on \(main.name)"
            )
            #expect(
                restored.minY == candidate.rect.minY,
                "y drifted for \(candidate.name) on \(main.name)"
            )
            #expect(restored.width == candidate.rect.width)
            #expect(restored.height == candidate.rect.height)
        }
    }
}

@Test func conversionFlipsVerticallyAroundTheMainScreenTop() {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    // An AppKit rect sitting on the bottom edge is at the top-left bottom.
    let bottomEdge = CoordinateConverter.toTopLeft(
        CGRect(x: 0, y: 0, width: 400, height: 300),
        mainScreenFrame: main
    )
    #expect(bottomEdge.minY == 780)
    #expect(bottomEdge.maxY == 1080)

    // An AppKit rect flush with the top edge is at the top-left origin.
    let topEdge = CoordinateConverter.toTopLeft(
        CGRect(x: 0, y: 780, width: 400, height: 300),
        mainScreenFrame: main
    )
    #expect(topEdge.minY == 0)
}

@Test func horizontalCoordinatesAreNeverFlipped() {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let converted = CoordinateConverter.toTopLeft(
        CGRect(x: -500, y: 100, width: 200, height: 200),
        mainScreenFrame: main
    )
    #expect(converted.minX == -500)
    #expect(converted.size.width == 200)
}

@Test func aDisplayAboveTheMainScreenProducesNegativeTopLeftCoordinates() {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let above = CoordinateConverter.toTopLeft(
        CGRect(x: 0, y: 1080, width: 1920, height: 1080),
        mainScreenFrame: main
    )
    #expect(above.minY == -1080)
    #expect(above.maxY == 0)
}

@Test func pointConversionAgreesWithRectConversion() {
    for main in mainScreenFrames {
        for candidate in rects {
            let rect = CoordinateConverter.toTopLeft(candidate.rect, mainScreenFrame: main.frame)
            let point = CoordinateConverter.pointToTopLeft(
                CGPoint(x: candidate.rect.minX, y: candidate.rect.maxY),
                mainScreenFrame: main.frame
            )
            #expect(point.x == rect.minX, "x mismatch for \(candidate.name) on \(main.name)")
            #expect(point.y == rect.minY, "y mismatch for \(candidate.name) on \(main.name)")
        }
    }
}
