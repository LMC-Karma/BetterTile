import BetterTileCore
import Testing
@testable import BetterTileApp

@MainActor private final class CoherentObservationFixture {
    let system: FakeAppWindowSystem
    let h: ApplyHarness
    let model: BetterTileModel
    let applier: SavedLayoutApplier
    let source: DisplayID, destination: DisplayID
    let a: WindowID, b: WindowID
    let sourceSpace: NativeSpaceID, destinationSpace: NativeSpaceID
    let baseline: [WindowID: BTRect]
    let document: SavedLayoutDocument
    var forward: [WindowID] = []
    var reads: [(Int, Int, Int)] = []
    var phases: [String] = []
    var generations: Set<Int> = []
    var remainedReady = true
    var afterWriteValidations = 0

    init(control: String = "none") throws {
        let system = makeManualWindowSystem()
        let h = ApplyHarness(system: system)
        let source = system.mainDisplay.id, destination = DisplayID(rawValue: "destination")
        let a = WindowID(rawValue: "a-transfer"), b = WindowID(rawValue: "z-local")
        let sourceSpace = h.space(4902), destinationSpace = h.space(12293)
        let targetBounds = BTRect(x: 3770, y: 30, width: 1920, height: 1050)
        system.availableDisplays = [
            DisplaySnapshot(id: source, frame: BTRect(x: 1210, y: 0, width: 2560, height: 1440),
                visibleFrame: BTRect(x: 1210, y: 34, width: 2560, height: 1406), isMain: true),
            DisplaySnapshot(id: destination, frame: BTRect(x: 3770, y: 0, width: 1920, height: 1080),
                visibleFrame: targetBounds, isMain: false)
        ]
        system.windows = [
            WindowSnapshot(id: a, processIdentifier: 42, bundleIdentifier: "com.example.Editor",
                frame: BTRect(x: 1280, y: 160, width: 520, height: 340), displayID: source),
            WindowSnapshot(id: b, processIdentifier: 43, bundleIdentifier: "com.example.Local",
                frame: BTRect(x: 3870, y: 100, width: 600, height: 400), displayID: destination)
        ]
        let baseline = Dictionary(uniqueKeysWithValues: system.windows.map { ($0.id, $0.frame) })
        system.desktopObservation = NativeDesktopObservation(
            currentSpaceByDisplay: [source: sourceSpace, destination: destinationSpace],
            knownSpacesByDisplay: [source: [sourceSpace], destination: [destinationSpace]],
            windowMembership: [a: [sourceSpace], b: [destinationSpace]])
        system.physicalDesktopObservation = system.desktopObservation
        system.simulatesNativeClassification = true
        let model = h.model()
        model.configuration.defaultLayoutMode = .manual
        model.configuration.singleWindowPlacement = nil
        system.focusedID = a; model.setActiveMode(.manual)
        system.focusedID = b; model.setActiveMode(.manual)
        for index in system.windows.indices { system.windows[index].frame = baseline[system.windows[index].id]! }
        system.requestedFrames = [:]
        system.frameWriteCounts = [:]
        let applier = try #require(model.savedLayoutApplier)
        applier.observesKeyboard = false
        applier.application = h.applier.application
        let document = SavedLayoutDocument(name: "Transfer and local", mode: .bento,
            layout: .split(axis: .vertical, ratios: [0.5, 0.5], children: [.slot("transfer"), .slot("local")]),
            slots: [.init(id: "transfer", bundleID: "com.example.Editor"), .init(id: "local", bundleID: "com.example.Local")], paneGap: 1)
        self.system = system; self.h = h; self.model = model; self.applier = applier
        self.source = source; self.destination = destination; self.a = a; self.b = b
        self.sourceSpace = sourceSpace; self.destinationSpace = destinationSpace
        self.baseline = baseline; self.document = document
        system.onFrameWrite = { [unowned self] id, frame in
            if frame == self.baseline[id] {
                if id == self.a { system.physicalDesktopObservation?.windowMembership[self.a] = [self.sourceSpace] }
            } else {
                self.forward.append(id)
                self.reads.append((system.completeSweepCount, system.nativeDesktopRefreshCount, system.cachedRefreshCount))
                if self.forward.count == 2 {
                    // Writes complete before the cached native observation catches up.
                    system.physicalDesktopObservation?.windowMembership[self.a] = [self.destinationSpace]
                    switch control {
                    case "sourceSpace": system.physicalDesktopObservation?.currentSpaceByDisplay[self.source] = NativeSpaceID(rawValue: 999)
                    case "hidden": system.physicalDesktopObservation?.windowMembership[self.a] = [NativeSpaceID(rawValue: 999)]
                    case "sticky": system.physicalDesktopObservation?.windowMembership[self.a] = [self.sourceSpace, self.destinationSpace]
                    case "visibility": system.offscreenWindowIDs = [self.a]
                    default: break
                    }
                }
            }
        }
        let destinationRead = applier.destinationSnapshot
        applier.destinationSnapshot = { [unowned self] in
            var state = try destinationRead()
            if self.forward.count >= 2 {
                self.afterWriteValidations += 1
                if control == "generation" || (control == "postGeneration" && self.afterWriteValidations >= 2)
                    || (control == "finalGeneration" && self.afterWriteValidations >= 5) { state.generation += 1 }
                if control == "readiness" { state.readyDisplays.remove(self.destination) }
            }
            self.generations.insert(state.generation)
            self.remainedReady = self.remainedReady && state.isStable && state.readyDisplays.contains(self.destination)
            return state
        }
        applier.timing = { [unowned self] _, _, phase, _ in self.phases.append(phase.rawValue) }
        if control == "overlap" {
            system.frameReadbackTransform = { [unowned self] id, requested in
                guard requested != self.baseline[id] else { return requested }
                var frame = requested
                if id == self.a { frame.size.width += 2 } else { frame.origin.x -= 2 }
                return frame
            }
        }
    }
    func apply() async -> SavedLayoutApplyResult? {
        await system.drive { await self.applier.apply(self.document, displayID: self.destination) }
    }
    func close() {
        system.onFrameWrite = nil; system.frameReadbackTransform = nil
        system.onBeforeFrameWrite = nil; system.onBeforeInventoryNativeRefresh = nil
        model.shutdown(); h.close()
    }
}

@Test(.appTestApplication, .timeLimit(.minutes(1))) @MainActor
func savedLayoutTransferValidatesMembershipFromTheSameObservationAsItsDisplay() async throws {
    let f = try CoherentObservationFixture()
    defer { f.close() }
    let result = await f.apply()
    #expect(result?.placed == 2)
    #expect(result?.movedSlots == ["transfer"])
    #expect(result?.issues.isEmpty == true)
    #expect(f.forward == [f.a, f.b])
    #expect(f.system.windows.allSatisfy { $0.displayID == f.destination })
    #expect(f.system.windows.first { $0.id == f.a }?.frame == BTRect(x: 3770, y: 30, width: 960, height: 1050))
    #expect(f.system.windows.first { $0.id == f.b }?.frame == BTRect(x: 4731, y: 30, width: 959, height: 1050))
    #expect(f.system.frameWriteCounts[f.a] == 1 && f.system.frameWriteCounts[f.b] == 1)
    #expect(f.model.activeMode(for: f.destination) == .bento)
    let sessions = try #require(Mirror(reflecting: f.model).children.first {
        $0.label?.hasSuffix("sessionStore") == true
    }?.value as? LayoutSessionStore)
    #expect(sessions.session(for: f.destination)?.automaticWritesSuspended == false)
    #expect(f.applier.canUndo)
    #expect(f.remainedReady && f.generations.count == 1)
    #expect(f.phases.allSatisfy { !$0.hasPrefix("failure.") })
    try #require(f.reads.count == 2)
    #expect(f.reads[1].0 - f.reads[0].0 == 0)
    #expect(f.reads[1].1 - f.reads[0].1 == 1)
    #expect(f.reads[1].2 - f.reads[0].2 == 1)
    _ = await f.system.drive { await f.applier.undoLastApply() }
    #expect(Dictionary(uniqueKeysWithValues: f.system.windows.map { ($0.id, $0.frame) }) == f.baseline)
    #expect(!f.applier.canUndo)
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: ["generation", "readiness", "postGeneration", "finalGeneration", "overlap"]) @MainActor
func savedLayoutLaterValidationFailureRestoresBothAndNamesTheCheck(control: String) async throws {
    let f = try CoherentObservationFixture(control: control)
    defer { f.close() }
    let result = await f.apply()
    #expect(result?.placed == 0)
    #expect(Dictionary(uniqueKeysWithValues: f.system.windows.map { ($0.id, $0.frame) }) == f.baseline)
    #expect(f.system.frameWriteCounts[f.a] == 2 && f.system.frameWriteCounts[f.b] == 2)
    let expected: String = switch control {
    case "generation", "readiness": "failure.coordinator.finalOwnership"
    case "postGeneration": "failure.model.postPlacement"
    case "finalGeneration": "failure.model.finalValidation"
    default: "failure.settlement.overlap"
    }
    #expect(f.phases.contains(expected))
    if control == "generation" { #expect(f.phases.contains("failure.current.generation")) }
    if control == "readiness" { #expect(f.phases.contains("failure.current.readiness")) }
}

@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: ["sourceSpace", "hidden", "sticky", "visibility"]) @MainActor
func savedLayoutCoherentReadsKeepTransferSafetyRestrictions(control: String) async throws {
    let f = try CoherentObservationFixture(control: control)
    defer { f.close() }
    let result = await f.apply()
    #expect(result?.placed == 0)
    #expect(f.forward == [f.a, f.b])
    #expect(f.system.frameWriteCounts[f.a] == 1 && f.system.frameWriteCounts[f.b] == 1)
    #expect(f.phases.contains("failure.coordinator.finalOwnership"))
}


@Test(.appTestApplication, .timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func savedLayoutFallbackUsesTheNewestSourceSpaceBeforeWritingOrRestoring(duringRollback: Bool) async throws {
    let f = try CoherentObservationFixture()
    defer { f.close() }
    let unavailableSource = NativeSpaceID(rawValue: 999)
    var inventoryReads = 0
    var changedSource = false
    var cachedSourceBeforeInventory: NativeSpaceID?
    var writesAfterSourceChange: [WindowID] = []
    let originalWrite = f.system.onFrameWrite
    f.system.onFrameWrite = { id, frame in
        originalWrite?(id, frame)
        if id == f.a, frame != f.baseline[id] {
            f.system.physicalDesktopObservation?.windowMembership[f.a] = [f.destinationSpace]
            if !duringRollback { f.system.cachedSnapshotsAvailable = false }
        }
    }
    if duringRollback {
        // B's forward guard succeeds, then its write fails without changing B.
        // Rollback first checks B and skips its unchanged baseline, then checks A.
        f.system.failedFrameWriteNumbers[f.b] = [1]
    }
    f.system.onBeforeFrameWrite = { id in
        if changedSource { writesAfterSourceChange.append(id) }
        if duringRollback, id == f.b { f.system.cachedSnapshotsAvailable = false }
    }
    f.system.onBeforeInventoryNativeRefresh = {
        guard !f.system.cachedSnapshotsAvailable else { return }
        inventoryReads += 1
        guard inventoryReads == (duringRollback ? 2 : 1) else { return }
        cachedSourceBeforeInventory = f.system.nativeDesktopObservation()?.currentSpace(on: f.source)
        f.system.physicalDesktopObservation?.currentSpaceByDisplay[f.source] = unavailableSource
        changedSource = true
    }
    let result = await f.apply()
    #expect(changedSource)
    #expect(cachedSourceBeforeInventory == f.sourceSpace)
    #expect(f.system.nativeDesktopObservation()?.currentSpace(on: f.source) == unavailableSource)
    #expect(result?.placed == 0)
    #expect(f.forward == (duringRollback ? [f.a, f.b] : [f.a]))
    #expect(writesAfterSourceChange.isEmpty)
    // No B forward write after the fallback sees the unavailable endpoint.
    // No restoring write may send A back to that endpoint either.
    #expect(f.system.frameWriteCounts[f.a] == 1)
    #expect(f.system.frameWriteCounts[f.b, default: 0] == (duringRollback ? 1 : 0))
    #expect(f.system.windows.first { $0.id == f.a }?.frame == BTRect(x: 3770, y: 30, width: 960, height: 1050))
    #expect(f.system.windows.first { $0.id == f.b }?.frame == f.baseline[f.b])
    #expect(f.model.statusMessage?.contains("Repair Layout") == true)
}
