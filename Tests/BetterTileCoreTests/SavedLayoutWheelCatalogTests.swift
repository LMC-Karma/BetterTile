import Foundation
import Testing
@testable import BetterTileCore

struct SavedLayoutWheelCatalogTests {
    @Test func savedCategoryKeepsEightGroupsAndLeavesConfigurationBytesUnchanged() throws {
        for level in [LayoutWheelLevelCount.one, .two] {
            var base = LayoutWheelConfiguration(style: .grouped, levelCount: level)
            let customized = LayoutWheelGroupContents(quickAction: nil,
                options: [.maximize, .center, .leftHalf, .rightHalf, .topHalf, .bottomHalf].map { .windowAction($0) })
            base.setGroup(customized, at: .bottomLeft)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let before = try encoder.encode(base)
            var runtime = base
            runtime.savedLayouts = (0..<9).map { .init(file: "file\($0).json", name: "Layout \($0)") }
            let root = runtime.group(at: .bottomLeft)
            #expect(root.options.count == 6)
            #expect(root.options.last == .savedLayouts)
            #expect(Array(root.options.prefix(4)) == Array(customized.options.prefix(4)))
            #expect(root.options[4] == .moreLayoutChoices)
            #expect(runtime.groupedInnerSlots == base.groupedInnerSlots)
            #expect(LayoutWheelSector.allCases.count == 8)
            #expect(try encoder.encode(runtime) == before)
            runtime.browsingSavedLayouts = true
            #expect(runtime.group(at: .bottomLeft).options.count == 6)
            #expect(runtime.group(at: .bottomLeft).options.last == .moreSavedLayouts)
            #expect(try encoder.encode(runtime) == before)
            runtime.savedLayouts = []
            #expect(runtime.group(at: .bottomLeft) == customized)
            #expect(try encoder.encode(runtime) == before)
            let decoded = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: before)
            #expect(decoded.savedLayouts.isEmpty && !decoded.browsingSavedLayouts)
        }
    }
    @Test func zeroOneSixAndSevenLayoutsHaveBoundedFans() {
        var wheel = LayoutWheelConfiguration(style: .grouped)
        #expect(wheel.group(at: .bottomLeft).options.count == 5)
        for count in [1, 6, 7] {
            wheel.savedLayouts = (0..<count).map { .init(file: "\($0).json", name: "Layout \($0)") }
            wheel.browsingSavedLayouts = false
            #expect(wheel.group(at: .bottomLeft).options.count == 6)
            wheel.browsingSavedLayouts = true
            #expect(wheel.group(at: .bottomLeft).options.count == min(count, 6))
            #expect(wheel.group(at: .bottomLeft).options.contains(.moreSavedLayouts) == (count > 6))
        }
    }
}
