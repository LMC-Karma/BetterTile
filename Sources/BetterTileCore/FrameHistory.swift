import Foundation

public struct FrameHistory: Sendable {
    public let capacity: Int
    private var framesByWindow: [WindowID: [BTRect]] = [:]

    public init(capacity: Int = 10) {
        self.capacity = max(1, capacity)
    }

    public mutating func record(_ frame: BTRect, for windowID: WindowID) {
        var frames = framesByWindow[windowID, default: []]
        // Preserve intentional one-point nudges; ignore only effectively identical AX readings.
        guard frames.last?.approximatelyEquals(frame, tolerance: 0.01) != true else { return }
        frames.append(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
        framesByWindow[windowID] = frames
    }

    public mutating func restore(for windowID: WindowID) -> BTRect? {
        guard var frames = framesByWindow[windowID], let result = frames.popLast() else { return nil }
        framesByWindow[windowID] = frames
        return result
    }

    public func count(for windowID: WindowID) -> Int { framesByWindow[windowID]?.count ?? 0 }

    public mutating func remove(windowID: WindowID) { framesByWindow.removeValue(forKey: windowID) }
    public mutating func removeAll() { framesByWindow.removeAll() }
}
