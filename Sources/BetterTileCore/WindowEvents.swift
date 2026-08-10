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
        case .created, .destroyed, .minimized, .restored:
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
