#if DEBUG
import Foundation
import BetterTileCore

/// Opt-in diagnostic only. Times use the same uptime clock as screen-capture sidecars.
@MainActor
public final class ArrivalTrace {
    public static let shared = ArrivalTrace()
    public let isEnabled: Bool
    private let runID: String
    private let writer: ArrivalTraceWriter?
    private struct WindowState {
        let pid: Int32
        var target: BTRect?
        var wrote = false
        var matched = false
        var settled = false
    }
    private var windows: [WindowID: WindowState] = [:]

    public convenience init(defaults: UserDefaults = .standard, url: URL? = nil) {
        self.init(isEnabled: defaults.bool(forKey: "BetterTileArrivalTrace"), url: url)
    }

    public init(isEnabled: Bool, url: URL? = nil) {
        self.isEnabled = isEnabled
        runID = isEnabled ? UUID().uuidString : ""
        writer = isEnabled ? ArrivalTraceWriter(url: url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BetterTile/arrival-trace.jsonl")) : nil
    }

    public func record(_ phase: String, pid: Int32, windowID: WindowID? = nil,
                       frame: BTRect? = nil, mode: String? = nil,
                       outcome: String? = nil, reason: String? = nil, axHash: UInt? = nil) {
        guard let writer else { return }
        writer.append(ArrivalTraceRecord(timestamp_ns: DispatchTime.now().uptimeNanoseconds,
            run_id: runID, pid: pid, window_id: windowID?.rawValue, phase: phase,
            frame: frame.map { [$0.minX, $0.minY, $0.size.width, $0.size.height] },
            mode: mode, outcome: outcome, reason: reason, ax_hash: axHash))
    }

    public func readable(pid: Int32, windowID: WindowID, frame: BTRect, axHash: UInt? = nil) {
        guard isEnabled, windows[windowID] == nil else { return }
        windows[windowID] = WindowState(pid: pid)
        record("first_readable_frame", pid: pid, windowID: windowID, frame: frame, axHash: axHash)
    }

    public func observe(_ snapshots: [WindowSnapshot]) {
        guard isEnabled else { return }
        for window in snapshots {
            readable(pid: window.processIdentifier, windowID: window.id, frame: window.frame)
            readback(windowID: window.id, frame: window.frame)
        }
    }

    public func readback(windowID: WindowID, frame: BTRect) {
        guard isEnabled, var state = windows[windowID], state.wrote, !state.matched,
              let target = state.target, frame.approximatelyEquals(target, tolerance: 2) else { return }
        state.matched = true
        windows[windowID] = state
        record("write_readback_matching", pid: state.pid, windowID: windowID, frame: frame)
    }

    public func decided(_ placements: [Placement], mode: String) {
        guard isEnabled else { return }
        for placement in placements {
            guard var state = windows[placement.windowID], !state.settled else { continue }
            if state.target != placement.frame {
                state.target = placement.frame
                state.matched = false
                windows[placement.windowID] = state
                record("placement_decided", pid: state.pid, windowID: placement.windowID,
                       frame: placement.frame, mode: mode)
            }
        }
    }

    public func willWrite(_ placement: Placement) {
        guard isEnabled, var state = windows[placement.windowID], !state.settled, state.target != nil else { return }
        let phase = state.wrote ? "frame_write_issued" : "first_frame_write_issued"
        state.wrote = true
        windows[placement.windowID] = state
        record(phase, pid: state.pid, windowID: placement.windowID, frame: placement.frame)
    }

    /// Called only at an existing settlement boundary; never performs a read.
    public func settled(_ snapshots: [WindowSnapshot], accepted: Bool = false) {
        guard isEnabled else { return }
        observe(snapshots)
        settled(frames: Dictionary(snapshots.map { ($0.id, $0.frame) }, uniquingKeysWith: { _, last in last }), accepted: accepted)
    }

    public func settled(frames: [WindowID: BTRect], accepted: Bool = false) {
        guard isEnabled else { return }
        for (id, frame) in frames {
            guard var state = windows[id], state.wrote, !state.settled,
                  let target = state.target,
                  frame.approximatelyEquals(target, tolerance: 2)
                    || (accepted && SteppedSizeAcceptance.evaluate(requested: target, actual: frame, allowsGrowth: true) == .stepped)
            else { continue }
            if !state.matched, frame.approximatelyEquals(target, tolerance: 2) {
                state.matched = true
                record("write_readback_matching", pid: state.pid, windowID: id, frame: frame)
            }
            state.settled = true
            windows[id] = state
            record("settled", pid: state.pid, windowID: id, frame: frame,
                outcome: frame.approximatelyEquals(target, tolerance: 2) ? "matching" : "accepted_stepped")
        }
    }

    public func disposition(_ phase: String, windowID: WindowID, reason: String) {
        guard isEnabled, let state = windows[windowID], !state.settled else { return }
        record(phase, pid: state.pid, windowID: windowID, reason: reason)
    }

    /// Drains test-owned output. Production never waits for diagnostic disk I/O.
    public func flush() { writer?.flush() }
}

private struct ArrivalTraceRecord: Encodable, Sendable {
    let timestamp_ns: UInt64
    let run_id: String
    let pid: Int32
    let window_id: String?
    let phase: String
    let frame: [Double]?
    let mode: String?
    let outcome: String?
    let reason: String?
    let ax_hash: UInt?
}

/// The serial queue owns the handle. Encoding and disk writes stay off the main actor.
private final class ArrivalTraceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lmckarma.BetterTile.arrival-trace", qos: .utility)
    private let url: URL
    private var handle: FileHandle?
    private var failed = false
    init(url: URL) { self.url = url }
    func append(_ record: ArrivalTraceRecord) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                if handle == nil {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                    }
                    handle = try FileHandle(forWritingTo: url)
                    try handle?.seekToEnd()
                }
                var data = try JSONEncoder().encode(record)
                data.append(0x0a)
                try handle?.write(contentsOf: data)
            } catch {
                failed = true
                NSLog("BetterTile arrival trace write failed: %@", error.localizedDescription)
            }
        }
    }
    func flush() { queue.sync {} }
    deinit { try? handle?.close() }
}
#endif
