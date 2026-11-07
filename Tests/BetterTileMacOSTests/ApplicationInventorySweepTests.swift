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
            if hung.contains(pid) {
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

    @Test func aRecoveredApplicationIsReadAgainAfterItsHold() throws {
        let fixture = InventorySweepFixture(responsive: Self.responsive, hung: [201])
        for index in 0..<5 {
            if index > 0 { fixture.now = (fixture.gate.holdDeadline(201) ?? fixture.now) + 0.01 }
            fixture.sweep()
        }
        #expect(fixture.gate.stallCount(201) == 5)
        fixture.now += 1
        fixture.hung.removeAll()
        let deadline = try #require(fixture.gate.holdDeadline(201))
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
            fixture.now = (fixture.gate.holdDeadline(201) ?? fixture.now) + 0.01
        }
        fixture.sweep()
        fixture.hung.removeAll()
        fixture.now += 0.5
        fixture.gate.release(201)
        let sweep = fixture.sweep()
        #expect(sweep.answered.contains(201) && fixture.holds[201] == nil)
    }
}
