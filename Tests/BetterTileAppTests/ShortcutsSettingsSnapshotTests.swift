import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct ShortcutsSettingsSnapshotTests {
    @Test func rendersShortcutsStatesWithoutMutatingWindows() throws {
        let directory = ProcessInfo.processInfo.environment["BT_P2_SNAPSHOT_DIR"]
        let states = directory == nil ? ["default"] : ["default", "recording", "duplicate", "modified", "off", "all", "search", "no-results"]
        for dark in directory == nil ? [false] : [false, true] {
            for state in states {
                let system = FakeAppWindowSystem()
                let model = makeModel(system: system)
                defer { model.shutdown() }
                var error: (action: WindowAction, message: String)?
                if state == "duplicate" {
                    let shortcut = try #require(model.configuration.shortcuts.first { $0.action == .rightHalf }?.shortcut)
                    let original = model.configuration
                    model.assign(shortcut: shortcut, to: .leftHalf)
                    #expect(model.configuration == original)
                    error = (.leftHalf, try #require(model.statusMessage))
                } else if state == "modified" {
                    model.assign(shortcut: nil, to: .leftHalf)
                } else if state == "off" {
                    model.updateConfiguration { $0.keyboardShortcutsEnabled = false }
                }
                let configuration = model.configuration
                let host = try SettingsSnapshotHost(
                    VStack(spacing: 0) {
                        SettingsPageHeader(destination: .shortcuts)
                            .padding(SettingsSpacing.s6)
                        ShortcutsSettings(model: model, shortcutError: error,
                            expandedGroups: state == "all" ? Set(WindowActionGroup.allCases) : [.halves, .thirds],
                            search: state == "search" ? "left half" : state == "no-results" ? "no-such-action" : "",
                            recordingAction: state == "recording" ? .leftHalf : nil)
                    }, dark: dark, width: 770, height: state == "all" ? 3200 : 900, fitHeight: false)
                defer { host.close() }
                let bitmap = try host.render()
                #expect(bitmap.pixelsWide >= 770)
                #expect(model.configuration == configuration)
                #expect(system.frameWriteCounts.isEmpty)
                try write(bitmap, name: "page-\(state)-\(dark ? "dark" : "light")", directory: directory)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BT_P2_SNAPSHOT_DIR"] != nil,
                   "Writes offscreen Settings PNGs only when requested."))
    func rendersSettingsAtMinimumAndDefaultSizes() throws {
        let directory = ProcessInfo.processInfo.environment["BT_P2_SNAPSHOT_DIR"]
        for dark in [false, true] {
            for size in [CGSize(width: 980, height: 640), CGSize(width: 1060, height: 760)] {
                for destination in [SettingsDestination.shortcuts, .general, .windowLayout] {
                    let system = FakeAppWindowSystem()
                    let model = makeModel(system: system)
                    defer { model.shutdown() }
                    let host = try SettingsSnapshotHost(
                        SettingsTestFactory.makeSettingsView(model: model, openSetup: {}, selection: destination),
                        dark: dark, width: size.width, height: size.height, fitHeight: false)
                    defer { host.close() }
                    try write(host.render(), name: "settings-\(destination.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))", directory: directory)
                    #expect(system.frameWriteCounts.isEmpty)
                }
            }
        }
    }

    private func write(_ bitmap: NSBitmapImageRep, name: String, directory: String?) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
