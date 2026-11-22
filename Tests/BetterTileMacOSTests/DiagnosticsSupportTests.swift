import AppKit
import Testing
import BetterTileTestSupport
@testable import BetterTileCore
@testable import BetterTileMacOS

@Suite(.macOSTestApplication) @MainActor
struct DiagnosticsSupportTests {
    @Test func writesPlainTextAndReplacesEarlierContents() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("earlier", forType: .string)
        pasteboard.setData(Data([1, 2, 3]), forType: .png)

        #expect(DiagnosticsPasteboard.write("BetterTile diagnostics\n", to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "BetterTile diagnostics\n")
        #expect(pasteboard.data(forType: .png) == nil)
    }

    @Test func readsVersionsArchitectureAndThePrivateAPISwitch() {
        let defaults = PrivateAPISwitchDefaults()
        defaults.set(true, forKey: "disablePrivateAPIs")

        let environment = DiagnosticsEnvironmentReader.current(
            accessibilityGranted: false, automaticUpdateChecks: false, defaults: defaults)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #expect(environment.macOSVersion.hasPrefix("\(version.majorVersion).\(version.minorVersion)"))
        #expect(environment.macOSBuild != "unknown" && !environment.macOSBuild.isEmpty)
        #expect(["arm64", "x86_64", "x86_64 (under Rosetta)"].contains(environment.architecture))
        #expect(environment.privateAPIsDisabled)
        #expect(!environment.accessibilityGranted)
        #expect(environment.automaticUpdateChecks == false)

        defaults.set(false, forKey: "disablePrivateAPIs")
        #expect(!DiagnosticsEnvironmentReader.current(
            accessibilityGranted: true, automaticUpdateChecks: nil, defaults: defaults).privateAPIsDisabled)
    }

    /// `ResultPillFeedback.failure(_:)` reduces each error to a fixed title.
    /// Each title must stay reportable, so the log keeps in step with it.
    @Test(arguments: [
        "Accessibility permission is required.", "BetterTile is set to ignore this app.",
        "Tab commands work on Tabbed desktops.", "Focus a tab to use tab commands.",
        "Repair Layout is available only on an Adaptive desktop.", "No eligible focused window.",
        "Adaptive holds up to six windows.", "The windows cannot fit their minimum size.",
        "The window refused its Tabbed size.", "Choose Single Pane in Layout Gallery.", "Use Tabbed Undo.",
        "Float the window to use this action.", "Choose Repair Layout.", "The desktop changed.",
        "The captured window is no longer available.", "Quarterly Plan.docx failed for an unknown reason",
    ])
    func everyNormalizedFailureTitleIsReportable(error: String) {
        let feedback = ResultPillFeedback.failure(error)
        #expect(DiagnosticsResultLog.reportableTitle(feedback.message) == feedback.message, "\(feedback.message)")
    }

    @Test func recordsKindAndFixedTitleButNeverTheDetail() {
        var log = DiagnosticsResultLog()
        log.record(ResultPillFeedback.failure("Quarterly Plan.docx cannot fit its minimum size."))
        log.record(.failure(title: ResultPillLayout.title(naming: "Quarterly Plan.docx") { "\($0) is floating" },
                            detail: "Drag Quarterly Plan.docx into a pane."))
        log.record(.layoutResult(title: "Board Meeting applied", detail: "Safari stayed in place.",
                                 kind: .warning, actions: []))
        #expect(log.entries == [
            DiagnosticsResult(kind: .failure, message: "Can’t fit this layout"),
            DiagnosticsResult(kind: .failure, message: nil),
            DiagnosticsResult(kind: .warning, message: nil),
        ])
    }
}

/// Keeps values in memory, so the test leaves no preferences file behind.
private final class PrivateAPISwitchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Bool] = [:]
    override func bool(forKey key: String) -> Bool { values[key] ?? false }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
}
