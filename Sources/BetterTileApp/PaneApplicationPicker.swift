import AppKit
import BetterTileCore
import BetterTileMacOS
import Observation
import OSLog
import SwiftUI

struct PaneApplicationInstance: Equatable {
    let processIdentifier: Int32
    let launchDate: Date?
    var isActive = false
    var isFrontmost = false
}

@MainActor protocol PaneApplicationLaunching {
    func runningApplicationBundleIdentifiers() -> Set<String>
    func runningInstances(of application: ApplicationChoice) -> [PaneApplicationInstance]
    func launch(_ application: ApplicationChoice) async throws -> PaneApplicationInstance
    func reopen(_ application: ApplicationChoice, instance: PaneApplicationInstance, activating: Bool, timeout: TimeInterval) async throws
}

extension PaneApplicationLaunching {
    func reopen(_ application: ApplicationChoice, instance: PaneApplicationInstance, activating: Bool) async throws {
        try await reopen(application, instance: instance, activating: activating, timeout: 10)
    }
    func preferredInstance(in instances: [PaneApplicationInstance]) -> PaneApplicationInstance? {
        instances.first(where: \.isActive) ?? instances.first(where: \.isFrontmost)
            ?? (instances.count == 1 ? instances.first : nil)
    }
    func contains(_ instance: PaneApplicationInstance, of application: ApplicationChoice) -> Bool {
        runningInstances(of: application).contains {
            $0.processIdentifier == instance.processIdentifier && $0.launchDate == instance.launchDate
        }
    }
    func reopen(_ application: ApplicationChoice, instance: PaneApplicationInstance, activating: Bool, timeout: TimeInterval) async throws {
        _ = try await launch(application)
    }
}

@MainActor struct WorkspacePaneApplicationLauncher: PaneApplicationLaunching {
    func runningApplicationBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
    }
    func runningInstances(of application: ApplicationChoice) -> [PaneApplicationInstance] {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: application.id).filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }
        // The public on-screen list is front to back. It supplies only process IDs here.
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        let orderedPIDs = records.filter { ($0[kCGWindowLayer] as? Int) == 0 }
            .compactMap { ($0[kCGWindowOwnerPID] as? NSNumber)?.int32Value }
        let frontmostPID = orderedPIDs.first { pid in instances.contains { $0.processIdentifier == pid } }
        return instances.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return (orderedPIDs.firstIndex(of: $0.processIdentifier) ?? Int.max)
                < (orderedPIDs.firstIndex(of: $1.processIdentifier) ?? Int.max)
        }.map { PaneApplicationInstance(processIdentifier: $0.processIdentifier, launchDate: $0.launchDate, isActive: $0.isActive,
            isFrontmost: $0.processIdentifier == frontmostPID) }
    }

    func reopen(_ application: ApplicationChoice, instance: PaneApplicationInstance, activating: Bool, timeout: TimeInterval) async throws {
        guard timeout > 0, !Task.isCancelled else { throw CocoaError(.userCancelled) }
        guard let running = RunningApplicationLookup.application(processIdentifier: instance.processIdentifier),
              running.bundleIdentifier == application.id, running.launchDate == instance.launchDate,
              !running.isTerminated else {
            throw CocoaError(.executableNotLoadable)
        }
        let reopenURL = try Self.reopenURL(for: application, runningBundleURL: running.bundleURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activating
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = false
        let reopened = try await ApplicationReopenCompletion.open(timeout: timeout) { reply in
            NSWorkspace.shared.openApplication(at: reopenURL, configuration: configuration) { application, error in
                Task { @MainActor in reply(application, error) }
            }
        }
        guard reopened.processIdentifier == instance.processIdentifier, !reopened.isTerminated else {
            throw CocoaError(.executableNotLoadable)
        }
    }

    static func reopenURL(for application: ApplicationChoice, runningBundleURL: URL?) throws -> URL {
        guard let url = runningBundleURL,
              ApplicationCatalog.application(at: url)?.id == application.id else {
            throw CocoaError(.executableNotLoadable)
        }
        return url
    }

    func launch(_ application: ApplicationChoice) async throws -> PaneApplicationInstance {
        guard ApplicationCatalog.application(at: application.url)?.id == application.id else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = false
        let running = try await NSWorkspace.shared.openApplication(at: application.url, configuration: configuration)
        guard !running.isTerminated, running.bundleIdentifier == application.id else {
            throw CocoaError(.executableNotLoadable)
        }
        return PaneApplicationInstance(processIdentifier: running.processIdentifier, launchDate: running.launchDate)
    }
}

@MainActor final class ApplicationReopenCompletion {
    private var continuation: CheckedContinuation<NSRunningApplication, any Error>?
    var timeout: Task<Void, Never>?
    static func open(timeout seconds: TimeInterval,
        wait: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        dispatch: (@escaping @MainActor (NSRunningApplication?, (any Error)?) -> Void) -> Void) async throws -> NSRunningApplication {
        let completion = ApplicationReopenCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.continuation = continuation
                guard seconds > 0, !Task.isCancelled else {
                    completion.finish(nil, error: CancellationError())
                    return
                }
                completion.timeout = Task { @MainActor in
                    try? await wait(seconds)
                    completion.finish(nil, error: CocoaError(.userCancelled))
                }
                dispatch { application, error in completion.finish(application, error: error) }
            }
        } onCancel: {
            Task { @MainActor in completion.finish(nil, error: CancellationError()) }
        }
    }
    func finish(_ application: NSRunningApplication?, error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        if let application { continuation.resume(returning: application) }
        else { continuation.resume(throwing: error ?? CocoaError(.executableNotLoadable)) }
    }
}

/// One intent record for all opening requests owned by a model. No input history is persisted.
@MainActor final class ApplicationRequestIntent {
    static let log = Logger(subsystem: "com.lmckarma.BetterTile", category: "request-focus")
    private struct Participant { weak var focus: ApplicationRequestFocus? }
    private var participants: [UUID: Participant] = [:]
    private var active: [ApplicationRequestFocus] { participants.values.compactMap(\.focus) }
    var registeredFocusCount: Int { participants.count }
    private(set) var movedOn = false
    private var latestUserApplication: String?
    /// The chosen copy. Restoration targets this process, not any copy with the bundle ID.
    private var latestUserProcess: Int32?
    private var choiceRevision = 0
    private var restoredRevision: Int?
    private var restorationActivation: String?
    private var keysAtChoice: UInt32 = 0
    private var lastClick: UInt64?
    private var keyboardEventCount: () -> UInt32 = { 0 }

    fileprivate func register(_ focus: ApplicationRequestFocus) {
        if active.isEmpty {
            participants = [:]
            movedOn = false; latestUserApplication = nil; latestUserProcess = nil; choiceRevision = 0
            restoredRevision = nil; restorationActivation = nil; lastClick = nil
            keyboardEventCount = focus.keyboardEventCount
            keysAtChoice = keyboardEventCount()
        }
        participants[focus.id] = Participant(focus: focus)
    }

    fileprivate func remove(_ focus: ApplicationRequestFocus) { participants[focus.id] = nil }
    fileprivate func contains(_ focus: ApplicationRequestFocus) -> Bool { participants[focus.id]?.focus === focus }

    func activated(_ bundleID: String?, processIdentifier: Int32? = nil) {
        guard !active.isEmpty else { return }
        let currentKeys = keyboardEventCount()
        let newerKeyboardInput = keysAtChoice != currentKeys
        Self.log.debug("activation app=\(bundleID ?? "none", privacy: .private) pid=\(processIdentifier ?? 0) choiceKeys=\(self.keysAtChoice) currentKeys=\(currentKeys)")
        if let bundleID, restorationActivation == bundleID, !newerKeyboardInput {
            Self.log.debug("activation app=\(bundleID, privacy: .private) class=other reason=restore")
            restorationActivation = nil
            return
        }
        let expected = active.filter { $0.expectedActivations.contains(bundleID ?? "") }
        if let bundleID { for focus in expected { focus.expectedActivations.remove(bundleID) } }
        if !expected.isEmpty, !newerKeyboardInput {
            Self.log.debug("activation app=\(bundleID ?? "none", privacy: .private) class=expected-target")
            return
        }
        // An opening app may activate again. Only a click or newer keyboard input
        // can replace a recorded user choice with an in-flight target.
        if latestUserApplication != nil, active.contains(where: { $0.requested.contains(bundleID ?? "") }),
           !newerKeyboardInput {
            Self.log.debug("activation app=\(bundleID ?? "none", privacy: .private) class=expected-target")
            return
        }
        Self.log.debug("activation app=\(bundleID ?? "none", privacy: .private) class=\(bundleID == nil ? "other" : "user-choice")")
        userChose(bundleID, processIdentifier: processIdentifier, source: newerKeyboardInput ? "keyboard" : "activation")
    }

    func userChose(_ bundleID: String?, processIdentifier: Int32? = nil, click: UInt64? = nil, source: String = "click") {
        guard !active.isEmpty else {
            Self.log.debug("choice skip reason=no-request source=\(source, privacy: .public)")
            return
        }
        if let click, lastClick == click {
            Self.log.debug("choice skip reason=duplicate-click")
            return
        }
        lastClick = click
        for focus in active { focus.expectedActivations = [] }
        restorationActivation = nil
        movedOn = true
        latestUserApplication = bundleID
        latestUserProcess = processIdentifier
        keysAtChoice = keyboardEventCount()
        choiceRevision &+= 1
        Self.log.info("choice source=\(source, privacy: .public) app=\(bundleID ?? "none", privacy: .private) pid=\(processIdentifier ?? 0) revision=\(self.choiceRevision) keys=\(self.keysAtChoice)")
    }

    fileprivate func restore(using focus: ApplicationRequestFocus) -> Bool {
        let current = focus.frontmost()
        let currentKeys = keyboardEventCount()
        let reason: String
        if !contains(focus) { reason = "released" }
        else if !movedOn { reason = "no-choice" }
        else if restoredRevision == choiceRevision { reason = "already-restored" }
        else if latestUserApplication == nil { reason = "unknown-choice" }
        else if !(current.map { current in active.contains(where: { $0.requested.contains(current) }) } ?? false) { reason = "target-not-frontmost" }
        else if current == latestUserApplication { reason = "choice-is-target" }
        else if keysAtChoice != currentKeys { reason = "newer-keyboard" }
        else { reason = "restore" }
        guard reason == "restore", let latestUserApplication else {
            Self.log.debug("restore decision=skip reason=\(reason, privacy: .public) front=\(current ?? "none", privacy: .private) choiceKeys=\(self.keysAtChoice) currentKeys=\(currentKeys)")
            return false
        }
        // Consume before activation, including a synchronous workspace notification.
        restoredRevision = choiceRevision
        restorationActivation = latestUserApplication
        Self.log.info("restore decision=act reason=target-frontmost target=\(current ?? "none", privacy: .private) choice=\(latestUserApplication, privacy: .private) pid=\(self.latestUserProcess ?? 0)")
        let result = focus.restoreFrontmost(latestUserApplication, latestUserProcess)
        // No activation follows a refused request, so a later one is the user's again.
        if result == .unavailable { restorationActivation = nil }
        Self.log.info("restore result=\(result.rawValue, privacy: .public)")
        return true
    }

    fileprivate func needsObservation(using focus: ApplicationRequestFocus) -> Bool {
        contains(focus) && restoredRevision != choiceRevision
    }
}

/// The count-only keyboard guard. No key code, character or event payload is read.
protocol KeyboardEventCounting {
    func keyDownCount() -> UInt32
}

/// The public aggregate key-down count for the login session.
struct SessionKeyDownCounter: KeyboardEventCounting {
    func keyDownCount() -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown) }
}

/// A request's source and expected activation, registered with the model's shared intent.
@MainActor final class ApplicationRequestFocus {
    let id = UUID()
    let source: String?
    var requested: Set<String> = []
    fileprivate var expectedActivations: Set<String> = []
    private var dispatchingApplication: String?
    private var intent = ApplicationRequestIntent()
    var movedOn: Bool { intent.movedOn }
    let keyboardEventCount: () -> UInt32
    let frontmost: () -> String?
    /// Restores the chosen app, and the chosen copy when its process is known.
    let restoreFrontmost: (String, Int32?) -> ApplicationActivationResult
    /// Production restores through the coordinator's Accessibility activation of the chosen process.
    init(frontmost: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         keyboard: any KeyboardEventCounting = SessionKeyDownCounter(),
         activator: any ApplicationActivating) {
        self.frontmost = frontmost; source = frontmost()
        restoreFrontmost = { [weak activator] bundleID, processIdentifier in
            activator?.activateApplication(bundleIdentifier: bundleID, processIdentifier: processIdentifier) ?? .unavailable
        }
        self.keyboardEventCount = { keyboard.keyDownCount() }
        intent.register(self)
    }
    /// Injected sources for tests that observe restoration by bundle ID only.
    init(frontmost: @escaping () -> String?, keyboardEventCount: @escaping () -> UInt32,
         restoreFrontmost: @escaping (String) -> Void) {
        self.frontmost = frontmost; source = frontmost()
        self.restoreFrontmost = { bundleID, _ in restoreFrontmost(bundleID); return .accessibility }
        self.keyboardEventCount = keyboardEventCount
        intent.register(self)
    }
    func shareIntent(_ shared: ApplicationRequestIntent) {
        intent.remove(self); intent = shared; intent.register(self)
    }
    func requestStarted(target: String) {
        ApplicationRequestIntent.log.info("request start target=\(target, privacy: .private) source=\(self.source ?? "none", privacy: .private) keys=\(self.keyboardEventCount())")
    }
    func finish() { expectedActivations = []; dispatchingApplication = nil; intent.remove(self) }
    /// Launch, menu dispatch and background reopen may cause one activation themselves.
    func expectActivation(of bundleID: String) {
        dispatchingApplication = bundleID
        if frontmost() != bundleID { expectedActivations.insert(bundleID) }
    }
    func prepareReopen(of bundleID: String) -> Bool {
        expectActivation(of: bundleID)
        return false
    }
    func reopenFailed() {
        if let dispatchingApplication { expectedActivations.remove(dispatchingApplication) }
        dispatchingApplication = nil
    }
    func activated(_ bundleID: String?, processIdentifier: Int32? = nil) {
        guard intent.contains(self) else { return }
        intent.activated(bundleID, processIdentifier: processIdentifier)
    }
    func userChose(_ bundleID: String?, processIdentifier: Int32? = nil, click: UInt64? = nil) {
        guard intent.contains(self) else {
            ApplicationRequestIntent.log.debug("choice skip reason=released-helper")
            return
        }
        intent.userChose(bundleID, processIdentifier: processIdentifier, click: click)
    }
    @discardableResult func restoreUserFocusIfNeeded() -> Bool { intent.restore(using: self) }
    var needsObservation: Bool { intent.needsObservation(using: self) }
    var allowsRaising: Bool {
        intent.contains(self) && !movedOn && (frontmost() == source || requested.contains(frontmost() ?? ""))
    }
}

/// Request-local order, independent of inventory order and window ID spelling.
/// A creation token keeps its place even if its window ID resolves after a later creation.
struct ApplicationRequestArrivalOrder {
    private var next = 0
    private var windows: [WindowID: Int] = [:]
    private var tokens: [UInt64: Int] = [:]

    mutating func created(id: WindowID?, token: UInt64?) {
        let order = next
        next += 1
        if let id { windows[id] = min(windows[id] ?? order, order) }
        if let token { tokens[token] = min(tokens[token] ?? order, order) }
    }

    mutating func resolve(_ id: WindowID, token: UInt64) {
        guard let order = tokens[token] else { return }
        windows[id] = min(windows[id] ?? order, order)
    }

    mutating func observe(_ snapshots: [WindowSnapshot]) {
        for window in snapshots where windows[window.id] == nil {
            windows[window.id] = next
            next += 1
        }
    }

    var ids: [WindowID] { windows.keys.sorted { windows[$0]! < windows[$1]! } }
}

/// A click on a window that BetterTile asked an app to open. The pointer must come back up within
/// `dragThreshold` points of where it went down: a drag of the new window is not a click.
struct PaneApplicationClick: Equatable {
    static let dragThreshold = 4.0
    let windowID: WindowID
    let processIdentifier: Int32
    /// Seconds since system start, from the mouse-down event.
    let downTime: TimeInterval
    let downPosition: BTPoint
    var released = false

    func moved(to point: BTPoint) -> Bool {
        hypot(point.x - downPosition.x, point.y - downPosition.y) > Self.dragThreshold
    }
}

@Observable @MainActor final class PaneApplicationRequest {
    enum Phase: Equatable { case choosing, waiting, placing(WindowID), fallback(String) }
    enum FallbackReason { case arrived, unsupported, severalCopies, timedOut, failed, other }
    var fallbackReason = FallbackReason.other
    var instances: [PaneApplicationInstance] = []
    var showingWindows = false
    var launching = false
    /// A mouse-down on an arrived window, waiting for its mouse-up. Never stored beyond this request.
    var clickCandidate: PaneApplicationClick?
    /// The arrived window raised for the user to click, so it is raised once, not on every refresh.
    var revealedWindowID: WindowID?
    /// When BetterTile stops waiting for a click on the window that arrived (system uptime).
    var clickDeadline: TimeInterval?
    var windowAtPoint: ((BTPoint) -> WindowSnapshot?)?
    /// Rebuilt from normal window observations, never by row rendering.
    var pickerWindowsByApplication: [String: [ApplicationPickerWindow]] = [:]
    var windows: ((ApplicationChoice) -> [ApplicationPickerWindow]?)?
    var onChooseWindow: ((ApplicationChoice, ApplicationPickerWindow) -> Void)?
    let id = UUID()
    let paneID: UUID
    let paneNumber: Int
    let displayID: DisplayID
    let sessionID: DesktopSessionID
    let spaceID: NativeSpaceID?
    let generation: Int
    let workArea: BTRect
    var phase = Phase.choosing
    var needsPolling: Bool {
        switch phase {
        case .waiting, .placing: true
        case .fallback: fallbackReason == .arrived
        case .choosing: false
        }
    }
    var application: ApplicationChoice?
    var instance: PaneApplicationInstance?
    /// Only a completed launch grants the first-window exception to creation evidence.
    var launchedInstance: PaneApplicationInstance?
    var baseline: Set<WindowID> = []
    var arrivals: Set<WindowID> = []
    var createdAfterRequest: Set<WindowID> = []
    var creationTokens: Set<UInt64> = []
    var arrivalOrder = ApplicationRequestArrivalOrder()
    var openingStartedAt: TimeInterval?
    var stillOpening = false
    var deadline: TimeInterval?
    var dispatched = false
    var focusIntent: ApplicationRequestFocus?
    func finishFocusIntent() {
        let focus = focusIntent
        focusIntent = nil
        focus?.finish()
    }
    var automaticPlacement = false
    var existingWindows: [WindowSnapshot] = []
    var pendingExistingWindowID: WindowID?
    var onChoose: ((ApplicationChoice) -> Void)?
    var onExisting: ((WindowID) -> Void)?
    var onRetry: (() -> Void)?
    var onCancel: (() -> Void)?

    var status: PaneRequestStatus? {
        guard let application else { return nil }
        let entries = existingWindows.map { PaneRequestWindow(id: $0.id, title: $0.title.isEmpty ? application.name : $0.title) }
        let kind: PaneRequestStatus.Kind
        switch phase {
        case .choosing: return nil
        case .waiting: kind = stillOpening ? .stillOpening : .opening(launching: launching)
        case .placing: kind = stillOpening ? .stillOpening : .opening(launching: launching)
        case let .fallback(reason):
            switch fallbackReason {
            case .arrived: kind = .awaitingClick(entries.filter { arrivals.contains($0.id) })
            case .unsupported: kind = .noNewWindow(entries)
            case .timedOut: kind = .timedOut(showingWindows: showingWindows, windows: entries)
            case .failed: kind = .failed
            case .other: kind = .other(message: reason, windows: entries)
            case .severalCopies:
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                let groups = instances.enumerated().map { index, instance in
                    PaneRequestWindowGroup(label: instance.launchDate.map { "Copy started " + formatter.string(from: $0) }
                        ?? "Copy \(index + 1)", windows: existingWindows.filter {
                            $0.processIdentifier == instance.processIdentifier
                        }.map { PaneRequestWindow(id: $0.id, title: $0.title.isEmpty ? application.name : $0.title) })
                }
                kind = .severalCopies(groups)
            }
        }
        return PaneRequestStatus(requestID: id, paneID: paneID, appName: application.name, appIconURL: application.url, kind: kind)
    }

    static func candidateWindows(applicationID: String, displayID: DisplayID, windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.filter { window in
            window.bundleIdentifier == applicationID && window.displayID == displayID
                && window.isEligible && !window.isFloating
        }.sorted { $0.id < $1.id }
    }

    static func automaticArrival(in windows: [WindowSnapshot], applicationID: String,
                                 processIdentifier: Int32, baseline: Set<WindowID>, displayID: DisplayID,
                                 spaceID: NativeSpaceID?, observation: NativeDesktopObservation?,
                                 arrivalOrder: [WindowID], createdAfterRequest: Set<WindowID>) -> WindowSnapshot? {
        guard observation?.allowsAutomaticLayout(on: displayID) != false,
              observation == nil || observation?.currentSpace(on: displayID) == spaceID else { return nil }
        let ranks = Dictionary(uniqueKeysWithValues: arrivalOrder.enumerated().map { ($0.element, $0.offset) })
        let candidates = candidateWindows(applicationID: applicationID, displayID: displayID, windows: windows)
        return candidates.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }.first { window in
            ranks[window.id] != nil && createdAfterRequest.contains(window.id)
                && !baseline.contains(window.id) && window.processIdentifier == processIdentifier
                && window.constraints.isResizable
                && observation?.windowMembership[window.id].map { membership in
                    // Unknown membership is permitted only by the existing public visibility fallback.
                    membership.isEmpty || spaceID.map { membership == [$0] } == true
                } != false
        }
    }

    init(paneID: UUID, paneNumber: Int, displayID: DisplayID, sessionID: DesktopSessionID,
         spaceID: NativeSpaceID?, generation: Int, workArea: BTRect) {
        self.paneID = paneID; self.paneNumber = paneNumber; self.displayID = displayID
        self.sessionID = sessionID; self.spaceID = spaceID; self.generation = generation; self.workArea = workArea
    }
}

/// A cancelled creation cannot be recalled. Quarantine its late arrivals briefly, without retaining a placement.
struct PaneApplicationArrivalGuard {
    let id = UUID()
    let applicationID: String
    let instance: PaneApplicationInstance?
    let baseline: Set<WindowID>
    let expiresAt: TimeInterval

    func reserves(_ window: WindowSnapshot) -> Bool {
        applicationID == window.bundleIdentifier && !baseline.contains(window.id)
            && (instance == nil || instance?.processIdentifier == window.processIdentifier)
    }
}

struct PaneApplicationPicker: View {
    @Bindable var request: PaneApplicationRequest
    var installedApplications: @MainActor () async -> [ApplicationChoice] = {
        await InstalledApplicationCatalog.shared.applications()
    }
    var runningApplications: () -> [ApplicationChoice] = ApplicationPicker.runningApplicationChoices
    var recentApplications: RecentApplications = .shared

    var body: some View {
        ApplicationPicker(exclusions: [], installedApplications: installedApplications,
                          runningApplications: runningApplications, recentApplications: recentApplications,
                          returnHint: "New window", windows: { request.windows?($0) },
                          onChooseWindow: request.onChooseWindow) { request.onChoose?($0) }
            // Inset the list 6 pt, half of the search field's 12 pt margin.
            .padding(.horizontal, SettingsSpacing.s3 / 2)
            .padding(.top, SettingsSpacing.s3)
            .padding(.bottom, 8)
            .frame(width: 320, height: 420)
    }
}

@MainActor final class PaneApplicationPopover {
    let presenter: TabbedChooserPresenter
    let content: NSView
    var onDismiss: (() -> Void)?

    init(request: PaneApplicationRequest, recentApplications: RecentApplications = .shared,
         appearance: OverlayAppearance = OverlayAppearance(),
         presenterFactory: ((NSView, NSSize) -> TabbedChooserPresenter)? = nil) {
        content = PanePickerHostingView(rootView: PaneApplicationPicker(request: request,
                                                                      recentApplications: recentApplications))
        let size = content.fittingSize
        presenter = presenterFactory?(content, size) ?? TabbedChooserPresenter(content: content, size: size, appearance: appearance)
        presenter.onDismiss = { [weak self] in
            let callback = self?.onDismiss
            self?.onDismiss = nil
            callback?()
        }
    }

    func show(relativeTo rect: NSRect, of view: NSView, paneFrame: NSRect? = nil) {
        presenter.show(relativeTo: rect, of: view, paneFrame: paneFrame)
    }

    func close() { presenter.dismiss() }
}


@MainActor private final class PanePickerHostingView: NSHostingView<PaneApplicationPicker> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Saved Layouts only. Selecting rows appends preferences and keeps the picker open.
/// The Tabbed '+' entry above continues to use PaneApplicationPicker unchanged.
struct PanePreferenceApplicationPicker: View {
    var groups: AppGroupsDocument
    var selected: [AppPreference]
    var installedApplications: @MainActor () async -> [ApplicationChoice]
    var runningApplications: () -> [ApplicationChoice]
    var recentApplications: RecentApplications = .shared
    var onAdd: (AppPreference) -> Void
    var onDone: () -> Void
    @State private var search = ""
    @State private var installed: [ApplicationChoice] = []
    @State private var running: [ApplicationChoice] = []
    @State private var recent: [ApplicationChoice] = []
    @State private var highlight: String?
    @FocusState private var searchFocused: Bool

    private var sections: [ApplicationPickerModel.Section] {
        Self.appSections(installed: installed, running: running, recent: recent, selected: selected, search: search)
    }
    static func appSections(installed: [ApplicationChoice], running: [ApplicationChoice], recent: [ApplicationChoice],
                            selected: [AppPreference], search: String) -> [ApplicationPickerModel.Section] {
        let excluded = Set(selected.compactMap { preference -> String? in
            if case let .app(id) = preference { return id }; return nil
        })
        return ApplicationPickerModel.sections(installed: installed, running: running, recent: recent,
            excluding: excluded, search: search)
    }
    private var visibleGroups: [AppGroup] {
        groups.groups.filter { group in
            (search.isEmpty || group.name.localizedStandardContains(search)) && !selected.contains(.group(group.name))
        }
    }
    private var choices: [(id: String, preference: AppPreference)] {
        visibleGroups.map { ("group:" + $0.name, .group($0.name)) }
            + sections.flatMap(\.rows).map { ($0.id, .app($0.application.id)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search groups and apps", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onSubmit { chooseHighlighted() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !visibleGroups.isEmpty {
                            Text("App Groups").font(SettingsFont.caption).foregroundStyle(.secondary)
                            ForEach(visibleGroups, id: \.name) { group in
                                row(id: "group:" + group.name, preference: .group(group.name),
                                    presentation: .init(.group(group.name), applications: [:], groups: groups))
                            }
                            Divider().padding(.vertical, 4)
                        }
                        ForEach(sections) { section in
                            Text(section.kind.rawValue).font(SettingsFont.caption).foregroundStyle(.secondary)
                            ForEach(section.rows) { item in
                                row(id: item.id, preference: .app(item.application.id),
                                    presentation: .init(.app(item.application.id), applications: [item.application.id: item.application], groups: groups),
                                    caption: item.caption)
                            }
                        }
                        if choices.isEmpty { Text("No matching preferences").foregroundStyle(.secondary).padding(.vertical, 16) }
                    }
                }
                .onChange(of: highlight) { if let highlight { proxy.scrollTo(highlight, anchor: .center) } }
            }
            HStack {
                Text("Choose preferences in order.").font(SettingsFont.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
            }
        }
        .padding(12).frame(width: 320, height: 420).font(SettingsFont.body)
        .onChange(of: choices.map(\.id)) { _, ids in if !ids.contains(highlight ?? "no-selection") { highlight = ids.first } }
        .task {
            running = runningApplications()
            recent = ApplicationPickerModel.recentChoices(recentApplications.bundleIdentifiers, known: running, lookup: { _ in nil })
            installed = await installedApplications()
            recent = ApplicationPickerModel.recentChoices(recentApplications.bundleIdentifiers, known: running + installed, lookup: { _ in nil })
            highlight = choices.first?.id; searchFocused = true
        }
    }
    private func move(_ offset: Int) {
        let ids = choices.map(\.id)
        guard !ids.isEmpty else { return }
        let current = highlight.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        highlight = ids[min(ids.count - 1, max(0, current + offset))]
    }
    private func chooseHighlighted() {
        if let choice = choices.first(where: { $0.id == highlight }) { add(choice.preference) }
    }
    private func add(_ preference: AppPreference) {
        if case let .app(id) = preference { recentApplications.record(id) }
        onAdd(preference)
    }
    private func row(id: String, preference: AppPreference, presentation: SavedLayoutPreferencePresentation, caption: String? = nil) -> some View {
        Button { add(preference) } label: {
            HStack(spacing: 8) {
                SavedLayoutPreferenceIcon(presentation: presentation)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title).lineLimit(1)
                    if let caption { Text(caption).font(SettingsFont.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            .padding(.horizontal, 6).frame(minHeight: 36).contentShape(Rectangle())
            .background(highlight == id ? Color.accentColor.opacity(0.15) : .clear,
                in: RoundedRectangle.settings(SettingsRadius.control))
        }.buttonStyle(.plain).id(id)
    }
}
