import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .settingsUI) struct LayoutWheelSettingsPageTests {
    @Test func editingPreservesOtherContentAndNeverMovesWindows() {
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var wheel = model.configuration.layoutWheel
        let custom = wheel.innerSlots
        wheel.style = .grouped
        wheel.levelCount = .two
        LayoutWheelEditorSelection.slot(.init(ring: .inner, sector: .top)).assign(.repairBento, in: &wheel)
        var editing = LayoutWheelEditorSelection.group(.right)
        editing.assign(.windowAction(.previousDisplay), in: &wheel)
        editing.addChild(in: &wheel)
        editing.assign(.setMode(.manual), in: &wheel)
        editing.moveChild(by: -1, in: &wheel)
        #expect(editing == .child(.right, 0))
        #expect(wheel.group(at: .right).options == [.setMode(.manual), .windowAction(.previousDisplay)])
        editing.assign(nil, in: &wheel)
        #expect(wheel.group(at: .right).options.count == 2)
        editing.removeChild(in: &wheel)
        #expect(wheel.group(at: .right).options == [.windowAction(.previousDisplay)])
        #expect(wheel.innerSlots == custom)
        #expect(wheel.groupedInnerSlots[0] == .repairBento)
        #expect(wheel.group(at: .top) == .defaults(at: .top))
        model.updateConfiguration { $0.layoutWheel = wheel }
        #expect(system.frameWriteCounts.isEmpty)
    }

    @Test func childLimitAndBoundaryMovesKeepSelectionValid() {
        var wheel = LayoutWheelConfiguration(style: .grouped)
        var editing = LayoutWheelEditorSelection.group(.left)
        editing.addChild(in: &wheel)
        #expect(editing == .group(.left))
        #expect(wheel.group(at: .left).options.count == 6)
        editing = .child(.left, 0)
        let original = wheel
        editing.moveChild(by: -1, in: &wheel)
        #expect(wheel == original)
        for _ in 0..<6 { editing.removeChild(in: &wheel) }
        #expect(wheel.group(at: .left).options.isEmpty)
        #expect(editing == .group(.left))
        editing.removeChild(in: &wheel)
        editing.addChild(in: &wheel)
        #expect(editing == .child(.left, 0))
        #expect(wheel.group(at: .left).options == [nil])
    }

    @Test func pickerIncludesEveryCommandAndSearchesNames() {
        #expect(LayoutWheelCommandPicker.commands.contains(nil))
        for action in WindowAction.allCases {
            #expect(LayoutWheelCommandPicker.commands.contains(.windowAction(action)))
        }
        for mode in LayoutMode.allCases { #expect(LayoutWheelCommandPicker.commands.contains(.setMode(mode))) }
        for preset in TabbedPreset.allCases { #expect(LayoutWheelCommandPicker.commands.contains(.chooseLayout(preset))) }
        #expect(LayoutWheelCommandPicker.matches("repair") == [.repairBento])
        #expect(LayoutWheelCommandPicker.matches("no matching command").isEmpty)
    }

    @Test func oneFanFitsItsContentAtEverySectorAndLevel() {
        for levels in LayoutWheelLevelCount.allCases {
            let wheel = LayoutWheelConfiguration(style: .grouped, levelCount: levels)
            for sector in LayoutWheelSector.allCases {
                let one = LayoutWheelEditorDiagram(wheel: wheel, currentMode: .manual,
                    selection: .group(sector), allFans: false, expanded: [sector],
                    select: { _ in }, toggleFan: { _ in })
                let all = LayoutWheelEditorDiagram(wheel: wheel, currentMode: .manual,
                    selection: .group(sector), allFans: true, expanded: Set(LayoutWheelSector.allCases),
                    select: { _ in }, toggleFan: { _ in })
                #expect(one.contentBounds.height < all.contentBounds.height)
                #expect(all.contentBounds.contains(one.contentBounds))
            }
        }
    }

    @Test func pageRendersBothFanModesWithoutChangingConfiguration() throws {
        let directory = ProcessInfo.processInfo.environment["BT_WHEEL_SETTINGS_SNAPSHOTS"]
        for dark in [false, true] {
            for allFans in [false, true] {
                let system = FakeAppWindowSystem()
                let model = makeModel(system: system)
                defer { model.shutdown() }
                model.updateConfiguration {
                    $0.layoutWheel.style = .grouped
                    $0.overlayAppearance.useLiquidGlass = false
                }
                let before = model.configuration
                let host = try SettingsSnapshotHost(LayoutWheelSettings(model: model, initiallyShowsAllFans: allFans),
                    dark: dark, width: 830, height: 2350, fitHeight: false)
                defer { host.close() }
                let bitmap = try host.render()
                #expect(bitmap.pixelsWide >= 830)
                #expect(model.configuration == before)
                #expect(system.frameWriteCounts.isEmpty)
                if let directory {
                    let folder = URL(filePath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: folder.appending(path: "page-\(dark ? "dark" : "light")-\(allFans ? "all" : "one").png"))
                }
            }
        }
    }

    @Test(arguments: [
        LayoutWheelTriggers(),
        LayoutWheelTriggers(modifiers: LayoutWheelConfiguration.supportedKeyboardModifiers),
        LayoutWheelTriggers(modifiers: [.option, .command]),
        LayoutWheelTriggers(keyboard: .rightControl),
        LayoutWheelTriggers(keyboardEnabled: false, mouse: .optionMiddleClick),
        LayoutWheelTriggers(mouse: .middleClick),
    ])
    func everyTriggerChoiceRendersWithTheModifierButtons(triggers: LayoutWheelTriggers) throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration { $0.layoutWheel.triggers = triggers }
        let before = model.configuration
        for dark in [false, true] {
            let host = try SettingsSnapshotHost(LayoutWheelSettings(model: model), dark: dark, width: 770)
            defer { host.close() }
            _ = try host.render()
            #expect(host.view.fittingSize.width <= 770)
        }
        #expect(model.configuration == before)
        #expect(model.configuration.layoutWheel.triggers == triggers.normalized())
    }
}
