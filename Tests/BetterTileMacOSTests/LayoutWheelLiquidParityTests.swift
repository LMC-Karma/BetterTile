import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Suite(.macOSTestApplication) struct LayoutWheelLiquidParityTests {
    @Test(arguments: [LayoutWheelStyle.custom, .grouped], [LayoutWheelLevelCount.one, .two])
    func configuredContentMatchesPanel(style: LayoutWheelStyle, levels: LayoutWheelLevelCount) {
        var configuration = LayoutWheelConfiguration(style: style, levelCount: levels)
        configuration.groupOverrides[LayoutWheelSector.top.rawValue] = .init(
            quickAction: .windowAction(.leftHalf), options: [.windowAction(.rightHalf), .setMode(.tabbed), nil])
        configuration.groupedInnerSlots[0] = .repairBento
        let unavailable: Set<LayoutWheelCommand> = [.windowAction(.rightHalf), .setMode(.tabbed)]
        let modes: [LayoutMode?] = [nil, .manual, .bento, .tabbed]
        for layoutAvailable in [false, true] {
            for currentMode in modes {
                let scene = LayoutWheelSceneInput(configuration: configuration, unavailableCommands: unavailable,
                    layoutAvailable: layoutAvailable, currentMode: currentMode)
                let liquid = LayoutWheelLiquidContent(configuration: configuration, levelCount: levels,
                    unavailableCommands: unavailable, layoutAvailable: layoutAvailable, currentMode: currentMode)
                #expect(liquid.unavailableCommands == unavailable)
                #expect(liquid.currentMode == currentMode && liquid.layoutAvailable == layoutAvailable)
                for ring in configuration.activeRings {
                    for sector in LayoutWheelSector.allCases {
                        let selection = LayoutWheelSelection(ring: ring, sector: sector)
                        #expect(liquid.slot(selection) == scene.slot(.sector(selection)))
                        #expect(liquid.command(.init(selection: selection)) == configuration.command(at: selection))
                    }
                }
                if style == .grouped {
                    for sector in LayoutWheelSector.allCases {
                        let options = configuration.group(at: sector).options
                        #expect(liquid.fanOptions(sector).count == options.count)
                        for index in options.indices {
                            #expect(liquid.fanOptions(sector)[index] == scene.slot(.option(sector, index)))
                            #expect(liquid.command(.init(openSector: sector, aimedOption: index)) == options[index])
                        }
                    }
                }
            }
        }
    }
}
