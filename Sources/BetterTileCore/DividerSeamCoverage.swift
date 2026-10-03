/// An on-screen window in front-to-back order. Geometry uses top-left points.
public struct SeamStackEntry: Hashable, Sendable {
    public var windowID: WindowID?
    public var processIdentifier: Int32
    public var layer: Int
    public var alpha: Double
    public var frame: BTRect

    public init(windowID: WindowID?, processIdentifier: Int32, layer: Int, alpha: Double, frame: BTRect) {
        self.windowID = windowID
        self.processIdentifier = processIdentifier
        self.layer = layer
        self.alpha = alpha
        self.frame = frame
    }
}

public struct SeamArmRoom: Equatable, Sendable {
    public var up: Double
    public var down: Double
    public var left: Double
    public var right: Double
}

public enum DividerSeamCoverage {
    /// Only windows at or below `handleLayer` can be drawn over by the handle.
    /// Higher layers, such as the Dock's display-sized window, already draw
    /// above it, so they never hide or trim it.
    public static func frontCandidates(
        stack: [SeamStackEntry], ownProcess: Int32,
        managed: Set<WindowID>, seamParticipants: Set<WindowID>, handleLayer: Int
    ) -> [BTRect] {
        let back = stack.lastIndex { $0.windowID.map(seamParticipants.contains) == true } ?? stack.count
        return stack.prefix(back).compactMap { entry in
            guard entry.processIdentifier != ownProcess, entry.alpha > 0.01,
                  (0...handleLayer).contains(entry.layer), entry.windowID.map(managed.contains) != true
            else { return nil }
            return entry.frame
        }
    }

    public static func band(axis: SplitAxis, coordinate: Double, span: ClosedRange<Double>, hitWidth: Double) -> BTRect {
        axis == .vertical
            ? BTRect(x: coordinate - hitWidth / 2, y: span.lowerBound, width: hitWidth, height: span.upperBound - span.lowerBound)
            : BTRect(x: span.lowerBound, y: coordinate - hitWidth / 2, width: span.upperBound - span.lowerBound, height: hitWidth)
    }

    public static func exposedSegments(
        span: ClosedRange<Double>, axis: SplitAxis, band: BTRect, candidates: [BTRect]
    ) -> [ClosedRange<Double>] {
        let covered = candidates.compactMap { $0.intersection(band) }
            .filter { $0.area > 0 }
            .map { axis == .vertical ? ($0.minY, $0.maxY) : ($0.minX, $0.maxX) }
            .sorted { $0.0 < $1.0 }
        var segments: [ClosedRange<Double>] = []
        var cursor = span.lowerBound
        for (start, end) in covered {
            if start > cursor { segments.append(cursor...min(start, span.upperBound)) }
            cursor = max(cursor, end)
            if cursor >= span.upperBound { break }
        }
        if cursor < span.upperBound { segments.append(cursor...span.upperBound) }
        return segments
    }

    public static func segment(
        containing position: Double, in segments: [ClosedRange<Double>], minimumLength: Double = 24
    ) -> ClosedRange<Double>? {
        segments.first { $0.contains(position) && $0.upperBound - $0.lowerBound >= minimumLength }
    }

    public static func armRoom(
        center: BTPoint, acquisition: BTRect, hitWidth: Double, candidates: [BTRect]
    ) -> SeamArmRoom? {
        guard !candidates.contains(where: { ($0.intersection(acquisition)?.area ?? 0) > 0 }) else { return nil }
        var room = SeamArmRoom(up: .infinity, down: .infinity, left: .infinity, right: .infinity)
        let half = hitWidth / 2
        for frame in candidates {
            if frame.maxX > center.x - half, frame.minX < center.x + half {
                if frame.maxY <= center.y { room.up = min(room.up, center.y - frame.maxY) }
                if frame.minY >= center.y { room.down = min(room.down, frame.minY - center.y) }
            }
            if frame.maxY > center.y - half, frame.minY < center.y + half {
                if frame.maxX <= center.x { room.left = min(room.left, center.x - frame.maxX) }
                if frame.minX >= center.x { room.right = min(room.right, frame.minX - center.x) }
            }
        }
        return room
    }
}
