import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelLongLabelTests {
    private let longNames: [WindowAction] = [.bottomLeftQuarter, .bottomRightQuarter, .bottomCenterSixth,
        .topCenterSixth, .bottomRightSixth, .moveTabToNextPane, .moveTabToPreviousPane,
        .topRightQuarter, .rightTwoThirds, .topRightSixth, .bottomLeftSixth, .almostMaximize, .moveTabRight]

    private func input(levels: LayoutWheelLevelCount = .two, scale: Double = 1,
                       worst: Bool = true) -> LayoutWheelSceneInput {
        var config = LayoutWheelConfiguration(levelCount: levels, scale: scale)
        if worst { config.innerSlots = Array(repeating: .windowAction(.bottomCenterSixth), count: 8) }
        return .init(configuration: config)
    }

    @Test(arguments: [0.8, 1.0, 1.2])
    func fullLongNamesFitTheWellWithoutSmallerThreeLineType(scale: Double) {
        let space = LayoutWheelLabelSpace(input(scale: scale))
        var full = 0
        for action in longNames {
            let label = LayoutWheelCentreLabel(name: action.title, space: space)
            let expected = scale == 0.8 ? false
                : ![WindowAction.moveTabToNextPane, .moveTabToPreviousPane].contains(action)
            let actual = label.placement == .well && !label.usedShortName
            #expect(actual == expected, "\(action.title), scale \(scale): \(label)")
            if actual {
                full += 1
                #expect(label.lines.map(\.text).joined(separator: " ") == action.title)
            }
            if label.lines.count == 3 {
                #expect(label.placement == .well && !label.usedShortName)
                #expect(label.lines.allSatisfy { $0.fontSize == max(10, 11 * scale) && $0.height == max(12, 13 * scale) })
            }
            if scale >= 1 && action == .moveTabToNextPane {
                #expect(label.placement == .tag && !label.usedShortName)
                #expect(label.lines.map(\.text).joined(separator: " ") == action.title)
            }
            if scale >= 1 && action == .moveTabToPreviousPane {
                #expect(label.usedShortName && label.lines.map(\.text).joined(separator: " ") == "To Prev. Pane")
            }
        }
        #expect(full == (scale == 0.8 ? 0 : 11))
        let groupedActions = longNames.filter { ![WindowAction.moveTabToNextPane, .moveTabToPreviousPane, .moveTabRight].contains($0) }
        var grouped = input(scale: scale)
        grouped.configuration.style = .grouped
        let groupedSpace = LayoutWheelLabelSpace(grouped)
        for action in groupedActions {
            let label = LayoutWheelCentreLabel(name: action.title, space: groupedSpace)
            #expect((label.placement == .well) == (scale >= 1), "Grouped \(action.title), scale \(scale)")
            #expect(!label.usedShortName)
        }
    }

    @Test func baseThreeLinesPrecedeCompactTwoLinesAndTags() {
        for name in ["Right Two Thirds", "Bottom Right Sixth", "Bottom Left Quarter"] {
            let label = LayoutWheelCentreLabel(name: name, space: .init(input()))
            #expect(label.placement == .well && !label.usedShortName)
            #expect(label.lines.count == 3)
            #expect(label.lines.allSatisfy { $0.fontSize == 11 && $0.height == 13 })
        }
        let large = LayoutWheelCentreLabel(name: "Top Center Sixth", space: .init(input(scale: 1.2)))
        #expect(large.lines.map(\.text) == ["Top", "Center", "Sixth"])
        #expect(large.lines.allSatisfy { $0.fontSize == 13.2 && $0.height == 15.6 })
        let small = LayoutWheelCentreLabel(name: "Right Two Thirds", space: .init(input(scale: 0.8)))
        #expect(small.lines.count == 2 && small.usesTag)
        #expect(small.lines.allSatisfy { $0.fontSize >= 9 })
    }

    @Test(arguments: [0.8, 1.0, 1.2])
    func threeLinesReserveTheFixedUnavailableMarkForEveryName(scale: Double) {
        let space = LayoutWheelLabelSpace(input(scale: scale))
        let lines = ["Top", "Center", "Sixth"].map {
            LayoutWheelCentreLabel.measured($0, size: max(10, 11 * scale), height: max(12, 13 * scale))
        }
        #expect(space.fits(lines, in: .well) == (scale >= 1))
        for action in longNames {
            var available = input(scale: scale)
            available.configuration.outerSlots[LayoutWheelSector.right.rawValue] = .windowAction(action)
            available.selection = .init(ring: .outer, sector: .right)
            var unavailable = available
            unavailable.unavailableCommands = [.windowAction(action)]
            #expect(available.centreLabel == unavailable.centreLabel)
            let label = available.centreLabel!
            let top = -label.height / 2 - (label.usesTag ? 3 * scale : 0)
            #expect(top - space.markFrame.maxY >= scale - 0.001)
        }
    }

    @Test func tagTextClearsEveryDrawnLensOutline() {
        var tags = 0
        let commands = WindowAction.allCases.map(LayoutWheelCommand.windowAction)
        for levels in [LayoutWheelLevelCount.one, .two] {
            for scale in [0.8, 1.0, 1.2] {
                for worst in [false, true] {
                    for command in commands {
                        for sector in LayoutWheelSector.allCases {
                            var input = input(levels: levels, scale: scale, worst: worst)
                            input.configuration.innerSlots[sector.rawValue] = command
                            input.selection = .init(ring: .inner, sector: sector)
                            let label = input.centreLabel!
                            #expect(label.placement != .truncated, "\(command), \(levels), \(scale), worst=\(worst), \(sector)")
                            guard label.usesTag else { continue }
                            tags += 1
                            let drawn = LayoutWheelDrawnMetrics(input)
                            var y = -label.height / 2
                            for line in label.lines {
                                let text = CGRect(x: -line.width / 2, y: y, width: line.width, height: line.height)
                                for ring in input.configuration.activeRings {
                                    for direction in LayoutWheelSector.allCases {
                                        let selection = LayoutWheelSelection(ring: ring, sector: direction)
                                        let center = drawn.iconPoint(selection)
                                        let dx = max(text.minX - center.x, 0, center.x - text.maxX)
                                        let dy = max(text.minY - center.y, 0, center.y - text.maxY)
                                        let radius = drawn.lensRadius(selection, lean: .init(x: 0, y: 0))
                                        // The outline is one point wide, including at Small.
                                        #expect(hypot(dx, dy) >= radius + 0.5 + 2 * scale - 0.001,
                                            "\(command), \(levels), \(scale), worst=\(worst), slot=\(sector), lens=\(selection), line=\(line.text)")
                                    }
                                }
                                y += line.height
                            }
                        }
                    }
                }
            }
        }
        #expect(tags > 0)
    }
}
