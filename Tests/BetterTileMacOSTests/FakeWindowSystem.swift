import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// The shared fake adapter at the `WindowSystem` seam, reused by every
/// BetterTileMacOS test suite. Failure knobs simulate rejected, ignored,
/// numbered-failing, clamped, and late-settling Accessibility writes.
@MainActor
final class FakeWindowSystem: WindowSystem, TargetedWindowSystem, WindowEventSource, TabbedWindowSystem, WindowStackReading, MinimumSizeProbing {
    var availableDisplays = [DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: BTRect(x: 0, y: 0, width: 1000, height: 800),
        isMain: true
    )]
    var onScreenStackEntries: [SeamStackEntry]?
    var onScreenStackReads = 0
    var onScreenStackLabels: Set<WindowID> = []
    func onScreenStack(labeling ids: Set<WindowID>) -> [SeamStackEntry]? {
        onScreenStackReads += 1
        onScreenStackLabels = ids
        return onScreenStackEntries
    }
    var windows: [WindowSnapshot]
    var raisedWindows: [(WindowID, Bool)] = []
    var failingRaiseWindowID: WindowID?
    var ignoredRaise = false
    /// Focused-window reads that still report the old focus after an
    /// activating raise, simulating an application that is slow to activate.
    var delayedFocusReads = 0
    private var pendingFocusWindowID: WindowID?
    var closedWindowRequests: [WindowID] = []
    func windowNumbers(for windows: [WindowSnapshot]) -> [WindowID: Int] { [:] }
    func stackingOrder(for windows: [WindowSnapshot], excluding windowNumbers: Set<Int>) -> [TabbedStackEntry]? { nil }
    var frontmostProcessIdentifier: Int32? { nil }
    func applicationFocus(of window: WindowSnapshot) -> ApplicationFocusMatch { .confirmed }
    func isTransientPopup(_ window: WindowSnapshot) -> Bool { false }
    func raiseWindow(_ id: WindowID, activate: Bool) throws {
        if failingRaiseWindowID == id { throw WindowSystemError.operationFailed("Simulated raise failure") }
        guard windows.contains(where: { $0.id == id }) else { throw WindowSystemError.windowNotFound(id) }
        raisedWindows.append((id, activate))
        if activate && !ignoredRaise {
            if delayedFocusReads > 0 { pendingFocusWindowID = id } else { focusedWindowID = id }
        }
    }
    func requestCloseWindow(_ id: WindowID) throws { closedWindowRequests.append(id) }
    var failingWindowID: WindowID?
    var ignoredFrameWriteCounts: [WindowID: Int] = [:]
    var frameWriteCounts: [WindowID: Int] = [:]
    var frameWriteBatches: [[WindowID]] = []
    private var currentFrameWriteBatch: [WindowID]?
    func withFrameWriteBatch(_ updates: () throws -> Void) rethrows {
        // Like the Accessibility adapter, a nested batch joins the outer one.
        if currentFrameWriteBatch != nil { try updates(); return }
        currentFrameWriteBatch = []
        defer {
            frameWriteBatches.append(currentFrameWriteBatch ?? [])
            currentFrameWriteBatch = nil
        }
        try updates()
    }
    var failedFrameWriteNumbers: [WindowID: Set<Int>] = [:]
    /// The size write succeeds before the position write fails.
    var partiallyFailedFrameWriteNumbers: [WindowID: Set<Int>] = [:]
    var failingMinimizeWindowID: WindowID?
    var minimizeWriteCounts: [WindowID: Int] = [:]
    var failedMinimizeWriteNumbers: [WindowID: Set<Int>] = [:]
    var focusedWindowID: WindowID?
    var focusedWindowReadFails = false
    var eventHandler: (@MainActor (WindowSystemEvent) -> Void)?
    var targetedSnapshotRequests = 0
    var targetedSnapshotsFail = false
    var targetedSnapshotHandler: ((Set<WindowID>) -> Void)?
    /// Every `knownCurrentFrame` hint the coordinator supplied, per window, in
    /// call order. `nil` means the coordinator had no fresh reading.
    var recordedKnownCurrentFrames: [WindowID: [BTRect?]] = [:]
    /// Simulates an application that refuses to grow beyond a fixed width.
    var clampWidth: Double?
    /// Simulates applications whose real minimum sizes are not reported.
    var enforcedMinimumWidths: [WindowID: Double] = [:]
    var enforcedMinimumHeights: [WindowID: Double] = [:]
    /// Simulates applications that round sizes to whole points and an
    /// adapter that reads the frame back after each write.
    var roundsSizesAndReportsReadback = false
    func measuredFrameAfterWrite(for windowID: WindowID) -> BTRect? {
        roundsSizesAndReportsReadback ? windows.first(where: { $0.id == windowID })?.frame : nil
    }
    /// Simulates an application that applies a geometry change on its own run
    /// loop: the write is accepted, but the new frame is only observable after
    /// this many reads.
    var readsBeforeSettling = 0
    /// Simulates an application that applies a new position at once and the
    /// new size only after this delay, as Chromium does and as a window that
    /// moved to a display with another backing scale can appear. A read after
    /// the delay shows the new size.
    var sizeApplicationDelays: [WindowID: Duration] = [:]
    private var lateSizes: [WindowID: (frame: BTRect, due: ContinuousClock.Instant)] = [:]
    /// Receives each frame write with the frame read straight back, as the
    /// adapter reads it for minimum-size learning.
    var writeReadbackHandler: ((_ windowID: WindowID, _ requested: BTRect, _ previous: BTRect?, _ actual: BTRect) -> Void)?
    /// When set, WindowServer reports these frames instead of the windows'
    /// Accessibility frames, as for an application that has not drawn yet.
    var drawnFrameOverrides: [WindowID: BTRect]?
    func windowServerFrames(for ids: Set<WindowID>) -> [WindowID: BTRect]? {
        guard let drawnFrameOverrides else { return nil }
        var frames = Dictionary(windows.filter { ids.contains($0.id) }.map { ($0.id, $0.frame) },
                                uniquingKeysWith: { first, _ in first })
        for (id, frame) in drawnFrameOverrides where ids.contains(id) { frames[id] = frame }
        return frames
    }
    /// Windows that a minimum-size probe leaves at the wrong size.
    var unrestoredProbeWindowIDs: Set<WindowID> = []
    private(set) var probedWindowIDs: [Set<WindowID>] = []
    func probeMinimumSizes(for ids: Set<WindowID>) -> Set<WindowID> {
        probedWindowIDs.append(ids)
        return unrestoredProbeWindowIDs.intersection(ids)
    }
    private var pendingFrames: [WindowID: (frame: BTRect, readsRemaining: Int)] = [:]

    private func settlePendingFrames() {
        for (id, late) in lateSizes where ContinuousClock.now >= late.due {
            lateSizes.removeValue(forKey: id)
            if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].frame = late.frame }
        }
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
        if let pending = pendingFocusWindowID {
            if delayedFocusReads > 0 { delayedFocusReads -= 1 } else { focusedWindowID = pending; pendingFocusWindowID = nil }
        }
        return focusedWindowID.flatMap { id in windows.first(where: { $0.id == id }) } ?? windows.first
    }
    func visibleWindows() throws -> [WindowSnapshot] {
        settlePendingFrames()
        return windows
    }
    /// Windows a targeted read leaves out, as Accessibility does for an
    /// element it cannot read at the moment.
    var unreadableWindowIDs: Set<WindowID> = []
    func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        targetedSnapshotRequests += 1
        targetedSnapshotHandler?(ids)
        if targetedSnapshotsFail { throw WindowSystemError.operationFailed("Simulated snapshot failure") }
        // A held application cannot be read.
        if !ids.isDisjoint(with: heldWindowIDs) { throw WindowSystemError.operationFailed("Simulated unresponsive read") }
        settlePendingFrames()
        return windows.filter { ids.contains($0.id) && !unreadableWindowIDs.contains($0.id) }
    }
    func displays() -> [DisplaySnapshot] { availableDisplays }
    func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?) { eventHandler = handler }
    func startWindowObservation() {}
    func stopWindowObservation() {}
    func emit(_ event: WindowSystemEvent) { eventHandler?(event) }

    var intermediateFrameWriteCounts: [WindowID: Int] = [:]
    /// Like the Accessibility adapter, writes every window of a live tick
    /// before it reports the first failure.
    var attemptsWholeIntermediateBatch = true

    /// Windows whose application is held as unresponsive.
    var heldWindowIDs: Set<WindowID> = []
    func isApplicationUnresponsive(for windowID: WindowID) -> Bool { heldWindowIDs.contains(windowID) }

    /// Fails a live tick that includes this window before writing any window,
    /// as the adapter does while an application is held as unresponsive.
    var unpreparedIntermediateWindowID: WindowID?

    func setIntermediateFrames(_ writes: [Placement], knownCurrentFrames: [WindowID: BTRect]) throws {
        if let unpreparedIntermediateWindowID, writes.contains(where: { $0.windowID == unpreparedIntermediateWindowID }) {
            throw FrameWritesNotStarted(WindowSystemError.operationFailed(AccessibilityWindowSystem.unresponsiveApplicationMessage))
        }
        var failure: Error?
        for write in writes {
            do {
                try setIntermediateFrame(write.frame, knownCurrentFrame: knownCurrentFrames[write.windowID], for: write.windowID)
            } catch {
                failure = failure ?? error
                if !attemptsWholeIntermediateBatch { throw error }
            }
        }
        if let failure { throw failure }
    }

    func setIntermediateFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        intermediateFrameWriteCounts[windowID, default: 0] += 1
        try setFrame(frame, knownCurrentFrame: knownCurrentFrame, for: windowID)
    }

    /// Like the Accessibility adapter, attempts every write of a pass and
    /// reports the first failure, instead of stopping at it. A test can set
    /// it to false to model an adapter that stops at the first failure.
    var attemptsWholeBatch = true
    /// Fails the batch while preparing this window, before any write.
    var unpreparedBatchWindowID: WindowID?
    func setFrames(_ writes: [Placement], knownCurrentFrames: [WindowID: BTRect]) -> FrameBatchResult {
        if let unpreparedBatchWindowID, writes.contains(where: { $0.windowID == unpreparedBatchWindowID }) {
            return FrameBatchResult(attempted: [], failure: (unpreparedBatchWindowID, WindowSystemError.windowNotFound(unpreparedBatchWindowID)))
        }
        var attempted: [WindowID] = []
        var failure: (windowID: WindowID, error: Error)?
        // Like the adapter: shrinking windows, then growing windows, and no
        // further pass after a failed one.
        for pass in AccessibilityWindowSystem.shrinkingFirstPasses(writes, knownCurrentFrames: knownCurrentFrames) {
            guard failure == nil else { break }
            for write in pass {
                attempted.append(write.windowID)
                do {
                    try setFrame(write.frame, knownCurrentFrame: knownCurrentFrames[write.windowID], for: write.windowID)
                } catch {
                    if failure == nil { failure = (write.windowID, error) }
                    if !attemptsWholeBatch { return FrameBatchResult(attempted: attempted, failure: failure) }
                }
            }
        }
        return FrameBatchResult(attempted: attempted, failure: failure)
    }

    func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        currentFrameWriteBatch?.append(windowID)
        recordedKnownCurrentFrames[windowID, default: []].append(knownCurrentFrame)
        frameWriteCounts[windowID, default: 0] += 1
        if failingWindowID == windowID { throw WindowSystemError.operationFailed("Simulated Accessibility failure") }
        if failedFrameWriteNumbers[windowID]?.contains(frameWriteCounts[windowID, default: 0]) == true {
            throw WindowSystemError.operationFailed("Simulated numbered Accessibility failure")
        }
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { throw WindowSystemError.windowNotFound(windowID) }
        if partiallyFailedFrameWriteNumbers[windowID]?.contains(frameWriteCounts[windowID, default: 0]) == true {
            windows[index].frame.size = frame.size
            throw WindowSystemError.operationFailed("Simulated partial Accessibility failure")
        }
        if ignoredFrameWriteCounts[windowID, default: 0] > 0 {
            ignoredFrameWriteCounts[windowID, default: 0] -= 1
            return
        }
        var applied = frame
        if roundsSizesAndReportsReadback {
            applied.size.width = applied.size.width.rounded()
            applied.size.height = applied.size.height.rounded()
        }
        if let clampWidth { applied.size.width = min(applied.size.width, clampWidth) }
        if let minimum = enforcedMinimumWidths[windowID], applied.size.width < minimum {
            // A refused shrink keeps the window's edge nearest its old frame.
            if applied.minX > windows[index].frame.minX + 0.5 { applied.origin.x = applied.maxX - minimum }
            applied.size.width = minimum
        }
        if let minimum = enforcedMinimumHeights[windowID], applied.size.height < minimum {
            if applied.minY > windows[index].frame.minY + 0.5 { applied.origin.y = applied.maxY - minimum }
            applied.size.height = minimum
        }
        if readsBeforeSettling > 0 {
            pendingFrames[windowID] = (applied, readsBeforeSettling)
            return
        }
        var shown = applied
        lateSizes.removeValue(forKey: windowID)
        if let delay = sizeApplicationDelays[windowID], applied.size != windows[index].frame.size {
            shown.size = windows[index].frame.size
            lateSizes[windowID] = (applied, ContinuousClock.now + delay)
        }
        windows[index].frame = shown
        windows[index].displayID = availableDisplays.first(where: { $0.visibleFrame.intersection(shown)?.area ?? 0 > shown.area / 2 })?.id ?? windows[index].displayID
        writeReadbackHandler?(windowID, frame, knownCurrentFrame, shown)
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
