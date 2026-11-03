import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

/// Render production views against explicit design references. No desktop windows are ordered.
@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct SavedLayoutDesignSystemSnapshotTests {
    @Test(arguments: [false, true], [false, true])
    func editorMessageRendersItsSeverity(dark: Bool, failure: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = SavedLayoutEditor(files: .init(directory: directory))
        editor.newLayout()
        #expect(editor.save(as: "Work"))
        if failure {
            // Exporting over the library file is a real rejected operation, without live windows.
            editor.export(to: try #require(editor.url))
        }
        let message = try #require(editor.message)
        #expect(message.contains(failure ? "Couldn’t export" : "Saved locally"))
        try compare(SavedLayoutSettings(editor: editor).editorMessageNotice,
                    NoticeBanner(failure ? .warning : .info, title: message).textSelection(.enabled),
                    dark: dark, name: "editor-message-\(failure ? "failure" : "success")")
    }

    @Test(arguments: [false, true])
    func shapeMenuRendersItsCaptionAndPill(dark: Bool) throws {
        let editor = SavedLayoutEditor(files: .init(directory: FileManager.default.temporaryDirectory))
        let layout = SavedLayoutCanvas.presetLayout(.focus, panes: [])
        let actual = SavedLayoutSettings(editor: editor).shapeMenu(layout)
        let expected = Menu { Button("Main + 2") {} } label: {
            Text("Main + 2").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 1).fixedSize()
        }
        .menuStyle(.button).buttonStyle(.borderless).controlSize(.small).fixedSize()
        .background(Color(nsColor: .tertiarySystemFill), in: Capsule())
        try compare(actual, expected, dark: dark, name: "shape-menu")
    }

    /// The scaled MacBook tile used to be 74 × 48 pt. Its two-line name crossed the top border.
    /// The reference has 8 pt insets and room for two name lines and two status lines at 11 pt.
    @Test(arguments: [false, true], [false, true])
    func displayNameRendersFullyInsideTile(dark: Bool, target: Bool) throws {
        let name = target ? "Studio Display – Left" : "MacBook Pro"
        let width: CGFloat = target ? 112 : 74
        let actual = DisplaySetTile(name: name, caption: "Connected", isTarget: target, connected: true,
                                    detail: "", width: width, height: 48)
        let expected = VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Connected").font(.system(size: 11)).foregroundStyle(target ? Color.accentColor : .secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8).frame(width: width, height: 80, alignment: .bottomLeading)
        .background(target ? Color.accentColor.opacity(0.14) : Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(target ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.5))
        try compare(actual, expected, dark: dark, name: "display-name-inset-\(target ? "target" : "secondary")")
    }

    @Test(arguments: [false, true])
    func lastRunRendersCaptionAndStatusPill(dark: Bool) throws {
        let run = SavedLayoutRun(layoutName: "Work", offersUndo: false, date: .distantPast,
                                 displayID: .init(rawValue: "1"), result: .init(placed: 2))
        let actual = DisplayTriggerLastRun(run: run, applier: nil).statusPill
        let expected = Text(run.status.rawValue)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsColor.green)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(SettingsColor.green.opacity(0.16), in: Capsule()).fixedSize()
        try compare(actual, expected, dark: dark, name: "last-run-pill")
    }

    private func compare(_ actualView: some View, _ expectedView: some View, dark: Bool, name: String) throws {
        let actual = try SettingsSnapshotHost(actualView, dark: dark, width: 240, height: 160, fitHeight: false)
        defer { actual.close() }
        let expected = try SettingsSnapshotHost(expectedView, dark: dark, width: 240, height: 160, fitHeight: false)
        defer { expected.close() }
        let actualPNG = try #require(actual.render().representation(using: .png, properties: [:]))
        let expectedPNG = try #require(expected.render().representation(using: .png, properties: [:]))
        if let output = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] {
            let url = URL(filePath: output).appending(path: "\(name)-\(dark ? "dark" : "light").png")
            try actualPNG.write(to: url)
        }
        #expect(actualPNG == expectedPNG, "\(name) must render the specified text, insets, and shape")
    }
}
