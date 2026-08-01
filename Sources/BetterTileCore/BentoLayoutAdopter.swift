import Foundation

/// Infers a guillotine Bento tree from an already tiled set of real window
/// frames. It succeeds only when the inferred tree reproduces every frame, so
/// an ambiguous desktop is left untouched instead of being rearranged.
public struct BentoLayoutAdopter: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 6) {
        self.tolerance = max(0, tolerance)
    }

    public func adopt(
        frames: [WindowID: BTRect],
        in bounds: BTRect,
        metrics: BentoLayoutMetrics = .gapless
    ) -> BentoLayoutState? {
        guard !frames.isEmpty, frames.count <= 6,
              let root = infer(Array(frames), in: bounds, metrics: metrics)
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
