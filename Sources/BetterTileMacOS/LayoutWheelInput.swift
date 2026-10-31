import AppKit
import BetterTileCore
import IOKit.hidsystem

/// Scalar input only. Side-specific SDK masks stay at the macOS boundary.
struct LayoutWheelInput: Equatable, Sendable {
    var keyCode: UInt16 = 0
    var modifiers: ShortcutModifiers = []
    var rawModifierFlags: UInt = 0

    init(keyCode: UInt16 = 0, modifiers: ShortcutModifiers = [], rawModifierFlags: UInt = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.rawModifierFlags = rawModifierFlags
    }

    init(keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, modifiers: ShortcutModifiers(flags), rawModifierFlags: flags.rawValue)
    }

    static let rightControlKeyCode: UInt16 = 0x3E
    private static let otherSideKeys = UInt(NX_DEVICELCTLKEYMASK | NX_DEVICELSHIFTKEYMASK
        | NX_DEVICERSHIFTKEYMASK | NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK
        | NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK)
    var rightControlIsDown: Bool { rawModifierFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 }
    var hasOtherSideKey: Bool { rawModifierFlags & Self.otherSideKeys != 0 }
    /// Fn is not a trigger modifier, so it always counts as an extra one.
    /// Arrow and navigation keys also set this flag while they are held.
    var functionIsDown: Bool { rawModifierFlags & NSEvent.ModifierFlags.function.rawValue != 0 }
    /// The Fn (Globe) key's own key codes. Only a flags change that carries one
    /// of these says that the physical key moved.
    private static let functionKeyCodes: Set<UInt16> = [0x3F, 0xB3]
    var isFunctionKeyEvent: Bool { Self.functionKeyCodes.contains(keyCode) }
    /// The same input without the function flag.
    var withoutFunctionFlag: Self {
        var input = self
        input.rawModifierFlags &= ~NSEvent.ModifierFlags.function.rawValue
        return input
    }
    var isRightControlOnly: Bool {
        modifiers == .control && rightControlIsDown && !hasOtherSideKey && !functionIsDown
    }
    var isNeutral: Bool {
        modifiers.isEmpty && !rightControlIsDown && !hasOtherSideKey && !functionIsDown
    }
}
