import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor private final class WeakResource<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor
struct ResourceLifecycleTests {

    @Test func settingsPickerReleasesControllersAndContentAfter100Presentations() async {
        _ = NSApplication.shared
        let parent = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 980, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        var controllers: [WeakResource<SettingsPickerController>] = []
        var contents: [WeakResource<NSView>] = []
        for _ in 0..<100 {
            autoreleasepool {
                let content = NSView()
                let controller = SettingsPickerController(content: content, size: NSSize(width: 430, height: 480),
                                                          appearance: .init(), onDismiss: {})
                controllers.append(WeakResource(controller))
                contents.append(WeakResource(content))
                controller.present(over: parent)
                controller.dismiss()
            }
        }
        await Task.yield()
        #expect(controllers.allSatisfy { $0.value == nil })
        #expect(contents.allSatisfy { $0.value == nil })
        #expect(parent.childWindows?.isEmpty != false)
        #expect(parent.contentView?.subviews.isEmpty == true)
    }
}
