import Foundation

/// Framework-independent decisions behind BetterTileApp's lifecycle, update,
/// and feedback integrations.
///
/// The app delegate owns `SPUStandardUpdaterController` and conforms to
/// `SPUUpdaterDelegate`; it translates Sparkle's callbacks into the events
/// below. Keeping the resulting decisions here makes them testable without
/// linking Sparkle into the test target, and without pulling an updater API
/// into `BetterTileCore`. Nothing in this file imports Sparkle or AppKit.

public struct AvailableUpdate: Codable, Equatable, Sendable {
    public let displayVersion: String
    public let buildVersion: String

    public init(displayVersion: String, buildVersion: String) {
        self.displayVersion = displayVersion
        self.buildVersion = buildVersion
    }
}

/// Whether BetterTile is currently advertising an available update.
public enum UpdateIndicatorState: Codable, Equatable, Sendable {
    case idle
    case updateAvailable(AvailableUpdate)

    public var availableUpdate: AvailableUpdate? {
        guard case let .updateAvailable(update) = self else { return nil }
        return update
    }
}

/// What the updater reported. These map one-to-one onto the Sparkle delegate
/// callbacks the app delegate implements.
public enum UpdateIndicatorEvent: Equatable, Sendable {
    /// Sparkle found a valid update matching the signed appcast.
    case foundValidUpdate(AvailableUpdate)
    /// Sparkle completed a check and confirmed no update is available.
    case confirmedNoUpdate
    /// The user chose to skip this version.
    case userSkippedUpdate
    /// The user deferred the update, for example with "Remind Me Later".
    case userDeferredUpdate
    /// The user began downloading and installing the update. This only starts
    /// the work; it does not mean the update was applied.
    case userBeganInstallingUpdate
    /// The check failed, for example because the network was unreachable.
    case checkFailed
}

public enum UpdateIndicator {
    /// A confirmed result moves the indicator; anything inconclusive leaves it
    /// exactly as it was.
    ///
    /// Two events deliberately preserve the current state rather than clearing
    /// it:
    ///
    /// - A failed check says nothing about whether an update exists. Dropping
    ///   the indicator because a laptop woke on a captive network would hide a
    ///   real update until the next daily check.
    /// - Choosing Install only *begins* downloading and installing. If that
    ///   fails, the update is still available and the indicator must still say
    ///   so. A successful install quits and relaunches the app; restoration
    ///   clears the reminder when the running build reaches the stored build.
    public static func state(
        after event: UpdateIndicatorEvent,
        from current: UpdateIndicatorState
    ) -> UpdateIndicatorState {
        switch event {
        case let .foundValidUpdate(update):
            .updateAvailable(update)
        case .confirmedNoUpdate, .userSkippedUpdate:
            .idle
        case .userDeferredUpdate, .userBeganInstallingUpdate, .checkFailed:
            current
        }
    }

    /// Keeps a persisted reminder only while its build is newer than the
    /// running application. BetterTile release builds use numeric bundle
    /// versions, so malformed stored values are discarded rather than shown.
    public static func restoredState(
        _ stored: UpdateIndicatorState,
        runningBuildVersion: String
    ) -> UpdateIndicatorState {
        guard
            let update = stored.availableUpdate,
            let runningBuild = Int(runningBuildVersion),
            let availableBuild = Int(update.buildVersion),
            runningBuild < availableBuild
        else { return .idle }
        return stored
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

public enum SiblingApplicationDecision: Equatable, Sendable {
    case askUser
    case requestTermination
    case waitForTermination
    case continueLaunching
    case quitCurrentApplication
    case showTerminationFailure
}

public enum SiblingApplicationLaunch {
    /// Selects the next step while one BetterTile variant yields to the other.
    /// AppKit owns the prompt, termination request, and short run-loop wait;
    /// this function keeps their state transitions deterministic and tested.
    public static func nextDecision(
        userChoseToQuitSibling: Bool?,
        terminationRequestAccepted: Bool?,
        siblingIsTerminated: Bool,
        deadlinePassed: Bool
    ) -> SiblingApplicationDecision {
        if siblingIsTerminated { return .continueLaunching }
        guard let userChoseToQuitSibling else { return .askUser }
        guard userChoseToQuitSibling else { return .quitCurrentApplication }
        guard let terminationRequestAccepted else { return .requestTermination }
        guard terminationRequestAccepted else { return .showTerminationFailure }
        return deadlinePassed ? .showTerminationFailure : .waitForTermination
    }
}
