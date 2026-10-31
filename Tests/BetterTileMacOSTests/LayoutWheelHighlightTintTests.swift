import AppKit
import Testing
@_spi(LiquidWheelPrototype) @testable import BetterTileCore
@_spi(LiquidWheelPrototype) @testable import BetterTileMacOS

/// Action tint colours the highlight by the kind of the hovered icon. Every slice must have a source.
@MainActor @Suite(.macOSTestApplication) struct LayoutWheelHighlightTintTests {
    private func tint(_ content: LayoutWheelLiquidContent, _ state: LayoutWheelLiquidState) -> NSColor? {
        LayoutWheelLiquidPresenter.highlightTint(content: content, state: state)
    }

    private func configurations() -> [(String, LayoutWheelConfiguration)] {
        var result: [(String, LayoutWheelConfiguration)] = []
        for style in [LayoutWheelStyle.custom, .grouped] {
            for levels in [LayoutWheelLevelCount.one, .two] {
                result.append(("\(style) \(levels)", LayoutWheelConfiguration(style: style, levelCount: levels)))
            }
        }
        return result
    }

    @Test func everyRingSliceInEveryStyleHasAHighlightColour() {
        for (name, configuration) in configurations() {
            let content = LayoutWheelLiquidContent(configuration: configuration, levelCount: configuration.levelCount)
            for ring in configuration.activeRings {
                for sector in LayoutWheelSector.allCases {
                    let state = LayoutWheelLiquidState(selection: .init(ring: ring, sector: sector))
                    #expect(tint(content, state) != nil, "\(name), \(ring) ring, \(sector)")
                }
            }
        }
    }

    @Test func everyGroupParentTakesItsOwnKindsColour() throws {
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let content = LayoutWheelLiquidContent(configuration: configuration, levelCount: .two)
        for sector in LayoutWheelSector.allCases {
            let group = configuration.group(at: sector)
            let state = LayoutWheelLiquidState(selection: .init(ring: configuration.groupRing, sector: sector))
            let colour = try #require(tint(content, state), "\(sector) has no highlight colour")
            // The colour is the kind of the quick flick, or of the group's first child.
            let source = try #require(group.quickAction ?? group.options.compactMap { $0 }.first)
            #expect(colour == LayoutWheelLiquidPresenter.actionTint(source), "\(sector)")
        }
    }

    @Test func everyGroupChildTakesItsOwnKindsColour() throws {
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let content = LayoutWheelLiquidContent(configuration: configuration, levelCount: .two)
        for sector in LayoutWheelSector.allCases {
            for (index, command) in configuration.group(at: sector).options.enumerated() {
                let state = LayoutWheelLiquidState(selection: .init(ring: configuration.groupRing, sector: sector),
                                                   openSector: sector, aimedOption: index)
                let colour = try #require(tint(content, state), "\(sector) child \(index)")
                #expect(colour == LayoutWheelLiquidPresenter.actionTint(command))
            }
        }
    }

    @Test func theOwnerOfAnOpenSubmenuTakesItsKindEvenWithoutASelection() throws {
        let configuration = LayoutWheelConfiguration(style: .grouped, levelCount: .two)
        let content = LayoutWheelLiquidContent(configuration: configuration, levelCount: .two)
        // Thirds has no quick flick; with its submenu open and nothing selected it keeps the kind of its first child.
        let state = LayoutWheelLiquidState(selection: nil, openSector: .topRight, aimedOption: nil)
        #expect(tint(content, state) == LayoutWheelLiquidPresenter.actionTint(.windowAction(.leftThird)))
    }
}
