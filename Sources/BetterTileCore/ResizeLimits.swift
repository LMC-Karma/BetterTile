/// Minimum-size feedback for divider drags. A drag is limited when the
/// resize engine refused part of the requested divider movement; the windows
/// at their minimum along a refused axis are the ones stopping it.
public enum ResizeLimits {
    public static func windowsAtMinimum(
        _ placements: [Placement],
        windows: [WindowSnapshot],
        widthLimited: Bool,
        heightLimited: Bool,
        tolerance: Double = 0.5
    ) -> Set<WindowID> {
        guard widthLimited || heightLimited else { return [] }
        let constraints = Dictionary(windows.map { ($0.id, $0.constraints) }, uniquingKeysWith: { first, _ in first })
        return Set(placements.compactMap { placement in
            guard let minimum = constraints[placement.windowID]?.minimumSize else { return nil }
            let atWidth = widthLimited && placement.frame.size.width <= minimum.width + tolerance
            let atHeight = heightLimited && placement.frame.size.height <= minimum.height + tolerance
            return atWidth || atHeight ? placement.windowID : nil
        })
    }
}
