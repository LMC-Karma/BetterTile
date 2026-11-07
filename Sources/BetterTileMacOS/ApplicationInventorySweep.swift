import BetterTileCore

/// Chooses which applications one complete sweep reads, and which it keeps as
/// unreadable. A kept application's windows are left out of the sweep but keep
/// their identities. The model exempts them from absence removal, so their
/// panes stay in the layout.
///
/// The sweep keeps an application during its inventory backoff without
/// messaging it. It also waits out at most one messaging timeout for
/// applications that already stalled: after any call in the sweep times out,
/// it keeps each later application that stalled before and has not answered
/// since. It still reads every other application. Several hung applications
/// then cost one timeout per sweep, not one each, and the growing backoffs
/// spread their next reads apart.
///
/// The Accessibility adapter runs this loop over its running applications.
/// Tests run it with injected per-application read times.
enum ApplicationInventorySweep {
    /// Reads each application through `read`, or keeps it. Returns the
    /// inventory deadline of every application that this sweep did not read.
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
        var waitedOutTimeout = false
        func keep(_ pid: Int32) {
            let deadline = gate().inventoryBackoffDeadline(pid) ?? now()
            holds[pid] = max(deadline, previousHolds[pid] ?? deadline)
        }
        for application in applications {
            let pid = processIdentifier(application)
            if let deadline = previousHolds[pid], recoveryPIDs != nil,
               recoveryPIDs?.contains(pid) != true {
                // Keep expired holds visible so another app's timer cannot
                // probe an exhausted app or reset its retry budget.
                holds[pid] = max(deadline, gate().inventoryBackoffDeadline(pid) ?? deadline)
                continue
            }
            if gate().isInventoryBackedOff(pid, now: now()) {
                keep(pid)
                continue
            }
            if waitedOutTimeout, gate().stallCount(pid) > 0 {
                // A recovery sweep leaves this PID in place, so the model does
                // not count an attempt.
                keep(pid)
                continue
            }
            if previousHolds[pid] != nil { recoveryPIDs?.remove(pid) }
            let timeouts = gate().timeoutSerial(pid)
            read(application)
            // The serial also sees a timeout after a completed call in the same read.
            if gate().timeoutSerial(pid) != timeouts {
                waitedOutTimeout = true
                if let deadline = gate().inventoryBackoffDeadline(pid), deadline > now() {
                    holds[pid] = deadline
                }
            }
        }
        return holds
    }
}
