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
}

private let target = LayoutWheelTarget(
    windowID: WindowID(rawValue: "wheel-window"),
    displayID: DisplayID(rawValue: "wheel-display"),
    visibleFrame: BTRect(x: 0, y: 0, width: 1600, height: 1000)
)
private let anchor = BTPoint(x: 800, y: 500)
private let trigger: ShortcutModifiers = [.control, .option]

@MainActor
private struct Harness {
    let controller: LayoutWheelController
    let presenter = FakePresenter()
    var commits: [(LayoutWheelCommand, WindowID)] = []
    var captureCount = 0
    var endedCount = 0

    init(
        configuration: BetterTileConfiguration = BetterTileConfiguration(),
        capture: LayoutWheelTarget? = target,
        pointer: BTPoint = anchor
    ) {
        controller = LayoutWheelController(
            configuration: configuration,
            presenter: presenter,
            pointerProvider: { pointer }
        )
        controller.previewHandler = { _, _ in .ready(placements: []) }
        controller.start()
        let box = Box()
        controller.captureHandler = {
            box.captureCount += 1
            return capture
        }
        controller.commitHandler = { command, target in
            box.commits.append((command, target.windowID))
        }
        controller.unavailableHandler = { reason, target in
            box.unavailable.append((reason, target))
        }
        controller.gestureEndedHandler = { box.endedCount += 1 }
        self.box = box
    }

    final class Box {
        var commits: [(LayoutWheelCommand, WindowID)] = []
        var unavailable: [(String, LayoutWheelTarget)] = []
        var captureCount = 0
        var endedCount = 0
    }

    let box: Box

    /// Holds the trigger past the activation deadline.
    func activate(generation: Int = 1) {
        controller.handleModifiers(trigger)
        controller.handleActivationDeadline(generation: generation)
    }

    func release() { controller.handleModifiers([]) }
}

/// The hold has to elapse before anything opens, or every Control + Option
/// shortcut would flash a wheel on its way past.
@Test @MainActor func holdingTheTriggerOpensOnlyAfterTheDeadline() {
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

@Test @MainActor func releasingBeforeTheDeadlineNeverOpensTheWheel() {
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
@Test @MainActor func anOrdinaryKeyDuringTheHoldCancelsActivationWithoutAFlash() {
    let harness = Harness()

    harness.controller.handleModifiers(trigger)
    harness.controller.cancelPendingActivation()
    harness.controller.handleActivationDeadline(generation: 1)

    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.openCount == 0)

    // Still holding Control + Option: a second deadline must not open one either.
    harness.controller.handleModifiers(trigger)
    harness.controller.handleActivationDeadline(generation: 2)
    #expect(!harness.controller.isOpen)
}

/// Releasing and pressing again is a new gesture; holding through the end of
/// one gesture is not.
@Test @MainActor func aSecondWheelNeedsTheTriggerReleasedFirst() {
    let harness = Harness()
    harness.activate()
    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))
    harness.release()
    #expect(harness.presenter.openCount == 1)

    // Modifiers held down again without ever dropping the trigger.
    harness.controller.handleActivationDeadline(generation: 2)
    #expect(harness.presenter.openCount == 1)

    harness.controller.handleModifiers([])
    harness.activate(generation: 2)
    #expect(harness.presenter.openCount == 2)
}

@Test @MainActor func nothingEligibleLeavesTheWheelClosed() {
    let harness = Harness(capture: nil)

    harness.activate()

    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.openCount == 0)
    #expect(harness.box.commits.isEmpty)
}

/// Pointer jitter inside the hub is the cancel affordance, so it must not
/// select anything.
@Test @MainActor func pointerJitterInsideTheHubSelectsNothing() {
    let harness = Harness()
    harness.activate()

    harness.controller.handlePointer(BTPoint(x: anchor.x + 4, y: anchor.y - 3))
    #expect(harness.presenter.selection == nil)

    harness.release()
    #expect(harness.box.commits.isEmpty)
    #expect(harness.presenter.closeCount == 1)
}

@Test @MainActor func pointerDirectionSelectsTheDrawnSectorAndCommitsOnRelease() {
    let harness = Harness()
    harness.activate()

    // Straight up from the anchor, inside the inner ring.
    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))

    harness.release()
    #expect(harness.box.commits.count == 1)
    #expect(harness.box.commits.first?.0 == .windowAction(.topHalf))
    #expect(harness.box.commits.first?.1 == target.windowID)
    #expect(harness.presenter.closeCount == 1)
}

/// Releasing on the dead band between the rings cancels, exactly like the hub.
@Test @MainActor func releasingInTheDeadBandCancels() {
    let harness = Harness()
    harness.activate()
    let geometry = LayoutWheelMetrics.standard.geometry
    let deadBand = (geometry.innerRingOuterRadius + geometry.outerRingInnerRadius) / 2

    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - deadBand))
    #expect(harness.presenter.selection == nil)

    harness.release()
    #expect(harness.box.commits.isEmpty)
}

@Test @MainActor func releasingOnAnEmptySectorCancels() {
    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.innerSlots[LayoutWheelSector.top.rawValue] = nil
    let harness = Harness(configuration: configuration)
    harness.activate()

    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .inner, sector: .top))

    harness.release()
    #expect(harness.box.commits.isEmpty)
    #expect(harness.presenter.closeCount == 1)
}

/// A release, a repeated release, and a deactivation can all arrive for one
/// gesture. Only the first may act.
@Test @MainActor func duplicateReleaseAndDeactivationCommitExactlyOnce() {
    let harness = Harness()
    harness.activate()
    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))

    harness.release()
    harness.release()
    harness.controller.handleApplicationDeactivated()
    harness.controller.cancel()

    #expect(harness.box.commits.count == 1)
    #expect(harness.presenter.closeCount == 1)
    #expect(harness.box.endedCount == 1)
}

@Test @MainActor func escapeCancelsWithoutCommitting() {
    let harness = Harness()
    harness.activate()
    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))

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
@Test @MainActor func losingTheCapturedWindowCancelsAndNeverRetargets() {
    let harness = Harness()
    harness.activate()
    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))

    harness.controller.handleTargetLost(windowID: WindowID(rawValue: "other-window"))
    #expect(harness.controller.isOpen)

    harness.controller.handleTargetLost(windowID: target.windowID)
    #expect(!harness.controller.isOpen)

    harness.release()
    #expect(harness.box.commits.isEmpty)
}

@Test @MainActor func changingTheTriggerMidGestureCancels() {
    let harness = Harness()
    harness.activate()
    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))

    var configuration = BetterTileConfiguration()
    configuration.layoutWheel.keyboardModifiers = [.control, .shift]
    harness.controller.configuration = configuration

    #expect(!harness.controller.isOpen)
    #expect(harness.box.commits.isEmpty)
}

@Test @MainActor func disablingTheWheelMidGestureCancels() {
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
/// belongs to whatever shortcut the user actually pressed.
@Test @MainActor func extraModifiersDoNotOpenTheWheel() {
    let harness = Harness()

    harness.controller.handleModifiers([.control, .option, .command])
    #expect(!harness.controller.isPendingActivation)

    harness.controller.handleModifiers(trigger)
    #expect(harness.controller.isPendingActivation)
}

@Test @MainActor func keyboardMovesThroughRingsAndCommits() {
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

/// An unavailable command marks its sector and shows no placement. Release
/// emits the unavailable outcome so the app can report why without committing.
@Test @MainActor func anUnavailableCommandPreviewsNothingButStillReports() {
    let harness = Harness()
    harness.controller.previewHandler = { command, _ in
        command == .repairBento
            ? .unavailable(reason: "Repair Bento needs Bento mode.")
            : .ready(placements: [Placement(windowID: target.windowID, frame: BTRect(x: 0, y: 0, width: 10, height: 10))])
    }
    harness.activate()

    harness.controller.handleKey(.nextSector)
    harness.controller.handleKey(.switchRing)
    let shownBeforeRepairBento = harness.presenter.shownPlacements.count

    // Top left of the outer ring is Repair Bento by default.
    harness.controller.handleKey(.previousSector)
    #expect(harness.presenter.selection == LayoutWheelSelection(ring: .outer, sector: .topLeft))
    #expect(harness.presenter.presentations.last?.unavailableCommands == [.repairBento])
    // No new placement appeared for the command that cannot run.
    #expect(harness.presenter.shownPlacements.count == shownBeforeRepairBento)

    harness.controller.handleKey(.commit)
    #expect(harness.box.commits.isEmpty)
    #expect(harness.box.unavailable.first?.0 == "Repair Bento needs Bento mode.")
    #expect(harness.box.unavailable.first?.1 == target)
}

@Test @MainActor func aModifierMonitorRegistrationFailureIsReportedInline() {
    let controller = LayoutWheelController(
        configuration: BetterTileConfiguration(),
        presenter: FakePresenter(),
        addGlobalMonitor: { _, _ in nil },
        removeMonitor: { _ in }
    )
    var failure: String?
    controller.monitoringFailureHandler = { failure = $0 }

    controller.start()

    #expect(failure == "BetterTile could not monitor the Layout Wheel modifier trigger.")
    #expect(!controller.isPendingActivation)
    #expect(!controller.isOpen)
}

@Test @MainActor func availableCommandsShowTheirPlacements() {
    let harness = Harness()
    let placement = Placement(windowID: target.windowID, frame: BTRect(x: 0, y: 0, width: 800, height: 500))
    harness.controller.previewHandler = { _, _ in .ready(placements: [placement]) }
    harness.activate()

    harness.controller.handlePointer(BTPoint(x: anchor.x, y: anchor.y - 70))

    #expect(harness.presenter.shownPlacements.last == [placement])
}

/// Stopping the controller has to leave nothing open behind it.
@Test @MainActor func stoppingClosesAnOpenWheel() {
    let harness = Harness()
    harness.activate()

    harness.controller.stop()

    #expect(!harness.controller.isOpen)
    #expect(harness.presenter.closeCount == 1)
}

@Test @MainActor func suspendingRemovesEveryKeyboardMonitorAndResumeRestoresOnlyTheTrigger() {
    var addedMasks: [NSEvent.EventTypeMask] = []
    var removed = 0
    let controller = LayoutWheelController(
        configuration: BetterTileConfiguration(),
        presenter: FakePresenter(),
        pointerProvider: { anchor },
        addGlobalMonitor: { mask, _ in
            addedMasks.append(mask)
            return NSObject()
        },
        removeMonitor: { _ in removed += 1 }
    )
    controller.captureHandler = { target }
    controller.previewHandler = { _, _ in .ready(placements: []) }
    controller.start()
    controller.handleModifiers(trigger)
    controller.handleActivationDeadline(generation: 1)

    #expect(controller.isOpen)
    #expect(addedMasks.contains(.flagsChanged))
    #expect(addedMasks.contains(.keyDown))
    #expect(addedMasks.contains { $0.contains(.mouseMoved) })

    controller.suspend()

    #expect(!controller.isOpen)
    #expect(removed == 3)
    controller.handleModifiers(trigger)
    #expect(!controller.isPendingActivation)

    controller.resume()
    #expect(addedMasks.filter { $0 == .flagsChanged }.count == 2)
    #expect(addedMasks.filter { $0 == .keyDown }.count == 1)
}
