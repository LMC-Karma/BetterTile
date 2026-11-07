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
