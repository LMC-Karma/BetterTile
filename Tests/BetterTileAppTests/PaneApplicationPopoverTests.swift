import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor private final class PanePickerAnchorView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private func panePickerDescendants(_ root: NSObject) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func visit(_ object: NSObject) -> [NSObject] {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        let children = (object.responds(to: selector)
            ? object.perform(selector)?.takeUnretainedValue() as? [NSObject] : nil)
            ?? object.accessibilityAttributeValue(.children) as? [NSObject] ?? []
        return [object] + (children + ((object as? NSView)?.subviews ?? [])).flatMap(visit)
    }
    return visit(root)
}


@Test(.appTestApplication) @MainActor func paneApplicationPopoverUsesFittedContentSizeBeforeShowing() {
    _ = NSApplication.shared
    let request = PaneApplicationRequest(paneID: UUID(), paneNumber: 1,
        displayID: DisplayID(rawValue: "owned-popover"), sessionID: DesktopSessionID(rawValue: UUID()),
        spaceID: nil, generation: 0, workArea: BTRect(x: 0, y: 0, width: 1600, height: 900))
    let picker = PaneApplicationPopover(request: request, recentApplications: RecentApplications(defaults: MemoryDefaults()))
    defer { picker.close() }
    #expect(!picker.presenter.isPresented)
    #expect(picker.content.window?.styleMask.contains(.nonactivatingPanel) == true)
    #expect(picker.content.acceptsFirstMouse(for: nil) == true)
    #expect(picker.content.frame.size == picker.content.fittingSize)
    #expect(picker.content.frame.size == NSSize(width: 320, height: 420))
}

/// Local-only: this screen-bounds regression deliberately orders a test-owned
/// panel on each attached screen. Run alone with BETTERTILE_LOCAL_WINDOW_TESTS=1
/// and BETTERTILE_PANE_POPOVER_BOUNDS=1.
@Test(.appTestApplication, .enabled(if: OffscreenTestWindows.localWindowTestsEnabled && ProcessInfo.processInfo.environment["BETTERTILE_PANE_POPOVER_BOUNDS"] == "1"))
@MainActor func paneApplicationPopoverActualWindowStaysOnOwningScreen() async throws {
    _ = NSApplication.shared
    try #require(!NSScreen.screens.isEmpty)
    let application = ApplicationChoice(bundleIdentifier: "test.owned.popover", name: "Owned Bounds Fixture",
                                       url: URL(filePath: "/fixture/Owned.app"))
    for (screenIndex, screen) in NSScreen.screens.enumerated() {
        let visible = screen.visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: visible.minX, y: visible.maxY - 34,
                                               width: visible.width, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let anchor = PanePickerAnchorView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = anchor
        panel.orderFrontForTesting()
        defer { panel.close() }
        for edge in ["right", "left", "top", "bottom"] {
            panel.setFrameOrigin(NSPoint(x: visible.minX, y: edge == "bottom" ? visible.minY : visible.maxY - 34))
            let frameBefore = panel.frame
            let x = edge == "right" ? visible.width - 71 : edge == "left" ? 1 : visible.width / 2 - 14
            let rect = NSRect(x: x, y: 1, width: 28, height: 32)
            // Recreate the presentation after Escape, just as the app model does.
            for opening in 0...1 {
                let request = PaneApplicationRequest(paneID: UUID(), paneNumber: 1,
                    displayID: DisplayID(rawValue: "owned-popover"), sessionID: DesktopSessionID(rawValue: UUID()),
                    spaceID: nil, generation: 0,
                    workArea: BTRect(x: 0, y: 0, width: visible.width, height: visible.height))
                let recent = RecentApplications(defaults: MemoryDefaults())
                let picker = PaneApplicationPopover(request: request, recentApplications: recent)
                let host = NSHostingController(rootView: PaneApplicationPicker(request: request,
                    installedApplications: { [application] }, runningApplications: { [application] },
                    recentApplications: recent)
                    .environment(\.accessibilityEnabled, true))
                picker.content.removeFromSuperview()
                let container = try #require(picker.presenter.panel.contentView)
                host.view.frame = container.bounds
                host.view.autoresizingMask = [.width, .height]
                container.addSubview(host.view)
                var dismissals = 0
                picker.onDismiss = { dismissals += 1 }
                request.onCancel = { picker.close() }
                defer { picker.close() }
                // Check sizing before AppKit has a chance to show or constrain the window.
                #expect(picker.content.frame.size == host.view.fittingSize)
                picker.show(relativeTo: rect, of: anchor)
                for phase in ["catalog"] {
                    try await Task.sleep(for: .milliseconds(150)) // real-time: the opt-in native screen-bounds test waits for SwiftUI catalog layout
                    host.view.layoutSubtreeIfNeeded()
                    let window = try #require(host.view.window)
                    #expect(picker.presenter.isPresented)
                    #expect(window.level.rawValue > NSWindow.Level.floating.rawValue)
                    #expect(!window.hidesOnDeactivate)
                    #expect(window.collectionBehavior == [.transient, .ignoresCycle])
                    #expect(visible.contains(window.frame), "Actual chooser panel frame \(window.frame), visible \(visible)")
                    #expect(panel.frame == frameBefore)
                    #expect(host.view.frame.size == NSSize(width: 320, height: 420))
                    let elements = panePickerDescendants(host.view)
                    let scrollViews = elements.compactMap { $0 as? NSScrollView }.filter {
                        $0.bounds.width > 200 && $0.bounds.height > 100
                    }
                    #expect(!scrollViews.isEmpty, "The catalog/choice viewport must remain usable")
                    for scroll in scrollViews {
                        let frame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                        #expect(visible.contains(frame), "Catalog/choice viewport: \(frame)")
                        print("PANE-VIEWPORT edge=\(edge) phase=\(phase) frame=\(frame)")
                    }
                    if phase == "catalog" {
                        let field = try #require(elements.compactMap { $0 as? NSTextField }.first { $0.isEditable })
                        #expect(window.makeFirstResponder(field))
                    }
                    let labelSelector = #selector(NSAccessibilityProtocol.accessibilityLabel)
                    let controls = ["Browse…"]
                    for label in controls {
                        let element = try #require(elements.first {
                            $0.responds(to: labelSelector)
                                && $0.perform(labelSelector)?.takeUnretainedValue() as? String == label
                        }, "Missing owned control \(label)")
                        let frameSelector = NSSelectorFromString("accessibilityFrame")
                        try #require(element.responds(to: frameSelector))
                        typealias Frame = @convention(c) (NSObject, Selector) -> NSRect
                        let controlFrame = unsafeBitCast(element.method(for: frameSelector), to: Frame.self)(element, frameSelector)
                        #expect(!controlFrame.isEmpty)
                        #expect(visible.contains(controlFrame), "\(label): \(controlFrame)")
                        print("PANE-CONTROL screen=\(screenIndex) edge=\(edge) opening=\(opening) phase=\(phase) label=\(label) frame=\(controlFrame)")
                    }
                    print("PANE-BOUNDS screen=\(screenIndex) edge=\(edge) opening=\(opening) phase=\(phase) visible=\(visible) anchor=\(panel.convertToScreen(anchor.convert(rect, to: nil))) content=\(picker.content.frame.size) actual=\(window.frame)")
                    if let directory = ProcessInfo.processInfo.environment["BETTERTILE_PANE_POPOVER_RENDER_DIR"] {
                        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: URL(filePath: directory).appending(path: "screen-\(screenIndex)-\(edge)-\(opening)-\(phase).png"))
                    }
                }
                let window = try #require(host.view.window)
                let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                window.sendEvent(escape)
                #expect(await waitFor { !picker.presenter.isPresented })
                #expect(dismissals == 1)
                picker.close()
                #expect(dismissals == 1)
            }
        }
    }
}
