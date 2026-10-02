import BetterTileCore

/// Window integration used by the Tabbed experiment. The coordinator owns
/// mutations, including focus and close; panels emit intents only.
@MainActor
public protocol TabbedWindowSystem: TargetedWindowSystem {
    /// Validated, on-screen, normal-level WindowServer numbers. Omit windows
    /// without an exact identity; frame correlation is not safe for ordering.
    func windowNumbers(for windows: [WindowSnapshot]) -> [WindowID: Int]
    /// On-screen normal-level windows, front to back, excluding the given
    /// WindowServer numbers. Only windows with a validated exact identity
    /// carry an ID. Nil when exact identities are unavailable.
    func stackingOrder(for windows: [WindowSnapshot], excluding windowNumbers: Set<Int>) -> [TabbedStackEntry]?
    /// The application that really has focus. `focusedWindow()` can report
    /// another application's window when BetterTile or an unreadable
    /// application is in front.
    var frontmostProcessIdentifier: Int32? { get }
    func raiseWindow(_ id: WindowID, activate: Bool) throws
    func requestCloseWindow(_ id: WindowID) throws
}
