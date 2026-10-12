/// Decides whether a newly seen window is a popup that should float instead
/// of joining a layout: a file picker, a settings or progress dialog, an
/// About window. Many applications do not mark these as dialogs, so, like
/// AeroSpace's `isDialogHeuristic`, the decision also uses the title-bar
/// buttons: a window without an enabled full-screen button is not designed
/// to be large.
public enum PopupWindowClassifier {
    /// The state of one title-bar button.
    public enum ButtonState: Equatable, Sendable {
        case missing
        case disabled
        case enabled
        /// The read failed, for example because the application was busy.
        case unreadable
    }

    public enum Verdict: Equatable, Sendable {
        /// A popup: it floats at its own size and never joins a layout.
        case popup
        /// A normal window.
        case window
        /// Not decidable now, for example while a sheet is attached or the
        /// window is minimized. Ask again later; do not remember this answer.
        case undetermined
    }

    public struct Attributes: Equatable, Sendable {
        public var subrole: String?
        public var fullScreenButton: ButtonState
        public var closeButton: ButtonState
        public var minimizeButton: ButtonState
        public var isModal: Bool
        public var isMinimized: Bool
        public var bundleIdentifier: String?

        public init(
            subrole: String?,
            fullScreenButton: ButtonState,
            closeButton: ButtonState,
            minimizeButton: ButtonState,
            isModal: Bool = false,
            isMinimized: Bool = false,
            bundleIdentifier: String? = nil
        ) {
            self.subrole = subrole
            self.fullScreenButton = fullScreenButton
            self.closeButton = closeButton
            self.minimizeButton = minimizeButton
            self.isModal = isModal
            self.isMinimized = isMinimized
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public static let standardWindowSubrole = "AXStandardWindow"

    /// Applications whose ordinary windows can lack an enabled full-screen
    /// button: terminals and editors with hidden title bars, and apps
    /// that disable the button briefly (a Chromium tab dragged out).
    static let fullScreenButtonExceptions: Set<String> = [
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.googlecode.iterm2",
        "org.qutebrowser.qutebrowser", "org.gnu.Emacs", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.vscodium", "com.valvesoftware.steam", "org.gimp.gimp-2.10", "org.gimp.gimp",
        "com.apple.ActivityMonitor",
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.brave.Browser.beta",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.chromium.Chromium",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Applications whose regular windows use a non-standard subrole.
    static let subroleExceptions: Set<String> = ["org.qutebrowser.qutebrowser"]

    static let firefoxIdentifiers: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "org.mozilla.firefoxbeta", "app.zen-browser.zen", "net.waterfox.waterfox", "io.gitlab.librewolf-community",
    ]

    public static func classify(_ attributes: Attributes) -> Verdict {
        // Minimized windows and windows of hidden apps can report a dialog
        // subrole; they are judged once they are visible again.
        if attributes.isMinimized { return .undetermined }
        let id = attributes.bundleIdentifier ?? ""
        if attributes.isModal { return .popup }
        // A failed read is not evidence. Judge the window again later.
        guard let subrole = attributes.subrole else { return .undetermined }
        if subrole != standardWindowSubrole, !subroleExceptions.contains(id) { return .popup }
        if [attributes.fullScreenButton, attributes.closeButton, attributes.minimizeButton].contains(.unreadable) {
            return .undetermined
        }
        // An attached sheet removes the full-screen button and disables the
        // close button of its window. That window is not a popup.
        if attributes.closeButton == .disabled { return .undetermined }
        // Firefox's Picture in Picture window has no minimize button.
        if firefoxIdentifiers.contains(id), attributes.minimizeButton != .enabled { return .popup }
        if id == "com.mitchellh.ghostty" {
            return attributes.fullScreenButton != .enabled && attributes.closeButton == .enabled ? .popup : .window
        }
        if attributes.fullScreenButton != .enabled, !fullScreenButtonExceptions.contains(id) { return .popup }
        return .window
    }
}
