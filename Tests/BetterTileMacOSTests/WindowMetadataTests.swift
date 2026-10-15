import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

private func populatedWindowMetadata(_ ids: [WindowID]) -> WindowMetadata {
    var metadata = WindowMetadata()
    for id in ids {
        metadata.applicationKeys[id] = "test.application"
        metadata.continuousSettable[id] = true
        metadata.settabilityVerdicts[id] = (true, false)
        metadata.continuousSizeSettable[id] = false
        metadata.lastWriteReadback[id] = BTRect(x: 0, y: 0, width: 500, height: 800)
        metadata.liveRequestedSizes[id] = BTSize(width: 500, height: 800)
        metadata.popupVerdicts[id] = .window
        metadata.managedWindowIDs.insert(id)
        metadata.recentWindowIDs.append(id)
        metadata.minimizedWindowIDs.insert(id)
    }
    return metadata
}

@Test(arguments: [false, true]) func obsoleteWindowMetadataReleasesEveryRetainedValue(reset: Bool) {
    let closed = WindowID(rawValue: "closed"), survivor = WindowID(rawValue: "survivor")
    var metadata = populatedWindowMetadata([closed, survivor])
    if reset { metadata.removeAll() } else { metadata.remove(closed) }
    let expected: Set<WindowID> = reset ? [] : [survivor]
    #expect(Set(metadata.applicationKeys.keys) == expected)
    #expect(Set(metadata.continuousSettable.keys) == expected)
    #expect(Set(metadata.settabilityVerdicts.keys) == expected)
    #expect(Set(metadata.continuousSizeSettable.keys) == expected)
    #expect(Set(metadata.lastWriteReadback.keys) == expected)
    #expect(Set(metadata.liveRequestedSizes.keys) == expected)
    #expect(Set(metadata.popupVerdicts.keys) == expected)
    #expect(metadata.managedWindowIDs == expected)
    #expect(Set(metadata.recentWindowIDs) == expected)
    #expect(metadata.minimizedWindowIDs == expected)
}
