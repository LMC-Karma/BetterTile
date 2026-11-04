import Foundation
import Testing
@testable import BetterTileCore

struct LayoutWheelOneLevelDefaultsTests {
    private let bottom = LayoutWheelSelection(ring: .inner, sector: .bottom)

    private func decode(_ object: [String: Any]) throws -> LayoutWheelConfiguration {
        try JSONDecoder().decode(LayoutWheelConfiguration.self,
                                 from: JSONSerialization.data(withJSONObject: object))
    }

    private func encodedSlots(_ slots: [LayoutWheelCommand?]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(slots))
    }

    @Test func oneLevelBottomDefaultsToRepairLayout() {
        let wheel = LayoutWheelConfiguration()
        #expect(wheel.levelCount == .one)
        #expect(wheel.command(at: bottom) == .repairBento)
        var expected = LayoutWheelConfiguration.defaultInnerSlots
        expected[LayoutWheelSector.bottom.rawValue] = .repairBento
        #expect(wheel.innerSlots == expected)
    }

    @Test func twoLevelsKeepBottomHalfBecauseTheOuterRingHasRepair() {
        let wheel = LayoutWheelConfiguration(levelCount: .two)
        #expect(wheel.command(at: bottom) == .windowAction(.bottomHalf))
        #expect(wheel.outerSlots.contains(.repairBento))
    }

    @Test func untouchedFirstReleaseDefaultsMoveToRepairOnce() throws {
        // 0.5.2 saved the full slot list with no slotDefaults key.
        let old = try decode(["isEnabled": true, "levelCount": 1,
                              "innerSlots": encodedSlots(LayoutWheelConfiguration.defaultInnerSlots)])
        #expect(old.command(at: bottom) == .repairBento)

        // After one save the user may choose Bottom Half again, and it stays.
        var chosen = old
        chosen.innerSlots[LayoutWheelSector.bottom.rawValue] = .windowAction(.bottomHalf)
        let reloaded = try JSONDecoder().decode(LayoutWheelConfiguration.self,
                                                from: JSONEncoder().encode(chosen))
        #expect(reloaded.command(at: bottom) == .windowAction(.bottomHalf))
    }

    @Test func customizedOrTwoLevelFirstReleaseSlotsAreKept() throws {
        var custom = LayoutWheelConfiguration.defaultInnerSlots
        custom[0] = .windowAction(.maximize)
        let edited = try decode(["levelCount": 1, "innerSlots": encodedSlots(custom)])
        #expect(edited.innerSlots == custom)

        let twoLevels = try decode(["levelCount": 2,
                                    "innerSlots": encodedSlots(LayoutWheelConfiguration.defaultInnerSlots)])
        #expect(twoLevels.innerSlots == LayoutWheelConfiguration.defaultInnerSlots)
    }

    @Test func resetSlotUsesTheLevelDefault() {
        let one = LayoutWheelConfiguration(style: .custom, levelCount: .one)
        let two = LayoutWheelConfiguration(style: .custom, levelCount: .two)
        #expect(one.command(at: bottom) == .repairBento)
        #expect(two.command(at: bottom) == .windowAction(.bottomHalf))
    }
}
