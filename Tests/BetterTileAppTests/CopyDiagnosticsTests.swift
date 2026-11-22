import AppKit
import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

@Suite(.appTestApplication, .serialized) @MainActor
struct CopyDiagnosticsTests {
    /// Window titles, app identities, Saved Layout names, paths and display
    /// UUIDs reach the model through the fake window system and the
    /// configuration. Copy Diagnostics puts a report on the pasteboard that
    /// has none of them.
    @Test func copiesAReportWithoutIdentifyingValues() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        system.availableDisplays = [DisplaySnapshot(
            id: system.mainDisplay.id, frame: system.mainDisplay.frame, visibleFrame: system.mainDisplay.visibleFrame,
            scaleFactor: 2, isMain: true, persistentIdentifier: "37D8832A-2D66-02CA-B9F7-8F30A301B230")]
        system.windows[0].title = "Quarterly Plan.docx — /Users/alex/Documents"
        system.windows[0].bundleIdentifier = "com.secret.Editor"
        system.windows.append(WindowSnapshot(
            id: WindowID(rawValue: "peer"), processIdentifier: 43, bundleIdentifier: "org.example.Private",
            title: "Board Meeting Notes", frame: BTRect(x: 500, y: 0, width: 500, height: 800),
            displayID: system.mainDisplay.id))
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.updateConfiguration {
            $0.applicationRules.set(.excludeFromBento, for: "com.example.Ignored")
            $0.layoutWheel.savedLayouts = [LayoutWheelSavedLayout(file: "/Users/alex/Layouts/board.json",
                                                                   name: "Board Meeting Layout")]
        }
        model.setActiveMode(.bento)
        try #require(await system.waitFor { model.settlementTasks.isEmpty })

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)

        #expect(CopyDiagnosticsCommand.perform(model: model, automaticUpdateChecks: false, pasteboard: pasteboard))

        let text = try #require(pasteboard.string(forType: .string))
        #expect(text.hasPrefix("BetterTile diagnostics\n"))
        #expect(text.contains("Display 1 (main): 1000 × 800 pt, scale 2x, origin 0, 0\n"))
        #expect(text.contains("  Mode: Adaptive\n"))
        #expect(text.contains("  Managed windows: 2, automatic floats: 0\n"))
        #expect(text.contains("Accessibility permission: Granted\n"))
        #expect(text.contains("Update checks: Manual\n"))
        #expect(text.contains("App rules: 1\n"))
        for secret in ["Quarterly Plan", "/Users/alex", "Documents", "com.secret.Editor", "org.example.Private",
                       "com.example.Ignored", "Board Meeting", "board.json", "37D8832A-2D66-02CA-B9F7-8F30A301B230",
                       "focused", "peer", NSUserName(), ProcessInfo.processInfo.hostName] where !secret.isEmpty {
            #expect(!text.contains(secret), "\(secret)")
        }

        // The confirmation is a Result pill, and it is not itself a recent result.
        #expect(model.lastActionFeedback?.message == "Diagnostics copied")
        #expect(model.lastActionFeedback?.kind == .success)
        #expect(!model.diagnosticsResults.entries.contains { $0.message == "Diagnostics copied" })
        #expect(CopyDiagnosticsCommand.menuTitle == "Copy Diagnostics")
    }

    /// The model records each Result pill as it shows it.
    @Test func recentResultsComeFromShownPills() async throws {
        _ = NSApplication.shared
        let system = FakeAppWindowSystem()
        let model = makeModel(system: system)
        defer { model.shutdown() }
        model.setActiveMode(.manual)
        model.perform(.nextTab)
        let shown = try #require(model.lastActionFeedback)
        #expect(model.diagnosticsResults.entries.last?.kind == .failure)
        #expect(model.diagnosticsResults.entries.last?.message == shown.message)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        CopyDiagnosticsCommand.perform(model: model, automaticUpdateChecks: nil, pasteboard: pasteboard)
        let text = try #require(pasteboard.string(forType: .string))
        #expect(text.hasSuffix("Recent results, newest first\nFailure: \(shown.message)\n"))
    }
}
