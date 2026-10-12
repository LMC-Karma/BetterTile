import BetterTileCore

/// A window system that can measure the minimum size of a new window.
/// Call it only through `WindowCoordinator.probeMinimumSizes(for:)`.
@MainActor
public protocol MinimumSizeProbing {
    /// Measures each window and restores its original size. Returns the
    /// windows whose original size could not be confirmed afterwards.
    func probeMinimumSizes(for ids: Set<WindowID>) -> Set<WindowID>
}
