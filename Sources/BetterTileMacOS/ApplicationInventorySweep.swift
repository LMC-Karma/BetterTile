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
/// since. It still reads every other application. Applications that already
/// stalled then cost at most one timeout per sweep, and the growing backoffs
/// spread their next reads apart. An application that stalls for the first
/// time is always read.
///
/// The Accessibility adapter runs this loop over its running applications.
/// Tests run it with injected per-application read times.
enum ApplicationInventorySweep {
    /// Prepares one complete sweep, before any read can capture a timeout
    /// serial.
    ///
    /// 1. `retainRunning` receives every running PID, hidden and unmanaged
    ///    applications included. A filtered inventory cannot prove a quit.
    /// 2. `admitChangedLaunch` admits each managed application's launch. It
    ///    returns true when a new launch replaced a known one at the same
    ///    PID; that PID then loses the hold of the process that quit.
    ///
    /// Admitting a reused PID inside its read would reset its timeout serial
    /// there, and `run` would count the reset as a timeout.
    static func prepare<Application>(
        running: [Application],
        processIdentifier: (Application) -> Int32,
        isManaged: (Application) -> Bool,
        previousHolds: [Int32: Double],
        retainRunning: (Set<Int32>) -> Void,
        admitChangedLaunch: (Application) -> Bool
    ) -> (applications: [Application], previousHolds: [Int32: Double]) {
        retainRunning(Set(running.map(processIdentifier)))
        let applications = running.filter(isManaged)
        var holds = previousHolds
        for application in applications where admitChangedLaunch(application) {
            holds.removeValue(forKey: processIdentifier(application))
        }
        return (applications, holds)
    }

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
