import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct ModelCacheLifetimeTests {
    private func fields(_ model: BetterTileModel, _ name: String) -> [Any] {
        guard let value = Mirror(reflecting: model).children.first(where: {
            $0.label?.trimmingCharacters(in: CharacterSet(charactersIn: "_")) == name
        })?.value else { return [] }
        return Mirror(reflecting: value).children.map(\.value)
    }

    @Test func closureDuringASpaceSwitchReleasesThePreviousOwnersAdaptiveEvidence() async throws {
        let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
        let display = system.mainDisplay.id
        let one = NativeSpaceID(rawValue: 1), two = NativeSpaceID(rawValue: 2)
        let survivor = system.windows[0]
        let closing = WindowSnapshot(id: .init(rawValue: "closing"), processIdentifier: 43,
            frame: survivor.frame, displayID: display)
        let other = WindowSnapshot(id: .init(rawValue: "other"), processIdentifier: 44,
            frame: survivor.frame, displayID: display)
        system.windows.append(closing)
        system.desktopObservation = .init(currentSpaceByDisplay: [display: one],
            knownSpacesByDisplay: [display: [one, two]],
            windowMembership: [survivor.id: [one], closing.id: [one], other.id: [two]])
        let model = makeOffscreenModel(system: system, presentsTabbedChrome: false)
        defer { model.shutdown() }
        system.installWindowEventClock(in: model)
        model.primaryButtonIsPressed = { false }
        model.displayChangeScreenIsLocked = { false }
        func previous() -> LayoutSession? {
            let store = Mirror(reflecting: model).children.first {
                $0.label?.hasSuffix("sessionStore") == true
            }?.value as? LayoutSessionStore
            return store?.allSessions(for: display).first { $0.nativeSpaceID == one }
        }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })
        let index = try #require(system.windows.firstIndex { $0.id == closing.id })
        system.windows[index].isMinimized = true
        system.eventHandler?(.init(kind: .minimized, windowID: closing.id, processIdentifier: 43))
        try #require(await system.waitFor { previous()?.bentoReinsertionAnchors[closing.id] != nil })
        system.windows = [other]
        system.focusedID = other.id
        system.desktopObservation?.currentSpaceByDisplay[display] = two
        system.desktopObservation?.windowMembership[closing.id] = nil
        // The destruction notification can precede the Space notification.
        // Leave the active reducer's state unchanged until ownership settles.
        system.eventHandler?(.init(kind: .destroyed, windowID: closing.id, processIdentifier: 43))
        #expect(previous()?.bentoReinsertionAnchors[closing.id] != nil)
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace })
        #expect(previous()?.bentoReinsertionAnchors[closing.id] == nil)
        #expect(previous()?.bentoState.root?.windowIDs == [survivor.id])
    }

    @Test func tabbedUndoKeepsInactiveSpacesAndReleasesRemovedSpaceOwners() async throws {
        let system = makeManualWindowSystem(drivingPolicyDeadlines: true)
        let first = system.windows
        let display = system.mainDisplay.id
        let one = NativeSpaceID(rawValue: 1), two = NativeSpaceID(rawValue: 2)
        let second = WindowSnapshot(id: .init(rawValue: "other-space"), processIdentifier: 43,
            frame: first[0].frame, displayID: display)
        system.desktopObservation = .init(currentSpaceByDisplay: [display: one],
            knownSpacesByDisplay: [display: [one, two]],
            windowMembership: [first[0].id: [one], second.id: [two]])
        let model = makeOffscreenModel(system: system, presentsTabbedChrome: false)
        defer { model.shutdown() }
        system.installWindowEventClock(in: model)
        model.primaryButtonIsPressed = { false }
        model.displayChangeScreenIsLocked = { false }
        for space in [one, two] {
            system.windows = space == one ? first : [second]
            system.focusedID = system.windows[0].id
            system.desktopObservation?.currentSpaceByDisplay[display] = space
            model.beginActiveSpaceStabilization()
            try #require(await system.waitFor { !model.isStabilizingSpace })
            model.setActiveMode(.tabbed)
            try #require(await system.waitFor { !model.hasPendingTabbedPlacement && model.activeTabbedState != nil })
            await system.advance(by: .milliseconds(350))
            model.performTabbed(.preset(.rows, grouping: .distributeWindows))
            try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        }
        #expect(fields(model, "tabbedUndo").count == 2)
        system.desktopObservation?.knownSpacesByDisplay[display] = [two]
        model.beginActiveSpaceStabilization()
        try #require(await system.waitFor { !model.isStabilizingSpace && !model.hasPendingTabbedPlacement })
        #expect(fields(model, "tabbedUndo").count == 1)
        let before = model.activeTabbedState
        model.performTabbed(.undo)
        try #require(await system.waitFor { !model.hasPendingTabbedPlacement })
        #expect(model.activeTabbedState != before)
    }
}
