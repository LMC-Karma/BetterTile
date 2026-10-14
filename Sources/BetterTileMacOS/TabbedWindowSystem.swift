import BetterTileCore

/// How a window compares with its application's focused window.
public enum ApplicationFocusMatch: Equatable, Sendable {
    /// The application reports this window as its focused window.
    case confirmed
    /// The application reports another window as focused. A transient
    /// popup closes when it loses focus, such as a browser toolbar bubble.
    case otherWindow(isTransientPopup: Bool)
    /// The application's focus is on no window, such as Finder's desktop,
    /// so there is no window focus to protect.
    case noWindow
    /// The focused window could not be read.
    case unknown
}

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
    /// Whether the window's application reports this window as its focused
    /// window. `focusedWindow()` reports the application's main window when
    /// it cannot read the focused window, such as a small popup.
    func applicationFocus(of window: WindowSnapshot) -> ApplicationFocusMatch
    /// True for a popup that closes when it loses focus, such as a browser
    /// toolbar bubble. Standard windows, dialogs, and floating panels such
    /// as the Font panel are not transient.
    func isTransientPopup(_ window: WindowSnapshot) -> Bool
    func raiseWindow(_ id: WindowID, activate: Bool) throws
    func requestCloseWindow(_ id: WindowID) throws
}
