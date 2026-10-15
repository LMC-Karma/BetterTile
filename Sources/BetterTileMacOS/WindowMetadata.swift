import BetterTileCore

/// Value caches owned by the Accessibility adapter for each window.
struct WindowMetadata {
    /// Bundle identifiers of observed windows, for per-application minimum
    /// size seeds.
    var applicationKeys: [WindowID: String] = [:]
    var continuousSettable: [WindowID: Bool] = [:]
    /// The last answer each window's application gave about whether its
    /// position and size can be set. A busy application can fail the
    /// question without an answer; its window then keeps this verdict.
    var settabilityVerdicts: [WindowID: (movable: Bool?, resizable: Bool?)] = [:]
    /// Size settability, checked once per continuous gesture like moving.
    var continuousSizeSettable: [WindowID: Bool] = [:]
    var lastWriteReadback: [WindowID: BTRect] = [:]
    /// The size each window's latest live tick asked for. During a gesture
    /// an application can still be applying it when the next tick reads back.
    var liveRequestedSizes: [WindowID: BTSize] = [:]
    /// Decided popup classifications, kept for each window's lifetime.
    var popupVerdicts: [WindowID: PopupWindowClassifier.Verdict] = [:]
    var managedWindowIDs: Set<WindowID> = []
    var recentWindowIDs: [WindowID] = []
    var minimizedWindowIDs: Set<WindowID> = []

    mutating func remove(_ windowID: WindowID) {
        applicationKeys.removeValue(forKey: windowID)
        continuousSettable.removeValue(forKey: windowID)
        settabilityVerdicts.removeValue(forKey: windowID)
        continuousSizeSettable.removeValue(forKey: windowID)
        lastWriteReadback.removeValue(forKey: windowID)
        liveRequestedSizes.removeValue(forKey: windowID)
        popupVerdicts.removeValue(forKey: windowID)
        managedWindowIDs.remove(windowID)
        recentWindowIDs.removeAll { $0 == windowID }
        minimizedWindowIDs.remove(windowID)
    }

    mutating func removeAll() { self = WindowMetadata() }
}
