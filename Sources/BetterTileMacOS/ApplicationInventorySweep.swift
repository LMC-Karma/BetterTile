import BetterTileCore

/// Chooses which applications one complete sweep reads, and which it keeps as
/// unreadable. A kept application's windows are left out of the sweep but keep
/// their identities, so their panes stay in the layout.
///
/// The Accessibility adapter runs this loop over its running applications.
/// Tests run it with injected per-application read times.
enum ApplicationInventorySweep {
    /// Reads each application through `read`, or keeps it. Returns the hold
    /// deadline of every application that this sweep did not read.
    ///
    /// - Parameters:
    ///   - previousHolds: The holds that the previous sweep returned.
    ///   - recoveryPIDs: Nil for an ordinary sweep. For a recovery sweep, the
    ///     held applications that it may read; each one that it reads is
    ///     removed.
    ///   - now: Process uptime, the clock of the gate.
    ///   - gate: The current gate state. `read` records its calls there.
    static func run<Application>(
        _ applications: [Application],
        processIdentifier: (Application) -> Int32,
        previousHolds: [Int32: Double],
        recoveryPIDs: inout Set<Int32>?,
        now: () -> Double,
        gate: () -> UnresponsiveApplicationGate,
        read: (Application) -> Void
    ) -> [Int32: Double] {
        var holds: [Int32: Double] = [:]
        for application in applications {
            let pid = processIdentifier(application)
            defer {
                if let deadline = gate().holdDeadline(pid), deadline > now() {
                    holds[pid] = deadline
                }
            }
            if let deadline = previousHolds[pid], recoveryPIDs != nil {
                guard recoveryPIDs?.contains(pid) == true, !gate().isHeld(pid, now: now()) else {
                    // Keep expired holds visible so another app's timer cannot
                    // probe an exhausted app or reset its retry budget.
                    holds[pid] = max(deadline, gate().holdDeadline(pid) ?? deadline)
                    continue
                }
                recoveryPIDs?.remove(pid)
            }
            read(application)
        }
        return holds
    }
}
