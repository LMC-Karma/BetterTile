import Foundation

/// Decides when a window that is no longer being observed should lose its place
/// in a layout.
///
/// The window set comes from a sweep of the window server, and a sweep can miss
/// a window that is still on screen — during a Space or Mission Control
/// transition, while an application is busy, or when the window server briefly
/// reports it on another layer. Removing a pane the first time a sweep comes
/// back without it means one unlucky observation dismantles a layout the user
/// was working in, with nothing on screen to explain it.
///
/// So absence has to be corroborated. A window is given a few consecutive
/// misses before it is treated as gone, and an explicit destroyed or minimized
/// event bypasses the wait entirely because that is direct evidence rather than
/// an inference from silence.
public struct WindowPresenceTracker: Hashable, Sendable {
    /// Consecutive sweeps each absent window has been missing for.
    public private(set) var consecutiveAbsences: [WindowID: Int]

    /// How many sweeps a known window may be missing from before it is dropped.
    /// Two covers a transition that spans a sweep boundary without keeping a
    /// genuinely closed window in the tree long enough to be noticed.
    public var toleratedAbsences: Int

    public init(consecutiveAbsences: [WindowID: Int] = [:], toleratedAbsences: Int = 2) {
        self.consecutiveAbsences = consecutiveAbsences
        self.toleratedAbsences = max(0, toleratedAbsences)
    }

    /// Records one sweep and returns the windows that have now been missing
    /// long enough to remove.
    ///
    /// - Parameters:
    ///   - known: Windows the layout currently holds.
    ///   - present: Windows this sweep actually observed.
    ///   - confirmedGone: Windows a destroyed or minimized event has already
    ///     accounted for. Removed without waiting.
    ///   - exempt: Windows the layout is deliberately hiding, which are absent
    ///     by design and must not accumulate absences.
    public mutating func observe(
        known: Set<WindowID>,
        present: Set<WindowID>,
        confirmedGone: Set<WindowID> = [],
        exempt: Set<WindowID> = []
    ) -> Set<WindowID> {
        // Forget windows the layout no longer holds, so a reused identifier
        // never inherits a stale tally.
        consecutiveAbsences = consecutiveAbsences.filter { known.contains($0.key) }

        var removals: Set<WindowID> = []
        for windowID in known {
            if confirmedGone.contains(windowID) {
                consecutiveAbsences.removeValue(forKey: windowID)
                removals.insert(windowID)
                continue
            }
            if exempt.contains(windowID) {
                consecutiveAbsences.removeValue(forKey: windowID)
                continue
            }
            if present.contains(windowID) {
                consecutiveAbsences.removeValue(forKey: windowID)
                continue
            }
            let absences = (consecutiveAbsences[windowID] ?? 0) + 1
            if absences > toleratedAbsences {
                consecutiveAbsences.removeValue(forKey: windowID)
                removals.insert(windowID)
            } else {
                consecutiveAbsences[windowID] = absences
            }
        }
        return removals
    }

    /// Windows currently missing but still held, with how many sweeps they have
    /// been missing for. Diagnostics only.
    public var pending: [WindowID: Int] { consecutiveAbsences }

    public mutating func forget(_ windowID: WindowID) {
        consecutiveAbsences.removeValue(forKey: windowID)
    }

    public mutating func reset() {
        consecutiveAbsences.removeAll()
    }
}

/// Whether a frame BetterTile is about to write leaves the window reachable.
///
/// A placement can be arithmetically valid and still be useless: a stale
/// display frame, a layout computed against bounds that have since changed, or
/// a split driven to a display edge can all produce a frame that puts a window
/// mostly or entirely off-screen. Minimum-size validation does not catch any of
/// those, because the size can be perfectly legal while the origin is not.
public enum PlacementBounds {
    /// How much of a placement has to land inside the display's visible frame.
    /// Generous, because a window may legitimately overhang slightly, but
    /// decisive about frames that leave nothing to grab.
    public static let minimumVisibleFraction: Double = 0.5

    public static func isReachable(
        _ frame: BTRect,
        in visibleFrame: BTRect,
        minimumVisibleFraction: Double = minimumVisibleFraction
    ) -> Bool {
        let area = frame.size.width * frame.size.height
        guard area > 0 else { return false }
        guard visibleFrame.size.width > 0, visibleFrame.size.height > 0 else { return true }
        let visible = frame.intersection(visibleFrame)?.area ?? 0
        return visible / area >= minimumVisibleFraction
    }
}

/// What actually became of a frame BetterTile asked for.
///
/// A successful Accessibility write only means the application accepted the
/// message, not that the window is where it was asked to be. Reporting the
/// write as the outcome tells the user an action succeeded while they are
/// looking at a window that did not move.
public enum PlacementOutcome: Equatable, Sendable {
    /// The window is where it was asked to be.
    case landed
    /// Positioned correctly, but the application kept a size of its own. Common
    /// and usually benign: fixed-size and minimum-size windows do this.
    case resisted(actual: BTRect)
    /// The window is not where it was asked to be.
    case failed(actual: BTRect)
}

public enum PlacementVerifier {
    /// Position is judged more strictly than size. A window that refuses to
    /// resize is still where the user asked for it and the layout can adapt; a
    /// window in the wrong place is the failure people actually notice.
    public static func outcome(
        requested: BTRect,
        actual: BTRect,
        positionTolerance: Double = 8,
        sizeTolerance: Double = 8
    ) -> PlacementOutcome {
        let positionMatches = abs(actual.minX - requested.minX) <= positionTolerance
            && abs(actual.minY - requested.minY) <= positionTolerance
        guard positionMatches else { return .failed(actual: actual) }
        let sizeMatches = abs(actual.size.width - requested.size.width) <= sizeTolerance
            && abs(actual.size.height - requested.size.height) <= sizeTolerance
        return sizeMatches ? .landed : .resisted(actual: actual)
    }
}

public extension PlacementBounds {
    /// Slack for the arithmetic that produced a frame, not for how far a window
    /// may stray.
    static let containmentTolerance: Double = 0.5

    /// Whether a frame lies entirely inside the visible frame.
    ///
    /// Bento owns the whole work area and its panes are derived from it, so a
    /// proposal that leaves the visible frame at all is a bad proposal. That is
    /// a stricter question than `isReachable`, which asks only whether a window
    /// the user placed deliberately is still grabbable.
    static func isContained(
        _ frame: BTRect,
        in visibleFrame: BTRect,
        tolerance: Double = containmentTolerance
    ) -> Bool {
        guard visibleFrame.size.width > 0, visibleFrame.size.height > 0 else { return true }
        guard frame.size.width > 0, frame.size.height > 0 else { return false }
        return frame.minX >= visibleFrame.minX - tolerance
            && frame.minY >= visibleFrame.minY - tolerance
            && frame.maxX <= visibleFrame.maxX + tolerance
            && frame.maxY <= visibleFrame.maxY + tolerance
    }
}

/// The conclusion of a verification made after a window has had time to settle.
public enum DelayedPlacementVerdict: Equatable, Sendable {
    /// The window reached the frame it was asked for.
    case landed
    /// The window never moved: it is still sitting where it started.
    case failed
    /// Something else has happened to the window since. Nothing is reported,
    /// because the action being verified is no longer what the user is looking
    /// at.
    case superseded
    /// The window could not be read. Nothing can be concluded.
    case inconclusive
}

public enum DelayedPlacementVerifier {
    /// A delayed check is only allowed to report failure when the window
    /// demonstrably never moved.
    ///
    /// Verification runs a few hundred milliseconds after the write, and a lot
    /// can happen in that time: the user drags the window, a Bento reflow moves
    /// it, macOS tiles it somewhere else. Reporting on the original action then
    /// puts a failure on screen for something the user has already replaced.
    ///
    /// Two independent signals are needed. The mutation generation catches
    /// anything BetterTile did, but a mouse drag never touches the coordinator
    /// and so never changes it; the frame check catches that. A window found
    /// anywhere other than where it started or where it was sent has been moved
    /// by something else, whichever signal noticed.
    public static func verdict(
        source: BTRect,
        target: BTRect,
        actual: BTRect?,
        generationChanged: Bool,
        tolerance: Double = 8
    ) -> DelayedPlacementVerdict {
        guard let actual else { return .inconclusive }
        switch PlacementVerifier.outcome(
            requested: target,
            actual: actual,
            positionTolerance: tolerance,
            sizeTolerance: tolerance
        ) {
        case .landed, .resisted:
            return .landed
        case .failed:
            break
        }
        if generationChanged { return .superseded }
        let stillAtSource = abs(actual.minX - source.minX) <= tolerance
            && abs(actual.minY - source.minY) <= tolerance
        return stillAtSource ? .failed : .superseded
    }
}
