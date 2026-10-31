import Foundation
import Testing
@testable import BetterTileCore

/// Random Custom configurations encode, decode, and encode again to the same
/// bytes, and Custom never writes a style key.
@Test func customLayoutWheelConfigurationRoundTripsByteForByte() throws {
    var state: UInt64 = 0xC0FF_EE20_2610_21
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    let pool: [LayoutWheelCommand?] = [nil, .repairBento]
        + WindowAction.allCases.map(LayoutWheelCommand.windowAction)
        + LayoutMode.allCases.map(LayoutWheelCommand.setMode)
        + TabbedPreset.allCases.map(LayoutWheelCommand.chooseLayout)
    let modifiers: [ShortcutModifiers] = [.control, .option, .shift, .command]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for _ in 0..<2000 {
        func slots() -> [LayoutWheelCommand?] {
            (0..<LayoutWheelConfiguration.slotCount).map { _ in pool[Int(next() % UInt64(pool.count))] }
        }
        let chosen = modifiers.filter { _ in next() % 2 == 0 }
        var configuration = LayoutWheelConfiguration(
            style: .custom, isEnabled: next() % 2 == 0, levelCount: next() % 2 == 0 ? .one : .two,
            innerSlots: slots(), outerSlots: slots(), keyboardTriggerEnabled: next() % 2 == 0,
            keyboardModifiers: ShortcutModifiers(chosen), middleClickTriggerEnabled: next() % 2 == 0,
            scale: 0.8 + Double(next() % 1_000_001) / 1_000_000 * 0.5
        ).normalized()
        configuration.appearance.surfacePreset = LayoutWheelSurfacePreset.allCases[Int(next() % 3)]
        configuration.appearance.surfaceStrengths = .init(
            liquidGlass: Double(next() % 101) / 100,
            light: Double(next() % 101) / 100,
            dark: Double(next() % 101) / 100
        )
        let first = try encoder.encode(configuration)
        let decoded = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: first)
        let second = try encoder.encode(decoded)
        #expect(decoded == configuration)
        #expect(first == second)
        #expect(!String(decoding: first, as: UTF8.self).contains("\"style\""))
        // Grouped round trips too, and never rewrites Custom assignments.
        var grouped = configuration
        grouped.style = .grouped
        let groupedDecoded = try JSONDecoder().decode(LayoutWheelConfiguration.self, from: encoder.encode(grouped))
        #expect(groupedDecoded == grouped)
        #expect(groupedDecoded.innerSlots == configuration.innerSlots)
    }
}
