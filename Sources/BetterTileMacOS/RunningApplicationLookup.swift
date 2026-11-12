import AppKit

/// Finds the running application that owns a process.
///
/// `NSRunningApplication(processIdentifier:)` asks LaunchServices about one
/// process. It can return nil for a moment while the application runs. The
/// workspace's running-application list, which the complete inventory reads,
/// kept the entry during such answers, so the lookup reads the list when the
/// per-PID answer is nil. The fallback skips an entry that reports termination.
/// The list and `isTerminated` change only when the main run loop runs, so for
/// a short time after an application quits the list can still name it. Callers
/// keep their own checks of the application and its windows.
public enum RunningApplicationLookup {
    public static func application(processIdentifier: pid_t) -> NSRunningApplication? {
        resolve(
            processIdentifier,
            lookUp: { NSRunningApplication(processIdentifier: $0) },
            runningApplications: { NSWorkspace.shared.runningApplications }
        )
    }

    /// The policy of `application(processIdentifier:)`, with both macOS answers
    /// replaceable in tests. The per-PID answer wins when there is one.
    static func resolve(
        _ processIdentifier: pid_t,
        lookUp: (pid_t) -> NSRunningApplication?,
        runningApplications: () -> [NSRunningApplication]
    ) -> NSRunningApplication? {
        if let application = lookUp(processIdentifier) { return application }
        return runningApplications().first { $0.processIdentifier == processIdentifier && !$0.isTerminated }
    }
}
