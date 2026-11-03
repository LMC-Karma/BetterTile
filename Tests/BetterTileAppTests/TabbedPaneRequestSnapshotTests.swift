import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@Suite(.appTestApplication, .serialized) @MainActor struct TabbedPaneRequestSnapshotTests {
    private func render(_ view: NSView, size: NSSize, name: String, dark: Bool, directory: URL) async throws {
        let window = OffscreenTestWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.appearance = window.appearance
        view.frame = NSRect(origin: .zero, size: size)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120)) // real-time: advances hosted SwiftUI layout and native presentation before snapshot capture
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window.appearance!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
        #expect(!window.isVisible)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"] != nil))
    func snapshots() async throws {
        _ = NSApplication.shared
        let directory = URL(filePath: try #require(ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paneID = UUID()
        let app = ApplicationChoice(bundleIdentifier: "fixture.safari", name: "Safari", url: URL(filePath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"))
        let apps = [app, ApplicationChoice(bundleIdentifier: "fixture.notes", name: "Notes", url: URL(filePath: "/System/Applications/Notes.app")),
                    ApplicationChoice(bundleIdentifier: "fixture.terminal", name: "Terminal", url: URL(filePath: "/System/Applications/Utilities/Terminal.app")),
                    ApplicationChoice(bundleIdentifier: "fixture.mail", name: "Mail", url: URL(filePath: "/System/Applications/Mail.app"))]
        let windows = [PaneRequestWindow(id: WindowID(rawValue: "apple"), title: "Apple — Start Page"),
                       PaneRequestWindow(id: WindowID(rawValue: "docs"), title: "Docs — BetterTile Releases")]
        let kinds: [(String, PaneRequestStatus.Kind)] = [
            ("opening", .opening(launching: false)), ("click", .awaitingClick(windows)),
            ("no-new-window", .noNewWindow(windows)),
            ("several-copies", .severalCopies([.init(label: "Copy started 09:12", windows: [windows[0]]), .init(label: "Copy started 14:40", windows: [windows[1]])])),
            ("timed-out", .timedOut(showingWindows: false, windows: windows)), ("failed", .failed),
        ]
        for dark in [false, true] {
            for (name, size) in [("normal", NSSize(width: 500, height: 600)), ("small", NSSize(width: 300, height: 260))] {
                let empty = TabbedPaneView(frame: NSRect(origin: .zero, size: size))
                empty.number = 3
                try await render(empty, size: size, name: "pane-empty-\(name)", dark: dark, directory: directory)
                for (state, kind) in kinds {
                    let view = TabbedPaneView(frame: NSRect(origin: .zero, size: size))
                    view.number = 2
                    view.content.setRequestStatus(PaneRequestStatus(requestID: paneID, paneID: paneID, appName: "Safari", appIconURL: app.url, kind: kind))
                    try await render(view, size: size, name: "pane-\(state)-\(name)", dark: dark, directory: directory)
                }
            }
            for scene in ["default", "hovered", "selected"] {
                let gallery = TabbedLayoutGalleryView(current: .columns)
                if scene == "hovered" { gallery.choices[3].setHovering(true) }
                if scene == "selected" { gallery.select(.focus) }
                try await render(gallery, size: gallery.frame.size, name: "gallery-\(scene)", dark: dark, directory: directory)
            }
            for scene in ["plain", "running", "expanded", "long-names"] {
                let request = PaneApplicationRequest(paneID: paneID, paneNumber: 3, displayID: DisplayID(rawValue: "fixture"),
                    sessionID: DesktopSessionID(rawValue: UUID()), spaceID: nil, generation: 0,
                    workArea: BTRect(x: 0, y: 0, width: 1000, height: 800))
                if scene != "plain" {
                    request.windows = { choice in
                        choice.id == app.id ? windows.map { .init(id: $0.id.rawValue, title: $0.title) }
                            : choice.id == apps[1].id ? [] : nil
                    }
                }
                let recent = RecentApplications(defaults: MemoryDefaults())
                recent.record(apps[1].id); recent.record(app.id)
                let choices = scene == "long-names" ? [ApplicationChoice(bundleIdentifier: "fixture.long", name: "Microsoft Visual Studio Code — Insiders with a deliberately long application name", url: apps[2].url)] + apps : apps
                let host = NSHostingView(rootView: PaneApplicationPicker(request: request, installedApplications: { choices },
                    runningApplications: { [apps[1], app] }, recentApplications: recent)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                if scene == "expanded" {
                    let window = OffscreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    try #require(await waitFor { descendants(host).contains { $0 is NSSearchField } })
                    let field = try #require(descendants(host).compactMap { $0 as? NSSearchField }.first)
                    let delegate = try #require(field.delegate)
                    for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDown(_:)),
                                     #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDown(_:)),
                                     #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveDown(_:))] {
                        #expect(delegate.control?(field, textView: NSTextView(), doCommandBy: selector) == true)
                        try await Task.sleep(for: .milliseconds(30)) // real-time: advances hosted SwiftUI layout and native presentation before snapshot capture
                    }
                    window.contentView = nil
                    window.close()
                }
                try await render(host, size: NSSize(width: 320, height: 420), name: "picker-\(scene)", dark: dark, directory: directory)
            }
        }
    }
}
