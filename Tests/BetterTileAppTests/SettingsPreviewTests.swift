import AppKit
import SwiftUI
import Testing
@testable import BetterTileApp

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_NATIVE_GLASS_PREVIEW_DIR"] != nil,
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
    panel.orderFrontRegardless()
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
            try await Task.sleep(for: .milliseconds(250))
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"] != nil,
               "Requires an explicit settings preview output directory."))
@MainActor func windowLayoutSettingsPreview() throws {
    let directory = try #require(ProcessInfo.processInfo.environment["BETTERTILE_TAB_PREVIEW_DIR"])
    _ = NSApplication.shared
    let model = makeModel(system: FakeAppWindowSystem())
    defer { model.shutdown() }
    for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let view = NSHostingView(rootView: WindowLayoutSettings(model: model))
        let panel = NSPanel(contentRect: NSRect(x: 12000, y: 0, width: 750, height: 1300),
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
