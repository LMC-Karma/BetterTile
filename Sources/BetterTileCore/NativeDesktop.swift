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

    /// Removes windows that are known to belong to another Space. A window on
    /// several Spaces is sticky and therefore floats instead of joining Bento.
    /// Missing membership remains unknown and preserves the public-API result.
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
            guard let current = currentSpaceByDisplay[window.displayID], membership.contains(current) else {
                return nil
            }
            return window
        }
    }
}

/// Optional native capability alongside `WindowSystem`. Callers must preserve
/// their public-API inference path when an observation is unavailable.
@MainActor
public protocol NativeDesktopProviding: AnyObject {
    func nativeDesktopObservation() -> NativeDesktopObservation?
}
