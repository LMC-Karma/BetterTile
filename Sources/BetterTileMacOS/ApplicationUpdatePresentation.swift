import Foundation

/// Framework-independent decisions behind BetterTileApp's update and feedback
/// integrations.
///
/// The app delegate owns `SPUStandardUpdaterController` and conforms to
/// `SPUUpdaterDelegate`; it translates Sparkle's callbacks into the events
/// below. Keeping the resulting decisions here makes them testable without
/// linking Sparkle into the test target, and without pulling an updater API
/// into `BetterTileCore`. Nothing in this file imports Sparkle or AppKit.

/// Whether the menu-bar item is currently advertising an available update.
public enum UpdateIndicatorState: Equatable, Sendable {
    case idle
    case updateAvailable
}

/// What the updater reported. These map one-to-one onto the Sparkle delegate
/// callbacks the app delegate implements.
public enum UpdateIndicatorEvent: Equatable, Sendable {
    /// Sparkle found a valid update matching the signed appcast.
    case foundValidUpdate
    /// Sparkle completed a check and confirmed no update is available.
    case confirmedNoUpdate
    /// The user chose to skip this version.
    case userSkippedUpdate
    /// The user deferred the update, for example with "Remind Me Later".
    case userDeferredUpdate
    /// The user started installing the update.
    case userInstalledUpdate
    /// The check failed, for example because the network was unreachable.
    case checkFailed
}

public enum UpdateIndicator {
    /// A confirmed result moves the indicator; anything inconclusive leaves it
    /// exactly as it was.
    ///
    /// A failed check must not clear an already-advertised update: the update
    /// still exists, and silently dropping the indicator because a laptop woke
    /// up on a captive network would hide it until the next daily check.
    public static func state(
        after event: UpdateIndicatorEvent,
        from current: UpdateIndicatorState
    ) -> UpdateIndicatorState {
        switch event {
        case .foundValidUpdate:
            .updateAvailable
        case .confirmedNoUpdate, .userSkippedUpdate, .userInstalledUpdate:
            .idle
        case .userDeferredUpdate, .checkFailed:
            current
        }
    }
}

public enum FeedbackLink {
    static let issueFormPath = "https://github.com/LMC-Karma/BetterTile/issues/new"

    /// Pre-fills the public bug report form with nothing beyond the running
    /// version and build.
    ///
    /// Opening this URL does not submit anything: it shows GitHub's issue form
    /// for the user to complete. No window information, configuration,
    /// diagnostics, analytics, or system profile is included. See SECURITY.md.
    public static func url(version: String, build: String) -> URL? {
        var components = URLComponents(string: issueFormPath)
        components?.queryItems = [
            URLQueryItem(name: "template", value: "bug.yml"),
            URLQueryItem(name: "title", value: "[Bug] BetterTile \(version) (\(build)): "),
        ]
        return components?.url
    }
}

public enum ApplicationVolume {
    /// Whether BetterTile must ask the user to move it before launching.
    ///
    /// Running from the read-only disk image leaves Sparkle unable to install
    /// anything, so the app explains the move instead of starting. An
    /// unreadable volume flag is treated as writable: refusing to launch on a
    /// failed lookup would be worse than allowing it.
    public static func requiresRelocation(volumeIsReadOnly: Bool?) -> Bool {
        volumeIsReadOnly == true
    }
}
