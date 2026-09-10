import BetterTileCore

/// Public window actions used by the Tabbed experiment. The coordinator owns
/// all calls, including focus and close; panels emit intents only.
@MainActor
public protocol TabbedWindowSystem: TargetedWindowSystem {
    func raiseWindow(_ id: WindowID, activate: Bool) throws
    func requestCloseWindow(_ id: WindowID) throws
}
