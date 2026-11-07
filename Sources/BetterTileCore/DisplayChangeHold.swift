import Foundation

/// What a display change can alter: which displays exist, where they are, and
/// their size in points and pixels. Work areas are left out: a Dock or menu bar
/// change moves no window between displays, and the ordinary work-area reflow
/// already handles it.
public struct DisplayArrangement: Hashable, Sendable {
    public struct Display: Hashable, Sendable {
        public var id: DisplayID
        public var frame: BTRect
        public var pixelWidth: Int
        public var pixelHeight: Int

        public init(id: DisplayID, frame: BTRect, pixelWidth: Int, pixelHeight: Int) {
            self.id = id
            self.frame = frame
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    public var displays: Set<Display>

    public init(displays: Set<Display>) { self.displays = displays }

    public init(_ snapshots: [DisplaySnapshot]) {
        displays = Set(snapshots.map {
            Display(id: $0.id, frame: $0.frame,
                    pixelWidth: Int(($0.frame.size.width * $0.scaleFactor).rounded()),
                    pixelHeight: Int(($0.frame.size.height * $0.scaleFactor).rounded()))
        })
    }
}

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
    private var pendingReconfigurations = 0
    public var isWaitingForWakeOrUnlock: Bool { sleeping || inactive }
    /// Core Graphics reconfigurations that began and have not ended.
    public var pendingReconfigurationCount: Int { pendingReconfigurations }
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
        case .displayReconfigurationBegan: pendingReconfigurations += 1
        case .displayReconfigurationEnded: pendingReconfigurations = max(0, pendingReconfigurations - 1)
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
        guard pendingReconfigurations == 0, !displaySignature.isEmpty, quiet, time - signatureSince >= 0.249 else { return nil }
        return settle()
    }

    /// The limit is measured by time. Callers check it before a synchronous
    /// inventory, which can take seconds when applications do not answer.
    public func isPastLimit(at time: TimeInterval) -> Bool {
        isHolding && !sleeping && !inactive && time - lastEvent >= 5
    }

    /// Ends a hold whose reconfigurations all ended without changing the
    /// display arrangement. Sleep, lock and pending reconfigurations still hold.
    public mutating func releaseUnchanged(token expectedToken: UInt64) -> Action? {
        guard isHolding, expectedToken == token, !sleeping, !inactive, pendingReconfigurations == 0 else { return nil }
        return settle()
    }

    private mutating func settle(timedOut: Bool = false) -> Action {
        isHolding = false
        settledByLimit = timedOut
        pendingReconfigurations = 0
        return .settled(token: token)
    }
}
