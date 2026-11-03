import Foundation
import Testing
@testable import BetterTileCore

@Suite struct LayoutWheelGlowPrototypeTests {
    private let layout = LayoutWheelLiquidLayout(outerRadius: 154, stepRadius: 91, wellRadius: 32,
                                                iconRadii: [60, 124], dropletRadius: 22)

    @Test func iconTintUsesModelTimeAndLeavesOtherIconsAtInk() {
        var model = LayoutWheelLiquid(layout: layout)
        model.open()
        model.update(.init(focus: .init(ring: 1, slot: 2)))
        #expect(model.iconTint(ring: 1, slot: 2) == 0)
        model.advance(0.06)
        #expect(abs(model.iconTint(ring: 1, slot: 2) - 0.5) < 1e-9)
        #expect(model.iconTint(ring: 1, slot: 1) == 0)
        model.advance(0.06)
        #expect(abs(model.iconTint(ring: 1, slot: 2) - 1) < 1e-9)
        model.update(.init())
        model.advance(0.06)
        #expect(abs(model.iconTint(ring: 1, slot: 2) - 0.5) < 1e-9)
        model.advance(0.06)
        #expect(model.iconTint(ring: 1, slot: 2) == 0)
    }

    @Test func fanDimmingTracksOpenState() {
        var model = LayoutWheelLiquid(layout: layout)
        model.open()
        model.update(.init(focus: .init(ring: 1, slot: 2),
                           fan: .init(parentSlot: 2, options: [.init(x: 197, y: 0)])))
        model.advance(0.06); model.advance(0.06)
        #expect(model.submenuDimming == 1)
        model.update(.init())
        model.advance(0.06); model.advance(0.06)
        #expect(model.submenuDimming == 0)
    }
    @Test func settledFanAddsNoRimPullAndKeepsTheAimedBulge() {
        var plain = LayoutWheelLiquid(layout: layout)
        plain.open()
        plain.update(.init(pointer: .init(x: 124, y: 0), focus: .init(ring: 1, slot: 2)))
        for _ in 0..<600 { plain.advance(1.0 / 120) }
        var fan = plain
        fan.update(.init(pointer: .init(x: 197, y: 0), focus: .init(ring: 1, slot: 2),
                         fan: .init(parentSlot: 2, options: [.init(x: 197, y: 0)], aimedOption: 0)))
        let connectionFrames = Int(ceil(LayoutWheelLiquidDroplet.openingConnectionWindow.upperBound * 120))
        for _ in 0..<connectionFrames { fan.advance(1.0 / 120) }
        #expect(fan.droplets.allSatisfy { $0.connection == 0 })
        for _ in 0..<600 { fan.advance(1.0 / 120) }
        #expect(fan.droplets.allSatisfy { $0.connection == 0 })
        #expect(abs(fan.outer.radius(at: 0) - plain.outer.radius(at: 0)) < 0.01)
        #expect(fan.outer.radius(at: 0) - layout.outerRadius > 1)
        if let path = ProcessInfo.processInfo.environment["WH_GLOW_DIAGNOSTICS"] {
            let row: [String: Double] = ["restRadius": layout.outerRadius,
                "aimedRadius": plain.outer.radius(at: 0), "fanRadius": fan.outer.radius(at: 0),
                "fanOnlyDisplacement": fan.outer.radius(at: 0) - plain.outer.radius(at: 0),
                "aimedBulge": plain.outer.radius(at: 0) - layout.outerRadius,
                "connection": fan.droplets[0].connection, "gap": fan.gap(of: fan.droplets[0])]
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(filePath: path).appendingPathComponent("no-pull.json"))
        }
    }

}
