import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor @Suite(.appTestApplication, .serialized) struct WindowActionGlyphSiteTests {
    private let actions: [WindowAction] = [.leftHalf, .topLeftQuarter, .leftThird, .leftTwoThirds, .topLeftSixth]

    @Test func everyActionSurfaceUsesTheSharedGlyphEntryPoints() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let routes = [
            "Sources/BetterTileApp/BetterTileApp.swift": ["WindowActionGlyph(action: action)", "LayoutWheelActionGlyph(action: action"],
            "Sources/BetterTileApp/LayoutWheelSettings.swift": ["LayoutWheelCommandIcon(command:"],
            "Sources/BetterTileApp/LayoutWheelEditor.swift": ["LayoutWheelActionGlyph(action: action"],
            "Sources/BetterTileApp/WindowLayoutSettings.swift": ["WindowActionGlyph.image(for: action)"],
            "Sources/BetterTileApp/ShortcutsSettings.swift": ["WindowActionGlyph(action: action)"],
            "Sources/BetterTileApp/SnapZoneSettings.swift": ["WindowActionGlyph.image(for: action)", "WindowActionGlyph(action: assignedAction)"],
            "Sources/BetterTileApp/MenuBarSettings.swift": ["WindowActionGlyph(action: action)"],
            "Sources/BetterTileMacOS/LayoutWheelGlassView.swift": ["LayoutWheelIcon(slot: slot"],
        ]
        for (file, entryPoints) in routes {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for entryPoint in entryPoints { #expect(source.contains(entryPoint), "\(file): \(entryPoint)") }
        }
        // Menu and wheel editor paths must render each target.
        var menuImages = Set<Data>(), editorImages = Set<Data>()
        for action in WindowAction.allCases where WindowActionPartitionGlyph.actions[action] != nil {
            let menu = ImageRenderer(content: WindowActionGlyph.image(for: action).frame(width: 30, height: 26))
            let editor = ImageRenderer(content: LayoutWheelCommandIcon(command: .windowAction(action)).frame(width: 30, height: 26))
            menuImages.insert(try #require(menu.cgImage?.dataProvider?.data) as Data)
            editorImages.insert(try #require(editor.cgImage?.dataProvider?.data) as Data)
        }
        #expect(menuImages.count == 11)
        #expect(editorImages.count == 11)
    }

    @Test func renderMenuProof() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_ACTION_PROOF_DIR"] else { return }
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for scale: CGFloat in [1, 2] {
                let menu = HStack(spacing: 8) {
                    ForEach(actions) { action in
                        MenuPanelActionButton(action: action, shortcut: nil) {}
                            .frame(width: 156)
                    }
                }.padding(12)
                try write(menu, name: "menu-tiles-\(Int(scale))x-\(theme)", dark: dark, scale: scale, directory: directory)
            }
        }
    }

    private func write<V: View>(_ view: V, name: String, dark: Bool, scale: CGFloat, directory: String) throws {
        let renderer = ImageRenderer(content: view.background(Color(white: dark ? 0.12 : 0.97))
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.displayScale, scale))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: URL(filePath: directory).appending(path: name + ".png"))
    }
}
