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
