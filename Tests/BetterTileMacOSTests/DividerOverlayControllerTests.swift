import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func dividerHandleIsSuppressedWhenAFloatingWindowCoversIt() {
    let handle = BTRect(x: 490, y: 300, width: 20, height: 56)
    let settings = BTRect(x: 300, y: 180, width: 700, height: 520)
    let besideHandle = BTRect(x: 520, y: 300, width: 200, height: 200)

    #expect(DividerHandleOcclusion.isCovered(handle, by: [settings]))
    #expect(!DividerHandleOcclusion.isCovered(handle, by: [besideHandle]))

    let displayID = DisplayID(rawValue: "main")
    let managed = WindowSnapshot(
        id: WindowID(rawValue: "managed"),
        processIdentifier: 1,
        frame: BTRect(x: 0, y: 0, width: 500, height: 800),
        displayID: displayID
    )
    let floating = WindowSnapshot(
        id: WindowID(rawValue: "floating"),
        processIdentifier: 2,
        frame: settings,
        displayID: displayID
    )
    #expect(DividerHandleOcclusion.obscuringFrames(
        in: [managed, floating],
        excluding: [managed.id]
    ) == [settings])
}

@Test func dividerGripUsesThreefoldStraightGrowthAndShortSpanCap() {
    #expect(DividerHandleGeometry.straightLength(span: 0...200, active: false) == 56)
    #expect(DividerHandleGeometry.straightLength(span: 0...200, active: true) == 168)
    #expect(DividerHandleGeometry.straightLength(span: 0...90, active: true) == 90)
}

@Test func junctionGripKeepsACompactTargetAndGrowsOnlyExistingArms() {
    let arms: Set<DividerHandleArm> = [.up, .down, .left]
    let resting = DividerHandleGeometry.junctionFrame(
        center: .init(x: 100, y: 100), arms: arms, active: false, thickness: 6
    )
    let active = DividerHandleGeometry.junctionFrame(
        center: .init(x: 100, y: 100), arms: arms, active: true, thickness: 6
    )

    #expect(resting.width == 32)
    #expect(resting.height == 32)
    #expect(active.minX == 64)
    #expect(active.maxX == 103)
    #expect(active.minY == 64)
    #expect(active.maxY == 136)
}
