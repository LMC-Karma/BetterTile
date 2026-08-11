import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// The shared fake adapter at the `WindowSystem` seam, reused by every
/// BetterTileMacOS test suite. Failure knobs simulate rejected, ignored,
/// numbered-failing, clamped, and late-settling Accessibility writes.
@MainActor
final class FakeWindowSystem: WindowSystem, TargetedWindowSystem, WindowEventSource {
    var availableDisplays = [DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        isMain: true
    )]
    var windows: [WindowSnapshot]
    var failingWindowID: WindowID?
    var ignoredFrameWriteCounts: [WindowID: Int] = [:]
    var frameWriteCounts: [WindowID: Int] = [:]
    var failedFrameWriteNumbers: [WindowID: Set<Int>] = [:]
    var failingMinimizeWindowID: WindowID?
    var minimizeWriteCounts: [WindowID: Int] = [:]
    var failedMinimizeWriteNumbers: [WindowID: Set<Int>] = [:]
    var focusedWindowID: WindowID?
    var focusedWindowReadFails = false
    var eventHandler: (@MainActor (WindowSystemEvent) -> Void)?
    var targetedSnapshotRequests = 0
    var targetedSnapshotsFail = false
    /// Every `knownCurrentFrame` hint the coordinator supplied, per window, in
    /// call order. `nil` means the coordinator had no fresh reading.
    var recordedKnownCurrentFrames: [WindowID: [BTRect?]] = [:]
    /// Simulates an application that refuses to grow beyond a fixed width.
    var clampWidth: Double?
    /// Simulates an application that applies a geometry change on its own run
    /// loop: the write is accepted, but the new frame is only observable after
    /// this many reads.
    var readsBeforeSettling = 0
    private var pendingFrames: [WindowID: (frame: BTRect, readsRemaining: Int)] = [:]

    private func settlePendingFrames() {
        for (id, pending) in pendingFrames {
            let remaining = pending.readsRemaining - 1
            if remaining <= 0 {
                pendingFrames.removeValue(forKey: id)
                if let index = windows.firstIndex(where: { $0.id == id }) {
                    windows[index].frame = pending.frame
                }
            } else {
                pendingFrames[id] = (pending.frame, remaining)
            }
        }
    }

    init() {
        windows = [WindowSnapshot(
            id: WindowID(rawValue: "focused"), processIdentifier: 42, bundleIdentifier: "com.example.Test",
            frame: BTRect(x: 200, y: 200, width: 600, height: 400), displayID: DisplayID(rawValue: "main")
        )]
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool { true }
    func focusedWindow() throws -> WindowSnapshot? {
        if focusedWindowReadFails { throw WindowSystemError.operationFailed("Simulated focused-window failure") }
        return focusedWindowID.flatMap { id in windows.first(where: { $0.id == id }) } ?? windows.first
    }
    func visibleWindows() throws -> [WindowSnapshot] {
        settlePendingFrames()
        return windows
    }
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        targetedSnapshotRequests += 1
        if targetedSnapshotsFail { throw WindowSystemError.operationFailed("Simulated snapshot failure") }
        settlePendingFrames()
        return windows.filter { ids.contains($0.id) }
    }
    func displays() -> [DisplaySnapshot] { availableDisplays }
    func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?) { eventHandler = handler }
    func startWindowObservation() {}
    func stopWindowObservation() {}
    func emit(_ event: WindowSystemEvent) { eventHandler?(event) }

    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        recordedKnownCurrentFrames[windowID, default: []].append(knownCurrentFrame)
        frameWriteCounts[windowID, default: 0] += 1
        if failingWindowID == windowID { throw WindowSystemError.operationFailed("Simulated Accessibility failure") }
        if failedFrameWriteNumbers[windowID]?.contains(frameWriteCounts[windowID, default: 0]) == true {
            throw WindowSystemError.operationFailed("Simulated numbered Accessibility failure")
        }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { throw WindowSystemError.windowNotFound(windowID) }
        if ignoredFrameWriteCounts[windowID, default: 0] > 0 {
            ignoredFrameWriteCounts[windowID, default: 0] -= 1
            return
        }
        var applied = frame
        if let clampWidth { applied.size.width = min(applied.size.width, clampWidth) }
        if readsBeforeSettling > 0 {
            pendingFrames[windowID] = (applied, readsBeforeSettling)
            return
        }
        windows[index].frame = applied
        windows[index].displayID = availableDisplays.first(where: { $0.visibleFrame.intersection(applied)?.area ?? 0 > applied.area / 2 })?.id ?? windows[index].displayID
    }

    func setMinimized(_ minimized: Bool, for windowID: WindowID) throws {
        minimizeWriteCounts[windowID, default: 0] += 1
        if failingMinimizeWindowID == windowID { throw WindowSystemError.operationFailed("Simulated minimize failure") }
        if failedMinimizeWriteNumbers[windowID]?.contains(minimizeWriteCounts[windowID, default: 0]) == true {
            throw WindowSystemError.operationFailed("Simulated numbered minimize failure")
        }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { throw WindowSystemError.windowNotFound(windowID) }
        windows[index].isMinimized = minimized
    }

    func addSecondWindow() {
        windows.append(WindowSnapshot(
            id: WindowID(rawValue: "second"), processIdentifier: 43, bundleIdentifier: "com.example.Second",
            frame: BTRect(x: 800, y: 200, width: 200, height: 400), displayID: DisplayID(rawValue: "main")
        ))
    }
}
