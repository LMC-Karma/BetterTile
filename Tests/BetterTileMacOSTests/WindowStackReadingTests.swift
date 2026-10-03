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
    #expect(SeamStackRecord.parseStack([record], identities: identities, labeling: [id]) == [entry])
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

@Test(arguments: [false, true], [false, true]) @MainActor
func seamUnavailableExactIdentitiesRetainLegacyHoverCoverage(partialIdentity: Bool, covered: Bool) throws {
    _ = NSApplication.shared
    var identities = WindowIdentityRegistry()
    let owner = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let left = identities.resolve(application: owner, accessibilityHash: 1,
                                  exactWindowID: partialIdentity ? 101 : nil)
    let right = identities.resolve(application: owner, accessibilityHash: 2, exactWindowID: nil)
    let managed: Set<WindowID> = [left, right]
    var records: [[CFString: Any]] = [
        [kCGWindowNumber: 101, kCGWindowOwnerPID: 42, kCGWindowLayer: 0,
         kCGWindowBounds: ["X": -20000.0, "Y": -20000.0, "Width": 500.0, "Height": 800.0]],
        [kCGWindowNumber: 102, kCGWindowOwnerPID: 42, kCGWindowLayer: 0,
         kCGWindowBounds: ["X": -19500.0, "Y": -20000.0, "Width": 500.0, "Height": 800.0]],
    ]
    if covered {
        records.insert([kCGWindowNumber: 103, kCGWindowOwnerPID: 7, kCGWindowLayer: 0,
                        kCGWindowBounds: ["X": -19600.0, "Y": -19700.0, "Width": 200.0, "Height": 200.0]], at: 0)
    }
    let stack = SeamStackRecord.parseStack(records, identities: identities, labeling: managed)
    #expect(stack == nil)
    let controller = DividerOverlayController(
        coordinator: WindowCoordinator(system: FakeWindowSystem()), configuration: BetterTileConfiguration()
    )
    defer { controller.hideAndCancel() }
    controller.stackProvider = { _ in stack }
    let boundary = BoundaryDescriptor(
        id: "identity-fallback", displayID: DisplayID(rawValue: "main"), axis: .vertical,
        coordinate: -19500, spanStart: -20000, spanEnd: -19200,
        beforeWindowIDs: [left], afterWindowIDs: [right]
    )
    let cover = BTRect(x: -19600, y: -19700, width: 200, height: 200)
    controller.refresh(boundaries: [boundary], obscuringFrames: covered ? [cover] : [],
                       managedWindowIDs: [boundary.displayID: managed])
    let screen = try #require(NSScreen.screens.first)
    controller.updateHover(at: CGPoint(x: -19500, y: screen.frame.maxY + 19600))
    #expect((controller.visibleHandleView?.window?.isVisible == true) == !covered)
}

@Test func seamIncompleteStackUsesFallbackInsteadOfUnlabelledLayoutWindows() throws {
    var identities = WindowIdentityRegistry()
    let owner = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    let first = identities.resolve(application: owner, accessibilityHash: 1, exactWindowID: 101)
    let second = identities.resolve(application: owner, accessibilityHash: 2, exactWindowID: 102)
    let managed: Set<WindowID> = [first, second]
    let record: [CFString: Any] = [
        kCGWindowNumber: 101, kCGWindowOwnerPID: 42, kCGWindowLayer: 0,
        kCGWindowBounds: ["X": 0.0, "Y": 0.0, "Width": 500.0, "Height": 800.0],
    ]
    var other = record
    other[kCGWindowNumber] = 102
    let stack = try #require(SeamStackRecord.parseStack([record, other], identities: identities, labeling: managed))
    #expect(Set(stack.compactMap(\.windowID)) == managed)
    // An inactive or recently closed tab with a retained exact identity may
    // be absent from the on-screen list. It cannot cover the current seam.
    let visibleOnly = try #require(SeamStackRecord.parseStack([record], identities: identities, labeling: managed))
    #expect(visibleOnly.compactMap(\.windowID) == [first])
    other[kCGWindowOwnerPID] = 99
    #expect(SeamStackRecord.parseStack([record, other], identities: identities, labeling: managed) == nil)
    other[kCGWindowOwnerPID] = 42
    other[kCGWindowBounds] = nil
    #expect(SeamStackRecord.parseStack([record, other], identities: identities, labeling: managed) == nil)
    // A stale session ID falls back until the next boundary refresh removes it.
    identities.remove(second)
    #expect(SeamStackRecord.parseStack([record], identities: identities, labeling: managed) == nil)
    #expect(SeamStackRecord.parseStack([record], identities: identities, labeling: [first]) != nil)
}
