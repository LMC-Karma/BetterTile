import Foundation

/// Keyboard and mouse activation reset together, independently of wheel content.
public struct LayoutWheelTriggers: Codable, Hashable, Sendable {
    public enum Keyboard: String, Codable, CaseIterable, Sendable {
        case modifiers, rightControl
    }
    public enum Mouse: String, Codable, CaseIterable, Sendable {
        case off, middleClick, optionMiddleClick
    }

    public static let defaultModifiers: ShortcutModifiers = [.control, .option, .shift]
    public var keyboardEnabled: Bool
    public var keyboard: Keyboard
    public var modifiers: ShortcutModifiers
    public var mouse: Mouse

    public init(keyboardEnabled: Bool = true, keyboard: Keyboard = .modifiers,
                modifiers: ShortcutModifiers = Self.defaultModifiers, mouse: Mouse = .off) {
        self.keyboardEnabled = keyboardEnabled
        self.keyboard = keyboard
        self.modifiers = Self.validModifiers(modifiers)
        self.mouse = mouse
    }

    private enum CodingKeys: String, CodingKey { case keyboardEnabled, keyboard, modifiers, mouse }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decodeIfPresent(String.self, forKey: .keyboard)
        let keyboard = name.flatMap(Keyboard.init(rawValue:))
        let enabled = try values.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? true
        self.init(
            keyboardEnabled: enabled && (name == nil || keyboard != nil),
            keyboard: keyboard ?? .modifiers,
            modifiers: try values.decodeIfPresent(ShortcutModifiers.self, forKey: .modifiers) ?? Self.defaultModifiers,
            mouse: try values.decodeIfPresent(String.self, forKey: .mouse)
                .flatMap(Mouse.init(rawValue:)) ?? .off
        )
    }

    public func normalized() -> Self {
        Self(keyboardEnabled: keyboardEnabled, keyboard: keyboard, modifiers: modifiers, mouse: mouse)
    }

    /// Whether the page shows this chord modifier's button as on. While Right Control is the trigger, none is.
    public func isOn(_ modifier: ShortcutModifiers) -> Bool {
        keyboard == .modifiers && modifiers.contains(modifier)
    }

    /// Whether Settings must keep this chord modifier on. The wheel needs two modifiers.
    public func isLocked(_ modifier: ShortcutModifiers) -> Bool {
        keyboard == .modifiers && modifiers.contains(modifier) && modifiers.rawValue.nonzeroBitCount <= 2
    }

    /// Switches one chord modifier, as the modifier buttons on the Layout Wheel page do.
    /// A change that would leave fewer than two modifiers is ignored. While Right Control is
    /// the trigger, pressing a modifier button returns to the stored chord without changing it.
    public mutating func setModifier(_ modifier: ShortcutModifiers, enabled: Bool) {
        guard keyboard == .modifiers else { keyboard = .modifiers; return }
        var next = modifiers
        if enabled { next.insert(modifier) } else { next.remove(modifier) }
        guard next.rawValue.nonzeroBitCount >= 2 else { return }
        modifiers = next
    }

    private static func validModifiers(_ value: ShortcutModifiers) -> ShortcutModifiers {
        let supported = value.intersection(LayoutWheelConfiguration.supportedKeyboardModifiers)
        return supported.rawValue.nonzeroBitCount >= 2 ? supported : defaultModifiers
    }
}
