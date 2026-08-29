import BetterTileCore
import BetterTileMacOS
import Foundation
import Testing
@testable import BetterTileApp

@MainActor
private final class FakeAppWindowSystem: BetterTileWindowSystem {
    let mainDisplay = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        isMain: true
    )
    var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy = .disableAndRestore
    var permission = true
    var availableDisplays: [DisplaySnapshot]
    var windows: [WindowSnapshot]
    var eventHandler: (@MainActor (WindowSystemEvent) -> Void)?

    init() {
        availableDisplays = [mainDisplay]
        windows = [WindowSnapshot(
            id: WindowID(rawValue: "focused"),
            processIdentifier: 42,
            bundleIdentifier: "com.example.Test",
            frame: BTRect(x: 200, y: 200, width: 600, height: 400),
            displayID: mainDisplay.id
        )]
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool { permission }
    func focusedWindow() throws -> WindowSnapshot? { windows.first }
    func visibleWindows() throws -> [WindowSnapshot] { windows }
    func displays() -> [DisplaySnapshot] { availableDisplays }
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        windows.filter { ids.contains($0.id) }
    }
    func cachedVisibleWindows(refreshing ids: Set<WindowID>) throws -> [WindowSnapshot]? {
        windows
    }
    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        windows[index].frame = frame
    }
    func setMinimized(_ minimized: Bool, for windowID: WindowID) throws {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        windows[index].isMinimized = minimized
    }

    func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?) {
        eventHandler = handler
    }
    func startWindowObservation() {}
    func stopWindowObservation() {}
    func refreshApplicationObservers() {}
    func resetCachedWindows() {}
    func nativeDesktopObservation() -> NativeDesktopObservation? { nil }
    func refreshNativeDesktopObservation() -> NativeDesktopObservation? { nil }
    func observeApplicationEnforcedMinimum(
        windowID: WindowID,
        requested: BTRect,
        baseline: BTRect,
        actual: BTRect
    ) -> Bool { false }
    func startDockFootprintMonitoring(onChange: @escaping () -> Void) {}
    func stopDockFootprintMonitoring() {}
    func triggerDockFootprintCheck() {}
    func startDisplayReconfigurationMonitoring(onChange: @escaping @MainActor () -> Void) {}
    func stopDisplayReconfigurationMonitoring() {}
    func updateManagedWindowIDs(_ ids: Set<WindowID>) {}
}

@MainActor
private func makeModel(system: FakeAppWindowSystem) -> BetterTileModel {
    let store = ConfigurationStore(
        fileURL: URL(filePath: "/private/tmp/BetterTileAppTests-\(UUID().uuidString)/configuration.json")
    )
    return BetterTileModel(store: store, system: system, startRuntime: false)
}

@MainActor
private func target(for system: FakeAppWindowSystem) -> LayoutWheelTarget {
    LayoutWheelTarget(
        windowID: system.windows[0].id,
        displayID: system.windows[0].displayID,
        visibleFrame: system.mainDisplay.visibleFrame
    )
}

@Test @MainActor func manualLayoutWheelPreviewIsPureAndMatchesCommit() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let baseline = system.windows[0].frame

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.leftHalf),
        for: captured
    ) else {
        Issue.record("Expected a Manual Layout Wheel preview")
        return
    }

    #expect(system.windows[0].frame == baseline)
    #expect(placements.count == 1)
    model.performLayoutWheel(.windowAction(.leftHalf), for: captured)
    #expect(system.windows[0].frame == placements[0].frame)
}

@Test @MainActor func movingTheCapturedWindowToAnotherDisplayCancelsTheCommand() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let second = DisplaySnapshot(
        id: DisplayID(rawValue: "second"),
        frame: BTRect(x: 1000, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 1000, y: 0, width: 1000, height: 800)
    )
    system.availableDisplays.append(second)
    system.windows[0].displayID = second.id

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .windowAction(.leftHalf),
        for: captured
    ) else {
        Issue.record("Expected the captured-display change to cancel")
        return
    }

    #expect(reason.contains("window or display"))
}

@Test @MainActor func ignoredApplicationFailsBeforeLayoutWheelMutation() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    let captured = target(for: system)
    let baseline = system.windows[0].frame
    model.updateConfiguration {
        $0.applicationRules.set(.ignoreEverywhere, for: "com.example.Test")
    }

    guard case let .unavailable(reason) = model.previewLayoutWheel(
        .windowAction(.maximize),
        for: captured
    ) else {
        Issue.record("Expected the application rule to reject the command")
        return
    }

    #expect(reason == "BetterTile is set to ignore this app.")
    #expect(system.windows[0].frame == baseline)
}

@Test @MainActor func bentoLayoutWheelPreviewDoesNotCommitItsProposal() {
    let system = FakeAppWindowSystem()
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    let captured = target(for: system)
    let baseline = system.windows[0].frame

    guard case let .ready(placements) = model.previewLayoutWheel(
        .windowAction(.rightHalf),
        for: captured
    ) else {
        Issue.record("Expected a Bento Layout Wheel preview")
        return
    }

    #expect(!placements.isEmpty)
    #expect(system.windows[0].frame == baseline)
    model.performLayoutWheel(.windowAction(.rightHalf), for: captured)
    #expect(system.windows[0].frame == placements.first(where: {
        $0.windowID == captured.windowID
    })?.frame)
}
