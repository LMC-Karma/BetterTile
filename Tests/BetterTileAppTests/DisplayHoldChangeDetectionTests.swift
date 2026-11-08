import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

private let secondDisplay = DisplaySnapshot(id: DisplayID(rawValue: "second"),
    frame: BTRect(x: 1000, y: 0, width: 800, height: 600),
    visibleFrame: BTRect(x: 1000, y: 0, width: 800, height: 600))

/// AppKit posts screen-parameter notifications for reasons unrelated to the
/// displays. In Adaptive with two halves, such a notification must not hold
/// the layout, so the survivor of a close fills at once.
@Test(.appTestApplication) @MainActor
func aScreenNotificationWithoutADisplayChangeDoesNotDelayACloseFill() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let peer = WindowID(rawValue: "peer")
    system.windows.append(.init(id: peer, processIdentifier: 43, bundleIdentifier: "com.example.Peer",
        frame: BTRect(x: 300, y: 200, width: 600, height: 400), displayID: system.mainDisplay.id))
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    try await adaptiveSettled(model, system)
    let survivor = system.windows[0].id
    try #require(system.windows.allSatisfy { $0.frame.size.width < 600 })

    model.scheduleDisplayRefresh()
    #expect(!model.isHoldingDisplayChange, "An unchanged display arrangement started a hold")
    system.windows.removeAll { $0.id == peer }
    system.eventHandler?(.init(kind: .destroyed, windowID: peer, processIdentifier: 43))
    await system.advance(by: .milliseconds(400))
    try #require(await system.waitFor { model.windowEventTask == nil && model.settlementTasks.isEmpty })
    let frame = try #require(system.windows.first { $0.id == survivor }).frame
    #expect(frame.size.width > 900, "The survivor did not fill after the close: \(frame)")
}

/// Every full inventory blocks the main actor for 3 s, as when applications
/// do not answer Accessibility. Main-actor work keeps reading during the hold.
/// The 5 s limit is checked by time before each read: no read starts during
/// the hold after the limit, and the hold ends within 5 s plus one read.
@Test(.appTestApplication) @MainActor
func slowInventoriesDoNotStretchADisplayHoldPastItsLimit() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let clock = try #require(system.manualClock)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    // A reconfiguration that never reports completion: only the limit ends it.
    model.handleDisplayChange(.displayReconfigurationBegan)
    let origin = clock.now
    var heldReadsAfterLimit: [Duration] = []
    var holdEnded: Duration?
    system.onVisibleWindowSweep = { _ in
        let elapsed = clock.now - origin
        if model.isHoldingDisplayChange {
            if elapsed >= .seconds(5) { heldReadsAfterLimit.append(elapsed) }
        } else if holdEnded == nil {
            holdEnded = elapsed
        }
        clock.advance(by: .seconds(3))
    }
    for _ in 0..<4 { model.watchdog() }
    system.onVisibleWindowSweep = nil
    #expect(heldReadsAfterLimit.isEmpty, "Reads started during the hold after its limit: \(heldReadsAfterLimit)")
    #expect(!model.isHoldingDisplayChange)
    let ended = try #require(holdEnded)
    #expect(ended <= .seconds(8), "The hold lasted \(ended)")
}

enum DisplayChangeSource: String, CaseIterable, Sendable { case appKit, coreGraphics }
enum DisplayChangeKind: String, CaseIterable, Sendable {
    case none, workAreaOnly, displayAdded, displayRemoved, resolutionChanged
    var holds: Bool { self == .displayAdded || self == .displayRemoved || self == .resolutionChanged }
}

/// A real display add, removal or resolution change still holds, from either
/// source. A notification or a reconfiguration that leaves the arrangement as
/// it was, or changes only a work area, does not.
@Test(.appTestApplication, arguments: DisplayChangeSource.allCases, DisplayChangeKind.allCases) @MainActor
func onlyARealDisplayChangeHoldsTheLayout(source: DisplayChangeSource, change: DisplayChangeKind) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.availableDisplays = [system.mainDisplay, secondDisplay]
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    if source == .coreGraphics { model.handleDisplayReconfiguration(.beginConfigurationFlag) }
    switch change {
    case .none: break
    case .workAreaOnly:
        system.availableDisplays[0].visibleFrame = BTRect(x: 0, y: 25, width: 1000, height: 700)
    case .displayAdded:
        system.availableDisplays.append(DisplaySnapshot(id: DisplayID(rawValue: "third"),
            frame: BTRect(x: 1800, y: 0, width: 800, height: 600), visibleFrame: BTRect(x: 1800, y: 0, width: 800, height: 600)))
    case .displayRemoved:
        system.availableDisplays.removeAll { $0.id == secondDisplay.id }
    case .resolutionChanged:
        system.availableDisplays[0].frame = BTRect(x: 0, y: 0, width: 1280, height: 800)
        system.availableDisplays[0].visibleFrame = BTRect(x: 0, y: 0, width: 1280, height: 800)
    }
    if source == .coreGraphics { model.handleDisplayReconfiguration([]) } else { model.scheduleDisplayRefresh() }
    #expect(model.isHoldingDisplayChange == change.holds,
            "\(source) \(change): holding \(model.isHoldingDisplayChange)")
    if change.holds {
        await system.advance(by: .seconds(6))
        #expect(await system.waitFor { !model.isHoldingDisplayChange })
    }
}

enum LateReconfiguration: String, CaseIterable, Sendable {
    /// The second display is gone before the callbacks reach the model.
    case removal
    /// The active display list shrinks, as hardware mirroring does, and the
    /// end callbacks carry no display flag.
    case activeSetShrinks
    /// The main display doubles its pixels and keeps its logical bounds.
    case pixelSizeOnly
    /// The second display moves in the arrangement; nothing else changes.
    case originOnly
    /// The main display changed resolution before the callbacks reach the
    /// model. Its end callbacks report a mode change, not an added or removed
    /// display, so only the settled arrangement shows the change.
    case resolution
    /// The second display is removed and added again before the callbacks
    /// reach the model. Every arrangement read matches, but the end callbacks
    /// report the removal and the addition.
    case removeAndReAdd
}

/// The Core Graphics callback reaches the model through a main-actor task.
/// When the main actor was busy, every begin and end runs after macOS changed
/// the displays, so the begin already sees the new arrangement. The hold must
/// still cover that change.
@Test(.appTestApplication, arguments: LateReconfiguration.allCases) @MainActor
func aDisplayChangeHandledLateStillHolds(change: LateReconfiguration) async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.availableDisplays = [system.mainDisplay, secondDisplay]
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    let secondSessions = { @MainActor in try sessionStore(of: model).allSessions(for: secondDisplay.id).count }
    let sessionsBefore = try secondSessions()
    try #require(sessionsBefore > 0)
    switch change {
    case .removal, .activeSetShrinks: system.availableDisplays.removeAll { $0.id == secondDisplay.id }
    case .pixelSizeOnly: system.availableDisplays[0].scaleFactor = 2
    case .originOnly:
        system.availableDisplays[1].frame.origin.x = 1200
        system.availableDisplays[1].visibleFrame.origin.x = 1200
    case .resolution:
        system.availableDisplays[0].frame = BTRect(x: 0, y: 0, width: 1280, height: 800)
        system.availableDisplays[0].visibleFrame = BTRect(x: 0, y: 0, width: 1280, height: 800)
    case .removeAndReAdd: break
    }
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    switch change {
    case .removal:
        model.handleDisplayReconfiguration(.removeFlag)
        model.handleDisplayReconfiguration([])
    case .activeSetShrinks, .pixelSizeOnly:
        model.handleDisplayReconfiguration([])
        model.handleDisplayReconfiguration([])
    case .originOnly:
        model.handleDisplayReconfiguration(.movedFlag)
        model.handleDisplayReconfiguration([])
    case .resolution:
        model.handleDisplayReconfiguration(.setModeFlag)
        model.handleDisplayReconfiguration([])
    case .removeAndReAdd:
        model.handleDisplayReconfiguration(.removeFlag)
        model.handleDisplayReconfiguration(.addFlag)
    }
    model.scheduleDisplayRefresh()
    #expect(model.isHoldingDisplayChange, "A display change handled late ended its hold at once")
    // The missing display keeps its session while the hold lasts.
    #expect(try secondSessions() == sessionsBefore)
    // The hold then ends by the normal quiet settlement, well before its limit.
    await system.advance(by: .seconds(1))
    #expect(await system.waitFor { !model.isHoldingDisplayChange })
}

/// With two displays Core Graphics sends a begin and an end for each display.
/// An unchanged pair for each ends the hold after the last end, not before.
@Test(.appTestApplication) @MainActor
func twoUnchangedReconfigurationPairsEndTheHoldAfterTheLastEnd() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.availableDisplays = [system.mainDisplay, secondDisplay]
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    model.handleDisplayReconfiguration([])
    #expect(model.isHoldingDisplayChange)
    model.handleDisplayReconfiguration([])
    #expect(!model.isHoldingDisplayChange)
}

/// Adding a display sends more ends than begins: one for each online display
/// and one for the added display. That is a real change and holds.
@Test(.appTestApplication) @MainActor
func aDisplayAddWithMoreEndsThanBeginsHolds() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    system.availableDisplays.append(secondDisplay)
    model.handleDisplayReconfiguration([])
    model.handleDisplayReconfiguration(.addFlag)
    #expect(model.isHoldingDisplayChange)
}

/// A wake hold keeps waiting when an unchanged reconfiguration pair arrives
/// during it.
@Test(.appTestApplication) @MainActor
func anUnchangedReconfigurationDuringAWakeHoldKeepsTheHold() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    model.handleDisplayChange(.sleep)
    model.handleDisplayChange(.wake)
    try #require(model.isHoldingDisplayChange)
    model.handleDisplayReconfiguration(.beginConfigurationFlag)
    model.handleDisplayReconfiguration([])
    #expect(model.isHoldingDisplayChange, "An unchanged reconfiguration ended the wake hold")
}

/// One display has an explicit override during a hold that never reports
/// completion. Every full inventory blocks the main actor for 3 s. Application
/// launch and termination refreshes must check the limit before they read, so
/// no background inventory starts during the hold after 5 s.
@Test(.appTestApplication) @MainActor
func backgroundRefreshesCheckTheHoldLimitEvenWithADisplayOverride() async throws {
    let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
    system.availableDisplays = [system.mainDisplay, secondDisplay]
    let clock = try #require(system.manualClock)
    let model = makeModel(system: system)
    defer { model.shutdown() }
    model.setActiveMode(.bento)
    await system.advance(by: .seconds(1))
    model.handleDisplayChange(.displayReconfigurationBegan)
    // An explicit action releases its own display before the deadline.
    let before = system.frameWriteCounts
    model.perform(.leftHalf)
    try #require(system.frameWriteCounts != before)
    let origin = clock.now
    var heldReadsAfterLimit: [Duration] = []
    var holdEnded: Duration?
    system.onVisibleWindowSweep = { _ in
        let elapsed = clock.now - origin
        if model.isHoldingDisplayChange {
            if elapsed >= .seconds(5) { heldReadsAfterLimit.append(elapsed) }
        } else if holdEnded == nil {
            holdEnded = elapsed
        }
        clock.advance(by: .seconds(3))
    }
    for _ in 0..<4 { model.handleApplicationTopologyChange() }
    system.onVisibleWindowSweep = nil
    #expect(heldReadsAfterLimit.isEmpty, "Reads started during the hold after its limit: \(heldReadsAfterLimit)")
    #expect(!model.isHoldingDisplayChange)
    let ended = try #require(holdEnded)
    #expect(ended <= .seconds(8), "The hold lasted \(ended)")
}
