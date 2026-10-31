import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// Local-only: native popover glass needs the real window-server backdrop.
@Test(.appTestApplication, .enabled(if: OffscreenTestWindows.localWindowTestsEnabled && ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"] != nil,
               "Requires an explicit native glass preview output directory."))
@MainActor func menuGlassPopoverPreviews() async throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"])
    _ = NSApplication.shared
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    let panel = NSPanel(contentRect: NSRect(x: 80, y: 100, width: 960, height: 720),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    let background = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
    background.wantsLayer = true
    let gradient = CAGradientLayer()
    gradient.frame = background.bounds
    gradient.colors = [NSColor.systemBlue.cgColor, NSColor.systemOrange.cgColor]
    gradient.startPoint = .zero
    gradient.endPoint = CGPoint(x: 1, y: 1)
    background.layer?.addSublayer(gradient)
    panel.contentView = background
    panel.orderFrontForTesting()
    defer { panel.close() }
    let popover = NSPopover()
    popover.animates = false
    popover.contentViewController = NSHostingController(rootView: MenuPanelContent(model: model) {
        Text("Synthetic window actions").frame(maxWidth: .infinity, minHeight: 100)
    } notice: { EmptyView() })
    defer { popover.close() }
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        popover.appearance = NSAppearance(named: appearanceName)
        if !popover.isShown {
            popover.show(relativeTo: NSRect(x: 460, y: 680, width: 40, height: 20), of: background, preferredEdge: .minY)
        }
        for transparency in [0.0, 1.0] {
            model.updateConfiguration { $0.overlayAppearance.transparency = transparency }
            try await Task.sleep(for: .milliseconds(250)) // real-time: the window server must composite the glass before screencapture reads it
            let window = try #require(popover.contentViewController?.view.window)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                                 "\(directory)/menu-\(name)-\(Int(transparency)).png"]
            try capture.run()
            capture.waitUntilExit()
            #expect(capture.terminationStatus == 0)
        }
    }
}

@Test(.appTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] != nil,
               "Requires an explicit settings preview output directory."))
@MainActor func windowLayoutSettingsPreview() throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"])
    _ = NSApplication.shared
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let view = NSHostingView(rootView: WindowLayoutSettings(model: model))
        let panel = OffscreenTestPanel(contentRect: NSRect(x: 12000, y: 0, width: 750, height: 1300),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = appearance
        panel.contentView = view
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("window-layout-\(name).png")
        )
        panel.close()
    }
}

@Test(.appTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_RULE_PREVIEW_DIR"] != nil,
               "Requires an explicit rule settings preview output directory."))
@MainActor func applicationRuleSettingsPreviews() async throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_RULE_PREVIEW_DIR"])
    _ = NSApplication.shared
    for state in ["empty", "populated", "permission", "long-missing"] {
        for (theme, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            let system = FakeAppWindowSystem()
            system.windows[0].bundleIdentifier = "com.apple.Safari"
            system.windows[0].title = "BetterTile documentation"
            let model = makeModel(system: system)
            defer { model.shutdown() }
            if state != "empty" {
                model.configuration.applicationRules.set(.excludeFromBento, for: "com.apple.Safari")
            }
            if state == "long-missing" {
                model.configuration.applicationRules.set(.excludeFromBento, for: "org.example.International-Research-Workspace-Experimental-Edition-2026")
            }
            model.watchdog()
            model.hasAccessibilityPermission = state != "permission"
            let view = NSHostingView(rootView: ApplicationRuleSettings(model: model)
                .font(.system(size: 13)).background(Color(nsColor: .windowBackgroundColor)))
            let panel = OffscreenTestPanel(contentRect: NSRect(x: 12000, y: 0, width: 750, height: 580),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.appearance = appearance
            panel.contentView = view
            view.appearance = appearance
            turnNativeRunLoop(layout: view)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("rules-\(state)-\(theme).png")
            )
            panel.close()
        }
    }
}

/// Inspects only this process's off-screen view. No Accessibility permission or live AX reads.
@MainActor private func renderedRuleSettings(model: BetterTileModel) async throws -> (text: [String], image: CGImage) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: ApplicationRuleSettings(model: model)
        .environment(\.accessibilityEnabled, true)
        .background(Color(nsColor: .windowBackgroundColor)))
    let panel = OffscreenTestPanel(contentRect: NSRect(x: 12000, y: 0, width: 900, height: 800),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = host
    defer { panel.close() }
    func attribute(_ object: NSObject, _ selector: Selector) -> Any? {
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    var seen: Set<ObjectIdentifier> = []
    func text(in element: Any) -> [String] {
        guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        // SwiftUI's accessibility nodes implement the public selectors without
        // declaring conformance to the full NSAccessibilityProtocol.
        var result = [attribute(object, #selector(NSAccessibilityProtocol.accessibilityLabel)) as? String,
                      attribute(object, #selector(NSAccessibilityProtocol.accessibilityValue)) as? String].compactMap { $0 }
        // AppKit's outline rows still expose their children through this public compatibility API.
        let children = attribute(object, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any]
            ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
        for child in children { result += text(in: child) }
        return result
    }
    func switches(_ view: NSView) -> [NSSwitch] {
        ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches)
    }
    // SwiftUI applies its initial list selection, then publishes the selected rule's detail. The callers
    // have one rule: its row has one switch and its detail adds the Enabled switch.
    try await waitForSettingsUI("the selected rule's detail", in: host) { switches(host).count == 2 }
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return (text(in: host), try #require(bitmap.cgImage))
}

@Test(.appTestApplication) @MainActor func appRuleSettingsRendersSaveFailureStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let model = makeOffscreenModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    // The configuration loads normally; a later write fails because its parent is now a file.
    try Data().write(to: directory)
    model.setRule(.ignoreEverywhere, for: "test.save-failure")
    model.flushConfiguration()
    let failure = try #require(model.statusMessage)
    #expect(failure != "App not installed: \(ApplicationRule.ignoreEverywhere.title).")
    let rendered = try await renderedRuleSettings(model: model)
    #expect(rendered.text.contains(failure))
}

@Test(.appTestApplication) @MainActor func appRuleSettingsRendersInvalidIdentifierRowAndDetailWarnings() async throws {
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    model.configuration.applicationRules.set(.ignoreEverywhere, for: " \t ")
    let rendered = try await renderedRuleSettings(model: model)
    let visibleText = try await recognizedRuleSettingsText(in: rendered.image)
    #expect(visibleText.contains("No app identifier"))
    #expect(visibleText.contains("This rule has no app identifier"))
    #expect(visibleText.contains("BetterTile cannot match any window. Choose an app to repair the rule, or remove it."))
}

@Test(.appTestApplication) @MainActor func appRuleSettingsMissingAppHidesIdentifierInRowsHeaderNoticeAndStatus() async throws {
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    let id = "test.missing.application"
    model.setRule(.ignoreEverywhere, for: id)
    model.setRuleEnabled(false, for: id)
    #expect(model.statusMessage?.contains(id) == false)
    let rendered = try await renderedRuleSettings(model: model)
    let visibleText = try await recognizedRuleSettingsText(in: rendered.image)
    #expect(visibleText.contains("App not installed"))
    #expect(!visibleText.contains(id))
    #expect(!rendered.text.contains { $0.contains(id) })
}

@Test(.appTestApplication, .enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_RULE_PREVIEW_DIR"] != nil,
               "Requires an explicit rule settings preview output directory."))
@MainActor func appRuleSettingsInvalidIdentifierWarningVisualCheck() async throws {
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    model.configuration.applicationRules.set(.ignoreEverywhere, for: " \t ")
    let rendered = try await renderedRuleSettings(model: model)
    let visibleText = try await recognizedRuleSettingsText(in: rendered.image)
    #expect(visibleText.contains("BetterTile cannot match any window. Choose an app to repair the rule, or remove it."))
}

/// Checks the drawn warning, including the detail inside its scroll view.
private func recognizedRuleSettingsText(in image: CGImage) async throws -> String {
    try await snapshotRecognizedLines(in: image).joined(separator: " ")
}
