import AppKit
import BetterTileTestSupport
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// These tests never order a real panel. The cue and wireframe factories absorb
/// ordering and frame writes; wheel panels are inspected while still hidden.
@MainActor @Suite(.macOSTestApplication, .serialized) struct OverlayCaptureTests {
    @Test(arguments: [false, true])
    func dragPanelsFollowConfigurationAndLiveChanges(enabled: Bool) throws {
        let controller = DragSnapController(
            coordinator: WindowCoordinator(system: FakeWindowSystem()),
            configuration: .init(showsOverlaysInScreenRecordings: enabled),
            displayTicks: ResizeDisplayLink(), previewPanelFactory: makeHiddenPanel
        )
        let policy = controller.capturePolicy
        let cues = controller.prepareOverlayPanelsForTesting()
        defer { cues.hide() }
        let frame = BTRect(x: 100, y: 100, width: 600, height: 400)
        func showCue() {
            cues.showCue(targetFrame: frame, position: .center, phase: .armed,
                         seam: frame, sourceOriginalFrame: frame,
                         insertion: BTRect(x: 200, y: 100, width: 2, height: 24),
                         mainScreenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        }
        showCue()
        // Snap preview, drop cue, insertion line, landing and swap origin.
        let panels = policy.panelsForTesting
        #expect(panels.count == 5)
        #expect(panels.allSatisfy { $0.sharingType == (enabled ? .readOnly : .none) })
        controller.configuration.showsOverlaysInScreenRecordings = !enabled
        #expect(panels.allSatisfy { $0.sharingType == (enabled ? .none : .readOnly) })
        // Landing panels are released on hide and created again with the new value.
        cues.hide()
        showCue()
        #expect(policy.panelsForTesting.allSatisfy { $0.sharingType == (enabled ? .none : .readOnly) })
    }

    @Test(arguments: [false, true])
    func tabbedGalleryWireframesFollowSettingAndRecreation(enabled: Bool) throws {
        var panels: [NSPanel] = []
        let overlay = TabbedOverlayController(panelFactory: {
            let panel = makeHiddenPanel()
            panels.append(panel)
            return panel
        }, addGlobalKeyMonitor: { _ in nil }, addLocalKeyMonitor: { _ in nil }, removeMonitor: { _ in })
        defer { overlay.hide() }
        overlay.showsOverlaysInScreenRecordings = enabled
        overlay.refresh(state: TabbedLayoutState(preset: .single),
                        bounds: BTRect(x: 100, y: 100, width: 1000, height: 800), windows: [])
        overlay.previewLayoutGallery(.columns, grouping: .keepTabGroups)
        let wireframes = panels.filter { $0.contentView is PlacementWireframeView }
        #expect(wireframes.count == 2)
        #expect(wireframes.allSatisfy { $0.sharingType == (enabled ? .readOnly : .none) })
        overlay.showsOverlaysInScreenRecordings = !enabled
        #expect(wireframes.allSatisfy { $0.sharingType == (enabled ? .none : .readOnly) })
        overlay.previewLayoutGallery(nil, grouping: .keepTabGroups)
        overlay.previewLayoutGallery(.rows, grouping: .keepTabGroups)
        let recreated = panels.filter { $0.contentView is PlacementWireframeView && !wireframes.contains($0) }
        #expect(recreated.count == 2)
        #expect(recreated.allSatisfy { $0.sharingType == (enabled ? .none : .readOnly) })
        #expect(panels.filter { !($0.contentView is PlacementWireframeView) }.allSatisfy { $0.sharingType == .readOnly })
    }

    @Test(arguments: [false, true])
    func wireframesFollowLiveChangesAndRecreation(enabled: Bool) throws {
        let policy = OverlayCapturePolicy(showsInRecordings: enabled)
        let wireframes = PlacementWireframeController(capturePolicy: policy, reduceMotion: { true },
                                                     panelFactory: makeHiddenPanel)
        defer { wireframes.hide() }
        let placement = Placement(windowID: WindowID(rawValue: "capture"),
                                  frame: BTRect(x: 100, y: 100, width: 600, height: 400))
        wireframes.show([placement])
        let panel = try #require(policy.panelsForTesting.first)
        #expect(panel.sharingType == (enabled ? .readOnly : .none))
        policy.showsInRecordings = !enabled
        #expect(panel.sharingType == (enabled ? .none : .readOnly))
        wireframes.hide()
        wireframes.show([placement])
        #expect(policy.panelsForTesting.count == 2) // `panel` retains the retired instance.
        #expect(policy.panelsForTesting.allSatisfy { $0.sharingType == (enabled ? .none : .readOnly) })
    }

    @Test(arguments: [false, true])
    func fallbackWheelFollowsControllerConfiguration(enabled: Bool) throws {
        let policy = OverlayCapturePolicy()
        let presenter = LayoutWheelPanelPresenter(capturePolicy: policy)
        let controller = LayoutWheelController(configuration: .init(showsOverlaysInScreenRecordings: enabled),
                                               presenter: presenter)
        let panel = try #require(policy.panelsForTesting.first)
        #expect(panel.sharingType == (enabled ? .readOnly : .none))
        controller.configuration.showsOverlaysInScreenRecordings = !enabled
        #expect(panel.sharingType == (enabled ? .none : .readOnly))
        #expect(!panel.isVisible)
    }

    @Test(arguments: [false, true])
    func liquidWheelAndFutureFallbackFollowControllerConfiguration(enabled: Bool) throws {
        let renderer = LayoutWheelLiquidPresenter(clock: WheelTestClock())
        let adapter = LayoutWheelLiquidAdapter(renderer: renderer)
        let controller = LayoutWheelController(configuration: .init(showsOverlaysInScreenRecordings: enabled),
                                               presenter: adapter)
        let policy = renderer.capturePolicy
        #expect(renderer.panelForTesting.sharingType == (enabled ? .readOnly : .none))
        // A failed preparation builds a fallback without opening either panel.
        adapter.prepareHandler = { _ in false }
        adapter.prepareToOpen(configuration: .init(), appearance: .init())
        #expect(policy.panelsForTesting.count == 2)
        #expect(policy.panelsForTesting.allSatisfy { $0.sharingType == (enabled ? .readOnly : .none) })
        controller.configuration.showsOverlaysInScreenRecordings = !enabled
        #expect(policy.panelsForTesting.allSatisfy { $0.sharingType == (enabled ? .none : .readOnly) })
        let previousPanels = Set(policy.panelsForTesting.map(ObjectIdentifier.init))
        adapter.discardPreparation()
        adapter.prepareToOpen(configuration: .init(), appearance: .init())
        #expect(!Set(policy.panelsForTesting.map(ObjectIdentifier.init)).subtracting(previousPanels).isEmpty)
        #expect(policy.panelsForTesting.allSatisfy { $0.sharingType == (enabled ? .none : .readOnly) && !$0.isVisible })
    }

    @Test func prototypeCaptureOverrideUsesTheSamePolicy() {
        let renderer = LayoutWheelLiquidPresenter(capturable: true)
        #expect(renderer.panelForTesting.sharingType == .readOnly)
    }

    @Test func policyDoesNotRetainDismissedPanels() {
        let policy = OverlayCapturePolicy()
        weak var released: NSPanel?
        autoreleasepool {
            let panel = makeHiddenPanel()
            released = panel
            policy.apply(to: panel)
        }
        #expect(released == nil)
        policy.showsInRecordings = true
        #expect(policy.panelsForTesting.isEmpty)
    }
}

@MainActor private func makeHiddenPanel() -> NSPanel {
    CaptureTestPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
}

@MainActor private final class CaptureTestPanel: NSPanel {
    override func orderFrontRegardless() {}
    override func orderOut(_ sender: Any?) {}
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {}
}
