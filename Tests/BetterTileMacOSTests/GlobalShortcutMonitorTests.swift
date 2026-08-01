import Carbon.HIToolbox
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func carbonModifierFlagsMatchConfiguredShortcutModifiers() {
    let allModifiers: ShortcutModifiers = [.control, .option, .shift, .command]

    #expect(ShortcutModifiers.control.carbonFlags == UInt32(controlKey))
    #expect(ShortcutModifiers.option.carbonFlags == UInt32(optionKey))
    #expect(
        allModifiers.carbonFlags
            == UInt32(controlKey | optionKey | shiftKey | cmdKey)
    )
}

@Test @MainActor func hotKeyIDsRoundTripEveryWindowAction() {
    for (index, action) in WindowAction.allCases.enumerated() {
        #expect(GlobalShortcutMonitor.action(forHotKeyID: UInt32(index + 1)) == action)
    }
    #expect(GlobalShortcutMonitor.action(forHotKeyID: 0) == nil)
    #expect(GlobalShortcutMonitor.action(forHotKeyID: UInt32(WindowAction.allCases.count + 1)) == nil)
}
