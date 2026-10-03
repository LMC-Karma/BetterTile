import AppKit
import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Test func seamStackParserReadsOnlyGeometryAndExactIdentity() throws {
    var identities = WindowIdentityRegistry()
    let id = identities.resolve(application: ApplicationLaunchInstance(processIdentifier: 42, generation: 1),
                                accessibilityHash: 5, exactWindowID: 123)
    let record: [CFString: Any] = [
        kCGWindowNumber: 123, kCGWindowOwnerPID: 42, kCGWindowLayer: 3,
        kCGWindowAlpha: 0.5, kCGWindowBounds: ["X": -500.0, "Y": 20.0, "Width": 200.0, "Height": 100.0],
        kCGWindowName: "This field must never be read",
    ]
    var keys = Set<CFString>()
    let entry = try #require(SeamStackRecord.parse(value: { key in
        keys.insert(key)
        return record[key]
    }, identities: identities, labeling: [id]))
    #expect(keys == [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowAlpha, kCGWindowBounds])
    #expect(entry == SeamStackEntry(windowID: id, processIdentifier: 42, layer: 3, alpha: 0.5,
                                    frame: BTRect(x: -500, y: 20, width: 200, height: 100)))
    var mismatch = record
    mismatch[kCGWindowOwnerPID] = 43
    #expect(SeamStackRecord.parse(value: { mismatch[$0] }, identities: identities, labeling: [id])?.windowID == nil)
    #expect(SeamStackRecord.parse(value: { record[$0] }, identities: identities, labeling: [])?.windowID == nil)
    mismatch = record
    mismatch[kCGWindowAlpha] = nil
    #expect(SeamStackRecord.parse(value: { mismatch[$0] }, identities: identities, labeling: [id])?.alpha == 1)
    mismatch[kCGWindowBounds] = ["X": Double.nan, "Y": 0.0, "Width": 20.0, "Height": 20.0]
    #expect(SeamStackRecord.parse(value: { mismatch[$0] }, identities: identities, labeling: [id]) == nil)
}
