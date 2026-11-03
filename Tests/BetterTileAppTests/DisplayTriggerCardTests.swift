import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

/// Hosts the display set card at a fixed width. With `BT_SNAPSHOT_DIR` set, each case also writes a PNG there.
@Suite(.appTestApplication) @MainActor struct DisplayTriggerCardTests {
    enum Scene: String, CaseIterable, CustomTestStringConvertible {
        case noTrigger = "no-trigger", matching, nonMatching = "non-matching", corrupt, uncertain, missingLayout = "missing-layout"
        /// Switches on, with a Last run row: applied with an issue, cancelled by input, and offered after an uncertain match.
        case autoApplied = "auto-applied", autoCancelled = "auto-cancelled", autoOffered = "auto-offered"
        var isAutomatic: Bool { [.autoApplied, .autoCancelled, .autoOffered].contains(self) }
        var testDescription: String { rawValue }
    }

    private static func fingerprint(_ uuid: String, name: String, model: UInt32, serial: UInt32 = 0, builtIn: Bool,
                                    frame: BTRect) -> DisplayFingerprint {
        .init(uuid: uuid, vendor: 1552, model: model, serial: serial, builtIn: builtIn, name: name, frame: frame)
    }
    static let studio = fingerprint("37D8", name: "Studio Display", model: 41010, serial: 11, builtIn: false,
                                    frame: BTRect(x: 0, y: 0, width: 2560, height: 1440))
    static let macbook = fingerprint("macbook-builtin", name: "MacBook Pro", model: 41022, builtIn: true,
                                     frame: BTRect(x: -1512, y: 438, width: 1512, height: 982))
    static let leftUltra = fingerprint("left-ultra", name: "LG UltraFine", model: 3, builtIn: false, frame: BTRect(x: 0, y: 0, width: 2560, height: 1440))
    static let rightUltra = fingerprint("right-ultra", name: "LG UltraFine", model: 3, builtIn: false, frame: BTRect(x: 2560, y: 0, width: 2560, height: 1440))

    private struct Host {
        var view: NSHostingView<AnyView>
        var window: NSWindow
        var editor: SavedLayoutEditor
        var store: DisplayTriggerStore
        var directory: URL
        var model: BetterTileModel?
    }

    private func makeHost(_ scene: Scene, dark: Bool, width: Double = 640) throws -> Host {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "DisplayTriggerCard-" + UUID().uuidString)
        let editor = SavedLayoutEditor(files: SavedLayoutFiles(directory: directory.appending(path: "Saved Layouts")))
        editor.newLayout()
        #expect(editor.edit { $0 = SavedLayoutDocument(name: "Main + 2 · Studio Display", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.62, 0.38], children: [.slot("a"), .slot("b")]),
            slots: [.init(id: "a", bundleID: "com.apple.dt.Xcode"), .init(id: "b", bundleID: "com.apple.Safari")], paneGap: 6) })
        #expect(editor.save(as: "Main + 2 · Studio Display"))
        let file = try #require(editor.url).lastPathComponent
        let url = directory.appending(path: "Display Triggers.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let set = scene == .uncertain || scene == .autoOffered ? [Self.leftUltra, Self.rightUltra] : [Self.macbook, Self.studio]
        if scene == .corrupt { try Data("{ \"version\": 1, \"triggers\": [".utf8).write(to: url) }
        else if scene != .noTrigger {
            let store = DisplayTriggerStore(url: url)
            #expect(store.bind(.init(layoutFile: scene == .missingLayout ? "gone.json" : file, enabled: scene == .matching || scene.isAutomatic,
                                     displays: set, target: set.count - 1)))
            if scene == .missingLayout { #expect(store.bind(.init(layoutFile: file, displays: set, target: 0))) }
        }
        let store = DisplayTriggerStore(url: url)
        if scene == .autoApplied { #expect(store.update(file) { $0.alsoAfterWake = true }) }
        let connected: [DisplayFingerprint] = switch scene {
        case .matching, .corrupt, .missingLayout, .autoApplied, .autoCancelled: [Self.studio, Self.macbook]
        case .noTrigger: [Self.macbook, Self.studio]
        case .nonMatching: [Self.studio]
        case .uncertain, .autoOffered: [Self.rightUltra, Self.leftUltra].map { var d = $0; d.uuid += "-new"; return d }
        }
        let live = connected.enumerated().map { LiveDisplay(id: DisplayID(rawValue: String($0.offset + 1)), fingerprint: $0.element) }
        var model: BetterTileModel?
        if scene.isAutomatic {
            let value = makeOffscreenModel(store: .init(fileURL: directory.appending(path: "configuration.json")),
                                        system: FakeAppWindowSystem(), startRuntime: false)
            value.hasAccessibilityPermission = true
            let result: SavedLayoutApplyResult = switch scene {
            case .autoApplied: .init(placed: 2, unplaced: 1, issues: [.init(.notRunning, "Safari is not running. Skipped.")])
            case .autoCancelled: .init(unplaced: 2, issues: [.init(.stopped, "Not applied. You were moving windows.")])
            default: .init(unplaced: 2, issues: [.init(.other, "These displays look like the saved set, but BetterTile can’t tell them apart. Not applied.")])
            }
            value.displayTriggerRuntime?.runs[file] = .init(layoutName: "Main + 2 · Studio Display", offersUndo: false,
                date: Date(timeIntervalSince1970: 1_790_000_000), displayID: live.last!.id, result: result,
                declared: scene == .autoCancelled ? .cancelled : scene == .autoOffered ? .offered : nil)
            model = value
        }
        var readDisplays = false
        let content = DisplayTriggerCard(editor: editor, store: store, model: model, readDisplays: {
            readDisplays = true
            return live
        })
            .padding(16).frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .active)
        let view = NSHostingView(rootView: AnyView(content))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = appearance
        view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let window = OffscreenTestWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = view
        try settleSavedLayoutSnapshot(view, until: { readDisplays })
        window.setContentSize(NSSize(width: width, height: max(120, view.fittingSize.height)))
        view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        try settleSavedLayoutSnapshot(view, until: { readDisplays })
        return Host(view: view, window: window, editor: editor, store: store, directory: directory, model: model)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(UInt32(color.redComponent * 63) << 12 | UInt32(color.greenComponent * 63) << 6 | UInt32(color.blueComponent * 63))
            }
        }
        return seen.count
    }

    struct Variant: CustomTestStringConvertible {
        var dark: Bool, width: Double
        var testDescription: String { "\(dark ? "dark" : "light") \(Int(width))" }
    }
    nonisolated static let variants: [Variant] = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] == nil
        ? [Variant(dark: false, width: 640)]
        : [false, true].flatMap { dark in [640.0, 440.0].map { Variant(dark: dark, width: $0) } }

    @Test(arguments: Scene.allCases, variants)
    func rendersEveryState(scene: Scene, variant: Variant) throws {
        let host = try makeHost(scene, dark: variant.dark, width: variant.width)
        defer { host.window.close(); try? FileManager.default.removeItem(at: host.directory) }
        let bitmap = try render(host.view)
        #expect(bitmap.pixelsWide >= Int(variant.width))
        #expect(host.view.fittingSize.height > 80)
        #expect(distinctColors(bitmap) > 8)
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "display-card-\(scene.rawValue)-\(variant.dark ? "dark" : "light")-\(Int(variant.width)).png"
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
        }
    }

    @Test func aCorruptFileKeepsItsBytesWhileTheCardShowsIt() throws {
        let host = try makeHost(.corrupt, dark: false)
        defer { host.window.close(); try? FileManager.default.removeItem(at: host.directory) }
        #expect(host.store.loadError != nil)
        #expect(String(decoding: try Data(contentsOf: host.store.url), as: UTF8.self).hasPrefix("{ \"version\""))
    }

    @Test func identicalDisplayNamesGetPositions() {
        #expect(displayTriggerNames([Self.rightUltra, Self.leftUltra]) == ["LG UltraFine (right)", "LG UltraFine (left)"])
        #expect(displayTriggerNames([Self.studio, Self.macbook]) == ["Studio Display", "MacBook Pro"])
    }

    @Test func bindingTheCurrentDisplaysStartsWithBothSwitchesOff() throws {
        let host = try makeHost(.noTrigger, dark: false)
        defer { host.window.close(); try? FileManager.default.removeItem(at: host.directory) }
        let file = try #require(host.editor.url).lastPathComponent
        #expect(host.store.bindCurrent(layoutFile: file, displays: [Self.macbook, Self.studio], target: 1) == .bound)
        let trigger = try #require(host.store.trigger(for: file))
        #expect(!trigger.enabled && !trigger.alsoAfterWake && trigger.target == 1)
    }

    @Test func aSecondLayoutOnTheSameDisplayAsksBeforeReplacing() throws {
        let host = try makeHost(.noTrigger, dark: false)
        defer { host.window.close(); try? FileManager.default.removeItem(at: host.directory) }
        let set = [Self.macbook, Self.studio]
        #expect(host.store.bindCurrent(layoutFile: "one.json", displays: set, target: 1) == .bound)
        guard case let .needsReplacement(trigger, other) = host.store.bindCurrent(layoutFile: "two.json", displays: set, target: 1) else {
            Issue.record("expected a replacement request"); return
        }
        #expect(other == "one.json")
        #expect(host.store.trigger(for: "two.json") == nil)
        // The other display of the set is free.
        #expect(host.store.bindCurrent(layoutFile: "two.json", displays: set, target: 0) == .bound)
        #expect(host.store.bind(trigger, replacing: other))
        #expect(host.store.trigger(for: "one.json") == nil)
    }

    @Test func rebindingKeepsTheSwitches() throws {
        let host = try makeHost(.matching, dark: false)
        defer { host.window.close(); try? FileManager.default.removeItem(at: host.directory) }
        let file = try #require(host.editor.url).lastPathComponent
        #expect(host.store.update(file) { $0.alsoAfterWake = true })
        #expect(host.store.bindCurrent(layoutFile: file, displays: [Self.studio], target: 0) == .bound)
        let trigger = try #require(host.store.trigger(for: file))
        #expect(trigger.enabled && trigger.alsoAfterWake && trigger.displays == [Self.studio])
    }
}
