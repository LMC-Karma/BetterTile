import AppKit
import Foundation
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor
private final class FakePresenter: LayoutWheelPresenting {
    var presentations: [LayoutWheelPresentation] = []
    var openCount = 0
    var closeCount = 0
    var shownPlacements: [[Placement]] = []
    var hideCount = 0
    var acknowledgments: [LayoutWheelAcknowledgment] = []
    var onEnd: (() -> Void)?

    var isOpen: Bool { openCount > closeCount }
    var selection: LayoutWheelSelection? { presentations.last?.selection }

    func open(_ presentation: LayoutWheelPresentation) {
        openCount += 1
        presentations.append(presentation)
    }

    func update(_ presentation: LayoutWheelPresentation) {
        presentations.append(presentation)
    }

    func showPlacements(_ placements: [Placement]) { shownPlacements.append(placements) }
    func hidePlacements() { hideCount += 1 }
    func close() { closeCount += 1 }
    func end(_ acknowledgment: LayoutWheelAcknowledgment) {
        acknowledgments.append(acknowledgment)
        close()
        onEnd?()
    }
}

@Test(.macOSTestApplication) @MainActor func wheelTerminationDetachesInputBeforeAcknowledgmentAndDispatchesOnce() {
    for acknowledgment in LayoutWheelAcknowledgment.allCases {
        let harness = Harness()
        defer { harness.controller.stop() }
        harness.activate()
        harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))
        let updates = harness.presenter.presentations.count
        harness.presenter.onEnd = {
            #expect(!harness.controller.isOpen)
            #expect(harness.box.commits.isEmpty)
            harness.controller.release()
            harness.controller.cancel()
            harness.move(BTPoint(x: anchor.x + innerSelectionOffset, y: anchor.y))
            harness.controller.handleKey(.nextSector)
        }
        if acknowledgment == .commit { harness.release() }
        else { harness.controller.cancel() }
        #expect(harness.presenter.acknowledgments == [acknowledgment])
        #expect(harness.presenter.presentations.count == updates)
        #expect(harness.box.commits.count == (acknowledgment == .commit ? 1 : 0))
        #expect(harness.box.endedCount == 1)
        harness.controller.release()
        #expect(harness.presenter.acknowledgments.count == 1)
    }
}

@Test(.macOSTestApplication) @MainActor func wheelReleaseWithoutCommandAcknowledgesCancellation() {
    let harness = Harness(configuration: .init(layoutWheel: .init(style: .grouped, levelCount: .two)))
    defer { harness.controller.stop() }
    harness.activate()
    harness.move(BTPoint(x: anchor.x - 124, y: anchor.y))
    harness.release()
    #expect(harness.box.commits.isEmpty)
    #expect(harness.presenter.acknowledgments == [.cancel])
}

private let target = LayoutWheelTarget(
    windowID: WindowID(rawValue: "wheel-window"),
    displayID: DisplayID(rawValue: "wheel-display"),
    visibleFrame: BTRect(x: 0, y: 0, width: 1600, height: 1000)
)
private let anchor = BTPoint(x: 800, y: 500)
private let trigger: ShortcutModifiers = [.control, .option, .shift]
private let innerSelectionOffset =
    (LayoutWheelMetrics.standard.geometry.hubRadius
        + LayoutWheelMetrics.standard.geometry.innerRingOuterRadius) / 2

@MainActor
private struct Harness {
    let controller: LayoutWheelController
    let presenter = FakePresenter()
    var commits: [(LayoutWheelCommand, WindowID)] = []
    var captureCount = 0
    var endedCount = 0

    init(
        configuration: BetterTileConfiguration = BetterTileConfiguration(
            layoutWheel: LayoutWheelConfiguration(levelCount: .two)
        ),
        capture: LayoutWheelTarget? = target,
        pointer: BTPoint = anchor
    ) {
        let box = Box()
        box.pointer = pointer
        controller = LayoutWheelController(
            configuration: configuration,
            presenter: presenter,
            pointerProvider: { box.pointer },
            addGlobalMonitor: { _, _ in NSObject() },
            addLocalMonitor: { _, _ in NSObject() },
            removeMonitor: { _ in }
        )
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.start()
        controller.captureHandler = { _ in
            box.captureCount += 1
            return capture
        }
        controller.commitHandler = { command, target in
            if let windowID = target.windowID { box.commits.append((command, windowID)) }
        }
        controller.unavailableHandler = { reason, target in
            box.unavailable.append((reason, target))
        }
        controller.gestureEndedHandler = { box.endedCount += 1 }
        self.box = box
    }

    final class Box {
        var pointer = anchor
        var commits: [(LayoutWheelCommand, WindowID)] = []
        var unavailable: [(String, LayoutWheelTarget)] = []
        var captureCount = 0
        var endedCount = 0
    }

    let box: Box

    func move(_ position: BTPoint) {
        box.pointer = position
        controller.handlePointer(position)
    }

    /// Holds the trigger past the activation deadline.
    func activate(generation: Int = 1) {
        controller.handleModifiers(trigger)
        controller.handleActivationDeadline(generation: generation)
    }

    func release() { controller.handleModifiers([]) }
}

/// The hold has to elapse before anything opens, or every trigger chord
/// shortcut would flash a wheel on its way past.
@Test(.macOSTestApplication) @MainActor func holdingTheTriggerOpensOnlyAfterTheDeadline() {
    let harness = Harness()

    harness.controller.handleModifiers(trigger)
    #expect(harness.controller.isPendingActivation)
    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.openCount == 0)

    harness.controller.handleActivationDeadline(generation: 1)
    #expect(harness.controller.isOpen)
    #expect(harness.presenter.openCount == 1)
    #expect(harness.box.captureCount == 1)
}

@Test(.macOSTestApplication) @MainActor func wheelSelectionRendersOnceAndRepeatedPointerSamplesDoNoWork() {
    let harness = Harness()
    defer { harness.controller.stop() }
    harness.activate()
    let before = harness.presenter.presentations.count
    let point = BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset)
    harness.move(point)
    #expect(harness.presenter.presentations.count - before == 1)
    let previews = harness.presenter.shownPlacements.count
    let after = harness.presenter.presentations.count
    for _ in 0..<100 { harness.move(point) }
    #expect(harness.presenter.presentations.count == after)
    #expect(harness.presenter.shownPlacements.count == previews)
    harness.move(anchor)
    #expect(harness.presenter.selection == nil)
}

@Test(.macOSTestApplication) @MainActor func wheelPresenterRemovesGlassBetweenSessions() throws {
    let harness = Harness()
    defer { harness.controller.stop() }
    harness.activate()
    var presentation = try #require(harness.presenter.presentations.last)
    presentation = LayoutWheelPresentation(
        configuration: presentation.configuration,
        placement: LayoutWheelPlacement.clamped(anchor: BTPoint(x: -5000, y: -5000), diameter: 300,
            visibleFrame: BTRect(x: -6000, y: -6000, width: 1200, height: 1000)),
        selection: nil, unavailableCommands: []
    )
    let presenter = LayoutWheelPanelPresenter()
    presenter.open(presentation)
    let original = try #require(presenter.hosting)
    let renderer = try #require(presenter.scene?.renderer)
    presentation.selection = .init(ring: .inner, sector: .left)
    presenter.update(presentation)
    #expect(presenter.scene?.renderer === renderer)
    #expect(renderer.input?.configuration == presentation.configuration)
    presenter.close()
    #expect(!renderer.isClockRunning && renderer.hosting == nil)
    presenter.open(presentation)
    #expect(presenter.hosting === original)
    #expect(presenter.hosting != nil)
    presenter.close()
}

@Test(.macOSTestApplication) @MainActor func wheelScaleChangesPlacementAndSelectionGeometryTogether() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.levelCount = .two
    configuration.layoutWheel.scale = 1.2
    let harness = Harness(configuration: configuration)

    harness.activate()

    let expectedDiameter = LayoutWheelMetrics.standard
        .scaled(by: 1.2)
        .presentationDiameter(for: .two)
    #expect(abs((harness.presenter.presentations.last?.placement.diameter ?? 0) - expectedDiameter) < 0.01)

    let geometry = LayoutWheelMetrics.standard.scaled(by: 1.2).geometry(for: .two)
    let midpoint = (geometry.hubRadius + geometry.innerRingOuterRadius) / 2
    harness.move(BTPoint(x: anchor.x, y: anchor.y - midpoint))
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))
}

@Test(.macOSTestApplication) @MainActor func wheelPresenterReopenDuringExitRejectsTheOldHide() throws {
    let harness = Harness()
    defer { harness.controller.stop() }
    harness.activate()
    var presentation = try #require(harness.presenter.presentations.last)
    presentation.selection = .init(ring: .inner, sector: .left)
    presentation.placement = LayoutWheelPlacement.clamped(anchor: BTPoint(x: -5000, y: -5000), diameter: 300,
        visibleFrame: BTRect(x: -6000, y: -6000, width: 2000, height: 2000))
    let clock = WheelTestClock()
    let renderer = LayoutWheelGlassRenderer(clock: clock)
    let presenter = LayoutWheelPanelPresenter(renderer: renderer)
    defer { presenter.close() }
    presenter.open(presentation)
    renderer.configure(.init(presentation), reduceMotion: false)
    presenter.end(.cancel)
    let stale = try #require(clock.callback)
    clock.frame()
    presenter.open(presentation)
    renderer.configure(.init(presentation), reduceMotion: false)
    stale(100)
    #expect(presenter.isVisible)
    #expect(renderer.exitPresentation == nil)
    presenter.end(.commit)
    presenter.end(.cancel) // A duplicate end must not replace its hide guard.
    clock.settle()
    #expect(!presenter.isVisible)
    #expect(renderer.exitPresentation?.acknowledgment == .commit)
    #expect(!clock.isRunning)
}

@Test(.macOSTestApplication) @MainActor func anOpenGestureOwnsShortcutKeysUntilItEnds() {
    let harness = Harness()
    var beganCount = 0
    var endedCount = 0
    harness.controller.gestureBeganHandler = { beganCount += 1 }
    harness.controller.gestureEndedHandler = { endedCount += 1 }

    harness.controller.handleModifiers(trigger)
    #expect(beganCount == 0)

    harness.controller.handleActivationDeadline(generation: 1)
    #expect(beganCount == 1)
    #expect(endedCount == 0)

    harness.controller.handleKey(.commit)
    #expect(endedCount == 1)
    harness.controller.cancel()
    #expect(endedCount == 1)
}

@Test(.macOSTestApplication) @MainActor func releasingBeforeTheDeadlineNeverOpensTheWheel() {
    let harness = Harness()

    harness.controller.handleModifiers(trigger)
    harness.release()
    harness.controller.handleActivationDeadline(generation: 1)

    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.openCount == 0)
    #expect(harness.box.commits.isEmpty)
}

/// An ordinary key during the hold means the user ran a shortcut. The wheel has
/// to stay away, and must not open when the modifiers are finally released.
@Test(.macOSTestApplication) @MainActor func anOrdinaryKeyDuringTheHoldCancelsActivationWithoutAFlash() {
    let harness = Harness()

    harness.controller.handleModifiers(trigger)
    harness.controller.cancelPendingActivation()
    harness.controller.handleActivationDeadline(generation: 1)

    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.openCount == 0)

    // Still holding the trigger: a second deadline must not open one either.
    harness.controller.handleModifiers(trigger)
    harness.controller.handleActivationDeadline(generation: 2)
    #expect(!harness.controller.isOpen)
}

/// Releasing and pressing again is a new gesture; holding through the end of
/// one gesture is not.
@Test(.macOSTestApplication) @MainActor func aSecondWheelNeedsTheTriggerReleasedFirst() {
    let harness = Harness()
    harness.activate()
    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))
    harness.release()
    #expect(harness.presenter.openCount == 1)

    // Modifiers held down again without ever dropping the trigger.
    harness.controller.handleActivationDeadline(generation: 2)
    #expect(harness.presenter.openCount == 1)

    harness.controller.handleModifiers([])
    harness.activate(generation: 2)
    #expect(harness.presenter.openCount == 2)
}

@Test(.macOSTestApplication) @MainActor func nothingEligibleLeavesTheWheelClosed() {
    let harness = Harness(capture: nil)

    harness.activate()

    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.openCount == 0)
    #expect(harness.box.commits.isEmpty)
}

/// Pointer jitter inside the hub is the cancel affordance, so it must not
/// select anything.
@Test(.macOSTestApplication) @MainActor func pointerJitterInsideTheHubSelectsNothing() {
    let harness = Harness()
    harness.activate()

    harness.move(BTPoint(x: anchor.x + 4, y: anchor.y - 3))
    #expect(harness.presenter.selection == nil)

    harness.release()
    #expect(harness.box.commits.isEmpty)
    #expect(harness.presenter.closeCount == 1)
}

@Test(.macOSTestApplication, arguments: [LayoutWheelLevelCount.one, .two], [0.8, 1.0, 1.3])
@MainActor func wheelNearAnEdgeSelectsTheSectorUnderThePointer(
    levels: LayoutWheelLevelCount, scale: Double
) throws {
    let display = BTRect(x: -1600, y: -200, width: 1600, height: 1000)
    let edgeTarget = LayoutWheelTarget(windowID: target.windowID, displayID: target.displayID,
                                       visibleFrame: display)
    let metrics = LayoutWheelMetrics.standard.scaled(by: scale)
    for (x, y) in [(0.0, 0.0), (0.5, 0), (1, 0), (0, 0.5), (1, 0.5), (0, 1), (0.5, 1), (1, 1)] {
        let point = BTPoint(x: display.minX + x * display.size.width,
                            y: display.minY + y * display.size.height)
        var configuration = BetterTileConfiguration()
        configuration.layoutWheel.levelCount = levels
        configuration.layoutWheel.scale = scale
        let harness = Harness(configuration: configuration, capture: edgeTarget, pointer: point)
        defer { harness.controller.stop() }
        harness.activate()
        let placement = try #require(harness.presenter.presentations.last?.placement)
        #expect(harness.presenter.selection == nil)
        harness.move(BTPoint(x: point.x + 3, y: point.y + 4))
        #expect(harness.presenter.selection == nil)
        let visibleRadius = metrics.diameter(for: levels) / 2 * LayoutWheelMetrics.selectedScale
        #expect(placement.center.x - visibleRadius >= display.minX)
        #expect(placement.center.x + visibleRadius <= display.maxX)
        #expect(placement.center.y - visibleRadius >= display.minY)
        #expect(placement.center.y + visibleRadius <= display.maxY)
        for ring in configuration.layoutWheel.activeRings {
            let radius = (metrics.innerRadius(for: ring) + metrics.outerRadius(for: ring, levelCount: levels)) / 2
            for sector in LayoutWheelSector.allCases {
                let angle = Double(sector.rawValue) * .pi / 4
                harness.move(BTPoint(
                    x: placement.center.x + sin(angle) * radius,
                    y: placement.center.y - cos(angle) * radius
                ))
                #expect(harness.presenter.selection == LayoutWheelSelection(ring: ring, sector: sector))
            }
        }
        harness.move(placement.center)
        #expect(harness.presenter.selection == nil)
        harness.release()
        #expect(harness.box.commits.isEmpty)
    }
}

@Test(.macOSTestApplication) @MainActor func wheelAtAnEdgeDoesNotCommitOnOpeningOrJitter() {
    let point = BTPoint(x: 5, y: 5)
    let harness = Harness(pointer: point)
    defer { harness.controller.stop() }
    harness.activate()
    harness.move(BTPoint(x: point.x + 3, y: point.y + 4))
    harness.release()
    #expect(harness.box.commits.isEmpty)
}

@Test(.macOSTestApplication) @MainActor func pointerDirectionSelectsTheDrawnSectorAndCommitsOnRelease() {
    let harness = Harness()
    harness.activate()

    // Straight up from the anchor, inside the inner ring.
    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))

    harness.release()
    #expect(harness.box.commits.count == 1)
    #expect(harness.box.commits.first?.0 == .windowAction(.topHalf))
    #expect(harness.box.commits.first?.1 == target.windowID)
    #expect(harness.presenter.closeCount == 1)
}

/// Releasing on the dead band between the rings cancels, exactly like the hub.
@Test(.macOSTestApplication) @MainActor func releasingInTheDeadBandCancels() {
    let harness = Harness()
    harness.activate()
    let geometry = LayoutWheelMetrics.standard.geometry
    let deadBand = (geometry.innerRingOuterRadius + geometry.outerRingInnerRadius) / 2

    harness.move(BTPoint(x: anchor.x, y: anchor.y - deadBand))
    #expect(harness.presenter.selection == nil)

    harness.release()
    #expect(harness.box.commits.isEmpty)
}

@Test(.macOSTestApplication) @MainActor func releasingOnAnEmptySectorCancels() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.innerSlots[LayoutWheelSector.top.rawValue] = nil
    let harness = Harness(configuration: configuration)
    harness.activate()

    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))

    harness.release()
    #expect(harness.box.commits.isEmpty)
    #expect(harness.presenter.closeCount == 1)
}

/// A release, a repeated release, and a deactivation can all arrive for one
/// gesture. Only the first may act.
@Test(.macOSTestApplication) @MainActor func duplicateReleaseAndDeactivationCommitExactlyOnce() {
    let harness = Harness()
    harness.activate()
    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))

    harness.release()
    harness.release()
    harness.controller.handleApplicationDeactivated()
    harness.controller.cancel()

    #expect(harness.box.commits.count == 1)
    #expect(harness.presenter.closeCount == 1)
    #expect(harness.box.endedCount == 1)
}

@Test(.macOSTestApplication) @MainActor func focusedWindowChangeCancelsWithoutCommitting() {
    let harness = Harness()
    harness.activate()
    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))

    harness.controller.handleFocusedWindowChanged()

    #expect(!harness.controller.isOpen)
    #expect(harness.box.commits.isEmpty)
    #expect(harness.presenter.closeCount == 1)
    #expect(harness.box.endedCount == 1)
}

@Test(.macOSTestApplication) @MainActor func escapeCancelsWithoutCommitting() {
    let harness = Harness()
    harness.activate()
    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))

    harness.controller.handleKey(.escape)

    #expect(!harness.controller.isOpen)
    #expect(harness.box.commits.isEmpty)
    #expect(harness.presenter.closeCount == 1)

    // The release that follows Escape must not commit the old selection.
    harness.release()
    #expect(harness.box.commits.isEmpty)
}

/// Losing the captured window ends the gesture. It must never fall through to
/// whichever window is focused by the time the user releases.
@Test(.macOSTestApplication) @MainActor func losingTheCapturedWindowCancelsAndNeverRetargets() {
    let harness = Harness()
    harness.activate()
    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))

    harness.controller.handleTargetLost(windowID: WindowID(rawValue: "other-window"))
    #expect(harness.controller.isOpen)

    harness.controller.handleTargetLost(windowID: WindowID(rawValue: "wheel-window"))
    #expect(!harness.controller.isOpen)

    harness.release()
    #expect(harness.box.commits.isEmpty)
}

@Test(.macOSTestApplication) @MainActor func changingTheTriggerMidGestureCancels() {
    let harness = Harness()
    harness.activate()
    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))

    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.keyboardModifiers = [.control, .shift]
    harness.controller.configuration = configuration

    #expect(!harness.controller.isOpen)
    #expect(harness.box.commits.isEmpty)
}

@Test(.macOSTestApplication) @MainActor func disablingTheWheelMidGestureCancels() {
    let harness = Harness()
    harness.activate()

    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.isEnabled = false
    harness.controller.configuration = configuration

    #expect(!harness.controller.isOpen)
    harness.controller.handleModifiers(trigger)
    #expect(!harness.controller.isPendingActivation)
}

/// A combination that only contains the trigger opens the wheel. A larger one
/// belongs to whatever shortcut the user actually pressed, so releasing its
/// extra key first does not open the wheel either; a fresh press does.
@Test(.macOSTestApplication) @MainActor func extraModifiersDoNotOpenTheWheel() {
    let harness = Harness()

    harness.controller.handleModifiers([.control, .option, .shift, .command])
    #expect(!harness.controller.isPendingActivation)

    harness.controller.handleModifiers(trigger)
    #expect(!harness.controller.isPendingActivation)

    harness.controller.handleModifiers([])
    harness.controller.handleModifiers(trigger)
    #expect(harness.controller.isPendingActivation)
}

@Test(.macOSTestApplication) @MainActor func keyboardMovesThroughRingsAndCommits() {
    let harness = Harness()
    harness.activate()

    harness.controller.handleKey(.nextSector)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))

    harness.controller.handleKey(.nextSector)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .topRight))

    harness.controller.handleKey(.switchRing)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .outer, sector: .topRight))

    harness.controller.handleKey(.previousSector)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .outer, sector: .top))

    harness.controller.handleKey(.commit)
    #expect(harness.box.commits.count == 1)
    #expect(harness.box.commits.first?.0 == .windowAction(.maximize))
}

/// The wheel's navigation keys are the same key codes the default shortcuts
/// bind to the halves, and a user may narrow the wheel trigger to the same
/// Control+Option the halves use. The wheel therefore has to own those keys
/// for as long as it is open.
///
/// It does, in two steps. `open` reports the gesture start before it accepts a
/// key, and the app suspends the Carbon hot keys on that signal, so no shortcut
/// is registered to compete. The key then selects a sector instead of ending
/// the gesture.
@Test(.macOSTestApplication) @MainActor func anOpenWheelOwnsTheArrowKeysTheDefaultShortcutsAlsoBind() {
    let arrows: [UInt16: LayoutWheelKey] = [
        123: .previousSector, 124: .nextSector, 126: .outerRing, 125: .innerRing,
    ]
    for (keyCode, expected) in arrows {
        #expect(LayoutWheelKey(keyCode: keyCode) == expected)
    }
    let boundArrows = Set(
        BetterTileConfiguration.defaultShortcuts
            .compactMap(\.shortcut?.keyCode)
            .map(UInt16.init)
            .filter { arrows.keys.contains($0) }
    )
    #expect(boundArrows == Set(arrows.keys))

    var beganWhileOpen: Bool?
    let harness = Harness()
    harness.controller.gestureBeganHandler = { [weak controller = harness.controller] in
        beganWhileOpen = controller?.isOpen
    }
    harness.activate()

    // Reported from inside `open`, so the suspend lands before the first key.
    #expect(beganWhileOpen == true)

    // The first key normalizes the selection, the second steps it backwards.
    harness.controller.handleKey(.previousSector)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))
    harness.controller.handleKey(.previousSector)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .topLeft))

    // Navigating, not ending the gesture the way a shortcut match would.
    #expect(harness.controller.isOpen)
    #expect(harness.box.endedCount == 0)
    #expect(harness.box.commits.isEmpty)
}

/// An unavailable command marks its sector and shows no placement. Release
/// emits the unavailable outcome so the app can report why without committing.
@Test(.macOSTestApplication) @MainActor func anUnavailableCommandPreviewsNothingButStillReports() {
    let harness = Harness()
    harness.controller.previewHandler = { command, _ in
        command == .repairBento
            ? .unavailable(reason: "Repair Layout is available only on an Adaptive desktop.")
            : .ready(placements: [Placement(windowID: WindowID(rawValue: "wheel-window"), frame: BTRect(x: 0, y: 0, width: 10, height: 10))])
    }
    harness.activate()

    harness.controller.handleKey(.nextSector)
    harness.controller.handleKey(.switchRing)
    let shownBeforeRepairBento = harness.presenter.shownPlacements.count

    // Top left of the outer ring is Repair Layout by default.
    harness.controller.handleKey(.previousSector)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .outer, sector: .topLeft))
    #expect(harness.presenter.presentations.last?.unavailableCommands == [.repairBento])
    // No new placement appeared for the command that cannot run.
    #expect(harness.presenter.shownPlacements.count == shownBeforeRepairBento)

    harness.controller.handleKey(.commit)
    #expect(harness.box.commits.isEmpty)
    #expect(harness.box.unavailable.first?.0 == "Repair Layout is available only on an Adaptive desktop.")
    #expect(harness.box.unavailable.first?.1 == target)
}

/// Hover publishes the command's name and availability. Only release reports
/// the reason, and a repeated release cannot report or dispatch it again.
@Test(.macOSTestApplication) @MainActor func unavailableReasonAppearsOnlyOnceOnRelease() throws {
    let harness = Harness()
    defer { harness.controller.stop() }
    let reason = "Repair Layout is available only on an Adaptive desktop."
    harness.controller.previewHandler = { command, _ in
        command == .repairBento ? .unavailable(reason: reason) : .ready(placements: [])
    }
    harness.activate()
    harness.move(BTPoint(x: anchor.x - 70, y: anchor.y - 70))
    let presentation = try #require(harness.presenter.presentations.last)
    let input = LayoutWheelSceneInput(presentation)
    #expect(input.centreContent?.name == "Repair Layout")
    #expect(input.centreContent?.available == false)
    #expect(harness.box.unavailable.isEmpty && harness.box.commits.isEmpty)
    for _ in 0..<20 { harness.move(BTPoint(x: anchor.x - 70, y: anchor.y - 70)) }
    #expect(harness.box.unavailable.isEmpty)
    harness.release()
    #expect(harness.box.unavailable.count == 1 && harness.box.unavailable.first?.0 == reason)
    #expect(harness.box.commits.isEmpty)
    harness.release()
    #expect(harness.box.unavailable.count == 1 && harness.box.commits.isEmpty)
}

@Test(.macOSTestApplication) @MainActor func aModifierMonitorRegistrationFailureIsReportedInline() {
    let controller = LayoutWheelController(
        configuration: BetterTileConfiguration(),
        presenter: FakePresenter(),
        addGlobalMonitor: { _, _ in nil },
        addLocalMonitor: { _, _ in NSObject() },
        removeMonitor: { _ in }
    )
    var failure: String?
    controller.monitoringFailureHandler = { failure = $0 }

    controller.start()

    #expect(failure == "BetterTile could not monitor the Layout Wheel modifier trigger.")
    #expect(!controller.isPendingActivation)
    #expect(!controller.isOpen)
}

/// Global AppKit monitors omit events delivered to BetterTile itself. The
/// matching local monitor keeps the trigger working while Settings is active.
@Test(.macOSTestApplication, arguments: [LayoutWheelStyle.custom, .grouped]) @MainActor
func aLocalModifierEventOpensTheWheelAndWheelKeysAreConsumed(style: LayoutWheelStyle) async {
    var localFlagsHandler: (@MainActor (LayoutWheelInput) -> Bool)?
    var localKeyHandler: (@MainActor (LayoutWheelInput) -> Bool)?
    let presenter = FakePresenter()
    let controller = LayoutWheelController(
        configuration: BetterTileConfiguration(layoutWheel: .init(style: style)),
        presenter: presenter,
        pointerProvider: { anchor },
        addGlobalMonitor: { _, _ in NSObject() },
        addLocalMonitor: { mask, handler in
            if mask == .flagsChanged { localFlagsHandler = handler }
            if mask == .keyDown { localKeyHandler = handler }
            return NSObject()
        },
        removeMonitor: { _ in }
    )
    controller.captureHandler = { _ in target }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    controller.start()

    #expect(localFlagsHandler?(.init(keyCode: 56, modifiers: trigger)) == false)
    await Task.yield()
    controller.handleActivationDeadline(generation: 1)

    #expect(controller.isOpen)
    #expect(presenter.openCount == 1)

    #expect(localKeyHandler?(.init(keyCode: 124)) == true)
    #expect(controller.isOpen)
    #expect(presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))

    #expect(localKeyHandler?(.init()) == false)
}

@Test(.macOSTestApplication) @MainActor func availableCommandsShowTheirPlacements() {
    let harness = Harness()
    let placement = Placement(windowID: WindowID(rawValue: "wheel-window"), frame: BTRect(x: 0, y: 0, width: 800, height: 500))
    harness.controller.previewHandler = { _, _ in .ready(placements: [placement]) }
    harness.activate()

    harness.move(BTPoint(x: anchor.x, y: anchor.y - innerSelectionOffset))

    #expect(harness.presenter.shownPlacements.last == [placement])
}

/// Stopping the controller has to leave nothing open behind it.
@Test(.macOSTestApplication) @MainActor func stoppingClosesAnOpenWheel() {
    let harness = Harness()
    harness.activate()

    harness.controller.stop()

    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.closeCount == 1)
}

@Test(.macOSTestApplication) @MainActor func suspendingRemovesEveryKeyboardMonitorAndResumeRestoresOnlyTheTrigger() {
    var addedGlobalMasks: [NSEvent.EventTypeMask] = []
    var addedLocalMasks: [NSEvent.EventTypeMask] = []
    var removed = 0
    let controller = LayoutWheelController(
        configuration: BetterTileConfiguration(),
        presenter: FakePresenter(),
        pointerProvider: { anchor },
        addGlobalMonitor: { mask, _ in
            addedGlobalMasks.append(mask)
            return NSObject()
        },
        addLocalMonitor: { mask, _ in
            addedLocalMasks.append(mask)
            return NSObject()
        },
        removeMonitor: { _ in removed += 1 }
    )
    controller.captureHandler = { _ in target }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    controller.start()
    controller.handleModifiers(trigger)
    controller.handleActivationDeadline(generation: 1)

    #expect(controller.isOpen)
    for addedMasks in [addedGlobalMasks, addedLocalMasks] {
        #expect(addedMasks.contains(.flagsChanged))
        #expect(addedMasks.contains(.keyDown))
        #expect(addedMasks.contains { $0.contains(.mouseMoved) })
    }

    controller.suspend()

    #expect(!controller.isOpen)
    #expect(removed == 6)
    controller.handleModifiers(trigger)
    #expect(!controller.isPendingActivation)

    controller.resume()
    #expect(addedGlobalMasks.filter { $0 == .flagsChanged }.count == 2)
    #expect(addedLocalMasks.filter { $0 == .flagsChanged }.count == 2)
    #expect(addedGlobalMasks.filter { $0 == .keyDown }.count == 1)
    #expect(addedLocalMasks.filter { $0 == .keyDown }.count == 1)
}

/// AppKit keeps monitor handlers until removal. They must not keep the
/// controller alive while the keyboard-triggered wheel is open.
@Test(.macOSTestApplication) @MainActor func installedMonitorHandlersDoNotRetainTheController() {
    var retainedHandlers: [Any] = []
    var controller: LayoutWheelController? = LayoutWheelController(
        configuration: BetterTileConfiguration(),
        presenter: FakePresenter(),
        pointerProvider: { anchor },
        addGlobalMonitor: { _, handler in
            retainedHandlers.append(handler)
            return NSObject()
        },
        addLocalMonitor: { _, handler in
            retainedHandlers.append(handler)
            return NSObject()
        },
        removeMonitor: { _ in }
    )
    controller?.captureHandler = { _ in target }
    controller?.previewHandler = { _, _ in .ready(placements: []) }
    controller?.start()
    controller?.handleModifiers(trigger)
    controller?.handleActivationDeadline(generation: 1)
    #expect(controller?.isOpen == true)
    weak let released = controller
    controller = nil

    #expect(released == nil)
    #expect(!retainedHandlers.isEmpty)
}

@Test(.macOSTestApplication) @MainActor func glassPreferenceUpdatesAnOpenWheelWithoutCancellingItsGesture() throws {
    let harness = Harness()
    defer { harness.controller.stop() }
    harness.activate()
    let placement = try #require(harness.presenter.presentations.last?.placement)
    harness.controller.configuration.overlayAppearance = .init(useLiquidGlass: false, strength: 0.9)
    let updated = try #require(harness.presenter.presentations.last)
    #expect(updated.overlayAppearance == OverlayAppearance(useLiquidGlass: false, strength: 0.9))
    #expect(updated.placement == placement)
    #expect(harness.box.endedCount == 0)
}

@Test(.macOSTestApplication, arguments: ["stop", "restart", "configuration", "suspension"]) @MainActor
func queuedWheelModifiersCannotStartAfterMonitorRetirement(retirement: String) async throws {
    var flags: ((NSEvent) -> Void)?
    let controller = LayoutWheelController(
        configuration: BetterTileConfiguration(), presenter: FakePresenter(),
        // Hold the pending phase while this test checks queued monitor events.
        activationDelay: .seconds(60), pointerProvider: { anchor },
        addGlobalMonitor: { mask, handler in
            if mask.contains(.flagsChanged) { flags = handler }
            return NSObject()
        }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in }
    )
    controller.start()
    defer { controller.stop() }
    let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.control, .option, .shift], timestamp: 1,
                                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0))
    #expect(flags != nil)
    flags?(event)
    switch retirement {
    case "configuration":
        controller.configuration.layoutWheel.keyboardTriggerEnabled = false
        controller.configuration.layoutWheel.keyboardTriggerEnabled = true
    case "suspension":
        controller.suspend()
        controller.resume()
    default:
        controller.stop()
        if retirement == "restart" { controller.start() }
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(!controller.isPendingActivation)
    #expect(!controller.isOpen)
    if retirement != "stop" {
        #expect(flags != nil)
        flags?(event)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.isPendingActivation)
    }
}

@MainActor private final class GroupedWheelTestClock {
    var time = 100.0
}

@Test(.macOSTestApplication, arguments: LayoutWheelLevelCount.allCases) @MainActor
func groupedWheelControllerRestOpensFanAndCommitsOnceWithInjectedClock(levels: LayoutWheelLevelCount) throws {
    let presenter = FakePresenter()
    let clock = GroupedWheelTestClock()
    var commits: [LayoutWheelCommand] = []
    let controller = LayoutWheelController(
        configuration: .init(layoutWheel: .init(style: .grouped, levelCount: levels)), presenter: presenter,
        now: { clock.time }, pointerProvider: { anchor },
        addGlobalMonitor: { _, _ in NSObject() }, addLocalMonitor: { _, _ in NSObject() }, removeMonitor: { _ in })
    controller.captureHandler = { _ in target }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    controller.commitHandler = { command, _ in commits.append(command) }
    controller.start()
    defer { controller.stop() }
    controller.handleModifiers(trigger)
    controller.handleActivationDeadline(generation: 1)
    controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - (levels == .one ? 68 : 124)))
    clock.time = 100.199
    controller.handleFanDeadline()
    #expect(presenter.presentations.last?.fan.openSector == nil)
    clock.time = 100.2
    controller.handleFanDeadline()
    #expect(presenter.presentations.last?.fan.openSector == .top)
    let offset = LayoutWheelMetrics.grouped.fanGeometry(for: .init(style: .grouped, levelCount: levels)).point(sector: .top, option: 1)
    controller.handlePointer(BTPoint(x: anchor.x + offset.x, y: anchor.y + offset.y))
    controller.release()
    controller.release()
    #expect(commits == [.windowAction(.center)])
    #expect(!controller.isOpen)
}

@Test(.macOSTestApplication) @MainActor func groupedWheelKeyboardAndHubCancelAndChooseLayoutIsDisabled() {
    let harness = Harness(configuration: .init(layoutWheel: .init(style: .grouped, levelCount: .two)))
    defer { harness.controller.stop() }
    harness.activate()
    let selectionPoint = BTPoint(x: anchor.x - 90, y: anchor.y + 90)
    harness.move(selectionPoint)
    #expect(harness.presenter.presentations.last?.layoutAvailable == false)
    #expect(harness.presenter.presentations.last?.selection?.sector == .bottomLeft)
    harness.move(anchor)
    harness.release()
    #expect(harness.box.commits.isEmpty)
}

@Test(.macOSTestApplication) @MainActor func groupedWheelBeyondOpenFanStillUsesReleaseDirection() {
    let harness = Harness(configuration: .init(layoutWheel: .init(style: .grouped, levelCount: .two)))
    defer { harness.controller.stop() }
    harness.activate()
    harness.controller.handleKey(.nextSector)
    harness.controller.handleKey(.outerRing)
    harness.controller.handleKey(.outerRing)
    #expect(harness.presenter.presentations.last?.fan.openSector == .top)
    harness.move(BTPoint(x: anchor.x, y: anchor.y + 1000))
    harness.release()
    #expect(harness.box.commits.map(\.0) == [.windowAction(.restore)])
}

@Test(.macOSTestApplication, arguments: [0.8, 1.0, 1.3]) @MainActor
func groupedWheelReservesFanBoundsWithoutMovingItsCenter(scale: Double) throws {
    for point in [BTPoint(x: 1, y: 1), BTPoint(x: 1599, y: 999)] {
        let harness = Harness(configuration: .init(layoutWheel: .init(style: .grouped, scale: scale)), pointer: point)
        defer { harness.controller.stop() }
        harness.activate()
        let placement = try #require(harness.presenter.presentations.last?.placement)
        let radius = LayoutWheelMetrics.grouped.scaled(by: scale).fanGeometry.outerRadius
        #expect(placement.center.x - radius >= target.visibleFrame.minX)
        #expect(placement.center.y - radius >= target.visibleFrame.minY)
        #expect(placement.center.x + radius <= target.visibleFrame.maxX)
        #expect(placement.center.y + radius <= target.visibleFrame.maxY)
        harness.controller.handleKey(.nextSector)
        harness.controller.handleKey(.outerRing)
        harness.controller.handleKey(.outerRing)
        #expect(harness.presenter.presentations.last?.fan.openSector == .top)
        #expect(harness.presenter.presentations.last?.placement == placement)
    }
}

@Test(.macOSTestApplication) @MainActor func wheelPresentationCarriesTheDesktopModeForTheModeParent() throws {
    for mode in LayoutMode.availableModes {
        let harness = Harness(capture: LayoutWheelTarget(
            windowID: WindowID(rawValue: "wheel-window"), displayID: DisplayID(rawValue: "wheel-display"),
            visibleFrame: BTRect(x: 0, y: 0, width: 1600, height: 1000), layoutMode: mode))
        defer { harness.controller.stop() }
        harness.activate()
        let presentation = try #require(harness.presenter.presentations.last)
        #expect(presentation.currentMode == mode)
        #expect(LayoutWheelGroup.at(.bottomRight).glyph(currentMode: presentation.currentMode) == .mode(mode))
    }
}

@Test(.macOSTestApplication) @MainActor func savedWheelCategoryAndMoreReleaseNeverCommitAPlacement() {
    func navigate(_ harness: Harness) {
        for _ in 0..<6 { harness.controller.handleKey(.nextSector) } // Top through Choose Layout.
        harness.controller.handleKey(.outerRing)
        for _ in 0..<6 { harness.controller.handleKey(.nextSector) } // Five presets, then Saved Layouts.
    }
    for more in [false, true] {
        let harness = Harness(configuration: .init(layoutWheel: .init(style: .grouped, levelCount: .one)))
        defer { harness.controller.stop() }
        harness.controller.savedLayouts = (0..<9).map { .init(file: "\($0).json", name: "Layout \($0)") }
        var navigation: [LayoutWheelCommand] = []
        harness.controller.savedLayoutNavigationHandler = { command, _ in navigation.append(command) }
        harness.activate(); navigate(harness)
        if more {
            harness.controller.handleKey(.outerRing) // Enter the category without releasing.
            for _ in 0..<6 { harness.controller.handleKey(.nextSector) }
        }
        harness.release()
        #expect(harness.box.commits.isEmpty)
        #expect(navigation == [more ? .moreSavedLayouts : .savedLayouts])
    }
}

@Test(.macOSTestApplication) @MainActor func savedWheelCustomizedOverflowReleaseOnlyNavigates() {
    var wheel = LayoutWheelConfiguration(style: .grouped)
    wheel.setGroup(.init(quickAction: nil,
        options: [.maximize, .center, .leftHalf, .rightHalf, .topHalf, .bottomHalf].map { .windowAction($0) }), at: .bottomLeft)
    let harness = Harness(configuration: .init(layoutWheel: wheel))
    defer { harness.controller.stop() }
    harness.controller.savedLayouts = [.init(file: "one.json", name: "One")]
    var navigation: [LayoutWheelCommand] = []
    harness.controller.savedLayoutNavigationHandler = { command, _ in navigation.append(command) }
    harness.activate()
    for _ in 0..<6 { harness.controller.handleKey(.nextSector) }
    harness.controller.handleKey(.outerRing)
    for _ in 0..<5 { harness.controller.handleKey(.nextSector) }
    harness.release()
    #expect(harness.box.commits.isEmpty)
    #expect(navigation == [.moreLayoutChoices])
}
