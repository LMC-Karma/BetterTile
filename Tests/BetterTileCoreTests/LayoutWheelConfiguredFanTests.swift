import Foundation
import Testing
@testable import BetterTileCore

@Suite struct LayoutWheelConfiguredFanTests {
    private let geometry = LayoutWheelGeometry(hubRadius: 32, innerRingOuterRadius: 68, outerRingInnerRadius: 76)!

    @Test(arguments: [LayoutWheelLevelCount.one, .two], 1...6)
    func editedChildrenUseTheSameLockForBothLevels(levels: LayoutWheelLevelCount, count: Int) {
        var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: levels)
        let commands: [LayoutWheelCommand?] = [.setMode(.tabbed), .repairBento, nil, .windowAction(.center),
                                               .chooseLayout(.grid), .windowAction(.restore)]
        configuration.setGroup(.init(quickAction: .windowAction(.rightHalf), options: Array(commands.prefix(count))), at: .top)
        let layout = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 20)
        for (index, point) in layout.positions(sector: .top, count: count).enumerated() {
            var state = LayoutWheelFanState()
            let rest = BTPoint(x: 0, y: levels == .one ? -60 : -98)
            state.update(vector: rest, at: 0, geometry: geometry, layout: layout, configuration: configuration)
            state.update(vector: rest, at: 0.2, geometry: geometry, layout: layout, configuration: configuration)
            #expect(state.openSector == .top)
            #expect(state.selection?.ring == configuration.groupRing)
            #expect(state.command == .windowAction(.rightHalf))
            state.update(vector: point, at: 0.3, geometry: geometry, layout: layout,
                         lockBeyondRim: .withinGroupAngle, configuration: configuration)
            #expect(state.optionIndex == index)
            #expect(state.release() == commands[index])
        }
    }

    @Test func editedInnerSlotsAndMixedLayoutAvailability() {
        var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        configuration.groupedInnerSlots[0] = .windowAction(.restore)
        configuration.setGroup(.init(quickAction: nil, options: [.chooseLayout(.grid), .windowAction(.center)]), at: .bottomLeft)
        let layout = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 20)
        var state = LayoutWheelFanState()
        state.update(vector: .init(x: 0, y: -50), at: 0, geometry: geometry, layout: layout,
                     layoutAvailable: false, configuration: configuration)
        #expect(state.command == .windowAction(.restore))
        let rest = BTPoint(x: -69, y: 69)
        state.update(vector: rest, at: 1, geometry: geometry, layout: layout, layoutAvailable: false, configuration: configuration)
        state.update(vector: rest, at: 1.2, geometry: geometry, layout: layout, layoutAvailable: false, configuration: configuration)
        #expect(state.openSector == .bottomLeft)
    }

    @Test func emptyEditedGroupNeverOpensAndAChangedGroupCannotKeepAStaleChild() {
        var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let layout = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 20)
        var state = LayoutWheelFanState()
        let rest = BTPoint(x: 98, y: 0)
        state.update(vector: rest, at: 0, geometry: geometry, layout: layout, configuration: configuration)
        state.update(vector: rest, at: 0.2, geometry: geometry, layout: layout, configuration: configuration)
        state.update(vector: layout.positions(sector: .right, count: 1)[0], at: 0.3,
                     geometry: geometry, layout: layout, configuration: configuration)
        #expect(state.optionIndex == 0)
        configuration.setGroup(.init(quickAction: nil, options: []), at: .right)
        state.update(vector: rest, at: 1, geometry: geometry, layout: layout, configuration: configuration)
        state.update(vector: rest, at: 2, geometry: geometry, layout: layout, configuration: configuration)
        #expect(state.openSector == nil && state.optionIndex == nil && state.deadline == nil && state.command == nil)
    }

    @Test func boundedLockUsesEditedOptionSpan() {
        var configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        // Displays has one default child; six edited children reach past its default span.
        configuration.setGroup(.init(quickAction: nil, options: Array(repeating: .repairBento, count: 6)), at: .right)
        let layout = LayoutWheelSubmenuLayout(rimRadius: 120, optionRadius: 20)
        let farOption = layout.positions(sector: .right, count: 6)[5]
        var state = LayoutWheelFanState()
        state.update(vector: .init(x: 98, y: 0), at: 0, geometry: geometry, layout: layout, configuration: configuration)
        state.update(vector: .init(x: 98, y: 0), at: 0.2, geometry: geometry, layout: layout, configuration: configuration)
        state.update(vector: farOption, at: 0.3, geometry: geometry, layout: layout,
                     lockBeyondRim: .withinGroupAngle, configuration: configuration)
        #expect(state.openSector == .right && state.optionIndex == 5)
        #expect(state.command == .repairBento)
    }
}
