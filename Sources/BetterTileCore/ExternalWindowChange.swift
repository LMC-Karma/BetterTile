import Foundation

/// What an externally-caused frame change means for a Bento layout.
///
/// External changes arrive as bare Accessibility move/resize events with no
/// indication of who caused them. Before this classification existed, every
/// change was fed to `BentoLayoutFitter`, which only knows how to read a moved
/// edge as a divider position. A window relocated by macOS's own
/// Window > Move & Resize therefore had its new far edge mistaken for a dragged
/// divider, collapsing its neighbour to a minimum-width sliver.
public enum ExternalWindowChange: Equatable, Sendable {
    /// The window landed on a layout position BetterTile itself can express.
    /// Routed through the same planner a BetterTile shortcut uses, so macOS's
    /// commands and BetterTile's own behave identically.
    case snapDestination(WindowAction)
    /// The window moved wholesale to somewhere unrecognised.
    case relocation
    /// One edge moved while its opposite edge stayed put: a divider drag.
    case dividerResize
}

public enum ExternalWindowChangeClassifier {
    /// Destination matching has to absorb macOS's tiled-window margins, which
    /// are on by default and inset roughly 7pt per side — about 14pt of size
    /// difference. The adjacency tolerance used for divider work is far too
    /// tight for this: at its default of 6 a macOS-tiled window would never be
    /// recognised, and would silently fall through to the divider path that
    /// produced the collapse in the first place.
    public static let defaultDestinationTolerance: Double = 16

    /// Positions macOS's Window > Move & Resize menu can produce. Thirds and
    /// sixths are deliberately absent: macOS does not offer them, so accepting
    /// them would only widen the chance of a false match.
    public static let recognisedDestinations: [WindowAction] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
        .maximize,
    ]

    /// - Parameters:
    ///   - expected: The frame the layout believes the window occupies.
    ///   - observed: The frame it actually occupies now.
    ///   - edgeTolerance: Slack when deciding whether an edge held still.
    public static func classify(
        expected: BTRect,
        observed: BTRect,
        in bounds: BTRect,
        edgeTolerance: Double = 6,
        destinationTolerance: Double = defaultDestinationTolerance
    ) -> ExternalWindowChange {
        let displacement = max(
            abs(observed.minX - expected.minX),
            abs(observed.minY - expected.minY),
            abs(observed.maxX - expected.maxX),
            abs(observed.maxY - expected.maxY)
        )

        // A recognised destination wins over the edge test, because filling the
        // screen from a half moves only one edge and the edge test alone would
        // call that a divider drag and push the split off the display.
        //
        // It only wins for a window that actually travelled, though. Nudging a
        // divider a few points away from the midpoint leaves the window within
        // tolerance of a half, and treating that as a snap would drag it back
        // to dead centre and make small adjustments near the middle impossible.
        if displacement > destinationTolerance,
           let action = matchDestination(observed, in: bounds, tolerance: destinationTolerance) {
            return .snapDestination(action)
        }

        // A divider drag pivots the window: one edge follows the pointer while
        // the opposite edge stays anchored. If both edges on either axis have
        // moved, the window was carried rather than stretched.
        let movedMinX = abs(observed.minX - expected.minX) > edgeTolerance
        let movedMaxX = abs(observed.maxX - expected.maxX) > edgeTolerance
        let movedMinY = abs(observed.minY - expected.minY) > edgeTolerance
        let movedMaxY = abs(observed.maxY - expected.maxY) > edgeTolerance
        if (movedMinX && movedMaxX) || (movedMinY && movedMaxY) {
            return .relocation
        }
        return .dividerResize
    }

    /// The closest recognised destination whose every edge falls within
    /// `tolerance`, or `nil` when the frame is not one of them. Ties are
    /// rejected rather than guessed.
    public static func matchDestination(
        _ frame: BTRect,
        in bounds: BTRect,
        tolerance: Double = defaultDestinationTolerance
    ) -> WindowAction? {
        guard bounds.size.width > 0, bounds.size.height > 0 else { return nil }
        var best: (action: WindowAction, distance: Double)?
        var tied = false
        for action in recognisedDestinations {
            guard let partition = action.partition else { continue }
            let candidate = partition.frame(in: bounds)
            let distance = max(
                abs(frame.minX - candidate.minX),
                abs(frame.minY - candidate.minY),
                abs(frame.maxX - candidate.maxX),
                abs(frame.maxY - candidate.maxY)
            )
            guard distance <= tolerance else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (action, distance)
                    tied = false
                } else if distance == current.distance {
                    tied = true
                }
            } else {
                best = (action, distance)
            }
        }
        return tied ? nil : best?.action
    }
}
