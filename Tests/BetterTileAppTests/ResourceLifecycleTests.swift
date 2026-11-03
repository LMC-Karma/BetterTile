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
    @Test func failedInventoryDefersPillCleanupUntilReconciliationRecovers() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var controllers: [WeakResource<ResultPillController>] = []
        model.resultPillFactory = {
            let panel = ResourcePillPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: true)
            let controller = ResultPillController(panel: panel)
            controllers.append(WeakResource(controller))
            return controller
        }
        let runtime = try #require(model.displayTriggerRuntime)
        let removed = DisplaySnapshot(id: DisplayID(rawValue: "removed"),
            frame: BTRect(x: 12000, y: 0, width: 1000, height: 800),
            visibleFrame: BTRect(x: 12000, y: 0, width: 1000, height: 800))
        system.availableDisplays.append(removed)
        for display in system.availableDisplays {
            runtime.notice(.init(title: "Apply cancelled", kind: .warning, displayID: display.id, actions: []))
        }
        system.availableDisplays = [system.mainDisplay]
        system.failedVisibleWindowSweeps.insert(system.completeSweepCount + 1)
        model.handleApplicationTopologyChange()
        #expect(controllers.count == 2)
        #expect(controllers.allSatisfy { $0.value != nil })
        model.handleApplicationTopologyChange()
        await Task.yield()
        #expect(controllers[0].value != nil)
        #expect(controllers[1].value == nil)
    }

    @Test func connectedDisplayReusesItsAutomaticResultPill() throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        let panel = ResourcePillPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
        var creations = 0
        model.resultPillFactory = {
            creations += 1
            return ResultPillController(panel: panel)
        }
        let runtime = try #require(model.displayTriggerRuntime)
        for _ in 0..<100 {
            runtime.notice(.init(title: "Apply cancelled", kind: .warning, displayID: system.mainDisplay.id, actions: []))
            model.handleApplicationTopologyChange()
        }
        #expect(creations == 1)
        #expect(panel.presented)
        model.shutdown()
        #expect(!panel.presented)
    }

    @Test func disconnectedDisplaysReleaseAutomaticResultPillsAfter100Connections() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        var controllers: [WeakResource<ResultPillController>] = []
        var panels: [WeakResource<ResourcePillPanel>] = []
        model.resultPillFactory = {
            let panel = ResourcePillPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: true)
            let controller = ResultPillController(panel: panel)
            controllers.append(WeakResource(controller))
            panels.append(WeakResource(panel))
            return controller
        }
        let runtime = try #require(model.displayTriggerRuntime)
        for index in 0..<100 {
            let display = DisplaySnapshot(id: DisplayID(rawValue: "connection-\(index)"),
                frame: BTRect(x: 12000, y: 0, width: 1000, height: 800),
                visibleFrame: BTRect(x: 12000, y: 0, width: 1000, height: 800))
            system.availableDisplays = [system.mainDisplay, display]
            runtime.notice(.init(title: "Apply cancelled", kind: .warning, displayID: display.id, actions: []))
            system.availableDisplays = [system.mainDisplay]
            model.handleApplicationTopologyChange()
        }
        await Task.yield()
        let retained = controllers.filter { $0.value != nil }.count
        let presented = panels.filter { $0.value?.presented == true }.count
        print("PERF automatic pills after 100 disconnected displays: retained=\(retained) presented=\(presented)")
        #expect(retained == 0)
        #expect(presented == 0)
    }

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

    @Test func menuPanelReleasesControllersAfter100Presentations() async {
        _ = NSApplication.shared
        var controllers: [WeakResource<MenuPanelController<Text>>] = []
        for _ in 0..<100 {
            autoreleasepool {
                let controller = MenuPanelController(rootView: Text("Resource lifecycle"), appearance: .init(),
                    presentWindow: { _ in }, reduceMotion: { true }, animate: { _, finish in finish() })
                controllers.append(WeakResource(controller))
                controller.show(relativeTo: NSRect(x: 12500, y: 800, width: 24, height: 24),
                                visibleFrame: NSRect(x: 12000, y: 0, width: 1200, height: 800))
                controller.dismiss()
            }
        }
        await Task.yield()
        #expect(controllers.allSatisfy { $0.value == nil })
    }
}

/// Records presentation without ordering a window on the user's displays.
@MainActor private final class ResourcePillPanel: NSPanel {
    var presented = false
    override func orderFrontRegardless() { presented = true }
    override func orderOut(_ sender: Any?) { presented = false }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) { super.setFrame(frameRect, display: false) }
}
