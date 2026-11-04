import Foundation
import Testing
@testable import BetterTileCore

private let groupedGeometry = LayoutWheelFanGeometry(
    wheel: LayoutWheelGeometry(hubRadius: 26, innerRingOuterRadius: 88, outerRingInnerRadius: 94)!,
    innerRadius: 164, outerRadius: 230)
private func groupedVector(_ sector: LayoutWheelSector, radius: Double = 124) -> BTPoint {
    let angle = Double(sector.rawValue) * .pi / 4
    return BTPoint(x: sin(angle) * radius, y: -cos(angle) * radius)
}

@Test func groupedLegacyStyleLiteralKeepsEverySavedField() throws {
    // Literal pre-style fixture, with a user Empty and a hidden outer assignment.
    let fixture = Data(#"{"innerSlots":[null,{"windowAction":{"_0":"rightHalf"}},null,null,null,null,null,null],"isEnabled":true,"keyboardModifiers":7,"keyboardTriggerEnabled":true,"levelCount":1,"middleClickTriggerEnabled":false,"outerSlots":[{"repairBento":{}},null,null,null,null,null,null,null],"scale":0.85}"#.utf8)
    let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: fixture)
    #expect(wheel.style == .custom)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let migrated = try encoder.encode(wheel)
    let originalFields = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    var migratedFields = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
    for key in ["appearance", "groupOverrides", "groupedInnerSlots", "slotDefaults", "triggers"] {
        migratedFields.removeValue(forKey: key)
    }
    #expect(NSDictionary(dictionary: originalFields).isEqual(to: migratedFields))
    var grouped = wheel
    grouped.style = .grouped
    #expect(try JSONDecoder().decode(LayoutWheelConfiguration.self, from: encoder.encode(grouped)) == grouped)
    #expect(grouped.effectiveLevelCount == .one)
    grouped.style = .custom
    #expect(try encoder.encode(grouped) == migrated)
}

@Test func groupedActionsMatchFixedDesignAndNeverReadCustomSlots() {
    var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two, innerSlots: Array(repeating: nil, count: 8),
                                         outerSlots: Array(repeating: nil, count: 8))
    #expect(LayoutWheelSector.allCases.map { LayoutWheelGroup.at($0).title } ==
            ["Size", "Thirds", "Displays", "Mode", "Restore", "Choose Layout", "Sixths", "Move"])
    for sector in LayoutWheelSector.allCases {
        #expect(wheel.command(at: .init(ring: .inner, sector: sector)) == LayoutWheelConfiguration.defaultInnerSlots[sector.rawValue])
        #expect(LayoutWheelGroup.at(sector).options.count <= 6)
    }
    #expect(wheel.command(at: .init(ring: .outer, sector: .top)) == .windowAction(.maximize))
    #expect(wheel.command(at: .init(ring: .outer, sector: .right)) == .windowAction(.nextDisplay))
    #expect(wheel.command(at: .init(ring: .outer, sector: .bottom)) == .windowAction(.restore))
    #expect(LayoutWheelGroup.at(.top).options == [.windowAction(.almostMaximize), .windowAction(.center), .windowAction(.centerResize)])
    #expect(LayoutWheelGroup.at(.bottomRight).options == [.setMode(.manual), .setMode(.bento), .setMode(.tabbed)])
    #expect(LayoutWheelGroup.at(.bottomLeft).options == [.single, .columns, .rows, .focus, .grid].map(LayoutWheelCommand.chooseLayout))
    wheel.style = .custom
    #expect(wheel.innerSlots.allSatisfy { $0 == nil })
    #expect(wheel.outerSlots.allSatisfy { $0 == nil })
}

@Test func groupedFlickVersusRestAndMovingRestOrigin() {
    var state = LayoutWheelFanState()
    state.update(vector: groupedVector(.top), at: 0, geometry: groupedGeometry)
    #expect(state.phase == .hovering(.top, deadline: 0.2))
    state.update(vector: groupedVector(.top, radius: 1000), at: 0.05, geometry: groupedGeometry)
    #expect(state.release() == .windowAction(.maximize)) // Beyond every ring still selects by direction.
    state.update(vector: groupedVector(.top), at: 1, geometry: groupedGeometry)
    state.update(vector: groupedVector(.top, radius: 132), at: 1.19, geometry: groupedGeometry)
    state.update(vector: groupedVector(.top, radius: 132), at: 1.38, geometry: groupedGeometry)
    #expect(state.openSector == nil)
    state.update(vector: groupedVector(.top, radius: 132), at: 1.4, geometry: groupedGeometry)
    #expect(state.openSector == .top)
    #expect(state.optionIndex == nil) // Opening never selects a child.
    #expect(state.release() == .windowAction(.maximize))
}

@Test(arguments: LayoutWheelSector.allCases.filter { !LayoutWheelGroup.at($0).options.isEmpty })
func groupedEveryFanOptionMapsToItsCommand(_ sector: LayoutWheelSector) {
    for (index, command) in LayoutWheelGroup.at(sector).options.enumerated() {
        var state = LayoutWheelFanState()
        let vector = groupedVector(sector)
        state.update(vector: vector, at: 0, geometry: groupedGeometry)
        state.update(vector: vector, at: 0.2, geometry: groupedGeometry)
        state.update(vector: groupedGeometry.point(sector: sector, option: index), at: 0.3, geometry: groupedGeometry)
        #expect(state.optionIndex == index)
        #expect(state.release() == command)
        #expect(state.phase == .idle)
        #expect(state.release() == nil)
    }
}

@Test func groupedFanAttachmentAndAngularHysteresis() {
    var state = LayoutWheelFanState()
    state.update(vector: groupedVector(.top), at: 0, geometry: groupedGeometry)
    state.update(vector: groupedVector(.top), at: 0.2, geometry: groupedGeometry)
    state.update(vector: groupedGeometry.point(sector: .top, option: 1, radius: 173), at: 0.3, geometry: groupedGeometry)
    #expect(state.optionIndex == nil)
    state.update(vector: groupedGeometry.point(sector: .top, option: 1, radius: 175), at: 0.4, geometry: groupedGeometry)
    #expect(state.optionIndex == 1)
    state.update(vector: groupedGeometry.point(sector: .top, option: 1, radius: 160), at: 0.5, geometry: groupedGeometry)
    #expect(state.optionIndex == 1)
    let angle = groupedGeometry.optionAngle / 2
    state.update(vector: BTPoint(x: sin(angle + 0.01) * 200, y: -cos(angle + 0.01) * 200), at: 0.6, geometry: groupedGeometry)
    #expect(state.optionIndex == 1)
    state.update(vector: BTPoint(x: sin(angle + 0.04) * 200, y: -cos(angle + 0.04) * 200), at: 0.7, geometry: groupedGeometry)
    #expect(state.optionIndex == nil) // The gap between the 30-degree tiles is neutral.
    state.update(vector: groupedGeometry.point(sector: .top, option: 2), at: 0.75, geometry: groupedGeometry)
    #expect(state.optionIndex == 2)
    state.update(vector: groupedVector(.top, radius: 90), at: 0.8, geometry: groupedGeometry)
    #expect(state.openSector == nil) // Retreat toward the hub closes the fan.
}

@Test func groupedSectorHysteresisHubEscapeAndDisabledLayout() {
    var state = LayoutWheelFanState()
    state.update(vector: groupedVector(.top), at: 0, geometry: groupedGeometry)
    let angle = Double.pi / 8
    state.update(vector: BTPoint(x: sin(angle + 0.01) * 124, y: -cos(angle + 0.01) * 124), at: 0.1, geometry: groupedGeometry)
    #expect(state.selection?.sector == .top)
    state.update(vector: BTPoint(x: sin(angle + 0.08) * 124, y: -cos(angle + 0.08) * 124), at: 0.2, geometry: groupedGeometry)
    #expect(state.selection?.sector == .topRight)
    state.update(vector: BTPoint(x: 0, y: 0), at: 0.3, geometry: groupedGeometry)
    #expect(state.release() == nil)
    state.update(vector: groupedVector(.bottomLeft), at: 1, geometry: groupedGeometry, layoutAvailable: false)
    state.update(vector: groupedVector(.bottomLeft), at: 2, geometry: groupedGeometry, layoutAvailable: false)
    #expect(state.openSector == nil)
    #expect(state.release() == nil)
    state.update(vector: groupedVector(.top), at: 3, geometry: groupedGeometry)
    state.handleKey(.escape)
    #expect(state.release() == nil)
}

@Test func groupedKeyboardCanOpenAndSelectFansWithoutPointerTime() {
    var state = LayoutWheelFanState()
    state.handleKey(.nextSector) // Inner Top.
    state.handleKey(.outerRing)
    state.handleKey(.outerRing)
    #expect(state.openSector == .top)
    #expect(state.optionIndex == nil)
    state.handleKey(.nextSector)
    #expect(state.release() == .windowAction(.almostMaximize))
}

@Test(arguments: [LayoutWheelSector.top, .bottomRight])
func groupedStationaryReleaseKeepsParentAfterFanReveal(_ sector: LayoutWheelSector) {
    var state = LayoutWheelFanState()
    let resting = groupedVector(sector, radius: 197)
    state.update(vector: resting, at: 0, geometry: groupedGeometry)
    state.update(vector: resting, at: 0.2, geometry: groupedGeometry)
    #expect(state.openSector == sector)
    // Mouse-up supplies another sample, even when the pointer never moved.
    state.update(vector: resting, at: 0.3, geometry: groupedGeometry)
    #expect(state.optionIndex == nil)
    #expect(state.release() == LayoutWheelGroup.at(sector).quickAction)
}

@Test func groupedPostRevealMovementMustCrossHysteresisBeforeSelectingOption() {
    var state = LayoutWheelFanState()
    let resting = groupedVector(.bottomRight, radius: 197)
    state.update(vector: resting, at: 0, geometry: groupedGeometry)
    state.update(vector: resting, at: 0.2, geometry: groupedGeometry)
    state.update(vector: BTPoint(x: resting.x + 3, y: resting.y), at: 0.3, geometry: groupedGeometry)
    #expect(state.optionIndex == nil)
    state.update(vector: groupedGeometry.point(sector: .bottomRight, option: 1, radius: 210), at: 0.4, geometry: groupedGeometry)
    #expect(state.optionIndex == 1)
    #expect(state.release() == .setMode(.bento))
}

@Test func groupedRestThenRetreatToHubCancelsWithoutSelectingOption() {
    var state = LayoutWheelFanState()
    let resting = groupedVector(.bottomRight, radius: 197)
    state.update(vector: resting, at: 0, geometry: groupedGeometry)
    state.update(vector: resting, at: 0.2, geometry: groupedGeometry)
    state.update(vector: BTPoint(x: 0, y: 0), at: 0.3, geometry: groupedGeometry)
    #expect(state.openSector == nil)
    #expect(state.optionIndex == nil)
    #expect(state.release() == nil)
}

@Test func groupedDirectionalFansUseCompassPositions() {
    let expected: [(LayoutWheelSector, [Double])] = [
        (.topLeft, [0, -90, 90, 180]),
        (.topRight, [-90, 0, 90, -135, 135]),
        (.left, [-60, 0, 60, -120, 180, 120]),
        (.top, [-45, 0, 45])
    ]
    for (sector, degrees) in expected {
        for (option, degree) in degrees.enumerated() {
            #expect(abs(groupedGeometry.angle(sector: sector, option: option) - degree * .pi / 180) < 0.0001)
        }
    }
    let down = groupedGeometry.point(sector: .topLeft, option: 3)
    #expect(down.y > 0)
    #expect(abs(down.x) < 0.0001)
}
