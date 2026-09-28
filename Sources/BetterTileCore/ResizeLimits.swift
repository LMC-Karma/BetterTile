/// Detects the windows a resize has pressed against their minimum size.
/// Resize engines clamp at the minimum, so a window that shrank and now sits
/// at it is the one stopping the divider.
public enum ResizeLimits {
    public static func windowsAtMinimum(
        _ placements: [Placement],
        windows: [WindowSnapshot],
        baselineFrames: [WindowID: BTRect]
    ) -> Set<WindowID> {
        let constraints = Dictionary(windows.map { ($0.id, $0.constraints) }, uniquingKeysWith: { first, _ in first })
        return Set(placements.compactMap { placement in
            guard let minimum = constraints[placement.windowID]?.minimumSize,
                  let baseline = baselineFrames[placement.windowID]
            else { return nil }
            let size = placement.frame.size
            let atWidth = size.width < baseline.size.width - 0.5 && size.width <= minimum.width + 0.5
            let atHeight = size.height < baseline.size.height - 0.5 && size.height <= minimum.height + 0.5
            return atWidth || atHeight ? placement.windowID : nil
        })
    }
}
