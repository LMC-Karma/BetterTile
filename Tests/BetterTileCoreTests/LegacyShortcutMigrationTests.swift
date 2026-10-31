import Foundation
import Testing
@testable import BetterTileCore

@Test func legacyShortcutSchemaMigratesToCurrentShortcuts() throws {
    // Literal action order and legacy defaults copied from the shortcut schema 2 build.
    let oldActions: [WindowAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds, .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter, .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth, .maximize, .almostMaximize, .center, .centerResize, .previousDisplay, .nextDisplay, .moveLeft, .moveRight, .moveUp, .moveDown, .growWidth, .shrinkWidth, .growHeight, .shrinkHeight, .restore]
    let legacy: [ShortcutBinding] = [
        .init(action: .leftHalf, shortcut: .init(keyCode: 123, modifiers: [.control, .option], keyLabel: "←")),
        .init(action: .rightHalf, shortcut: .init(keyCode: 124, modifiers: [.control, .option], keyLabel: "→")),
        .init(action: .topHalf, shortcut: .init(keyCode: 126, modifiers: [.control, .option], keyLabel: "↑")),
        .init(action: .bottomHalf, shortcut: .init(keyCode: 125, modifiers: [.control, .option], keyLabel: "↓")),
        .init(action: .maximize, shortcut: .init(keyCode: 126, modifiers: [.control, .option, .command], keyLabel: "↑")),
        .init(action: .restore, shortcut: .init(keyCode: 125, modifiers: [.control, .option, .command], keyLabel: "↓")),
        .init(action: .nextDisplay, shortcut: .init(keyCode: 124, modifiers: [.control, .option, .command], keyLabel: "→")),
        .init(action: .previousDisplay, shortcut: .init(keyCode: 123, modifiers: [.control, .option, .command], keyLabel: "←")),
    ] + oldActions.filter { action in
        ![.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .restore, .nextDisplay, .previousDisplay].contains(action)
    }.map { ShortcutBinding(action: $0, shortcut: nil) }
    #expect(legacy.count == 34)
    #expect(legacy == BetterTileConfiguration.legacyDefaultShortcutsV2)
    let bindings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
    let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "shortcuts": bindings])
    let migrated = try ConfigurationStore.decode(bytes)
    #expect(migrated.shortcuts == BetterTileConfiguration.defaultShortcuts)
    #expect(migrated.shortcuts.count == 41)
    #expect(migrated.shortcuts.filter { $0.action == .showTabBar || $0.action.isTabCommand }.allSatisfy { $0.shortcut == nil })
    #expect(migrated.tabbedStripPresentation == .alwaysVisible)
    #expect(migrated.snapEdgeActivationDistance == 5)
    #expect(migrated.snapCornerActivationSize == 64)
    #expect(try ConfigurationStore.decode(JSONEncoder().encode(migrated)) == migrated)

    // Old persisted custom configuration with all newly introduced keys absent.
    var custom = BetterTileConfiguration()
    custom.shortcuts = oldActions.reversed().map { ShortcutBinding(action: $0, shortcut: nil) }
    custom.shortcuts[0].shortcut = .init(keyCode: 11, modifiers: [.control, .command], keyLabel: "B")
    custom.menuBarActions = [.restore, .leftHalf]
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(custom)) as? [String: Any])
    for key in ["tabbedStripPresentation", "snapEdgeActivationDistance", "snapCornerActivationSize"] { object.removeValue(forKey: key) }
    let restored = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: object))
    #expect(restored == custom)
    #expect(try ConfigurationStore.decode(JSONEncoder().encode(restored)) == custom)
}
