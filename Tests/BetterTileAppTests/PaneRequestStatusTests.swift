import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
import SwiftUI
@testable import BetterTileApp

@Suite(.appTestApplication) @MainActor struct PaneRequestStatusTests {
    @Test func phasesMapToPaneStatus() throws {
        let request = PaneApplicationRequest(paneID: UUID(), paneNumber: 2, displayID: DisplayID(rawValue: "test"),
            sessionID: DesktopSessionID(rawValue: UUID()), spaceID: nil, generation: 0,
            workArea: BTRect(x: 0, y: 0, width: 1000, height: 800))
        request.application = ApplicationChoice(bundleIdentifier: "safari", name: "Safari", url: URL(filePath: "/fixture/Safari.app"))
        #expect(request.status == nil)
        request.phase = .waiting
        #expect(request.status?.kind == .opening(launching: false))
        #expect(request.status?.message == "")
        request.launching = true
        #expect(request.status?.message == "")
        let window = WindowSnapshot(id: WindowID(rawValue: "window"), processIdentifier: 42, title: "",
            frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: request.displayID)
        request.existingWindows = [window]
        let entries = [PaneRequestWindow(id: window.id, title: "Safari")]
        request.phase = .fallback("An earlier request may still open a window.")
        #expect(request.status?.kind == .other(message: "An earlier request may still open a window.", windows: entries))
        request.fallbackReason = .arrived
        request.arrivals = [window.id]
        #expect(request.status?.kind == .awaitingClick(entries))
        #expect(request.status?.headline == "Choose a Safari window")
        request.fallbackReason = .unsupported
        #expect(request.status?.kind == .noNewWindow(entries))
        #expect(request.status?.headline == "Safari didn't offer a new window")
        request.fallbackReason = .timedOut
        #expect(request.status?.kind == .timedOut(showingWindows: false, windows: entries))
        request.showingWindows = true
        #expect(request.status?.kind == .timedOut(showingWindows: true, windows: entries))
        request.fallbackReason = .failed
        #expect(request.status?.kind == .failed)
        request.fallbackReason = .severalCopies
        request.instances = [.init(processIdentifier: 42, launchDate: nil), .init(processIdentifier: 43, launchDate: Date(timeIntervalSince1970: 1))]
        guard case let .severalCopies(groups) = request.status?.kind else { Issue.record("Expected groups"); return }
        #expect(request.status?.headline == "Several copies are running")
        #expect(groups[0].label == "Copy 1")
        #expect(groups[0].windows == entries)
        #expect(groups[1].label.hasPrefix("Copy started "))
        #expect(groups[1].windows.isEmpty)
        request.phase = .placing(window.id)
        #expect(request.status?.kind == .opening(launching: true))
        #expect(request.status?.headline == "Opening Safari…")
        #expect(request.status?.message == "")
    }

    @Test func fallbackSingleWindowHasOneDirectActionAndNoTimingCopy() {
        let window = PaneRequestWindow(id: WindowID(rawValue: "one"), title: "Notes")
        let kinds: [PaneRequestStatus.Kind] = [.awaitingClick([window]), .noNewWindow([window]),
            .timedOut(showingWindows: false, windows: [window]), .other(message: "Choose a window.", windows: [window]),
            .severalCopies([.init(label: "Copy 1", windows: [window]), .init(label: "Copy 2", windows: [])])]
        for kind in kinds {
            let status = PaneRequestStatus(requestID: UUID(), paneID: UUID(), appName: "Notes", kind: kind)
            #expect(status.singleWindow == window)
            #expect(status.singleWindowButtonTitle == "Use “Notes”")
            #expect(!status.message.contains("seconds") && !status.message.contains("minute"))
        }
        let multiple = PaneRequestStatus(requestID: UUID(), paneID: UUID(), appName: "Notes",
            kind: .noNewWindow([window, .init(id: WindowID(rawValue: "two"), title: "Second")]))
        #expect(multiple.singleWindow == nil)
        let untitled = PaneRequestStatus(requestID: UUID(), paneID: UUID(), appName: "Notes",
            kind: .noNewWindow([.init(id: window.id, title: "")]))
        #expect(untitled.singleWindowButtonTitle == "Use “Notes”")
    }

    @Test func unresolvedCreationTokensKeepTheirOriginalArrivalOrder() {
        var arrivals = ApplicationRequestArrivalOrder()
        let earlier = WindowID(rawValue: "z-earlier")
        let later = WindowID(rawValue: "a-later")
        arrivals.created(id: nil, token: 10)
        arrivals.created(id: later, token: 11)
        arrivals.resolve(earlier, token: 10)
        #expect(arrivals.ids == [earlier, later])
    }

    @Test func firstObservationKeepsOrderWithoutCreationCallbacks() {
        var arrivals = ApplicationRequestArrivalOrder()
        let windows = ["z-earlier", "a-later"].map {
            WindowSnapshot(id: WindowID(rawValue: $0), processIdentifier: 42,
                frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: DisplayID(rawValue: "test"))
        }
        arrivals.observe(windows)
        arrivals.observe(windows.reversed())
        #expect(arrivals.ids == windows.map(\.id))
    }

    /// Offline rendering only. Never order a window or launch the app.
    @Test(arguments: [false, true])
    func requestFeedbackRendersOffscreen(dark: Bool) throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_PANE_REQUEST_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let window = PaneRequestWindow(id: WindowID(rawValue: "one"), title: "Quarterly planning")
        let scenes: [(String, PaneRequestStatus.Kind)] = [
            ("opening", .opening(launching: false)), ("still-opening", .stillOpening),
            ("one-window", .awaitingClick([window])),
            ("one-window-long-title", .noNewWindow([.init(id: window.id, title: "Quarterly planning – a long document name that must stay inside this pane")])),
            ("timed-out", .timedOut(showingWindows: false, windows: [])),
            ("timed-out-one-window", .timedOut(showingWindows: false, windows: [window]))]
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, kind) in scenes {
            let status = PaneRequestStatus(requestID: UUID(), paneID: UUID(), appName: "Safari",
                appIconURL: URL(filePath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"), kind: kind)
            let view = NSHostingView(rootView: PaneRequestStatusBody(status: status, action: { _ in })
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .active))
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.appearance = appearance
            view.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
            let host = OffscreenTestWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.appearance = appearance
            host.contentView = view
            defer { host.close() }
            for _ in 0..<4 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) } // real-time: AppKit must lay out and render the hosted status view
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func presetTitlesAndGallerySelection() {
        #expect(TabbedPreset.allCases.map(\.title) == ["Single Pane", "2 Columns", "2 Rows", "Main + 2", "2×2 Grid"])
    }
}

@Test(.appTestApplication, arguments: ["unrecorded", "desktopChanged"]) @MainActor
func paneRequestSecurityAutomaticArrivalRejectsUnrequestedWindows(reason: String) {
    let display = DisplayID(rawValue: "test")
    let space = NativeSpaceID(rawValue: 1)
    let window = WindowSnapshot(id: WindowID(rawValue: "new"), processIdentifier: 42,
        bundleIdentifier: "test.app", frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: display)
    let observation = NativeDesktopObservation(currentSpaceByDisplay: [display: NativeSpaceID(rawValue: 2)],
        knownSpacesByDisplay: [display: [space, NativeSpaceID(rawValue: 2)]], windowMembership: [window.id: [space]])
    #expect(PaneApplicationRequest.automaticArrival(in: [window], applicationID: "test.app", processIdentifier: 42,
        baseline: [], displayID: display, spaceID: space, observation: reason == "desktopChanged" ? observation : nil,
        arrivalOrder: reason == "unrecorded" ? [] : [window.id], createdAfterRequest: [window.id]) == nil)
}

@Test(.appTestApplication, arguments: ["valid", "pid", "bundle", "baseline", "uncreated", "unrecorded", "display", "desktop", "multiSpace",
    "hidden", "minimized", "fullscreen", "floating", "immovable", "fixed", "fullscreenSpace"]) @MainActor
func paneRequestSecurityAutomaticArrivalEnforcesEveryFilter(reason: String) {
    let display = DisplayID(rawValue: "test")
    let space = NativeSpaceID(rawValue: 1)
    let otherSpace = NativeSpaceID(rawValue: 2)
    var window = WindowSnapshot(id: WindowID(rawValue: "candidate"), processIdentifier: reason == "pid" ? 43 : 42,
        bundleIdentifier: reason == "bundle" ? "other.app" : "test.app",
        frame: BTRect(x: 0, y: 0, width: 400, height: 300), displayID: reason == "display" ? .init(rawValue: "other") : display)
    window.isHidden = reason == "hidden"; window.isMinimized = reason == "minimized"
    window.isFullScreen = reason == "fullscreen"; window.isFloating = reason == "floating"
    window.constraints.isMovable = reason != "immovable"; window.constraints.isResizable = reason != "fixed"
    let membership: Set<NativeSpaceID> = reason == "desktop" ? [otherSpace] : reason == "multiSpace" ? [space, otherSpace] : [space]
    let observation = NativeDesktopObservation(currentSpaceByDisplay: [display: space],
        knownSpacesByDisplay: [display: [space, otherSpace]], windowMembership: [window.id: membership],
        fullscreenSpaceIDs: reason == "fullscreenSpace" ? [space] : [])
    let arrival = PaneApplicationRequest.automaticArrival(in: [window], applicationID: "test.app", processIdentifier: 42,
        baseline: reason == "baseline" ? [window.id] : [], displayID: display, spaceID: space, observation: observation,
        arrivalOrder: reason == "unrecorded" ? [] : [window.id], createdAfterRequest: reason == "uncreated" ? [] : [window.id])
    #expect(arrival?.id == (reason == "valid" ? window.id : nil))
}
