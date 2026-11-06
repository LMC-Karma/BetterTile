import Foundation

/// Holds ambient layout while macOS replaces displays and moves windows between them.
/// Times are elapsed monotonic seconds supplied by the caller, never wall-clock dates.
public struct DisplayChangeHold: Sendable {
    public enum Event: String, Sendable {
        case sleep, wake, displayReconfigurationBegan, displayReconfigurationEnded
        case screenParametersChanged, sessionResigned, sessionBecameActive
    }

    public enum Action: Equatable, Sendable {
        case settled(token: UInt64)
    }

    public private(set) var isHolding = false
    public private(set) var token: UInt64 = 0
    public private(set) var settledByLimit = false
    private var sleeping = false
    private var inactive = false
    private var reconfiguring = false
    private var lastEvent: TimeInterval = 0
    private var signature: Set<DisplaySnapshot>?
    private var signatureSince: TimeInterval = 0
    private var detector = DisplaySettleDetector(quietInterval: 0.25, limit: 5)

    public init() {}

    public mutating func receive(_ event: Event, at time: TimeInterval) {
        switch event {
        case .sleep: sleeping = true
        case .wake: sleeping = false
        case .sessionResigned: inactive = true
        case .sessionBecameActive: inactive = false
        case .displayReconfigurationBegan: reconfiguring = true
        case .displayReconfigurationEnded: reconfiguring = false
        case .screenParametersChanged: break
        }
        token &+= 1
        isHolding = true
        settledByLimit = false
        lastEvent = time
        signature = nil
        detector = DisplaySettleDetector(quietInterval: 0.25, limit: 5)
    }

    /// A stale sampling task cannot release a newer hold. A missing observation
    /// cannot prove quiet, but the deadline still releases an active session.
    public mutating func sample(displaySignature: Set<DisplaySnapshot>, windowFrames: [WindowID: BTRect]?,
                                at time: TimeInterval, token expectedToken: UInt64) -> Action? {
        guard isHolding, expectedToken == token, !sleeping, !inactive else { return nil }
        if time - lastEvent >= 5 { return settle(timedOut: true) }
        guard let windowFrames else {
            signature = nil
            detector = DisplaySettleDetector(quietInterval: 0.25, limit: 5)
            return nil
        }
        if signature != displaySignature {
            signature = displaySignature
            signatureSince = time
            detector = DisplaySettleDetector(quietInterval: 0.25, limit: 5)
        }
        let quiet = detector.observe(windowFrames, at: time) == .quiet
        guard !reconfiguring, !displaySignature.isEmpty, quiet, time - signatureSince >= 0.249 else { return nil }
        return settle()
    }

    private mutating func settle(timedOut: Bool = false) -> Action {
        isHolding = false
        settledByLimit = timedOut
        reconfiguring = false
        return .settled(token: token)
    }
}
