import Foundation

/// Checks the frames windows really took after a Bento write. A layout that
/// reports success must not leave managed windows overlapping.
public enum BentoLayoutVerifier {
    /// Windows whose frames overlap another's by more than the tolerance.
    public static func overlappingWindowIDs(_ frames: [WindowID: BTRect], tolerance: Double = 2) -> Set<WindowID> {
        let entries = frames.sorted { $0.key < $1.key }
        var result: Set<WindowID> = []
        for (index, first) in entries.enumerated() {
            for second in entries.dropFirst(index + 1) {
                let a = first.value, b = second.value
                let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if width > tolerance, height > tolerance {
                    result.insert(first.key)
                    result.insert(second.key)
                }
            }
        }
        return result
    }
}
