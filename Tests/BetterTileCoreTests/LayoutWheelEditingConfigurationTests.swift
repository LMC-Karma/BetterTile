import Foundation
import Testing
@testable import BetterTileCore

@Suite struct LayoutWheelEditingConfigurationTests {
    @Test func defaultsAndSchemaStayCompatible() throws {
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data("{}".utf8))
        #expect(wheel == LayoutWheelConfiguration())
        #expect(BetterTileConfiguration.currentSchemaVersion == 12)
        for sector in LayoutWheelSector.allCases {
            #expect(wheel.group(at: sector) == .defaults(at: sector))
        }
    }

    @Test func legacyGroupedKeepsItsInnerRing() throws {
        // Pre-editor schema-12 file: levelCount was only Custom's preference.
        let fixture = #"{"style":"grouped","isEnabled":true,"levelCount":1,"keyboardTriggerEnabled":true,"keyboardModifiers":14,"middleClickTriggerEnabled":false,"scale":1}"#
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(fixture.utf8))
        #expect(wheel.levelCount == .two)
        #expect(wheel.groupedInnerSlots == LayoutWheelConfiguration.defaultInnerSlots)
        #expect(wheel.activeRings == [.inner, .outer])
        let saved = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: JSONEncoder().encode(wheel))
        #expect(saved == wheel)
    }

    @Test(arguments: ["groupedInnerSlots", "groupOverrides", "triggers"])
    func editorFilesKeepExplicitOneLevel(marker: String) throws {
        let value = marker == "groupedInnerSlots" ? "[]" : "{}"
        let json = "{\"style\":\"grouped\",\"levelCount\":1,\"\(marker)\":\(value)}"
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(json.utf8))
        #expect(wheel.levelCount == .one)
    }

    @Test func unknownKeyboardTriggerDisablesKeyboard() throws {
        let json = #"{"triggers":{"keyboard":"future","keyboardEnabled":true,"modifiers":7}}"#
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(json.utf8))
        #expect(!wheel.triggers.keyboardEnabled)
        #expect(!wheel.keyboardTriggerEnabled)
        let saved = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: JSONEncoder().encode(wheel))
        #expect(!saved.triggers.keyboardEnabled)
        let missing = try JSONDecoder().decode(LayoutWheelTriggers.self, from: Data("{}".utf8))
        #expect(missing.keyboardEnabled)
    }

    @Test func unknownGroupedInnerCommandBecomesEmptyWithoutShiftingSlots() throws {
        let json = #"{"style":"grouped","levelCount":2,"groupedInnerSlots":[{"repairBento":{}},{"futureCommand":{}},null,{"windowAction":{"_0":"futureAction"}},{"windowAction":{"_0":"center"}},null,null,null]}"#
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(json.utf8))
        #expect(wheel.groupedInnerSlots == [.repairBento, nil, nil, nil, .windowAction(.center), nil, nil, nil])
        #expect(wheel.innerSlots == LayoutWheelConfiguration.defaultInnerSlots)
        #expect(wheel.group(at: .top) == .defaults(at: .top))
        let saved = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: JSONEncoder().encode(wheel))
        #expect(saved == wheel)
    }

    @Test func editsRoundTripWithoutReplacingCustom() throws {
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let custom = wheel.innerSlots
        wheel.groupedInnerSlots[0] = .repairBento
        wheel.setGroup(.init(quickAction: nil, options: [.setMode(.manual), nil, .repairBento]), at: .top)
        wheel.triggers = .init(keyboard: .rightControl, mouse: .optionMiddleClick)
        let decoded = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: JSONEncoder().encode(wheel))
        #expect(decoded == wheel)
        #expect(decoded.innerSlots == custom)
        #expect(decoded.command(at: .init(ring: .inner, sector: .top)) == .repairBento)
        #expect(decoded.group(at: .top).options[1] == nil)
    }

    @Test func unknownChildDropsOnlyThatChild() throws {
        let json = #"{"groupOverrides":{"0":{"quickAction":{"windowAction":{"_0":"maximize"}},"options":[{"repairBento":{}},{"futureCommand":{}},null,{"windowAction":{"_0":"futureAction"}},{"windowAction":{"_0":"center"}}]}}}"#
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(json.utf8))
        #expect(wheel.group(at: .top).quickAction == .windowAction(.maximize))
        #expect(wheel.group(at: .top).options == [.repairBento, nil, .windowAction(.center)])
        #expect(wheel.group(at: .left) == .defaults(at: .left))
    }

    @Test func explicitAppearanceOwnsSizeAndResetsLegacyScale() {
        var wheel = LayoutWheelConfiguration(scale: 0.85)
        wheel.appearance = .init()
        #expect(wheel.scale == 1)
        let explicit = LayoutWheelConfiguration(scale: 0.85, appearance: .init(size: .large))
        #expect(explicit.scale == 1.2)
    }

    @Test func editedCountsAreBoundedAndEmptyIsRetained() {
        var wheel = LayoutWheelConfiguration()
        wheel.groupOverrides[0] = .init(quickAction: nil, options: Array(repeating: nil, count: 20))
        #expect(wheel.normalized().group(at: .top).options.count == 6)
        wheel.setGroup(.init(quickAction: .repairBento, options: []), at: .bottom)
        #expect(wheel.group(at: .bottom).options.isEmpty)
    }

    @Test func newTriggerFallbackDoesNotReserveAnotherGesture() throws {
        struct Legacy: Decodable {
            let keyboardTriggerEnabled: Bool
            let keyboardModifiers: ShortcutModifiers
            let middleClickTriggerEnabled: Bool
        }
        for mouse in LayoutWheelTriggers.Mouse.allCases {
            let wheel = LayoutWheelConfiguration(triggers: .init(keyboard: .rightControl, modifiers: [.control], mouse: mouse))
            let legacy = try JSONDecoder().decode(Legacy.self, from: JSONEncoder().encode(wheel))
            #expect(!legacy.keyboardTriggerEnabled)
            #expect(legacy.keyboardModifiers.rawValue.nonzeroBitCount >= 2)
            #expect(legacy.middleClickTriggerEnabled == (mouse == .middleClick))
        }
    }

    @Test func legacyTriggersMigrateAndNestedTriggersWin() throws {
        let legacy = #"{"keyboardTriggerEnabled":false,"keyboardModifiers":5,"middleClickTriggerEnabled":true}"#
        let wheel = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(legacy.utf8))
        #expect(!wheel.triggers.keyboardEnabled)
        #expect(wheel.triggers.modifiers == [.control, .command])
        #expect(wheel.triggers.mouse == .middleClick)
        let nested = #"{"keyboardTriggerEnabled":false,"middleClickTriggerEnabled":true,"triggers":{"keyboardEnabled":true,"keyboard":"rightControl","mouse":"optionMiddleClick"}}"#
        let next = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: Data(nested.utf8))
        #expect(next.triggers.keyboardEnabled)
        #expect(next.triggers.keyboard == .rightControl)
        #expect(next.triggers.mouse == .optionMiddleClick)
    }

    @Test(arguments: LayoutWheelLevelCount.allCases)
    func editedFansUseActualCountAndAssignments(_ levels: LayoutWheelLevelCount) {
        var wheel = LayoutWheelConfiguration(style: .grouped, levelCount: levels)
        wheel.setGroup(.init(quickAction: .repairBento,
                             options: [.windowAction(.restore), nil, .setMode(.manual), .repairBento, .windowAction(.center), .windowAction(.maximize)]), at: .right)
        let geometry = LayoutWheelFanGeometry(
            wheel: .init(hubRadius: 32, innerRingOuterRadius: 88, outerRingInnerRadius: 94)!,
            innerRadius: 164, outerRadius: 230, configuration: wheel)
        for index in 0..<6 {
            var state = LayoutWheelFanState()
            let parent = BTPoint(x: 124, y: 0)
            state.update(vector: parent, at: 0, geometry: geometry)
            state.update(vector: parent, at: 0.2, geometry: geometry)
            state.update(vector: geometry.point(sector: .right, option: index), at: 0.3, geometry: geometry)
            #expect(state.optionIndex == index)
            #expect(state.release() == wheel.group(at: .right).options[index])
        }
    }

    @Test func groupedOneLevelUsesGroupsAndKeyboardOpensChildren() {
        let wheel = LayoutWheelConfiguration(style: .grouped, levelCount: .one)
        #expect(wheel.activeRings == [.inner])
        #expect(wheel.command(at: .init(ring: .inner, sector: .top)) == .windowAction(.maximize))
        var state = LayoutWheelFanState()
        state.handleKey(.nextSector, configuration: wheel)
        state.handleKey(.outerRing, configuration: wheel)
        #expect(state.openSector == .top)
        state.handleKey(.nextSector, configuration: wheel)
        #expect(state.release() == .windowAction(.almostMaximize))
    }
}
