import AppKit
import BetterTileCore
import Foundation
import SwiftUI
import os

/// The window and display captured when the wheel opened.
///
/// The gesture keeps this for its whole life. Losing the window cancels the
/// gesture rather than retargeting, so a wheel opened over one window can never
/// apply to whatever happens to be focused by the time the user releases.
public struct LayoutWheelTarget: Equatable, Sendable {
    public var windowID: WindowID
    public var displayID: DisplayID
    public var visibleFrame: BTRect

    public init(windowID: WindowID, displayID: DisplayID, visibleFrame: BTRect) {
        self.windowID = windowID
        self.displayID = displayID
        self.visibleFrame = visibleFrame
    }
}

public enum LayoutWheelPreviewOutcome: Equatable, Sendable {
    case ready(placements: [Placement])
    case unavailable(reason: String)
}

/// What the presenter needs to draw. A value type so tests can assert exactly
/// what the runtime asked for without a live panel.
public struct LayoutWheelPresentation: Equatable, Sendable {
    public var configuration: LayoutWheelConfiguration
    public var customZones: [CustomZone]
    public var placement: LayoutWheelPlacement
    public var selection: LayoutWheelSelection?
    public var unavailableCommands: Set<LayoutWheelCommand>
}

@MainActor
protocol LayoutWheelPresenting: AnyObject {
    func open(_ presentation: LayoutWheelPresentation)
    func update(_ presentation: LayoutWheelPresentation)
    func showPlacements(_ placements: [Placement])
    func hidePlacements()
    func close()
}

/// Owns the Layout Wheel gesture: the activation hold, the captured target, the
/// panel, pointer and keyboard selection, and every way the gesture can end.
///
/// It never mutates a window. Selection produces previews and one commit
/// request; the model decides what those mean.
@MainActor
public final class LayoutWheelController {
    public static let activationDelay: Duration = .milliseconds(220)

    public var configuration: BetterTileConfiguration {
        didSet {
            guard configuration.layoutWheel != oldValue.layoutWheel else { return }
            // Changing the trigger or the assignments mid-gesture would apply
            // something the user never aimed at.
            cancel()
            syncMonitoring()
        }
    }

    /// Returns the window and display to act on, or nil when nothing is
    /// eligible. Called once, when the hold succeeds.
    public var captureHandler: (() -> LayoutWheelTarget?)?
    public var previewHandler: ((LayoutWheelCommand, LayoutWheelTarget) -> LayoutWheelPreviewOutcome)?
    public var commitHandler: ((LayoutWheelCommand, LayoutWheelTarget) -> Void)?
    public var unavailableHandler: ((String, LayoutWheelTarget) -> Void)?
    public var monitoringFailureHandler: ((String?) -> Void)? {
        didSet { publishMonitoringFailure() }
    }
    public var gestureBeganHandler: (() -> Void)?
    public var gestureEndedHandler: (() -> Void)?

    public var isOpen: Bool {
        if case .open = phase { return true }
        return false
    }

    public var isPendingActivation: Bool {
        if case .pending = phase { return true }
        return false
    }

    private static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "LayoutWheel"
    )

    private enum Phase {
        case idle
        case pending(generation: Int)
        case open(Session)
    }

    private enum Trigger {
        case keyboard
        case middleClick
    }

    private struct Session {
        var target: LayoutWheelTarget
        var trigger: Trigger
        var placement: LayoutWheelPlacement
        var selection: LayoutWheelSelection?
        var unavailableReasons: [LayoutWheelCommand: String] = [:]
    }

    private let presenter: LayoutWheelPresenting
    private let metrics: LayoutWheelMetrics
    private let activationDelay: Duration
    private let pointerProvider: @MainActor () -> BTPoint
    private let addGlobalMonitor: (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> Void
    ) -> Any?
    private let addLocalMonitor: (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> Void
    ) -> Any?
    private let removeMonitor: (Any) -> Void
    private let middleClickMonitor: LayoutWheelMiddleClickMonitoring
    private var phase = Phase.idle
    private var activationTask: Task<Void, Never>?
    private var activationGeneration = 0
    /// Blocks a second gesture while the trigger is still held. Without it the
    /// hold that just committed would immediately start another activation.
    private var isArmed = true
    private var isStarted = false
    private var isSuspended = false
    private var keyboardMonitoringFailure: String?
    private var middleClickMonitoringFailure: String?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?

    public convenience init(configuration: BetterTileConfiguration) {
        self.init(configuration: configuration, presenter: LayoutWheelPanelPresenter())
    }

    init(
        configuration: BetterTileConfiguration,
        presenter: LayoutWheelPresenting,
        metrics: LayoutWheelMetrics = .standard,
        activationDelay: Duration = LayoutWheelController.activationDelay,
        pointerProvider: @escaping @MainActor () -> BTPoint = LayoutWheelController.systemPointerPosition,
        addGlobalMonitor: @escaping (
            NSEvent.EventTypeMask,
            @escaping (NSEvent) -> Void
        ) -> Any? = { mask, handler in
            NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        },
        addLocalMonitor: @escaping (
            NSEvent.EventTypeMask,
            @escaping (NSEvent) -> Void
        ) -> Any? = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                handler(event)
                return event
            }
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) },
        middleClickMonitor: LayoutWheelMiddleClickMonitoring = LayoutWheelMiddleClickMonitor()
    ) {
        self.configuration = configuration
        self.presenter = presenter
        self.metrics = metrics
        self.activationDelay = activationDelay
        self.pointerProvider = pointerProvider
        self.addGlobalMonitor = addGlobalMonitor
        self.addLocalMonitor = addLocalMonitor
        self.removeMonitor = removeMonitor
        self.middleClickMonitor = middleClickMonitor
        middleClickMonitor.eventHandler = { [weak self] event in
            self?.handleMiddleClick(event)
        }
        middleClickMonitor.failureHandler = { [weak self] failure in
            self?.middleClickMonitoringFailure = failure
            if failure != nil, self?.isMiddleClickGestureOpen == true {
                self?.cancel()
            }
            self?.publishMonitoringFailure()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        isStarted = true
        syncMonitoring()
    }

    public func stop() {
        isStarted = false
        cancel()
        syncMonitoring()
    }

    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        cancel()
        syncMonitoring()
    }

    public func resume() {
        guard isSuspended else {
            syncMonitoring()
            return
        }
        isSuspended = false
        syncMonitoring()
    }

    private var wheel: LayoutWheelConfiguration { configuration.layoutWheel }

    private var isKeyboardTriggerEnabled: Bool {
        !isSuspended && wheel.isEnabled && wheel.keyboardTriggerEnabled
    }

    private var isMiddleClickTriggerEnabled: Bool {
        !isSuspended && wheel.isEnabled && wheel.middleClickTriggerEnabled
    }

    private var isMiddleClickGestureOpen: Bool {
        guard case let .open(session) = phase else { return false }
        return session.trigger == .middleClick
    }

    /// Watches modifiers while the trigger is enabled, and nothing else.
    ///
    /// Key and pointer monitors exist only for the life of one gesture: the key
    /// monitor from the moment the hold starts, the pointer monitor from the
    /// moment the wheel opens. Outside a gesture BetterTile observes no
    /// keystrokes and no pointer movement for this feature.
    private func syncMonitoring() {
        if isStarted, isKeyboardTriggerEnabled {
            let handler: (NSEvent) -> Void = { [weak self] event in
                let modifiers = ShortcutModifiers(event.modifierFlags)
                Task { @MainActor in self?.handleModifiers(modifiers) }
            }
            if flagsMonitor == nil {
                flagsMonitor = addGlobalMonitor([.flagsChanged], handler)
            }
            if localFlagsMonitor == nil {
                localFlagsMonitor = addLocalMonitor([.flagsChanged], handler)
            }
            if flagsMonitor == nil || localFlagsMonitor == nil {
                keyboardMonitoringFailure =
                    "BetterTile could not monitor the Layout Wheel modifier trigger."
                publishMonitoringFailure()
            }
        } else {
            if let flagsMonitor {
                removeMonitor(flagsMonitor)
                self.flagsMonitor = nil
            }
            if let localFlagsMonitor {
                removeMonitor(localFlagsMonitor)
                self.localFlagsMonitor = nil
            }
        }
        if isStarted, isMiddleClickTriggerEnabled {
            if !middleClickMonitor.isRunning {
                _ = middleClickMonitor.start()
            }
        } else {
            middleClickMonitor.stop()
            middleClickMonitoringFailure = nil
        }
        _ = syncGestureMonitors()
        publishMonitoringFailure()
    }

    @discardableResult
    private func syncGestureMonitors() -> Bool {
        let needsKeys: Bool
        let needsPointer: Bool
        switch phase {
        case .idle:
            needsKeys = false
            needsPointer = false
        case .pending:
            needsKeys = true
            needsPointer = false
        case let .open(session):
            needsKeys = true
            needsPointer = session.trigger == .keyboard
        }

        if needsKeys, keyMonitor == nil || localKeyMonitor == nil {
            let handler: (NSEvent) -> Void = { [weak self] event in
                let keyCode = event.keyCode
                Task { @MainActor in self?.handleKeyDown(keyCode: keyCode) }
            }
            if keyMonitor == nil { keyMonitor = addGlobalMonitor([.keyDown], handler) }
            if localKeyMonitor == nil { localKeyMonitor = addLocalMonitor([.keyDown], handler) }
        } else if !needsKeys {
            if let keyMonitor {
                removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let localKeyMonitor {
                removeMonitor(localKeyMonitor)
                self.localKeyMonitor = nil
            }
        }

        if needsPointer, pointerMonitor == nil || localPointerMonitor == nil {
            let mask: NSEvent.EventTypeMask = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            ]
            let handler: (NSEvent) -> Void = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let frame = NSScreen.screens.first?.frame else { return }
                    handlePointer(GlobalGestureEvent.position(
                        nsEventMouseLocation: NSEvent.mouseLocation,
                        primaryScreenFrame: frame
                    ))
                }
            }
            if pointerMonitor == nil { pointerMonitor = addGlobalMonitor(mask, handler) }
            if localPointerMonitor == nil { localPointerMonitor = addLocalMonitor(mask, handler) }
        } else if !needsPointer {
            if let pointerMonitor {
                removeMonitor(pointerMonitor)
                self.pointerMonitor = nil
            }
            if let localPointerMonitor {
                removeMonitor(localPointerMonitor)
                self.localPointerMonitor = nil
            }
        }

        guard (!needsKeys || (keyMonitor != nil && localKeyMonitor != nil)),
              (!needsPointer || (pointerMonitor != nil && localPointerMonitor != nil))
        else {
            failGestureMonitoring()
            return false
        }
        if !isKeyboardTriggerEnabled || (flagsMonitor != nil && localFlagsMonitor != nil) {
            keyboardMonitoringFailure = nil
            publishMonitoringFailure()
        }
        return true
    }

    private func failGestureMonitoring() {
        let wasOpen = isOpen
        phase = .idle
        activationTask?.cancel()
        activationTask = nil
        isArmed = false
        if let keyMonitor {
            removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let localKeyMonitor {
            removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let pointerMonitor {
            removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
        if let localPointerMonitor {
            removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if wasOpen {
            presenter.hidePlacements()
            presenter.close()
            gestureEndedHandler?()
        }
        keyboardMonitoringFailure = "BetterTile could not monitor the active Layout Wheel gesture."
        publishMonitoringFailure()
    }

    private func publishMonitoringFailure() {
        monitoringFailureHandler?(middleClickMonitoringFailure ?? keyboardMonitoringFailure)
    }

    // MARK: - Trigger

    /// A modifier change either starts the activation hold, or ends whatever
    /// the gesture was doing.
    func handleModifiers(_ modifiers: ShortcutModifiers) {
        let supported = modifiers.intersection(LayoutWheelConfiguration.supportedKeyboardModifiers)
        // Exact match, so additional modifiers do not open a wheel the user did
        // not ask for.
        let matchesTrigger = supported == wheel.keyboardModifiers

        guard matchesTrigger else {
            isArmed = true
            switch phase {
            case .idle: break
            case .pending: cancelPendingActivation()
            case let .open(session):
                if session.trigger == .keyboard { release() }
            }
            return
        }

        guard isKeyboardTriggerEnabled, isArmed, case .idle = phase else { return }
        beginPendingActivation()
    }

    private func beginPendingActivation() {
        activationGeneration &+= 1
        let generation = activationGeneration
        phase = .pending(generation: generation)
        guard syncGestureMonitors() else { return }
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self, activationDelay] in
            try? await Task.sleep(for: activationDelay)
            guard !Task.isCancelled else { return }
            self?.handleActivationDeadline(generation: generation)
        }
    }

    /// Any ordinary key press during the hold means the user is running a
    /// keyboard shortcut, not opening the wheel.
    public func cancelPendingActivation() {
        guard case .pending = phase else { return }
        activationTask?.cancel()
        activationTask = nil
        phase = .idle
        syncGestureMonitors()
        // The trigger modifiers are still down; do not reopen until released.
        isArmed = false
    }

    private func handleKeyDown(keyCode: UInt16) {
        if isOpen, let key = LayoutWheelKey(keyCode: keyCode) {
            handleKey(key)
            return
        }
        cancelPendingActivation()
    }

    func handleActivationDeadline(generation: Int) {
        guard case let .pending(pending) = phase, pending == generation else { return }
        activationTask = nil
        open(anchor: pointerProvider(), trigger: .keyboard)
    }

    // MARK: - Session

    private func open(anchor: BTPoint, trigger: Trigger) {
        guard let target = captureHandler?() else {
            // Nothing eligible to act on. Do not open an empty wheel.
            phase = .idle
            syncGestureMonitors()
            isArmed = false
            return
        }
        let placement = LayoutWheelPlacement.clamped(
            anchor: anchor,
            diameter: metrics.diameter(for: wheel.levelCount),
            contentHeight: metrics.presentationHeight(for: wheel.levelCount),
            visibleFrame: target.visibleFrame
        )
        var session = Session(target: target, trigger: trigger, placement: placement)
        session.selection = selection(for: anchor, placement: placement)
        phase = .open(session)
        guard syncGestureMonitors() else { return }
        gestureBeganHandler?()
        presenter.open(presentation(for: session))
        refreshPreview()
    }

    func handleMiddleClick(_ event: LayoutWheelMiddleClickEvent) {
        guard isStarted, isMiddleClickTriggerEnabled else { return }
        switch event.kind {
        case .down:
            guard case .idle = phase else { return }
            open(anchor: event.position, trigger: .middleClick)
        case .dragged:
            guard isMiddleClickGestureOpen else { return }
            handlePointer(event.position)
        case .up:
            guard isMiddleClickGestureOpen else { return }
            release()
        }
    }

    func handlePointer(_ position: BTPoint) {
        guard case var .open(session) = phase else { return }
        let updated = selection(for: position, placement: session.placement)
        guard updated != session.selection else { return }
        session.selection = updated
        phase = .open(session)
        presenter.update(presentation(for: session))
        refreshPreview()
    }

    func handleKey(_ key: LayoutWheelKey) {
        guard case var .open(session) = phase else { return }
        switch key {
        case .escape:
            cancel()
        case .commit:
            release()
        default:
            let updated = LayoutWheelKeyboard.selection(
                for: key,
                from: session.selection,
                levelCount: wheel.levelCount
            )
            guard updated != session.selection else { return }
            session.selection = updated
            phase = .open(session)
            presenter.update(presentation(for: session))
            refreshPreview()
        }
    }

    /// Selection is measured from the anchor, never from the drawn centre, so
    /// clamping the wheel onto the display cannot rotate the directions.
    private func selection(
        for position: BTPoint,
        placement: LayoutWheelPlacement
    ) -> LayoutWheelSelection? {
        metrics.geometry.selection(
            for: BTPoint(
                x: position.x - placement.anchor.x,
                y: position.y - placement.anchor.y
            ),
            levelCount: wheel.levelCount
        )
    }

    private func presentation(for session: Session) -> LayoutWheelPresentation {
        LayoutWheelPresentation(
            configuration: wheel,
            customZones: configuration.customZones,
            placement: session.placement,
            selection: session.selection,
            unavailableCommands: Set(session.unavailableReasons.keys)
        )
    }

    /// Previews are planning only. An unavailable command marks its sector and
    /// shows nothing, so the wheel never implies a placement that cannot happen.
    private func refreshPreview() {
        guard case var .open(session) = phase else { return }
        guard let selection = session.selection,
              let command = wheel.command(at: selection)
        else {
            presenter.hidePlacements()
            return
        }
        switch previewHandler?(command, session.target) {
        case let .ready(placements):
            session.unavailableReasons.removeValue(forKey: command)
            phase = .open(session)
            presenter.update(presentation(for: session))
            presenter.showPlacements(placements)
        case let .unavailable(reason):
            session.unavailableReasons[command] = reason
            phase = .open(session)
            presenter.update(presentation(for: session))
            presenter.hidePlacements()
            Self.log.debug("layout wheel command unavailable: \(reason, privacy: .public)")
        case nil:
            presenter.hidePlacements()
        }
    }

    // MARK: - Ending

    /// Releasing the trigger. Commits the selected command exactly once, or
    /// cancels when the release lands on the hub, the dead band, or Empty.
    func release() {
        guard case let .open(session) = phase else { return }
        // Ending the phase first makes a duplicate release a no-op, so a
        // repeated flagsChanged or a deactivation cannot commit twice.
        finish()
        guard let selection = session.selection,
              let command = wheel.command(at: selection)
        else { return }
        if let reason = session.unavailableReasons[command] {
            unavailableHandler?(reason, session.target)
        } else {
            commitHandler?(command, session.target)
        }
    }

    public func cancel() {
        guard case .open = phase else {
            cancelPendingActivation()
            return
        }
        finish()
    }

    /// The captured window went away. The gesture ends rather than moving on to
    /// whatever replaced it.
    public func handleTargetLost(windowID: WindowID) {
        guard case let .open(session) = phase, session.target.windowID == windowID else { return }
        cancel()
    }

    public func handleApplicationDeactivated() {
        cancel()
    }

    public func handleFocusedWindowChanged() {
        cancel()
    }

    private func finish() {
        let endedWithKeyboard: Bool
        if case let .open(session) = phase {
            endedWithKeyboard = session.trigger == .keyboard
        } else {
            endedWithKeyboard = false
        }
        phase = .idle
        activationTask?.cancel()
        activationTask = nil
        if endedWithKeyboard {
            isArmed = false
        }
        syncGestureMonitors()
        presenter.hidePlacements()
        presenter.close()
        gestureEndedHandler?()
    }

    static func systemPointerPosition() -> BTPoint {
        guard let frame = NSScreen.screens.first?.frame else { return BTPoint(x: 0, y: 0) }
        return GlobalGestureEvent.position(
            nsEventMouseLocation: NSEvent.mouseLocation,
            primaryScreenFrame: frame
        )
    }
}

extension LayoutWheelKey {
    /// Only the keys the wheel acts on. Everything else stays an ordinary key
    /// press for the focused application.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 53: self = .escape
        case 36, 76: self = .commit
        case 48: self = .switchRing
        case 123: self = .previousSector
        case 124: self = .nextSector
        case 126: self = .outerRing
        case 125: self = .innerRing
        default: return nil
        }
    }
}

/// Presents the wheel in a borderless, nonactivating panel that never takes key
/// focus, plus the shared wireframe preview panels.
@MainActor
final class LayoutWheelPanelPresenter: LayoutWheelPresenting {
    private let panel: NSPanel
    private let placementPreviews = PlacementWireframeController()
    private var hosting: NSHostingView<LayoutWheelView>?

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The wheel is driven by global pointer events, so it must never take a
        // click away from the window underneath it.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = .none
    }

    func open(_ presentation: LayoutWheelPresentation) {
        let view = NSHostingView(rootView: LayoutWheelView(presentation))
        hosting = view
        panel.contentView = view
        position(view: view, at: presentation.placement)
        panel.orderFrontRegardless()
    }

    func update(_ presentation: LayoutWheelPresentation) {
        guard let hosting else { return }
        hosting.rootView = LayoutWheelView(presentation)
        position(view: hosting, at: presentation.placement)
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        hosting = nil
    }

    func showPlacements(_ placements: [Placement]) {
        placementPreviews.show(placements)
    }

    func hidePlacements() {
        placementPreviews.hide()
    }

    /// The wheel sits on the placement centre.
    private func position(view: NSView, at placement: LayoutWheelPlacement) {
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        let size = view.fittingSize
        let frame = BTRect(
            x: placement.center.x - size.width / 2,
            y: placement.center.y - placement.diameter / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(
            CoordinateConverter.toAppKit(frame, mainScreenFrame: mainFrame),
            display: true
        )
    }
}

private extension LayoutWheelView {
    init(_ presentation: LayoutWheelPresentation) {
        self.init(
            configuration: presentation.configuration,
            customZones: presentation.customZones,
            selection: presentation.selection,
            unavailableCommands: presentation.unavailableCommands
        )
    }
}
