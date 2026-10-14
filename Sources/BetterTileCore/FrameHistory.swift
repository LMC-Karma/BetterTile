import Foundation

public struct FrameHistory: Sendable {
    public let capacity: Int
    private var framesByWindow: [WindowID: [BTRect]] = [:]

    public init(capacity: Int = 10) {
        self.capacity = max(1, capacity)
    }

    /// Returns false when the frame repeats the newest entry and is not added.
    @discardableResult
    public mutating func record(_ frame: BTRect, for windowID: WindowID) -> Bool {
        var frames = framesByWindow[windowID, default: []]
        // Preserve intentional one-point nudges; ignore only effectively identical AX readings.
        guard frames.last?.approximatelyEquals(frame, tolerance: 0.01) != true else { return false }
        frames.append(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
        framesByWindow[windowID] = frames
        return true
    }

    /// Removes the newest entry when it is `frame`, for a step whose change
    /// was undone by other means. Older entries stay.
    @discardableResult
    public mutating func removeLast(_ frame: BTRect, for windowID: WindowID) -> Bool {
        guard var frames = framesByWindow[windowID], frames.last?.approximatelyEquals(frame, tolerance: 0.01) == true
        else { return false }
        frames.removeLast()
        framesByWindow[windowID] = frames.isEmpty ? nil : frames
        return true
    }

    /// Returns the next restore frame without consuming it.
    public func peek(for windowID: WindowID) -> BTRect? { framesByWindow[windowID]?.last }

    public mutating func restore(for windowID: WindowID) -> BTRect? {
        guard var frames = framesByWindow[windowID], let result = frames.popLast() else { return nil }
        framesByWindow[windowID] = frames
        return result
    }

    public func count(for windowID: WindowID) -> Int { framesByWindow[windowID]?.count ?? 0 }

    public mutating func remove(windowID: WindowID) { framesByWindow.removeValue(forKey: windowID) }
    public mutating func removeAll() { framesByWindow.removeAll() }
}
