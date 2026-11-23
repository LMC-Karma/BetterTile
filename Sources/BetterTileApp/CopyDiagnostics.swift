import AppKit
import BetterTileCore
import BetterTileMacOS

/// Copy Diagnostics: the user asks for a plain-text report, and BetterTile
/// puts it on the pasteboard and confirms with a Result pill. Nothing is sent,
/// saved or logged. The user decides whether to paste it into a bug report.
@MainActor enum CopyDiagnosticsCommand {
    /// The menu item's title, next to Send Feedback….
    static let menuTitle = "Copy Diagnostics"

    @discardableResult
    static func perform(model: BetterTileModel, automaticUpdateChecks: Bool?,
                        pasteboard: NSPasteboard = .general, bundle: Bundle = .main) -> Bool {
        let environment = DiagnosticsEnvironmentReader.current(
            accessibilityGranted: model.hasAccessibilityPermission,
            automaticUpdateChecks: automaticUpdateChecks,
            bundle: bundle
        )
        let copied = DiagnosticsPasteboard.write(model.diagnosticsReport(environment: environment).text,
                                                 to: pasteboard)
        model.presentDiagnosticsCopyResult(copied: copied)
        return copied
    }
}
