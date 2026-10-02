import BetterTileCore

/// Window integration used by the Tabbed experiment. The coordinator owns
/// mutations, including focus and close; panels emit intents only.
@MainActor
public protocol TabbedWindowSystem: TargetedWindowSystem {
    /// Validated, on-screen, normal-level WindowServer numbers. Omit windows
    /// without an exact identity; frame correlation is not safe for ordering.
    func windowNumbers(for windows: [WindowSnapshot]) -> [WindowID: Int]
    func raiseWindow(_ id: WindowID, activate: Bool) throws
    func requestCloseWindow(_ id: WindowID) throws
}
