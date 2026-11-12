import AppKit
import CoreGraphics
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// Applications with injected inventory read times, swept by the adapter's own
/// loop and gate. A hung application's read waits out the 0.35 s messaging
/// timeout, as in a live sweep, and fails.
private final class InventorySweepFixture {
    static let timeout = 0.351
    var now = 1000.0
    var gate = UnresponsiveApplicationGate()
    var holds: [Int32: Double] = [:]
    var applications: [Int32]
    var hung: Set<Int32>
    /// Applications whose `AXWindows` read answers and whose next window
    /// snapshot then waits out its timeout.
    var answersThenStalls: Set<Int32> = []

    init(responsive: [Int32], hung: [Int32]) {
        applications = responsive + hung
        self.hung = Set(hung)
    }

    struct Sweep {
        /// Applications that got an Accessibility message, in order.
        var messaged: [Int32] = []
        var answered: Set<Int32> = []
        var duration = 0.0
        var stalls: Int { messaged.count - answered.count }
    }

    @discardableResult
    func sweep(recovering recoveryPIDs: inout Set<Int32>?) -> Sweep {
        var result = Sweep()
        let start = now
        holds = ApplicationInventorySweep.run(
            applications,
            processIdentifier: { $0 },
            previousHolds: holds,
            recoveryPIDs: &recoveryPIDs,
            now: { self.now },
            gate: { self.gate }
        ) { pid in
            // `gatedCall`: a held application fails without a message.
            guard !gate.isHeld(pid, now: now) else { return }
            result.messaged.append(pid)
            if answersThenStalls.contains(pid) {
                gate.record(pid, cannotComplete: false, elapsed: 0.001, now: now)
                now += Self.timeout
                gate.record(pid, cannotComplete: true, elapsed: Self.timeout, now: now)
            } else if hung.contains(pid) {
                now += Self.timeout
                gate.record(pid, cannotComplete: true, elapsed: Self.timeout, now: now)
            } else {
                gate.record(pid, cannotComplete: false, elapsed: 0.001, now: now)
                result.answered.insert(pid)
            }
        }
        result.duration = now - start
        return result
    }

    @discardableResult
    func sweep() -> Sweep {
        var recoveryPIDs: Set<Int32>?
        return sweep(recovering: &recoveryPIDs)
    }
}

@Suite struct ApplicationInventorySweepTests {
    static let hung: [Int32] = Array(201...209)
    static let responsive: [Int32] = [101, 102]

    /// The live report: nine hung applications each waited out a 0.35 s
    /// timeout in every sweep, about 3.2 s per sweep, and sweeps ran back to
    /// back. Every sweep after the first must wait out at most one timeout.
    @Test func hungApplicationsAreNotReadAgainOnEverySweep() {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: Self.hung)
        let first = fixture.sweep()
        #expect(first.stalls == Self.hung.count, "Unknown applications are read once each")
        var later: [InventorySweepFixture.Sweep] = []
        while fixture.now < 1060 {
            fixture.now += 0.05
            later.append(fixture.sweep())
        }
        let stallsPerSweep = later.map(\.stalls)
        let worst = stallsPerSweep.max() ?? 0
        let total = stallsPerSweep.reduce(0, +)
        print("""
            inventory-sweep-measure: sweeps=\(later.count + 1) first-sweep-stalls=\(first.stalls) \
            later-max-stalls=\(worst) later-total-stalls=\(total) \
            later-max-duration=\(later.map(\.duration).max() ?? 0)
            """)
        #expect(worst <= 1, "A sweep waits out at most one timeout of an application that already stalled; got \(worst)")
        #expect(later.allSatisfy { $0.duration <= InventorySweepFixture.timeout + 0.001 })
        #expect(later.allSatisfy { Set(Self.responsive).isSubset(of: $0.answered) },
            "Every sweep still reads every responsive application")
        // Holds grow to 30 s, so each hung application is read about twice a minute, not every sweep.
        #expect(total <= Self.hung.count * 6, "Stalled reads in one minute after the first sweep: \(total)")
    }

    /// A kept application is reported like a held one, so its windows keep
    /// their identities and the model schedules its recovery.
    @Test func everyUnreadApplicationIsReportedAsHeld() {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: Self.hung)
        fixture.sweep()
        for _ in 0..<40 {
            fixture.now += 0.05
            let sweep = fixture.sweep()
            for pid in Self.hung {
                #expect(fixture.holds[pid] != nil && !sweep.answered.contains(pid),
                    "Hung application \(pid) must stay reported as unreadable")
            }
            #expect(Self.responsive.allSatisfy { fixture.holds[$0] == nil })
        }
    }

    /// A recovery sweep may read only one application that already stalled.
    /// The others keep their recovery PIDs, so no attempt is charged for a
    /// read that did not happen.
    @Test func aKeptApplicationKeepsItsRecoveryAttempt() {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: [201, 202])
        fixture.sweep()
        fixture.now += UnresponsiveApplicationGate.holdSeconds + 1
        var recovery: Set<Int32>? = [201, 202]
        let sweep = fixture.sweep(recovering: &recovery)
        #expect(sweep.messaged.filter { $0 > 200 } == [201])
        #expect(recovery == [202], "The kept application must stay eligible for its recovery attempt")
        #expect(fixture.holds[202] != nil)
    }

    /// The inventory answers, then a window snapshot times out. That completed
    /// call resets the stall count, but the sweep must still count the timeout
    /// and keep the next application that already stalled.
    @Test func aTimeoutAfterACompletedCallStillEndsTheSweepsReadsOfStalledApplications() {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: [201, 202, 203])
        fixture.sweep()
        fixture.now += UnresponsiveApplicationGate.holdSeconds + 1
        fixture.hung = [202, 203]
        fixture.answersThenStalls = [201]
        let sweep = fixture.sweep()
        #expect(sweep.messaged.filter { $0 > 200 } == [201], "Read after the first timeout: \(sweep.messaged)")
        #expect(sweep.duration <= InventorySweepFixture.timeout + 0.001)
        #expect([201, 202, 203].allSatisfy { fixture.holds[$0] != nil })
    }

    /// The sweep reads no application during its backoff, even after the
    /// shorter call hold has ended.
    @Test func aSweepDoesNotMessageAnApplicationDuringItsBackoff() throws {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: [201])
        for index in 0..<4 {
            if index > 0 { fixture.now = (fixture.gate.inventoryBackoffDeadline(201) ?? fixture.now) + 0.01 }
            fixture.sweep()
        }
        let backoff = try #require(fixture.gate.inventoryBackoffDeadline(201))
        fixture.now += UnresponsiveApplicationGate.holdSeconds + 0.5
        #expect(!fixture.gate.isHeld(201, now: fixture.now) && fixture.now < backoff)
        #expect(!fixture.sweep().messaged.contains(201))
        #expect(fixture.holds[201] == backoff, "The model's recovery waits for the backoff")
    }

    @Test func aRecoveredApplicationIsReadAgainAfterItsHold() throws {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: [201])
        for index in 0..<5 {
            if index > 0 { fixture.now = (fixture.gate.inventoryBackoffDeadline(201) ?? fixture.now) + 0.01 }
            fixture.sweep()
        }
        #expect(fixture.gate.stallCount(201) == 5)
        fixture.now += 1
        fixture.hung.removeAll()
        let deadline = try #require(fixture.gate.inventoryBackoffDeadline(201))
        #expect(!fixture.sweep().answered.contains(201), "Still held before its deadline")
        fixture.now = deadline + 0.01
        #expect(fixture.sweep().answered.contains(201))
        #expect(fixture.gate.stallCount(201) == 0 && fixture.holds[201] == nil)
    }

    /// An activation or the application's own Accessibility notification
    /// releases it. The next sweep reads it at once, even inside a long backoff.
    @Test func anApplicationThatRunsAgainIsReadOnTheNextSweep() {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: [201])
        for _ in 0..<5 {
            fixture.sweep()
            fixture.now = (fixture.gate.inventoryBackoffDeadline(201) ?? fixture.now) + 0.01
        }
        fixture.sweep()
        fixture.hung.removeAll()
        fixture.now += 0.5
        fixture.gate.release(201)
        let sweep = fixture.sweep()
        #expect(sweep.answered.contains(201) && fixture.holds[201] == nil)
    }
}

/// The adapter's own release paths. The process identifier is made up: no
/// Accessibility message is sent to it.
@Suite(.macOSTestApplication, .serialized) @MainActor
struct AccessibilityReleaseTests {
    private static let pid: Int32 = 999_901

    private func stall() {
        AccessibilityWindowSystem.unresponsiveApplications.withLock {
            $0.record(Self.pid, cannotComplete: true, elapsed: 0.351, now: 1)
            $0.record(Self.pid, cannotComplete: true, elapsed: 0.351, now: 3)
        }
    }

    private var stallCount: Int {
        AccessibilityWindowSystem.unresponsiveApplications.withLock { $0.stallCount(Self.pid) }
    }

    @Test func activationReleasesAManagedApplication() {
        let system = AccessibilityWindowSystem()
        defer { AccessibilityWindowSystem.unresponsiveApplications.withLock { $0.release(Self.pid) } }
        stall()
        system.recordActivation(processIdentifier: Self.pid, activationPolicy: .accessory, isHidden: false)
        #expect(stallCount == 2, "An application BetterTile does not manage keeps its backoff")
        system.recordActivation(processIdentifier: Self.pid, activationPolicy: .regular, isHidden: false)
        #expect(stallCount == 0)
    }

    @Test func aDeliveredNotificationReleasesItsApplication() throws {
        let system = AccessibilityWindowSystem()
        defer { AccessibilityWindowSystem.unresponsiveApplications.withLock { $0.release(Self.pid) } }
        let application = ApplicationLaunchInstance(processIdentifier: Self.pid, generation: 1)
        system.observationLifetime.install(application)
        let captured = try #require(system.observationLifetime.capture(kind: .focused, application: application,
            accessibilityHash: 0, identities: WindowIdentityRegistry()))
        stall()
        // A callback from a replaced observer is not proof that the application runs.
        var stale = captured
        stale.observerToken &+= 1
        system.receiveAXEvent(stale)
        #expect(stallCount == 2)
        system.receiveAXEvent(captured)
        #expect(stallCount == 0)
    }
}

/// Closure of an unread application's window, proved only by the full
/// WindowServer list. Identifiers are made up.
@Suite struct UnreadWindowClosureEvidenceTests {
    private static let pid: pid_t = 301
    private static let open = WindowID(rawValue: "open")
    private static let closed = WindowID(rawValue: "closed")

    private func list(_ windows: [(CGWindowID, Bool)], pid: pid_t = pid) -> WindowServerIndex {
        // A responsive application's on-screen window keeps the list complete.
        WindowServerIndex(records: [WindowServerRecord(windowID: 900, processIdentifier: 42, layer: 0,
            frame: BTRect(x: 0, y: 0, width: 100, height: 100), isOnscreen: true)]
            + windows.map { WindowServerRecord(windowID: $0.0, processIdentifier: pid, layer: 0,
                frame: BTRect(x: 0, y: 0, width: 100, height: 100), isOnscreen: $0.1) })
    }

    private var candidates: [UnreadWindowClosureEvidence.Candidate] {
        [.init(windowID: Self.open, processIdentifier: Self.pid, exactWindowID: 1),
         .init(windowID: Self.closed, processIdentifier: Self.pid, exactWindowID: 2)]
    }

    @Test func twoFullListsWithoutTheExactIdentityProveClosure() {
        var evidence = UnreadWindowClosureEvidence()
        // Window 1 is on another Space or minimized: off screen, but in the full list.
        #expect(evidence.confirmClosed(candidates, windowServer: list([(1, false)])).isEmpty)
        #expect(evidence.confirmClosed(candidates, windowServer: list([(1, false)])) == [Self.closed])
    }

    @Test func aWindowThatReturnsToTheListStartsAgain() {
        var evidence = UnreadWindowClosureEvidence()
        _ = evidence.confirmClosed(candidates, windowServer: list([(1, true)]))
        _ = evidence.confirmClosed(candidates, windowServer: list([(1, true), (2, true)]))
        #expect(evidence.confirmClosed(candidates, windowServer: list([(1, true)])).isEmpty)
    }

    @Test func aMissingOrEmptyListIsNotEvidence() {
        var evidence = UnreadWindowClosureEvidence()
        for unavailable in [nil, WindowServerIndex(records: [])] {
            _ = evidence.confirmClosed(candidates, windowServer: list([(1, true)]))
            #expect(evidence.confirmClosed(candidates, windowServer: unavailable).isEmpty)
            #expect(evidence.confirmClosed(candidates, windowServer: list([(1, true)])).isEmpty, "The count started again")
            evidence.reset()
        }
    }

    /// Without an exact identity, only an application with no window left proves closure.
    @Test func withoutAnExactIdentityOnlyAnApplicationWithoutWindowsProvesClosure() {
        var evidence = UnreadWindowClosureEvidence()
        let withoutIDs = candidates.map { UnreadWindowClosureEvidence.Candidate(windowID: $0.windowID,
            processIdentifier: $0.processIdentifier, exactWindowID: nil) }
        for _ in 0..<3 { #expect(evidence.confirmClosed(withoutIDs, windowServer: list([(1, false)])).isEmpty) }
        _ = evidence.confirmClosed(withoutIDs, windowServer: list([]))
        #expect(evidence.confirmClosed(withoutIDs, windowServer: list([])) == [Self.open, Self.closed])
    }
}

/// The adapter prepares each complete sweep with `ApplicationInventorySweep.prepare`.
/// These fakes stand in for running applications; no process is messaged.
@Suite(.macOSTestApplication) struct InventorySweepPreparationTests {
    private struct App { let pid: Int32; let managed: Bool }

    @Test func runningHiddenAppsKeepTheirGateAndReusedPIDsAreAdmittedBeforeAnyRead() {
        let reused = App(pid: 10, managed: true), hidden = App(pid: 11, managed: false)
        let stalledBefore = App(pid: 12, managed: true), quit: Int32 = 13
        var gate = UnresponsiveApplicationGate()
        for pid in [reused.pid, hidden.pid, stalledBefore.pid, quit] {
            gate.record(pid, cannotComplete: true, elapsed: 0.35, now: 100)
        }
        var reads: [Int32] = []
        let prepared = ApplicationInventorySweep.prepare(
            running: [reused, hidden, stalledBefore], processIdentifier: \.pid, isManaged: \.managed,
            previousHolds: [reused.pid: 150],
            retainRunning: { gate.retainProcessIdentifiers($0) },
            admitChangedLaunch: { app in
                guard app.pid == reused.pid else { return false }
                gate.remove(processIdentifier: app.pid)
                return true
            })
        #expect(prepared.applications.map(\.pid) == [reused.pid, stalledBefore.pid])
        #expect(prepared.previousHolds.isEmpty, "The quit process's hold must not hold its successor")
        #expect(gate.stallCount(hidden.pid) == 1, "A hidden running application keeps its gate")
        #expect(gate.timeoutSerial(quit) == 0 && gate.stallCount(quit) == 0)
        #expect(gate.timeoutSerial(reused.pid) == 0)
        var recovery: Set<Int32>? = nil
        let holds = ApplicationInventorySweep.run(prepared.applications, processIdentifier: \.pid,
            previousHolds: prepared.previousHolds, recoveryPIDs: &recovery, now: { 200 }, gate: { gate }) { app in
            reads.append(app.pid)
        }
        #expect(reads == [reused.pid, stalledBefore.pid], "A reset seen inside a read looks like a timeout")
        #expect(holds.isEmpty)
    }

    /// The order the preparation prevents: a reset inside the reused PID's read
    /// changes its timeout serial, so the sweep skips a later stalled application.
    @Test func admittingAReusedPIDInsideItsReadWouldSkipALaterStalledApplication() {
        var gate = UnresponsiveApplicationGate()
        for pid: Int32 in [10, 12] { gate.record(pid, cannotComplete: true, elapsed: 0.35, now: 100) }
        var reads: [Int32] = []
        var recovery: Set<Int32>? = nil
        _ = ApplicationInventorySweep.run([App(pid: 10, managed: true), App(pid: 12, managed: true)],
            processIdentifier: \.pid, previousHolds: [:], recoveryPIDs: &recovery, now: { 200 }, gate: { gate }) { app in
            if app.pid == 10 { gate.remove(processIdentifier: 10) }
            reads.append(app.pid)
        }
        #expect(reads == [10])
    }
}

/// `applicationInstance(for:)` with this test process as the running application.
@Suite(.macOSTestApplication, .serialized) @MainActor
struct LaunchAdmissionGateTests {
    @Test func aFirstSeenLaunchKeepsItsGateAndAChangedLaunchAtAKnownPIDResetsIt() {
        let application = NSRunningApplication.current
        let pid = application.processIdentifier
        func gate<T>(_ body: (inout UnresponsiveApplicationGate) -> T) -> T {
            AccessibilityWindowSystem.unresponsiveApplications.withLock { body(&$0) }
        }
        defer { gate { $0.remove(processIdentifier: pid) } }
        gate { $0.record(pid, cannotComplete: true, elapsed: 0.35, now: 100) }
        let system = AccessibilityWindowSystem()

        let first = system.admitLaunchForTesting(application)
        #expect(gate { $0.timeoutSerial(pid) } == 1, "A gate set before the first launch record must stay")
        #expect(system.admitLaunchForTesting(application) == first)
        #expect(gate { $0.timeoutSerial(pid) } == 1)

        // A different launch token at the same PID means the old process quit.
        let token = application.launchDate?.timeIntervalSinceReferenceDate.bitPattern
        let replaced = system.recordLaunchForTesting(pid: pid, bundleIdentifier: nil, launchToken: (token ?? 0) &+ 1)
        let admitted = system.admitLaunchForTesting(application)
        #expect(admitted != replaced)
        #expect(gate { ($0.timeoutSerial(pid), $0.stallCount(pid), $0.holdDeadline(pid)) } == (0, 0, nil))
    }
}
