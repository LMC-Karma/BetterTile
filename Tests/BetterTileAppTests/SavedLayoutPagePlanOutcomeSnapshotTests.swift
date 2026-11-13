import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor private final class PlanOutcomePreviewLauncher: PaneApplicationLaunching {
    var calls = 0
    func runningApplicationBundleIdentifiers() -> Set<String> { ["com.apple.Safari", "com.apple.Terminal", "com.apple.Notes", "com.apple.TextEdit"] }
    func runningInstances(of application: ApplicationChoice) -> [PaneApplicationInstance] {
        runningApplicationBundleIdentifiers().contains(application.id) ? [.init(processIdentifier: 42, launchDate: nil)] : []
    }
    func isAlive(_ instance: PaneApplicationInstance, of application: ApplicationChoice) -> Bool {
        runningInstances(of: application).contains { $0.processIdentifier == instance.processIdentifier }
    }
    func launch(_ application: ApplicationChoice) async throws -> PaneApplicationInstance { calls += 1; throw CancellationError() }
    func reopen(_ application: ApplicationChoice, instance: PaneApplicationInstance, activating: Bool, timeout: TimeInterval) async throws { calls += 1; throw CancellationError() }
}

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutPagePlanOutcomeSnapshotTests {
    enum Scene: String, CaseIterable { case plan, portrait, ultrawide, manual, disconnected, captureName, single }
    @Test(arguments: Scene.allCases, [false, true])
    func targetShapeAndOutcomeLines(_ scene: Scene, dark: Bool) async throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let launcher = PlanOutcomePreviewLauncher()
        let applier = try #require(f.model.savedLayoutApplier)

        let installed = SavedLayoutPageSnapshotTests.installed
        let catalog = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        applier.application = { catalog[$0] }
        let width = scene == .portrait ? 900.0 : scene == .ultrawide ? 2560.0 : 1600.0
        let height = scene == .portrait ? 1500.0 : scene == .ultrawide ? 1080.0 : 1000.0
        f.live[1].fingerprint.frame = .init(x: 1000, y: 0, width: width, height: height + 30)
        f.sync()
        let area = BTRect(x: 1000, y: 30, width: width, height: height)
        f.system.availableDisplays[1].visibleFrame = area
        let bundles = ["com.apple.Safari", "com.apple.Terminal", "com.apple.Notes", "com.apple.mail", "com.apple.TextEdit", "org.example.Missing"]
        let slots = bundles.enumerated().map { SavedLayoutSlot(id: "s\($0.offset)", bundleID: $0.element) }
        var document = SavedLayoutDocument(name: "Coding", mode: .bento,
            layout: .split(axis: .vertical, ratios: [1/3, 1/3, 1/3], children: (0..<3).map { index in
                .split(axis: .horizontal, ratios: [0.5, 0.5], children: [.slot("s\(index * 2)"), .slot("s\(index * 2 + 1)")])
            }), slots: slots)
        if scene == .manual {
            document = .init(name: "Manual + float", mode: .manual, slots: [slots[0], slots[2]],
                windows: [.init(slot: "s0", rect: .init(x: 0.05, y: 0.1, width: 0.6, height: 0.8))],
                floats: [.init(slot: "s2", rect: .init(x: 0.65, y: 0.1, width: 0.3, height: 0.35))])
        }
        if scene == .single { document = .init(name: "Safari", mode: .bento, layout: .slot("s0"), slots: [slots[0]]) }
        if scene == .captureName {
            document.name = SavedLayoutQuickCapture.name(for: document, existingNames: [], appNames: catalog.mapValues(\.name))
        }
        f.editor.edit { $0 = document }; #expect(f.editor.save(as: document.name)); f.editor.message = nil
        func window(_ id: String, _ app: String, display: DisplayID, x: Double) -> WindowSnapshot {
            .init(id: .init(rawValue: id), processIdentifier: 42, bundleIdentifier: app,
                frame: .init(x: x, y: 100, width: 250, height: 240), displayID: display)
        }
        f.system.windows = [window("local", bundles[0], display: f.live[1].id, x: 1100),
            window("terminal-a", bundles[1], display: f.live[1].id, x: 1300),
            window("terminal-b", bundles[1], display: f.live[1].id, x: 1500),
            window("foreign", bundles[2], display: f.live[0].id, x: 100),
            window("hidden", bundles[4], display: f.live[1].id, x: 1200)]
        for item in f.system.windows { f.system.desktopObservation?.windowMembership[item.id] = [item.displayID == f.live[0].id ? .init(rawValue: 1) : .init(rawValue: 2)] }
        f.system.desktopObservation?.windowMembership[.init(rawValue: "hidden")] = [.init(rawValue: 99)]
        let snapshot = applier.snapshot
        applier.snapshot = { var state = try snapshot(); state.knownWindows = f.system.windows; return state }
        let page = SavedLayoutSettings(editor: f.editor, model: f.model,
            paletteSource: .init(installed: { installed }, running: { [] }, recent: RecentApplications(defaults: MemoryDefaults())),
            suppliedSession: f.session, readTargetDisplays: { f.live })
        page.refreshTarget(); page.pickDisplay(f.live[1].id)
        if scene == .disconnected {
            f.live.remove(at: 1)
            f.system.availableDisplays.remove(at: 1)
            page.refreshTarget()
        }
        let defaults = MemoryDefaults(); defaults.set(false, forKey: "savedLayoutsBindingsExpanded")
        let size = NSSize(width: 860, height: 1180)
        let host = NSHostingView(rootView: page.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(defaults))
        let windowHost = OffscreenTestWindow(contentRect: .init(origin: .init(x: 12000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        windowHost.isReleasedWhenClosed = false
        windowHost.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = windowHost.appearance; windowHost.contentView = host
        defer { windowHost.close() }
        try await waitForSavedLayoutSnapshot(in: host)
        #expect(!windowHost.isVisible)
        #expect(f.system.frameWriteCounts.isEmpty && launcher.calls == 0)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(filePath: directory).appending(path: "a2-\(scene.rawValue)-\(dark ? "dark" : "light").png"))
        }
    }
}


extension SavedLayoutPagePlanOutcomeSnapshotTests {
    @Test(arguments: [false, true]) func fullPageWithAppGroups(dark: Bool) async throws {
        let f = SavedLayoutDisplayPickerFixture(); defer { f.close() }
        let store = f.model.appGroupsStore
        await store.load()
        try store.save(.init(groups: [
            .init(name: "Browser", apps: [.init(name: "Safari", bundleID: "com.apple.Safari")]),
            .init(name: "Coding", apps: [.init(name: "Xcode", bundleID: "com.apple.dt.Xcode")])]))
        #expect(f.editor.edit { $0.slots[0].prefer = [.group("Browser")] })
        #expect(f.editor.save())
        let applier = try #require(f.model.savedLayoutApplier)
        let installed = SavedLayoutPageSnapshotTests.installed
        applier.application = { id in installed.first { $0.id == id } }
        let page = SavedLayoutSettings(editor: f.editor, model: f.model,
            paletteSource: .init(installed: { installed }, running: { [] }, recent: RecentApplications(defaults: MemoryDefaults())),
            suppliedSession: f.session, readTargetDisplays: { f.live })
        page.initializePage(); page.refreshTarget()
        #expect(page.groupsIntegration.section?.store === store)
        let size = NSSize(width: 860, height: 1700)
        let host = NSHostingView(rootView: page.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
            .defaultAppStorage(MemoryDefaults()))
        let window = OffscreenTestWindow(contentRect: .init(origin: .init(x: 12000, y: 0), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance; window.contentView = host
        defer { window.close() }
        try await waitForSavedLayoutSnapshot(in: host)
        #expect(!window.isVisible && f.system.frameWriteCounts.isEmpty)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(filePath: directory).appending(path: "int-full-page-\(dark ? "dark" : "light").png"))
        }
    }
}
