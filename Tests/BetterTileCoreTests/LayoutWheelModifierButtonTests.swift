import Testing
@testable import BetterTileCore

/// The Layout Wheel page shows one toggle button for each chord modifier.
/// These rules decide what a press does.
struct LayoutWheelModifierButtonTests {
    @Test func defaultChordLocksNothing() {
        let triggers = LayoutWheelTriggers()
        #expect(triggers.modifiers == [.control, .option, .shift])
        for modifier in [ShortcutModifiers.control, .option, .shift, .command] {
            #expect(!triggers.isLocked(modifier))
        }
    }

    @Test func buttonsAddAndRemoveOneModifierEach() {
        var triggers = LayoutWheelTriggers()
        triggers.setModifier(.command, enabled: true)
        #expect(triggers.modifiers == [.control, .option, .shift, .command])
        triggers.setModifier(.shift, enabled: false)
        #expect(triggers.modifiers == [.control, .option, .command])
    }

    @Test func theLastTwoModifiersStayOn() {
        var triggers = LayoutWheelTriggers(modifiers: [.control, .option])
        #expect(triggers.isLocked(.control) && triggers.isLocked(.option))
        #expect(!triggers.isLocked(.shift))
        triggers.setModifier(.control, enabled: false)
        #expect(triggers.modifiers == [.control, .option])
        triggers.setModifier(.shift, enabled: true)
        #expect(triggers.modifiers == [.control, .option, .shift])
        #expect(!triggers.isLocked(.control))
    }

    @Test func buttonsShowTheStoredChord() {
        let chord = LayoutWheelTriggers(modifiers: [.option, .command])
        #expect(chord.isOn(.option) && chord.isOn(.command) && !chord.isOn(.control) && !chord.isOn(.shift))
        // While Right Control is the trigger, every chord button is off.
        let rightControl = LayoutWheelTriggers(keyboard: .rightControl, modifiers: [.option, .command])
        #expect(![ShortcutModifiers.control, .option, .shift, .command].contains { rightControl.isOn($0) })
    }

    @Test func rightControlKeepsTheStoredChordAndLocksNothing() {
        var triggers = LayoutWheelTriggers(keyboard: .rightControl, modifiers: [.option, .command])
        #expect(!triggers.isLocked(.option) && !triggers.isLocked(.command))
        // A press returns to the stored chord and changes nothing else.
        triggers.setModifier(.shift, enabled: true)
        #expect(triggers.keyboard == .modifiers)
        #expect(triggers.modifiers == [.option, .command])
    }

    @Test func buttonsLeaveTheMouseTriggerAndTheKeyboardSwitchAlone() {
        var triggers = LayoutWheelTriggers(keyboardEnabled: false, mouse: .optionMiddleClick)
        triggers.setModifier(.command, enabled: true)
        #expect(triggers.mouse == .optionMiddleClick)
        #expect(!triggers.keyboardEnabled)
    }
}
