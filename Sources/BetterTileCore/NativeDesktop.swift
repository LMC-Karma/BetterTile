/// Process-local identity for one native macOS Space. SkyLight identities are
/// not a persistence contract, so BetterTile never encodes this value.
public struct NativeSpaceID: RawRepresentable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: NativeSpaceID, rhs: NativeSpaceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Validated, all-or-nothing native desktop topology for one observation.
public struct NativeDesktopObservation: Hashable, Sendable {
    public var currentSpaceByDisplay: [DisplayID: NativeSpaceID]
    public var knownSpacesByDisplay: [DisplayID: Set<NativeSpaceID>]
    /// Missing entries mean unknown. Empty memberships are never stored.
    public var windowMembership: [WindowID: Set<NativeSpaceID>]
    public var fullscreenSpaceIDs: Set<NativeSpaceID>

    public init(
        currentSpaceByDisplay: [DisplayID: NativeSpaceID],
        knownSpacesByDisplay: [DisplayID: Set<NativeSpaceID>],
        windowMembership: [WindowID: Set<NativeSpaceID>] = [:],
        fullscreenSpaceIDs: Set<NativeSpaceID> = []
    ) {
        self.currentSpaceByDisplay = currentSpaceByDisplay
        self.knownSpacesByDisplay = knownSpacesByDisplay
        self.windowMembership = windowMembership.filter { !$0.value.isEmpty }
        self.fullscreenSpaceIDs = fullscreenSpaceIDs
    }

    public func currentSpace(on displayID: DisplayID) -> NativeSpaceID? {
        currentSpaceByDisplay[displayID]
    }

    public func isFullscreenSpace(on displayID: DisplayID) -> Bool {
        currentSpaceByDisplay[displayID].map(fullscreenSpaceIDs.contains) ?? false
    }

    public func allowsAutomaticLayout(on displayID: DisplayID) -> Bool {
        !isFullscreenSpace(on: displayID)
    }

    /// Live members of this desktop. Sticky and unknown memberships cannot
    /// corroborate a pane's presence in one particular layout session.
    public func exclusiveWindowIDs(on displayID: DisplayID) -> Set<WindowID> {
        guard let space = currentSpace(on: displayID) else { return [] }
        return Set(windowMembership.compactMap { id, spaces in
            spaces == [space] ? id : nil
        })
    }

    /// Removes windows that are known to belong to another Space. A window on
    /// several Spaces is sticky and therefore floats instead of joining Bento.
    /// Missing membership remains unknown and preserves the public-API result.
    ///
    /// With separate Spaces per display, a window's center can cross to a
    /// neighbouring display while the window still belongs to the current
    /// Space of the display it came from, for example during a drag. That
    /// window is on screen on a current Space, so it is kept and reported on
    /// its Space's display. Only a window whose Space is current on no display
    /// is removed.
    public func windowsOnCurrentSpaces(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.compactMap { window in
            guard let membership = windowMembership[window.id], !membership.isEmpty else {
                return window
            }
            guard membership.count == 1 else {
                var floating = window
                floating.isFloating = true
                return floating
            }
            if let current = currentSpaceByDisplay[window.displayID], membership.contains(current) {
                return window
            }
            guard let spaceDisplay = currentSpaceByDisplay.keys.sorted().first(where: {
                membership.contains(currentSpaceByDisplay[$0]!)
            }) else { return nil }
            var placed = window
            placed.displayID = spaceDisplay
            return placed
        }
    }
}
