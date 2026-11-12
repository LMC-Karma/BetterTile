import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test(.macOSTestApplication) func stageManagerThumbnailFramesAreRejected() {
    let full = BTRect(x: 100, y: 100, width: 800, height: 600)
    let decorated = BTRect(x: 100, y: 99, width: 800, height: 601)
    let thumbnail = BTRect(x: 20, y: 100, width: 160, height: 120)
    #expect(OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: decorated))
    #expect(!OnscreenWindowMatcher.matches(accessibilityFrame: full, windowServerFrame: thumbnail))
}

@Test(.macOSTestApplication) func windowSystemNeverManagesItsOwnApplicationWindows() {
    #expect(!AccessibilityWindowSystem.shouldManageApplication(
        processIdentifier: 42,
        ownProcessIdentifier: 42,
        activationPolicy: .regular,
        isHidden: false,
        includeHidden: false
    ))
    #expect(AccessibilityWindowSystem.shouldManageApplication(
        processIdentifier: 43,
        ownProcessIdentifier: 42,
        activationPolicy: .regular,
        isHidden: false,
        includeHidden: false
    ))
}

/// A failed read of a title-bar button, or of its enabled state, is not
/// evidence for a popup verdict; only an absent attribute is.
@Test(.macOSTestApplication) func popupButtonReadsMapFailuresToUnreadable() {
    typealias System = AccessibilityWindowSystem
    #expect(System.buttonState(reference: .attributeUnsupported, enabled: nil) == .missing)
    #expect(System.buttonState(reference: .noValue, enabled: nil) == .missing)
    #expect(System.buttonState(reference: .cannotComplete, enabled: nil) == .unreadable)
    #expect(System.buttonState(reference: .success, enabled: (.success, false)) == .disabled)
    #expect(System.buttonState(reference: .success, enabled: (.success, true)) == .enabled)
    #expect(System.buttonState(reference: .success, enabled: (.attributeUnsupported, nil)) == .enabled)
    #expect(System.buttonState(reference: .success, enabled: (.cannotComplete, nil)) == .unreadable)
}

/// A process that quits takes its applications' seeds with it: those of the
/// windows it had and the one its launch record names. Another application's
/// seed and every window's own measurement stay.
@Test(.macOSTestApplication) func aQuitProcessDropsItsApplicationsSeedsOnly() {
    var learner = WindowMinimumSizeLearner()
    let mail = WindowID(rawValue: "mail"), notes = WindowID(rawValue: "notes")
    func measure(_ id: WindowID, _ application: String) {
        _ = learner.observeWriteReadback(windowID: id, application: application,
            requested: BTRect(x: 0, y: 0, width: 100, height: 100), previous: BTRect(x: 0, y: 0, width: 800, height: 600),
            actual: BTRect(x: 0, y: 0, width: 500, height: 375), now: 0)
    }
    measure(mail, "com.apple.mail")
    measure(notes, "com.apple.Notes")
    let keys = [mail: "com.apple.mail", notes: "com.apple.Notes"]

    let quit = AccessibilityWindowSystem.quitApplicationBundles(
        closedWindowIDs: [mail], applicationKeys: keys, launchBundleIdentifier: nil
    )
    #expect(quit == ["com.apple.mail"])
    #expect(AccessibilityWindowSystem.forgetSeeds(of: quit, in: &learner) == ["com.apple.mail"])
    #expect(learner.applicationSizes["com.apple.mail"] == nil)
    #expect(learner.applicationSizes["com.apple.Notes"] != nil)
    #expect(learner.hasMeasurement(for: mail))

    // A process that quit without windows is known by its launch record.
    let windowless = AccessibilityWindowSystem.quitApplicationBundles(
        closedWindowIDs: [], applicationKeys: keys, launchBundleIdentifier: "com.apple.Notes"
    )
    #expect(windowless == ["com.apple.Notes"])
    #expect(AccessibilityWindowSystem.forgetSeeds(of: windowless, in: &learner) == ["com.apple.Notes"])
    #expect(learner.applicationSizes.isEmpty)
    // Nothing left to drop.
    #expect(AccessibilityWindowSystem.forgetSeeds(of: windowless, in: &learner).isEmpty)
}

/// A process registered without a name learns it from its own windows, so
/// its seed can be dropped when it quits; a named or older record does not.
@Test(.macOSTestApplication) func aLaunchRecordLearnsItsBundleIdentifierOnlyFromItsOwnLaunch() {
    let current = ApplicationLaunchInstance(processIdentifier: 42, generation: 2)
    let earlier = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    #expect(AccessibilityWindowSystem.recordLearnsBundleIdentifier(
        recordInstance: current, recordBundleIdentifier: nil, windowInstance: current))
    #expect(!AccessibilityWindowSystem.recordLearnsBundleIdentifier(
        recordInstance: current, recordBundleIdentifier: "com.apple.mail", windowInstance: current))
    #expect(!AccessibilityWindowSystem.recordLearnsBundleIdentifier(
        recordInstance: earlier, recordBundleIdentifier: nil, windowInstance: current))
}


/// A targeted read names the application as the complete inventory did. A fresh
/// per-PID LaunchServices lookup can answer without a bundle identifier while the
/// application runs, which made Saved Layout Apply refuse every pane before any write.
@Test(.macOSTestApplication) func aTargetedReadKeepsTheBundleIdentifierItsLaunchRecorded() {
    let current = ApplicationLaunchInstance(processIdentifier: 42, generation: 2)
    let earlier = ApplicationLaunchInstance(processIdentifier: 42, generation: 1)
    var lookups = 0
    let missing: () -> String? = { lookups += 1; return nil }
    #expect(AccessibilityWindowSystem.targetedReadBundleIdentifier(
        recordInstance: current, recordBundleIdentifier: "com.example.Fixture", windowInstance: current,
        lookUp: missing) == "com.example.Fixture")
    #expect(lookups == 0)
    // An unnamed record or another launch at the same PID proves nothing; ask LaunchServices.
    #expect(AccessibilityWindowSystem.targetedReadBundleIdentifier(
        recordInstance: current, recordBundleIdentifier: nil, windowInstance: current,
        lookUp: { "com.example.Fresh" }) == "com.example.Fresh")
    #expect(AccessibilityWindowSystem.targetedReadBundleIdentifier(
        recordInstance: earlier, recordBundleIdentifier: "com.example.Quit", windowInstance: current,
        lookUp: { "com.example.Fresh" }) == "com.example.Fresh")
    #expect(AccessibilityWindowSystem.targetedReadBundleIdentifier(
        recordInstance: nil, recordBundleIdentifier: nil, windowInstance: current,
        lookUp: missing) == nil)
    // A process cannot change its bundle: for the same launch the record wins over a
    // different fresh answer. Another launch at the same PID takes the fresh answer.
    #expect(AccessibilityWindowSystem.targetedReadBundleIdentifier(
        recordInstance: current, recordBundleIdentifier: "com.example.Fixture", windowInstance: current,
        lookUp: { "com.example.Other" }) == "com.example.Fixture")
    #expect(AccessibilityWindowSystem.targetedReadBundleIdentifier(
        recordInstance: earlier, recordBundleIdentifier: "com.example.Fixture", windowInstance: current,
        lookUp: { "com.example.Other" }) == "com.example.Other")
}

/// The adapter's targeted-read entry point keeps the recorded name of a launch while
/// the per-PID lookup answers nothing or something else. The PID has no process, so
/// the launch comes from the seeded record, as during a nil LaunchServices answer.
@Test(.macOSTestApplication) @MainActor func targetedReadApplicationKeepsTheRecordedNameOfItsLaunch() {
    let system = AccessibilityWindowSystem()
    let pid = pid_t(Int32.max - 7)
    var lookups: [pid_t] = []
    var answer: String? = nil
    system.targetedReadBundleLookup = { lookups.append($0); return answer }
    let launch = system.recordLaunchForTesting(pid: pid, bundleIdentifier: "com.example.Fixture")
    var read = system.targetedReadApplication(forPID: pid)
    #expect(read.instance == launch)
    #expect(read.bundleIdentifier == "com.example.Fixture")
    answer = "com.example.Other"
    read = system.targetedReadApplication(forPID: pid)
    #expect(read.bundleIdentifier == "com.example.Fixture")
    #expect(lookups.isEmpty)
    // A launch recorded without a name asks the lookup.
    let unnamed = pid - 1
    system.recordLaunchForTesting(pid: unnamed, bundleIdentifier: nil)
    answer = "com.example.Fresh"
    #expect(system.targetedReadApplication(forPID: unnamed).bundleIdentifier == "com.example.Fresh")
    #expect(lookups == [unnamed])
}

/// `windowSnapshot(id:)` and `readCreatedWindow(token:)` need a live, readable AX
/// window before they name an application, so tests cannot run them. Each must
/// name its application through `targetedReadApplication(forPID:)`; a direct per-PID
/// LaunchServices lookup brought back "0 placed · 4 need attention".
@Test(.macOSTestApplication) func bothTargetedReadsNameTheirApplicationThroughTheRecordedLaunch() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appending(path: "Sources/BetterTileMacOS/AccessibilityWindowSystem.swift"), encoding: .utf8)
    for signature in ["func windowSnapshot(id: WindowID) throws -> WindowSnapshot? {",
                      "public func readCreatedWindow(token: UInt64) -> CreatedWindowRead {"] {
        let start = try #require(source.range(of: signature), "\(signature)")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        #expect(body.contains("let application = targetedReadApplication(forPID: pid)"), "\(signature)")
        #expect(body.contains("bundleIdentifier: application.bundleIdentifier"), "\(signature)")
        #expect(!body.contains("NSRunningApplication"), "\(signature)")
    }
}

/// `NSRunningApplication(processIdentifier:)` can answer nil for a running application.
/// The lookup then reads the workspace's running-application list. A process in neither
/// answer, such as one that quit, stays without an application.
@Test(.macOSTestApplication) func aRunningApplicationLookupReadsTheWorkspaceListWhenThePerPIDAnswerIsNil() {
    let current = NSRunningApplication.current
    let pid = current.processIdentifier
    var listReads = 0
    let listed: () -> [NSRunningApplication] = { listReads += 1; return [current] }
    // A per-PID answer wins without a list read.
    #expect(RunningApplicationLookup.resolve(pid, lookUp: { _ in current }, runningApplications: listed) === current)
    #expect(listReads == 0)
    #expect(RunningApplicationLookup.resolve(pid, lookUp: { _ in nil }, runningApplications: listed) === current)
    #expect(listReads == 1)
    #expect(RunningApplicationLookup.resolve(pid &+ 1, lookUp: { _ in nil }, runningApplications: listed) == nil)
    #expect(RunningApplicationLookup.resolve(pid, lookUp: { _ in nil }, runningApplications: { [] }) == nil)
}

/// A recovery hold on an unreadable application stays while the application runs, even
/// when a per-PID lookup answers nil. The hold of an application that quit is dropped.
@Test(.macOSTestApplication) @MainActor func aRecoveryHoldStaysWhileItsApplicationRuns() {
    let system = AccessibilityWindowSystem()
    let running = pid_t(Int32.max - 11)
    let quit = pid_t(Int32.max - 12)
    system.runningApplicationLookup = { $0 == running ? NSRunningApplication.current : nil }
    system.holdUnreadableApplicationForTesting(pid: running, until: 50)
    system.holdUnreadableApplicationForTesting(pid: quit, until: 60)
    #expect(system.unresponsiveApplicationRecoveryDeadlines == [running: 50])
}

/// Raise, hit testing, launch identity, application window requests, Show App and
/// reopen need a live AX window or a real activation, so tests cannot run them. Each
/// must find its application through the running-application lookup. A direct per-PID
/// lookup can answer nil for a running application and refuse the action.
@Test(.macOSTestApplication) func everyPerPIDApplicationActionUsesTheRunningApplicationLookup() throws {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
    let adapter = try source("Sources/BetterTileMacOS/AccessibilityWindowSystem.swift")
    for signature in [
        "public var unresponsiveApplicationRecoveryDeadlines: [Int32: TimeInterval] {",
        "public func window(at point: BTPoint) throws -> WindowSnapshot? {",
        "private func applicationInstance(forPID pid: pid_t) -> ApplicationLaunchInstance {",
        "public func raiseWindow(_ id: WindowID, activate: Bool) throws {",
        "public func activateForWindowRequest(processIdentifier: Int32, bundleIdentifier: String) -> Bool {",
        "public func requestNewWindow(processIdentifier: Int32, bundleIdentifier: String,",
    ] {
        let start = try #require(adapter.range(of: signature), "\(signature)")
        let end = try #require(adapter.range(of: "\n    }\n", range: start.upperBound..<adapter.endIndex))
        let body = String(adapter[start.upperBound..<end.lowerBound])
        #expect(body.contains("runningApplicationLookup("), "\(signature)")
        #expect(!body.contains("NSRunningApplication(processIdentifier"), "\(signature)")
    }
    let appRoutes = [
        "Sources/BetterTileApp/BetterTileModel.swift":
            "let running = RunningApplicationLookup.application(processIdentifier: instance.processIdentifier),",
        "Sources/BetterTileApp/PaneApplicationPicker.swift":
            "guard let running = RunningApplicationLookup.application(processIdentifier: instance.processIdentifier),",
    ]
    for (path, route) in appRoutes { #expect(try source(path).contains(route), "\(path)") }
    // Only the lookup asks LaunchServices per PID. Two name lookups have their own
    // fallback, and a missing divider icon changes no action.
    let allowed = [
        "Sources/BetterTileMacOS/RunningApplicationLookup.swift": 1,
        "Sources/BetterTileMacOS/DividerOverlayController.swift": 1,
        "Sources/BetterTileApp/SavedLayoutApplier.swift": 1,
        "Sources/BetterTileApp/BetterTileModel.swift": 1,
    ]
    let sources = try #require(FileManager.default.enumerator(at: root.appending(path: "Sources"), includingPropertiesForKeys: nil))
    var found: [String: Int] = [:]
    for case let url as URL in sources where url.pathExtension == "swift" {
        let count = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "NSRunningApplication(processIdentifier: ").count - 1
        if count > 0 { found[String(url.path.dropFirst(root.path.count + 1)), default: 0] += count }
    }
    #expect(found == allowed)
}

/// Only two real answers make a window unmovable. An application that did
/// not answer leaves the question open, so a drag asks again on its next
/// tick instead of keeping the window still for the rest of the drag.
/// A busy application that fails the settable question with
/// `cannotComplete` says nothing about its window. The window keeps its
/// previous answer, or counts as movable and resizable when it never
/// answered, instead of being read as fixed-size and dropped from Tabbed.
@Test(.macOSTestApplication) func anUnansweredSettableQuestionKeepsThePreviousVerdict() {
    #expect(AccessibilityWindowSystem.settabilityVerdict(answer: true, previous: false) == (true, .reported))
    #expect(AccessibilityWindowSystem.settabilityVerdict(answer: false, previous: true) == (false, .reported))
    #expect(AccessibilityWindowSystem.settabilityVerdict(answer: nil, previous: false) == (false, .previous))
    #expect(AccessibilityWindowSystem.settabilityVerdict(answer: nil, previous: true) == (true, .previous))
    #expect(AccessibilityWindowSystem.settabilityVerdict(answer: nil, previous: nil) == (true, .assumed))
}

@Test(.macOSTestApplication) func movabilityNeedsAnAnswerBeforeAWindowCountsAsUnmovable() {
    #expect(AccessibilityWindowSystem.movability(position: true, size: nil) == true)
    #expect(AccessibilityWindowSystem.movability(position: false, size: true) == true)
    #expect(AccessibilityWindowSystem.movability(position: false, size: false) == false)
    #expect(AccessibilityWindowSystem.movability(position: nil, size: nil) == nil)
    #expect(AccessibilityWindowSystem.movability(position: false, size: nil) == nil)
}

/// Only a successful read that names the window confirms focus. An
/// application without a focused window, or a failed read, proves nothing.
@Test(.macOSTestApplication) func applicationFocusRequiresAPositiveRead() {
    func focus(_ result: AXError, role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
               matches: Bool = false) -> ApplicationFocusMatch {
        AccessibilityWindowSystem.applicationFocus(readResult: result, focusedRole: role,
                                                   focusedSubrole: subrole, matchesWindow: matches)
    }
    #expect(focus(.success, matches: true) == .confirmed)
    #expect(focus(.success) == .otherWindow(isTransientPopup: false))
    #expect(focus(.success, subrole: "AXUnknown") == .otherWindow(isTransientPopup: true))
    #expect(focus(.success, subrole: "AXDialog") == .otherWindow(isTransientPopup: false))
    // Finder's desktop is a scroll area; no window has focus.
    #expect(focus(.success, role: "AXScrollArea", subrole: nil) == .noWindow)
    #expect(focus(.noValue, role: nil, subrole: nil) == .noWindow)
    #expect(focus(.cannotComplete, role: nil, subrole: nil) == .unknown)
    #expect(focus(.attributeUnsupported, role: nil, subrole: nil) == .unknown)
    #expect(focus(.apiDisabled, matches: true) == .unknown)
}

/// During a shrinking live drag, Chromium's readbacks trail the requests by
/// two ticks. Each readback lies between an older readback and the newest
/// request, but above the previous request, so it is no clamp. A real clamp
/// below the previous request is still measured at once.
@Test(.macOSTestApplication) func liveTickReadbacksThatLagBehindTheirRequestsAreNotLearned() {
    var learner = WindowMinimumSizeLearner()
    var requested: [WindowID: BTSize] = [:]
    let id = WindowID(rawValue: "chrome")
    let widths = [800.0, 750, 700, 650, 600, 550, 500]
    var previous = BTRect(x: 200, y: 0, width: widths[0], height: 600)
    for tick in 1..<widths.count {
        let request = BTRect(x: 1000 - widths[tick], y: 0, width: widths[tick], height: 600)
        // The position is applied at once; the size two ticks late.
        let actual = BTRect(x: request.minX, y: 0, width: widths[max(0, tick - 2)], height: 600)
        let learned = AccessibilityWindowSystem.observeLiveReadback(
            &learner, requestedSizes: &requested, windowID: id, application: "com.google.Chrome",
            requested: request, previous: previous, actual: actual, now: Double(tick) / 60
        )
        #expect(!learned, "tick \(tick)")
        previous = actual
    }
    #expect(learner.learnedSizes.isEmpty)
    #expect(learner.applicationSizes.isEmpty)

    // A window that took 650 and then stops at its 620 pt minimum.
    var clamped = WindowMinimumSizeLearner()
    var clampedRequests: [WindowID: BTSize] = [:]
    _ = AccessibilityWindowSystem.observeLiveReadback(
        &clamped, requestedSizes: &clampedRequests, windowID: id, application: nil,
        requested: BTRect(x: 350, y: 0, width: 650, height: 600), previous: BTRect(x: 300, y: 0, width: 700, height: 600),
        actual: BTRect(x: 350, y: 0, width: 650, height: 600), now: 0
    )
    let learned = AccessibilityWindowSystem.observeLiveReadback(
        &clamped, requestedSizes: &clampedRequests, windowID: id, application: nil,
        requested: BTRect(x: 400, y: 0, width: 600, height: 600), previous: BTRect(x: 350, y: 0, width: 650, height: 600),
        actual: BTRect(x: 400, y: 0, width: 620, height: 600), now: 1.0 / 60
    )
    #expect(learned)
    #expect(clamped.learnedSizes[id] == BTSize(width: 620, height: 0))
}
