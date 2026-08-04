import Foundation

/// Infers a guillotine Bento tree from an already tiled set of real window
/// frames. It succeeds only when the inferred tree reproduces every frame, so
/// an ambiguous desktop is left untouched instead of being rearranged.
public struct BentoLayoutAdopter: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 6) {
        self.tolerance = max(0, tolerance)
    }

    /// Widest uniform inset still treated as a tiling margin rather than as a
    /// deliberate arrangement. macOS uses about 7pt per side; anything much
    /// larger is more likely a layout the user built than one macOS produced.
    public var maximumRecognisedMargin: Double = 16

    public func adopt(
        frames: [WindowID: BTRect],
        in bounds: BTRect,
        metrics: BentoLayoutMetrics = .gapless
    ) -> BentoLayoutState? {
        guard !frames.isEmpty, frames.count <= 6 else { return nil }
        if let state = adoptExactly(frames: frames, in: bounds, metrics: metrics) { return state }

        // macOS insets every tiled window by the same amount on all four sides
        // when "Tiled windows have margins" is on, which is the default. Those
        // frames tile the display perfectly once the inset is removed, so the
        // margin is recognised and then discarded: the arrangement is adopted
        // and re-emitted with whatever gaps the user has configured, rather
        // than inheriting macOS's.
        guard let margin = TiledMargin.infer(
            Array(frames.values),
            in: bounds,
            maximumMargin: maximumRecognisedMargin,
            tolerance: min(2, tolerance)
        ) else { return nil }
        let expanded = frames.mapValues { TiledMargin.removing(margin, from: $0) }
        guard var state = adoptExactly(frames: expanded, in: bounds, metrics: .gapless) else { return nil }
        state.metrics = metrics
        return state
    }

    private func adoptExactly(
        frames: [WindowID: BTRect],
        in bounds: BTRect,
        metrics: BentoLayoutMetrics
    ) -> BentoLayoutState? {
        guard let root = infer(Array(frames), in: bounds, metrics: metrics)
        else { return nil }
        var state = BentoLayoutState(root: root, metrics: metrics)
        // Same-axis binary discoveries normalize into one ordered partition.
        // Re-measure its ratios from the real frames so flattening never
        // changes a valid multi-pane arrangement when gaps are present.
        state.updateWeights(from: frames, in: bounds)
        let reproduced = Dictionary(uniqueKeysWithValues: state.placements(in: bounds).map { ($0.windowID, $0.frame) })
        let reproductionTolerance = min(1, tolerance)
        guard reproduced.count == frames.count,
              frames.allSatisfy({ id, frame in
                  reproduced[id]?.approximatelyEquals(frame, tolerance: reproductionTolerance) == true
              })
        else { return nil }
        return state
    }

    private func infer(
        _ windows: [(key: WindowID, value: BTRect)],
        in rect: BTRect,
        metrics: BentoLayoutMetrics
    ) -> BentoNode? {
        if windows.count == 1 {
            let window = windows[0]
            return window.value.approximatelyEquals(rect, tolerance: tolerance) ? .leaf(window.key) : nil
        }

        for axis in [SplitAxis.vertical, .horizontal] {
            for coordinate in sharedCoordinates(windows, axis: axis, gap: metrics.paneGap) {
                let first = windows.filter { belongsToFirst($0.value, axis: axis, coordinate: coordinate) }
                let second = windows.filter { belongsToSecond($0.value, axis: axis, coordinate: coordinate) }
                guard !first.isEmpty, !second.isEmpty, first.count + second.count == windows.count else { continue }

                let extent = axis == .vertical ? rect.size.width : rect.size.height
                let start = axis == .vertical ? rect.minX : rect.minY
                let usable = extent - metrics.paneGap
                guard usable > 0 else { continue }
                let weight = (coordinate - start - metrics.paneGap / 2) / usable
                guard weight >= 0.1, weight <= 0.9 else { continue }

                let firstRect: BTRect
                let secondRect: BTRect
                if axis == .vertical {
                    firstRect = BTRect(x: rect.minX, y: rect.minY, width: coordinate - metrics.paneGap / 2 - rect.minX, height: rect.size.height)
                    secondRect = BTRect(x: coordinate + metrics.paneGap / 2, y: rect.minY, width: rect.maxX - coordinate - metrics.paneGap / 2, height: rect.size.height)
                } else {
                    firstRect = BTRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: coordinate - metrics.paneGap / 2 - rect.minY)
                    secondRect = BTRect(x: rect.minX, y: coordinate + metrics.paneGap / 2, width: rect.size.width, height: rect.maxY - coordinate - metrics.paneGap / 2)
                }
                if let firstNode = infer(first, in: firstRect, metrics: metrics),
                   let secondNode = infer(second, in: secondRect, metrics: metrics) {
                    return .branch(BentoBranch(axis: axis, weight: weight, first: firstNode, second: secondNode))
                }
            }
        }
        return nil
    }

    private func sharedCoordinates(
        _ windows: [(key: WindowID, value: BTRect)],
        axis: SplitAxis,
        gap: Double
    ) -> [Double] {
        var coordinates: Set<Double> = []
        for first in windows {
            for second in windows where first.key != second.key {
                let firstEdge = axis == .vertical ? first.value.maxX : first.value.maxY
                let secondEdge = axis == .vertical ? second.value.minX : second.value.minY
                if abs((secondEdge - firstEdge) - gap) <= min(1, tolerance) {
                    coordinates.insert((firstEdge + secondEdge) / 2)
                }
            }
        }
        return coordinates.sorted()
    }

    private func belongsToFirst(_ frame: BTRect, axis: SplitAxis, coordinate: Double) -> Bool {
        let edge = axis == .vertical ? frame.maxX : frame.maxY
        let center = axis == .vertical ? frame.midX : frame.midY
        return edge <= coordinate + tolerance && center < coordinate
    }

    private func belongsToSecond(_ frame: BTRect, axis: SplitAxis, coordinate: Double) -> Bool {
        let edge = axis == .vertical ? frame.minX : frame.minY
        let center = axis == .vertical ? frame.midX : frame.midY
        return edge >= coordinate - tolerance && center > coordinate
    }
}

/// Recognises the uniform inset macOS applies to tiled windows.
///
/// With "Tiled windows have margins" on - the default - macOS insets every
/// tiled window by the same amount on all four sides, including against the
/// screen edge. The result tiles the display perfectly once that inset is
/// removed, which is what makes such an arrangement adoptable at all.
public enum TiledMargin {
    /// The inset shared by every frame, or `nil` when the arrangement does not
    /// look uniformly inset.
    ///
    /// The margin shows up as the smallest distance from each side of the
    /// display to the nearest window edge on that side. All four have to agree,
    /// because a one-sided gap is a gap the user made, not a tiling margin.
    public static func infer(
        _ frames: [BTRect],
        in bounds: BTRect,
        maximumMargin: Double = 16,
        tolerance: Double = 2
    ) -> Double? {
        guard !frames.isEmpty, bounds.size.width > 0, bounds.size.height > 0 else { return nil }
        guard let leading = frames.map({ $0.minX - bounds.minX }).min(),
              let top = frames.map({ $0.minY - bounds.minY }).min(),
              let trailing = frames.map({ bounds.maxX - $0.maxX }).min(),
              let bottom = frames.map({ bounds.maxY - $0.maxY }).min()
        else { return nil }
        let sides = [leading, top, trailing, bottom]
        guard let smallest = sides.min(), let largest = sides.max() else { return nil }
        guard smallest > tolerance else { return nil }
        guard largest <= maximumMargin, largest - smallest <= tolerance else { return nil }
        return sides.reduce(0, +) / Double(sides.count)
    }

    /// Grows a frame by the margin on all four sides, undoing the inset.
    public static func removing(_ margin: Double, from frame: BTRect) -> BTRect {
        BTRect(
            x: frame.minX - margin,
            y: frame.minY - margin,
            width: frame.size.width + margin * 2,
            height: frame.size.height + margin * 2
        )
    }
}
