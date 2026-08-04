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
