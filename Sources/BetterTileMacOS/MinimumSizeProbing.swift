import BetterTileCore

/// A window system that can measure the minimum size of a new window.
/// Call it only through `WindowCoordinator.probeMinimumSizes(for:)`.
@MainActor
public protocol MinimumSizeProbing {
    /// Authorize immediately before each new measurement write. Cleanup of
    /// an already-started measurement remains bounded even after interruption.
    func probeMinimumSizes(for ids: Set<WindowID>, validating isCurrent: () -> Bool) -> MinimumSizeProbeOutcome
}

/// A completed batch is distinct from one stopped before another measurement.
public struct MinimumSizeProbeOutcome: Sendable {
    public var startedWindowIDs: Set<WindowID> = []
    public var unrestoredWindowIDs: Set<WindowID> = []
    public var wasInterrupted = false

    public init() {}
}
