import Darwin
import Foundation

/// Reports test progress from a dedicated thread, so a report still appears when the main thread, the dispatch
/// queues and Swift's cooperative pool are all blocked. It writes straight to standard error.
///
/// - Every minute it writes a heartbeat: tests finished and running, and the last test started.
/// - When no registered test has started or finished for two minutes, it names the running tests, oldest first,
///   and writes one `sample` of this process, so a frozen test run shows its blocked stacks.
/// - A test that keeps an `AsyncTestLease` resource too long is named here as well.
/// - It keeps one block queued on the main thread and one detached task on Swift's cooperative pool. When either
///   waits `responsivenessLimit` seconds, it names the running tests and writes one `sample`, whose main-thread
///   stack shows what holds the main actor. It reports again when the block or task finally runs.
public enum TestWatchdog {
    private struct Running {
        var name: String
        var started: TimeInterval
    }

    private struct Holder {
        var name: String
        var since: TimeInterval
        var waiting: Int
        var interval: TimeInterval
        var reports = 0
    }

    /// A queue the watchdog checks for responsiveness.
    private enum Lane: CaseIterable, Sendable {
        case main, pool

        var waiting: String {
            self == .main ? "a block queued on the main thread has not run" : "a detached task has not started"
        }
        var answered: String { self == .main ? "the main thread ran its queued block" : "the detached task started" }
    }

    private struct State {
        var running: [UUID: Running] = [:]
        var pings: [Lane: TimeInterval] = [:]
        var pingReports: [Lane: Int] = [:]
        var responsivenessSamples = 0
        var holders: [UUID: Holder] = [:]
        var finished = 0
        var lastStarted: String?
        var lastProgress: TimeInterval = 0
        var lastStallReport: TimeInterval?
        var sampled = false
        var threadStarted = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    public static let heartbeatInterval: TimeInterval = 60
    public static let stallLimit: TimeInterval = 120
    /// `BETTERTILE_TEST_STALL_PROBE_SECONDS` lowers this limit for a local search for main-thread holders.
    public static let responsivenessLimit: TimeInterval =
        ProcessInfo.processInfo.environment["BETTERTILE_TEST_STALL_PROBE_SECONDS"].flatMap(TimeInterval.init) ?? 10

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime } // real-time: the watchdog measures wall-clock progress of the test process itself

    /// Records that `name` started. Pass the result to `testFinished`.
    public static func testStarted(_ name: String) -> UUID {
        let id = UUID()
        update {
            $0.running[id] = Running(name: name, started: now)
            $0.lastStarted = name
            $0.lastProgress = now
        }
        return id
    }

    public static func testFinished(_ id: UUID) {
        update {
            if $0.running.removeValue(forKey: id) != nil { $0.finished += 1 }
            $0.lastProgress = now
        }
    }

    /// Records the holder of a shared test resource, reported after each `interval` it keeps holding it.
    static func holderChanged(_ resource: UUID, holder: String?, waiting: Int, interval: TimeInterval?) {
        update {
            guard let holder, let interval else { $0.holders[resource] = nil; return }
            $0.holders[resource] = Holder(name: holder, since: now, waiting: waiting, interval: interval)
        }
    }

    static func waitingChanged(_ resource: UUID, waiting: Int) {
        update { $0.holders[resource]?.waiting = waiting }
    }

    private static func update(_ body: (inout State) -> Void) {
        let start = lock.withLock {
            body(&state)
            defer { state.threadStarted = true }
            return !state.threadStarted
        }
        guard start else { return }
        let thread = Thread { watch() }
        thread.name = "BetterTile test watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func watch() {
        var lastHeartbeat = now
        while true {
            Thread.sleep(forTimeInterval: 1) // real-time: the watchdog's own polling interval, independent of every test clock
            let time = now
            var lines: [String] = []
            var takeSample = false
            var pings: [Lane] = []
            lock.withLock {
                for (resource, holder) in state.holders {
                    let held = time - holder.since
                    guard held >= holder.interval * Double(holder.reports + 1) else { continue }
                    state.holders[resource]?.reports += 1
                    lines.append("Test resource holder: \(holder.name) has held the shared UI resource for \(Int(held)) s; "
                        + "\(holder.waiting) test(s) waiting.")
                }
                let oldest = state.running.values.sorted { $0.started < $1.started }
                let running = oldest.prefix(8).map { "\($0.name) (\(Int(time - $0.started)) s)" }.joined(separator: ", ")
                if time - lastHeartbeat >= heartbeatInterval {
                    lastHeartbeat = time
                    lines.append("Test heartbeat: \(state.finished) finished, \(state.running.count) running; "
                        + "last started \(state.lastStarted ?? "none"); oldest running: \(running)")
                }
                let quiet = time - state.lastProgress
                if !state.running.isEmpty, quiet >= stallLimit,
                   state.lastStallReport.map({ time - $0 >= stallLimit }) ?? true {
                    state.lastStallReport = time
                    lines.append("Test watchdog: no test started or finished for \(Int(quiet)) s; "
                        + "\(state.running.count) running, oldest first: \(running); last started \(state.lastStarted ?? "none").")
                    if !state.sampled { state.sampled = true; takeSample = true }
                }
                for lane in Lane.allCases {
                    guard let since = state.pings[lane] else { state.pings[lane] = time; pings.append(lane); continue }
                    let waited = time - since, reports = state.pingReports[lane, default: 0]
                    guard waited >= responsivenessLimit * Double(reports + 1) else { continue }
                    state.pingReports[lane] = reports + 1
                    lines.append("Test watchdog: \(lane.waiting) for \(Int(waited)) s; "
                        + "\(state.running.count) running, oldest first: \(running).")
                    if reports == 0, state.responsivenessSamples < 2 { state.responsivenessSamples += 1; takeSample = true }
                }
            }
            for line in lines { write(line + "\n") }
            if takeSample { writeSample() }
            for lane in pings {
                switch lane {
                case .main: DispatchQueue.main.async { answered(.main) }
                case .pool: Task.detached { answered(.pool) }
                }
            }
        }
    }

    private static func answered(_ lane: Lane) {
        let line: String? = lock.withLock {
            guard let since = state.pings.removeValue(forKey: lane) else { return nil }
            let reports = state.pingReports.removeValue(forKey: lane) ?? 0
            return reports > 0 ? "Test watchdog: \(lane.answered) after \(Int(now - since)) s.\n" : nil
        }
        if let line { write(line) }
    }

    private static func write(_ text: String) {
        text.withCString { pointer in _ = Darwin.write(STDERR_FILENO, pointer, strlen(pointer)) }
    }

    /// Writes one second of `sample` for this process: every thread's stack, including a blocked main thread.
    private static func writeSample() {
        let path = NSTemporaryDirectory() + "bettertile-test-stall-\(getpid()).txt"
        var pid: pid_t = 0
        let arguments = ["/usr/bin/sample", "\(getpid())", "1", "-mayDie", "-file", path]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        guard posix_spawn(&pid, arguments[0], nil, nil, &argv, environ) == 0 else {
            write("Test watchdog: could not start sample.\n")
            return
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            write("Test watchdog: sample wrote nothing.\n")
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        write("Test watchdog: sample of process \(getpid()) (first 800 of \(lines.count) lines, full file \(path)):\n")
        write(lines.prefix(800).joined(separator: "\n") + "\n")
    }
}
