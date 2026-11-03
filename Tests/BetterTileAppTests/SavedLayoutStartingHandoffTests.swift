import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .settingsUI, .serialized) @MainActor
struct SavedLayoutStartingHandoffTests {
    @Test func panelAfterFastSettingsRunKeepsApplyingThroughSharedStartup() async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let applier = try #require(f.model.savedLayoutApplier)
        let session = SavedLayoutApplySession(applier: applier)
        let originalFinish = applier.didFinish
        defer { applier.didFinish = originalFinish }
        var bodyWhileStarting: AnyView?
        applier.didFinish = {
            originalFinish()
            guard session.isStarting else { return }
            #expect(applier.isApplying && applier.isBusy)
            if case .applying = session.phase {} else { Issue.record("Settings must keep Applying during startup") }
            #expect(session.run == nil && !session.canUndo)
            bodyWhileStarting = AnyView(SavedLayoutPanelRun(model: f.model).body)
        }
        session.apply(document: f.document, displayID: f.other.id)
        try await waitForSavedLayoutState("The fast Settings run did not finish startup.") {
            !session.isStarting && !applier.isBusy && applier.lastRun != nil
        }
        let pendingBody = try #require(bodyWhileStarting, "The production run must reach the completed/startup overlap.")
        let actual = try SettingsSnapshotHost(pendingBody, dark: false, width: 300, height: 80, fitHeight: false)
        defer { actual.close() }
        let expected = try SettingsSnapshotHost(VStack(alignment: .leading, spacing: 6) {
            Text("Applying…").fontWeight(.semibold)
        }.font(SettingsFont.caption), dark: false, width: 300, height: 80, fitHeight: false)
        defer { expected.close() }
        let completed = try SettingsSnapshotHost(AnyView(SavedLayoutPanelRun(model: f.model).body),
            dark: false, width: 300, height: 80, fitHeight: false)
        defer { completed.close() }
        let actualPNG = try #require(actual.render().representation(using: .png, properties: [:]))
        let expectedPNG = try #require(expected.render().representation(using: .png, properties: [:]))
        let completedPNG = try #require(completed.render().representation(using: .png, properties: [:]))
        #expect(actualPNG == expectedPNG)
        #expect(actualPNG != completedPNG)
        #expect(session.run?.date == applier.lastRun?.date)
        #expect(session.canUndo)
    }

    @Test(arguments: [false, true])
    func outsideApplyRefusesFastSettingsStartupAndPreservesRunAndUndo(wheel: Bool) async throws {
        let f = try SavedLayoutActionFixture(); defer { f.close() }
        let applier = try #require(f.model.savedLayoutApplier)
        let session = SavedLayoutApplySession(applier: applier)
        let before = f.system.windows
        let originalFinish = applier.didFinish
        defer { applier.didFinish = originalFinish }
        var attempted = false
        var accepted: Bool?
        var reason: String?
        let wheelTarget = try #require(f.model.captureLayoutWheelTarget())
        var originalRun: Date?
        var writesAtFinish: [WindowID: Int]?
        applier.didFinish = {
            originalFinish()
            guard !attempted, session.isStarting else { return }
            attempted = true
            originalRun = applier.lastRun?.date
            writesAtFinish = f.system.frameWriteCounts
            if wheel {
                f.model.performLayoutWheel(.savedLayout(file: f.url.lastPathComponent, name: f.document.name), for: wheelTarget)
            } else {
                accepted = f.model.applySavedLayoutAction(f.url.lastPathComponent)
            }
            reason = f.model.savedLayoutActions.message
        }
        session.apply(document: f.document, displayID: f.other.id)
        try await waitForSavedLayoutState("The Apply tasks did not finish startup.") {
            attempted && !session.isStarting && !applier.isBusy && applier.lastRun != nil
        }
        #expect(attempted)
        if !wheel { #expect(accepted == false) }
        #expect(reason == "Another layout is applying. Try again when it finishes.")
        #expect(applier.lastRun?.date == originalRun)
        #expect(f.system.frameWriteCounts == writesAtFinish)
        #expect(session.canUndo)
        guard session.canUndo else { return }
        session.undo()
        try await waitForSavedLayoutState("Undo did not restore the original windows.") {
            !applier.isBusy && !applier.canUndo
        }
        #expect(f.system.windows.map(\.id) == before.map(\.id))
        #expect(f.system.windows.map(\.frame) == before.map(\.frame))
        #expect(f.system.windows.map(\.displayID) == before.map(\.displayID))
    }
}
