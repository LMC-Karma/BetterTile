import Foundation

public struct WindowEventBuffer: Sendable {
    public private(set) var frameEventWindowIDs: Set<WindowID> = []
    public private(set) var resizedWindowIDs: Set<WindowID> = []
    public private(set) var topologyChanged = false

    public init() {}

    public var isEmpty: Bool {
        frameEventWindowIDs.isEmpty && !topologyChanged
    }

    public func isReadyForProcessing(isGestureActive: Bool, isStabilizingSpace: Bool) -> Bool {
        !isEmpty && !isGestureActive && !isStabilizingSpace
    }

    public mutating func record(_ event: WindowSystemEvent) {
        switch event.kind {
        case .moved:
            if let windowID = event.windowID { frameEventWindowIDs.insert(windowID) }
        case .resized:
            if let windowID = event.windowID {
                frameEventWindowIDs.insert(windowID)
                resizedWindowIDs.insert(windowID)
            }
        case .destroyed:
            // A buffered sweep still needs the topology change, but a closed
            // window can no longer contribute a move or a resize. Holds and
            // gestures must not retain those keys until their eventual end.
            if let windowID = event.windowID {
                frameEventWindowIDs.remove(windowID)
                resizedWindowIDs.remove(windowID)
            }
            topologyChanged = true
        case .created, .minimized, .restored:
            topologyChanged = true
        case .focused:
            break
        }
    }

    public mutating func recordFrameChanges(_ windowIDs: Set<WindowID>) {
        frameEventWindowIDs.formUnion(windowIDs)
    }

    public mutating func recordTopologyChange() {
        topologyChanged = true
    }

    public mutating func formUnion(_ other: Self) {
        frameEventWindowIDs.formUnion(other.frameEventWindowIDs)
        resizedWindowIDs.formUnion(other.resizedWindowIDs)
        topologyChanged = topologyChanged || other.topologyChanged
    }

    public mutating func acknowledge(_ events: Self) {
        frameEventWindowIDs.subtract(events.frameEventWindowIDs)
        resizedWindowIDs.subtract(events.resizedWindowIDs)
        if events.topologyChanged { topologyChanged = false }
    }

    public mutating func removeAll() {
        frameEventWindowIDs.removeAll()
        resizedWindowIDs.removeAll()
        topologyChanged = false
    }

    public mutating func drain() -> Self {
        let result = self
        removeAll()
        return result
    }
}

public struct WindowEventRetryBackoff: Sendable {
    public static let initialDelay: Duration = .milliseconds(120)

    public private(set) var delay = Self.initialDelay

    public init() {}

    public mutating func nextDelayAfterFailure() -> Duration {
        delay = min(delay + delay, .milliseconds(1_920))
        return delay
    }

    public mutating func reset() {
        delay = Self.initialDelay
    }
}

/// When launch discovery reads a launched application again.
///
/// A burst covers the measured case: the launch sweep reads the first window
/// while the window server does not show it yet, and the window shows about
/// 10–40 ms later. The continuation covers an application that builds its first
/// window before its observer exists but shows it later, at a cadence that backs
/// off from four reads a second to one. A window created after the observer
/// exists announces itself with a creation event and gets its own created-window
/// arrival; discovery skips its reads while that arrival is pending and goes on
/// afterwards. The continuation only has to bridge the first seconds of a launch,
/// and it ends well before the 10 s watchdog. One read asks only the launched
/// application through Accessibility.
public enum LaunchDiscoverySchedule {
    /// The delay before each turn: 7 turns in the first 0.5 s, then 9 turns
    /// over the next 5.5 s, 16 scheduled turns in a nominal 6 s. Focus-requested
    /// reads (`focusReadLimit`) come on top.
    public static let delays: [Duration] = [
        .milliseconds(10), .milliseconds(15), .milliseconds(25), .milliseconds(50),
        .milliseconds(100), .milliseconds(150), .milliseconds(150),
        .milliseconds(250), .milliseconds(250), .milliseconds(500), .milliseconds(500),
        .milliseconds(500), .milliseconds(750), .milliseconds(750), .seconds(1), .seconds(1),
    ]

    /// Nil when discovery has had all its turns.
    public static func delay(beforeTurn turn: Int) -> Duration? {
        delays.indices.contains(turn) ? delays[turn] : nil
    }

    /// The nominal time from the launch sweep to the last turn. Each turn's own
    /// work and main-actor delays add to it; the turn count is the hard bound.
    public static var bound: Duration { delays.reduce(.zero, +) }

    /// A focus change of the launched application asks for a read outside the
    /// schedule. Such reads are at least this far apart, so a burst of focus
    /// events costs one read per interval.
    public static let focusReadInterval: Duration = .milliseconds(100)

    /// At most this many focus-requested reads per discovery. With the
    /// scheduled turns, one discovery makes at most 24 reads.
    public static let focusReadLimit = 8
}
