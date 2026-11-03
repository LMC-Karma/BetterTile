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
    public var windowID: WindowID?
    public var displayID: DisplayID
    public var visibleFrame: BTRect
    public var layoutMode: LayoutMode?
    public var desktopSessionID: DesktopSessionID?
    public var nativeSpaceID: NativeSpaceID?

    public init(windowID: WindowID? = nil, displayID: DisplayID, visibleFrame: BTRect,
                desktopSessionID: DesktopSessionID? = nil, nativeSpaceID: NativeSpaceID? = nil, layoutMode: LayoutMode? = nil) {
        self.windowID = windowID
        self.displayID = displayID
        self.visibleFrame = visibleFrame
        self.layoutMode = layoutMode
        self.desktopSessionID = desktopSessionID
        self.nativeSpaceID = nativeSpaceID
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
    public var overlayAppearance: OverlayAppearance = .init()
    public var placement: LayoutWheelPlacement
    public var selection: LayoutWheelSelection?
    public var unavailableCommands: Set<LayoutWheelCommand>
    public var fan: LayoutWheelFanState = .init()
    public var pointer: BTPoint?
    public var layoutAvailable: Bool = true
    /// The mode of the target desktop. The Mode parent shows its icon.
    public var currentMode: LayoutMode?
}

@MainActor
protocol LayoutWheelPresenting: AnyObject {
    var usesLiquidGeometry: Bool { get }
    /// Called when the presenter loses the open wheel it was drawing. The
    /// controller then ends the gesture, so no command is chosen from a
    /// wheel the user cannot see correctly.
    var presentationFailureHandler: (@MainActor () -> Void)? { get set }
    func prewarm(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance)
    /// Called when a gesture is about to open, whatever starts it (a keyboard hold or a mouse button).
    /// A presenter drops anything that belonged to an earlier gesture.
    func beginGesture()
    func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance)
    func discardPreparation()
    func open(_ presentation: LayoutWheelPresentation)
    func update(_ presentation: LayoutWheelPresentation)
    func showPlacements(_ placements: [Placement])
    func hidePlacements()
    func close()
    func end(_ acknowledgment: LayoutWheelAcknowledgment)
}

extension LayoutWheelPresenting {
    var usesLiquidGeometry: Bool { false }
    var presentationFailureHandler: (@MainActor () -> Void)? { get { nil } set {} }
    func prewarm(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {}
    func beginGesture() {}
    func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {}
    func discardPreparation() {}

    func end(_ acknowledgment: LayoutWheelAcknowledgment) { close() }
}

/// Owns the Layout Wheel gesture: the activation hold, the captured target, the
/// panel, pointer and keyboard selection, and every way the gesture can end.
///
/// It never mutates a window. Selection produces previews and one commit
/// request; the model decides what those mean.
@MainActor
public final class LayoutWheelController {
    public static let activationDelay: Duration = .milliseconds(220)

    /// Fixed diagnostic values only. Never include event content or window data.
    public enum CancellationReason: String {
        case requested, pendingCancellation, configurationChanged, stopped, suspended
        case triggerReleased, extraModifier, ordinaryKey, applicationDeactivated, applicationActivated
        case focusedWindowChanged, shortcut, displayChanged, spaceChanged, waking
        case permissionUnavailable, shortcutRecording, mouseDown, presenterFailed
    }

    public var configuration: BetterTileConfiguration {
        didSet {
            if configuration.layoutWheel != oldValue.layoutWheel || configuration.overlayAppearance != oldValue.overlayAppearance {
                presenter.prewarm(configuration: configuration.layoutWheel, appearance: configuration.overlayAppearance)
            }
            guard configuration.layoutWheel != oldValue.layoutWheel else {
                if configuration.overlayAppearance != oldValue.overlayAppearance, case let .open(session) = phase {
                    presenter.update(presentation(for: session))
                }
                return
            }
            // Changing the trigger or the assignments mid-gesture would apply
            // something the user never aimed at.
            if configuration.layoutWheel.triggers != oldValue.layoutWheel.triggers {
                retireModifierMonitors()
            }
            cancel(reason: .configurationChanged)
            syncMonitoring()
        }
    }

    /// Returns the window and display to act on, or nil when nothing is
    /// eligible. Called once, when the hold succeeds.
    /// Receives the top-left point the wheel opens at: the pointer when the
    /// hold ends, or the middle-click position.
    public var captureHandler: ((_ pointer: BTPoint) -> LayoutWheelTarget?)?
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

    // Observes the same privacy-safe messages sent to the unified log.
    // Internal so fake-system tests need no access to the system log store.
    var activationLogHandler: ((String) -> Void)?

    private func recordActivation(_ message: String) {
        Self.log.debug("\(message, privacy: .public)")
        activationLogHandler?(message)
    }

    private static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "LayoutWheel"
    )

    private enum Phase {
        case idle
        case pending(generation: Int, trigger: Trigger)
        case open(Session)
    }

    private enum Trigger {
        case keyboard
        case rightControl
        case middleClick
    }

    private struct Session {
        var target: LayoutWheelTarget
        var trigger: Trigger
        var placement: LayoutWheelPlacement
        var selection: LayoutWheelSelection?
        var fan = LayoutWheelFanState()
        var pointerVector: BTPoint?
        /// The last position Custom saw, so release can apply a queued sample.
        var lastPointerPosition: BTPoint?
        var previewedFan: LayoutWheelSector?
        var hasPointerMoved = false
        var unavailableReasons: [LayoutWheelCommand: String] = [:]
        // Debug diagnostics only. Never read by selection or dispatch.
        var openedAt: TimeInterval = 0
        var pointerSamples = 0
        var lastSampleAt: TimeInterval?
    }
    private var holdBeganAt: TimeInterval = 0
    // Remains set through target capture and monitor installation. Those can
    // skip an open after the pending phase has become an open session.
    private var unresolvedHold: Int?

    private func recordActivationOutcome(_ outcome: String, reason: String) {
        guard let hold = unresolvedHold else { return }
        unresolvedHold = nil
        recordActivation("wheel hold outcome: hold=\(hold) outcome=\(outcome) reason=\(reason) after=\(holdElapsedMilliseconds) ms")
    }

    private var holdElapsedMilliseconds: String {
        String(format: "%.0f", (now() - holdBeganAt) * 1000)
    }

    private let presenter: LayoutWheelPresenting
    private let metrics: LayoutWheelMetrics
    private let activationDelay: Duration
    private let activationWait: @MainActor (Duration) async throws -> Void
    private let pointerProvider: @MainActor () -> BTPoint
    private let addGlobalMonitor: (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> Void
    ) -> Any?
    private let addLocalMonitor: (
        NSEvent.EventTypeMask,
        @escaping @MainActor (LayoutWheelInput) -> Bool
    ) -> Any?
    private let modifierFlagsProvider: @MainActor () -> UInt?
    private var lastModifierInput = LayoutWheelInput()
    private var middleClickIsHeld = false
    private let removeMonitor: (Any) -> Void
    private let middleClickMonitor: LayoutWheelMiddleClickMonitoring
    private var phase = Phase.idle
    private var activationTask: Task<Void, Never>?
    private var fanTask: Task<Void, Never>?
    private let now: @MainActor () -> TimeInterval
    private var activationGeneration = 0
    /// Blocks a second gesture while the trigger is still held. Without it the
    /// hold that just committed would immediately start another activation.
    private var isArmed = true
    private var isStarted = false
    private var flagsMonitorGeneration: UInt64 = 0
    private var keyMonitorGeneration: UInt64 = 0
    private var pointerMonitorGeneration: UInt64 = 0
    private var mouseDownMonitorGeneration: UInt64 = 0
    private var isSuspended = false
    private var keyboardMonitoringFailure: String?
    private var middleClickMonitoringFailure: String?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var mouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?

    public convenience init(configuration: BetterTileConfiguration) {
        self.init(configuration: configuration, presenter: LayoutWheelLiquidAdapter.make(),
                  modifierFlagsProvider: { NSEvent.modifierFlags.rawValue })
    }

    init(
        configuration: BetterTileConfiguration,
        presenter: LayoutWheelPresenting,
        metrics: LayoutWheelMetrics = .standard,
        activationDelay: Duration = LayoutWheelController.activationDelay,
        activationWait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pointerProvider: @escaping @MainActor () -> BTPoint = LayoutWheelController.systemPointerPosition,
        addGlobalMonitor: @escaping (
            NSEvent.EventTypeMask,
            @escaping (NSEvent) -> Void
        ) -> Any? = { mask, handler in
            NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        },
        addLocalMonitor: @escaping (
            NSEvent.EventTypeMask,
            @escaping @MainActor (LayoutWheelInput) -> Bool
        ) -> Any? = { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                // The pointer monitor shares this closure: never read key-only
                // properties here directly.
                let input = LayoutWheelController.localMonitorInput(for: event)
                let consumed = MainActor.assumeIsolated { handler(input) }
                return consumed ? nil : event
            }
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) },
        modifierFlagsProvider: @escaping @MainActor () -> UInt? = { nil },
        middleClickMonitor: LayoutWheelMiddleClickMonitoring = LayoutWheelMiddleClickMonitor()
    ) {
        self.configuration = configuration
        self.presenter = presenter
        self.metrics = metrics
        self.activationDelay = activationDelay
        self.activationWait = activationWait
        self.now = now
        self.pointerProvider = pointerProvider
        self.addGlobalMonitor = addGlobalMonitor
        self.addLocalMonitor = addLocalMonitor
        self.removeMonitor = removeMonitor
        self.modifierFlagsProvider = modifierFlagsProvider
        self.middleClickMonitor = middleClickMonitor
        presenter.presentationFailureHandler = { [weak self] in self?.cancel(reason: .presenterFailed) }
        middleClickMonitor.eventHandler = { [weak self] event in
            self?.handleMiddleClick(event)
        }
        middleClickMonitor.failureHandler = { [weak self] failure in
            self?.middleClickMonitoringFailure = failure
            if failure != nil {
                if self?.isMiddleClickGestureOpen == true { self?.cancel() }
                self?.middleClickIsHeld = false
                if let self { self.isArmed = self.keyboardIsNeutral(self.lastModifierInput) }
                self?.syncMouseOwnership()
            }
            self?.publishMonitoringFailure()
        }
    }

    /// Reads what a local monitor needs from an event. The pointer monitor
    /// shares this path, and AppKit throws when a mouse event is asked for its
    /// key code, which drops the event before the wheel sees it.
    nonisolated static func localMonitorInput(for event: NSEvent) -> LayoutWheelInput {
        let keyCode: UInt16
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged: keyCode = event.keyCode
        default: keyCode = 0
        }
        return LayoutWheelInput(keyCode: keyCode, flags: event.modifierFlags)
    }

    isolated deinit {
        recordActivationOutcome("cancel", reason: "controllerReleased")
    }

    // MARK: - Lifecycle

    public func start() {
        presenter.prewarm(configuration: wheel, appearance: configuration.overlayAppearance)
        isStarted = true
        syncMonitoring()
    }

    public func stop() {
        isStarted = false
        cancel(reason: .stopped)
        syncMonitoring()
    }

    public func suspend(reason: CancellationReason = .suspended) {
        guard !isSuspended else { return }
        isSuspended = true
        cancel(reason: reason)
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
    private var cachedLiquidContent: LayoutWheelLiquidContent?

    private var effectiveMetrics: LayoutWheelMetrics {
        (wheel.style == .grouped && !presenter.usesLiquidGeometry ? .grouped : metrics).scaled(by: wheel.scale)
    }

    private var liquidContent: LayoutWheelLiquidContent {
        if let cachedLiquidContent, cachedLiquidContent.configuration == wheel { return cachedLiquidContent }
        let content = LayoutWheelLiquidDefaults.content(configuration: wheel)
        cachedLiquidContent = content
        return content
    }

    private func updateFan(_ fan: inout LayoutWheelFanState, vector: BTPoint, layoutAvailable: Bool) {
        if presenter.usesLiquidGeometry, liquidContent.submenuLayout != nil {
            LayoutWheelLiquidDefaults.updateFan(&fan, vector: vector, at: now(), content: liquidContent,
                                                configuration: wheel, layoutAvailable: layoutAvailable)
        } else {
            fan.update(vector: vector, at: now(), geometry: effectiveMetrics.fanGeometry(for: wheel),
                       layoutAvailable: layoutAvailable)
        }
    }

    private var isKeyboardTriggerEnabled: Bool {
        !isSuspended && wheel.isEnabled && wheel.triggers.keyboardEnabled
    }

    private var isMiddleClickTriggerEnabled: Bool {
        !isSuspended && wheel.isEnabled && wheel.triggers.mouse != .off
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
    #if BETTERTILE_TEST_HOOKS
    /// Runs after the main-actor task of each global modifier or key event has finished.
    var globalInputHandledForTesting: (@MainActor () -> Void)?
    /// The pending activation task, for a test that must join it before stop() clears it.
    var activationTaskForTesting: Task<Void, Never>? { activationTask }
    #endif

    private func syncMonitoring() {
        if isStarted, isKeyboardTriggerEnabled {
            let generation = flagsMonitorGeneration
            let handler: (NSEvent) -> Void = { [weak self] event in
                let input = Self.localMonitorInput(for: event)
                Task { @MainActor in
                    #if BETTERTILE_TEST_HOOKS
                    defer { self?.globalInputHandledForTesting?() }
                    #endif
                    guard let self, self.isStarted, self.flagsMonitorGeneration == generation else { return }
                    self.handleModifierInput(input)
                }
            }
            if flagsMonitor == nil, localFlagsMonitor == nil, let flags = modifierFlagsProvider() {
                let input = LayoutWheelInput(flags: NSEvent.ModifierFlags(rawValue: flags))
                lastModifierInput = input
                isArmed = keyboardIsNeutral(input)
            }
            if flagsMonitor == nil {
                flagsMonitor = addGlobalMonitor([.flagsChanged], handler)
            }
            if localFlagsMonitor == nil {
                localFlagsMonitor = addLocalMonitor([.flagsChanged]) { [weak self] input in
                    guard let self, self.isStarted, self.flagsMonitorGeneration == generation else { return false }
                    self.handleModifierInput(input)
                    return false
                }
            }
            if flagsMonitor == nil || localFlagsMonitor == nil {
                keyboardMonitoringFailure =
                    "BetterTile could not monitor the Layout Wheel modifier trigger."
                publishMonitoringFailure()
            }
        } else {
            retireModifierMonitors()
        }
        middleClickMonitor.trigger = wheel.triggers.mouse
        if isStarted, isMiddleClickTriggerEnabled {
            if !middleClickMonitor.isRunning {
                _ = middleClickMonitor.start()
            }
        } else {
            middleClickMonitor.stop()
            middleClickIsHeld = false
            middleClickMonitoringFailure = nil
        }
        _ = syncGestureMonitors()
        publishMonitoringFailure()
    }

    private func retireModifierMonitors() {
        flagsMonitorGeneration &+= 1
        if let flagsMonitor { removeMonitor(flagsMonitor); self.flagsMonitor = nil }
        if let localFlagsMonitor { removeMonitor(localFlagsMonitor); self.localFlagsMonitor = nil }
    }

    @discardableResult
    private func syncGestureMonitors() -> Bool {
        syncMouseOwnership()
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
            needsPointer = session.trigger != .middleClick
        }

        let needsMouseDown: Bool
        switch phase {
        case let .pending(_, trigger): needsMouseDown = trigger == .rightControl
        case let .open(session): needsMouseDown = session.trigger == .rightControl
        case .idle: needsMouseDown = false
        }
        if needsMouseDown, mouseDownMonitor == nil || localMouseDownMonitor == nil {
            let generation = mouseDownMonitorGeneration
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            if mouseDownMonitor == nil {
                mouseDownMonitor = addGlobalMonitor(mask) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.mouseDownMonitorGeneration == generation else { return }
                        self.cancel(reason: .mouseDown)
                    }
                }
            }
            if localMouseDownMonitor == nil {
                localMouseDownMonitor = addLocalMonitor(mask) { [weak self] _ in
                    guard let self, self.mouseDownMonitorGeneration == generation else { return false }
                    self.cancel(reason: .mouseDown)
                    return false
                }
            }
        } else if !needsMouseDown {
            mouseDownMonitorGeneration &+= 1
            if let mouseDownMonitor { removeMonitor(mouseDownMonitor); self.mouseDownMonitor = nil }
            if let localMouseDownMonitor { removeMonitor(localMouseDownMonitor); self.localMouseDownMonitor = nil }
        }

        if needsKeys, keyMonitor == nil || localKeyMonitor == nil {
            let generation = keyMonitorGeneration
            let globalHandler: (NSEvent) -> Void = { [weak self] event in
                let keyCode = event.keyCode
                Task { @MainActor in
                    #if BETTERTILE_TEST_HOOKS
                    defer { self?.globalInputHandledForTesting?() }
                    #endif
                    guard let self, self.keyMonitorGeneration == generation else { return }
                    self.handleKeyDown(keyCode: keyCode)
                }
            }
            if keyMonitor == nil { keyMonitor = addGlobalMonitor([.keyDown], globalHandler) }
            if localKeyMonitor == nil {
                localKeyMonitor = addLocalMonitor([.keyDown]) { [weak self] input in
                    guard let self, self.keyMonitorGeneration == generation else { return false }
                    return self.handleLocalKeyDown(keyCode: input.keyCode)
                }
            }
        } else if !needsKeys {
            keyMonitorGeneration &+= 1
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
            let generation = pointerMonitorGeneration
            let mask: NSEvent.EventTypeMask = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            ]
            let handler: (NSEvent) -> Void = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, pointerMonitorGeneration == generation, let frame = NSScreen.screens.first?.frame else { return }
                    handlePointer(GlobalGestureEvent.position(
                        nsEventMouseLocation: NSEvent.mouseLocation,
                        primaryScreenFrame: frame
                    ))
                }
            }
            if pointerMonitor == nil { pointerMonitor = addGlobalMonitor(mask, handler) }
            if localPointerMonitor == nil {
                localPointerMonitor = addLocalMonitor(mask) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, pointerMonitorGeneration == generation, let frame = NSScreen.screens.first?.frame else { return }
                        handlePointer(GlobalGestureEvent.position(
                            nsEventMouseLocation: NSEvent.mouseLocation,
                            primaryScreenFrame: frame
                        ))
                    }
                    return false
                }
            }
        } else if !needsPointer {
            pointerMonitorGeneration &+= 1
            if let pointerMonitor {
                removeMonitor(pointerMonitor)
                self.pointerMonitor = nil
            }
            if let localPointerMonitor {
                removeMonitor(localPointerMonitor)
                self.localPointerMonitor = nil
            }
        }

        guard !needsMouseDown || (mouseDownMonitor != nil && localMouseDownMonitor != nil) else {
            failGestureMonitoring(reason: "mouseDownMonitoringFailed")
            return false
        }
        guard (!needsKeys || (keyMonitor != nil && localKeyMonitor != nil)),
              (!needsPointer || (pointerMonitor != nil && localPointerMonitor != nil))
        else {
            let reason = needsKeys && (keyMonitor == nil || localKeyMonitor == nil)
                ? "keyMonitoringFailed" : "pointerMonitoringFailed"
            failGestureMonitoring(reason: reason)
            return false
        }
        if !isKeyboardTriggerEnabled || (flagsMonitor != nil && localFlagsMonitor != nil) {
            keyboardMonitoringFailure = nil
            publishMonitoringFailure()
        }
        return true
    }

    private func failGestureMonitoring(reason: String) {
        recordActivationOutcome("skip", reason: reason)
        let wasOpen = isOpen
        phase = .idle
        presenter.discardPreparation()
        fanTask?.cancel()
        fanTask = nil
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
        mouseDownMonitorGeneration &+= 1
        if let mouseDownMonitor { removeMonitor(mouseDownMonitor); self.mouseDownMonitor = nil }
        if let localMouseDownMonitor { removeMonitor(localMouseDownMonitor); self.localMouseDownMonitor = nil }
        syncMouseOwnership()
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
        handleModifierInput(LayoutWheelInput(modifiers: modifiers))
    }

    func handleModifierInput(_ input: LayoutWheelInput) {
        // A held arrow key sets the function flag on every later modifier event.
        // Once the wheel is open, only the Fn key's own event counts as Fn, so
        // the chord alone decides the release. That event cancels the open wheel
        // in this same call, so nothing keeps a record of Fn that could go stale,
        // for example when Fn comes up while an arrow key is still down.
        var input = input
        if isOpen, !input.isFunctionKeyEvent { input = input.withoutFunctionFlag }
        lastModifierInput = input
        guard !middleClickIsHeld else { return }
        if wheel.triggers.keyboard == .rightControl { handleRightControl(input) }
        else { handleChordModifiers(input) }
    }

    private func keyboardIsNeutral(_ input: LayoutWheelInput) -> Bool {
        wheel.triggers.keyboard == .rightControl ? input.isNeutral
            : input.modifiers.intersection(wheel.keyboardModifiers).isEmpty
    }

    private func syncMouseOwnership() {
        if case .idle = phase { middleClickMonitor.acceptsNewGesture = !middleClickIsHeld }
        else { middleClickMonitor.acceptsNewGesture = false }
    }

    private func handleRightControl(_ input: LayoutWheelInput) {
        defer { if input.isNeutral { isArmed = true } }
        if input.isRightControlOnly {
            guard isKeyboardTriggerEnabled, isArmed, case .idle = phase else { return }
            guard input.keyCode == LayoutWheelInput.rightControlKeyCode else {
                isArmed = false
                return
            }
            beginPendingActivation(trigger: .rightControl)
            return
        }
        let isRelease = input.isNeutral && input.keyCode == LayoutWheelInput.rightControlKeyCode
        switch phase {
        case .idle:
            if !input.isNeutral { isArmed = false }
        case .pending:
            cancelPendingActivation(reason: isRelease ? .triggerReleased : .extraModifier)
        case let .open(session):
            guard session.trigger == .rightControl else { return }
            if isRelease { releaseKeyboardSession(session) }
            else { cancel(reason: .extraModifier) }
        }
    }

    private func handleChordModifiers(_ input: LayoutWheelInput) {
        let supported = input.modifiers.intersection(LayoutWheelConfiguration.supportedKeyboardModifiers)
        let allTriggerKeysAreUp = supported.intersection(wheel.keyboardModifiers).isEmpty
        // A partial release or removal of an extra modifier must not re-arm
        // a gesture that just ended. A complete release may end and re-arm it.
        defer { if allTriggerKeysAreUp { isArmed = true } }
        let hasExtraModifier = !supported.subtracting(wheel.keyboardModifiers).isEmpty || input.functionIsDown
        // Exact match, so additional modifiers do not open a wheel the user did
        // not ask for.
        let matchesTrigger = supported == wheel.keyboardModifiers && !input.functionIsDown

        guard matchesTrigger else {
            switch phase {
            case .idle:
                if hasExtraModifier && !allTriggerKeysAreUp { isArmed = false }
            case .pending:
                Self.log.debug("""
                    wheel trigger changed before open after \((self.now() - self.holdBeganAt) * 1000, format: .fixed(precision: 0), privacy: .public) ms
                    """)
                cancelPendingActivation(reason: hasExtraModifier ? .extraModifier : .triggerReleased)
            case let .open(session):
                if session.trigger == .keyboard {
                    guard !hasExtraModifier else {
                        cancel(reason: .extraModifier)
                        return
                    }
                    releaseKeyboardSession(session)
                }
            }
            return
        }

        guard isKeyboardTriggerEnabled, isArmed, case .idle = phase else {
            Self.log.debug("""
                wheel trigger ignored: enabled=\(self.isKeyboardTriggerEnabled, privacy: .public) \
                armed=\(self.isArmed, privacy: .public) idle=\(!self.isOpen && !self.isPendingActivation, privacy: .public)
                """)
            return
        }
        beginPendingActivation(trigger: .keyboard)
    }

    private func releaseKeyboardSession(_ session: Session) {
        // Log the delivered samples before any final-pointer resample
        // changes them.
        logRelease("wheel trigger released", session: session,
                   resampling: wheel.style == .custom
                       || session.pointerVector != nil || session.selection == nil)
        // A modifier release can overtake queued pointer callbacks.
        // Grouped's larger hub must not turn a completed flick into
        // a cancellation. Keep deliberate keyboard navigation when
        // it, rather than the pointer, owns the selection.
        if wheel.style == .grouped,
           session.pointerVector != nil || session.selection == nil {
            handlePointer(pointerProvider())
        } else if wheel.style == .custom {
            resampleCustomPointer(at: pointerProvider(), in: session)
        }
        release()
    }

    private func beginPendingActivation(trigger: Trigger) {
        guard !isStarted || (flagsMonitor != nil && localFlagsMonitor != nil) else { return }
        activationGeneration &+= 1
        let generation = activationGeneration
        holdBeganAt = now()
        unresolvedHold = generation
        recordActivation("wheel hold started: hold=\(generation)")
        presenter.prepareToOpen(configuration: wheel, appearance: configuration.overlayAppearance)
        phase = .pending(generation: generation, trigger: trigger)
        guard syncGestureMonitors() else { return }
        activationTask?.cancel()
        let parts = activationDelay.components
        let holdDeadline = holdBeganAt + Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        activationTask = Task { @MainActor [weak self, activationWait] in
            guard !Task.isCancelled, let currentTime = self?.now() else { return }
            if self?.unresolvedHold == generation {
                self?.recordActivation("wheel activation task waiting: hold=\(generation)")
            }
            // Preparation and a busy run-loop turn consume the same hold.
            try? await activationWait(.seconds(max(0, holdDeadline - currentTime)))
            guard !Task.isCancelled else {
                // Normal cancellation already records its reason synchronously.
                // Keep an unexpected cancellation visible without changing policy.
                if self?.unresolvedHold == generation {
                    self?.recordActivationOutcome("skip", reason: "activationTaskCancelled")
                }
                return
            }
            self?.handleActivationDeadline(generation: generation)
        }
        recordActivation("wheel activation task scheduled: hold=\(generation)")
    }

    /// Any ordinary key press during the hold means the user is running a
    /// keyboard shortcut, not opening the wheel.
    public func cancelPendingActivation(reason: CancellationReason = .pendingCancellation) {
        guard case .pending = phase else { return }
        recordActivationOutcome("cancel", reason: reason.rawValue)
        activationTask?.cancel()
        activationTask = nil
        phase = .idle
        presenter.discardPreparation()
        syncGestureMonitors()
        // The trigger modifiers are still down; do not reopen until released.
        isArmed = false
    }

    private func handleKeyDown(keyCode: UInt16) {
        if isOpen {
            if let key = LayoutWheelKey(keyCode: keyCode) {
                handleKey(key)
            } else {
                cancel(reason: .ordinaryKey)
            }
            return
        }
        if case .pending = phase {
            // No key code: this must not become a keystroke log.
            Self.log.debug("""
                wheel hold cancelled by an ordinary key press \((self.now() - self.holdBeganAt) * 1000, format: .fixed(precision: 0), privacy: .public) ms after the hold began
                """)
        }
        cancelPendingActivation(reason: .ordinaryKey)
    }

    /// A local monitor can prevent wheel navigation from also reaching
    /// BetterTile's focused Settings controls. Global monitors remain
    /// observation-only and cannot consume another application's events.
    private func handleLocalKeyDown(keyCode: UInt16) -> Bool {
        let isWheelKey = isOpen && LayoutWheelKey(keyCode: keyCode) != nil
        handleKeyDown(keyCode: keyCode)
        return isWheelKey
    }

    func handleActivationDeadline(generation: Int) {
        guard case let .pending(pending, trigger) = phase, pending == generation else {
            recordActivation("wheel activation deadline ignored: hold=\(generation) current=\(unresolvedHold ?? -1)")
            return
        }
        activationTask = nil
        recordActivation("wheel activation deadline fired \(holdElapsedMilliseconds) ms after the hold began: hold=\(generation)")
        let input = modifierFlagsProvider().map { LayoutWheelInput(flags: NSEvent.ModifierFlags(rawValue: $0)) }
            ?? lastModifierInput
        let matches = trigger == .rightControl ? input.isRightControlOnly
            : input.modifiers == wheel.keyboardModifiers && !input.functionIsDown
        guard matches, !middleClickIsHeld else {
            cancelPendingActivation(reason: .triggerReleased)
            return
        }
        open(anchor: pointerProvider(), trigger: trigger)
    }

    // MARK: - Session

    private func makePlacement(anchor: BTPoint, target: LayoutWheelTarget) -> LayoutWheelPlacement {
        LayoutWheelPlacement.clamped(
            anchor: anchor,
            diameter: presenter.usesLiquidGeometry ? liquidContent.diameter
                : wheel.style == .grouped ? effectiveMetrics.groupedPresentationDiameter
                : effectiveMetrics.presentationDiameter(for: wheel.effectiveLevelCount),
            overflowPadding: presenter.usesLiquidGeometry
                ? LayoutWheelLiquidDefaults.overflowPadding * wheel.appearance.size.scale
                : wheel.style == .grouped ? LayoutWheelMetrics.presentationPadding - 2
                : effectiveMetrics.overflowPadding(for: wheel.effectiveLevelCount),
            visibleFrame: target.visibleFrame
        )
    }

    private func open(anchor: BTPoint, trigger: Trigger) {
        guard let target = captureHandler?(anchor) else {
            // Nothing eligible to act on. Do not open an empty wheel.
            Self.log.debug("wheel open skipped: no eligible window")
            recordActivationOutcome("skip", reason: "noEligibleTarget")
            phase = .idle
            presenter.discardPreparation()
            syncGestureMonitors()
            isArmed = false
            return
        }
        presenter.beginGesture()
        let placement = makePlacement(anchor: anchor, target: target)
        var session = Session(target: target, trigger: trigger, placement: placement)
        session.openedAt = now()
        if target.windowID == nil {
            for action in WindowAction.allCases {
                session.unavailableReasons[.windowAction(action)] = "No eligible focused window."
            }
            session.unavailableReasons[.repairBento] = "No eligible focused window."
        }
        phase = .open(session)
        guard syncGestureMonitors() else { return }
        gestureBeganHandler?()
        Self.log.debug("""
            wheel open requested: style=\(self.wheel.style.rawValue, privacy: .public) \
            scale=\(self.wheel.scale, format: .fixed(precision: 1), privacy: .public) \
            window=\(target.windowID != nil, privacy: .public)
            """)
        recordActivationOutcome("open", reason: "requested")
        let usedLiquidGeometry = presenter.usesLiquidGeometry
        presenter.open(presentation(for: session))
        if usedLiquidGeometry != presenter.usesLiquidGeometry {
            presenter.close()
            session.placement = makePlacement(anchor: anchor, target: target)
            phase = .open(session)
            presenter.open(presentation(for: session))
        }
        Self.log.debug("""
            wheel presenter returned \((self.now() - session.openedAt) * 1000, format: .fixed(precision: 1), privacy: .public) ms after the open request
            """)
        refreshPreview()
    }

    func handleMiddleClick(_ event: LayoutWheelMiddleClickEvent) {
        guard isStarted, isMiddleClickTriggerEnabled, event.button == 2 else { return }
        switch event.kind {
        case .down:
            guard case .idle = phase, !middleClickIsHeld,
                  LayoutWheelMiddleClickEvent.reserves(button: event.button, modifiers: event.modifiers,
                                                      trigger: wheel.triggers.mouse) else { return }
            middleClickIsHeld = true
            open(anchor: event.position, trigger: .middleClick)
        case .dragged:
            guard isMiddleClickGestureOpen else { return }
            handlePointer(event.position)
        case .up:
            middleClickIsHeld = false
            isArmed = keyboardIsNeutral(lastModifierInput)
            syncMouseOwnership()
            guard isMiddleClickGestureOpen else { return }
            if wheel.style == .grouped {
                handlePointer(event.position)
            } else if case let .open(session) = phase {
                resampleCustomPointer(at: event.position, in: session)
            }
            release()
        }
    }

    func handlePointer(_ position: BTPoint) {
        guard case var .open(session) = phase else { return }
        session.lastPointerPosition = position
        phase = .open(session)
        if !session.hasPointerMoved {
            // Opening near an edge can place a slice under the stationary
            // pointer. Require deliberate movement before choosing anything.
            guard hypot(position.x - session.placement.anchor.x,
                        position.y - session.placement.anchor.y) > 5 else { return }
            session.hasPointerMoved = true
            Self.log.debug("""
                wheel pointer armed \((self.now() - session.openedAt) * 1000, format: .fixed(precision: 0), privacy: .public) ms after open
                """)
        }
        session.pointerSamples += 1
        session.lastSampleAt = now()
        if wheel.style == .grouped {
            let previous = session.fan
            let vector = BTPoint(x: position.x - session.placement.center.x, y: position.y - session.placement.center.y)
            session.pointerVector = vector
            updateFan(&session.fan, vector: vector, layoutAvailable: session.target.layoutMode == .tabbed)
            session.selection = session.fan.selection
            phase = .open(session)
            if previous.deadline != session.fan.deadline { scheduleFanDeadline() }
            if previous.selection != session.fan.selection || previous.openSector != session.fan.openSector
                || previous.optionIndex != session.fan.optionIndex { refreshPreview() }
            else if presenter.usesLiquidGeometry { presenter.update(presentation(for: session)) }
        } else {
            let updated = selection(for: position, placement: session.placement)
            let changed = updated != session.selection
            session.selection = updated
            session.pointerVector = BTPoint(x: position.x - session.placement.center.x, y: position.y - session.placement.center.y)
            phase = .open(session)
            guard changed else {
                if presenter.usesLiquidGeometry { presenter.update(presentation(for: session)) }
                return
            }
            refreshPreview()
        }
    }

    /// Custom keeps no hysteresis, so the release position is the selection.
    /// An unchanged position leaves keyboard navigation in charge.
    private func resampleCustomPointer(at position: BTPoint, in session: Session) {
        guard position != (session.lastPointerPosition ?? session.placement.anchor) else { return }
        handlePointer(position)
    }

    private func scheduleFanDeadline() {
        fanTask?.cancel()
        fanTask = nil
        guard case let .open(session) = phase, let deadline = session.fan.deadline else { return }
        let delay = max(0, deadline - now())
        fanTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.handleFanDeadline()
        }
    }

    func handleFanDeadline() {
        guard wheel.style == .grouped else { return }
        guard case var .open(session) = phase, let vector = session.pointerVector else { return }
        let previous = session.fan
        updateFan(&session.fan, vector: vector, layoutAvailable: session.target.layoutMode == .tabbed)
        session.selection = session.fan.selection
        phase = .open(session)
        fanTask = nil
        if previous != session.fan { refreshPreview() }
    }

    private func command(for session: Session) -> LayoutWheelCommand? {
        if wheel.style == .grouped { return session.fan.command }
        return session.selection.flatMap { wheel.command(at: $0) }
    }

    func handleKey(_ key: LayoutWheelKey) {
        guard case var .open(session) = phase else { return }
        switch key {
        case .escape:
            cancel()
        case .commit:
            if session.trigger != .middleClick { release() }
        default:
            if wheel.style == .grouped {
                fanTask?.cancel()
                session.pointerVector = nil
                session.fan.handleKey(key, layoutAvailable: session.target.layoutMode == .tabbed, configuration: wheel)
                session.selection = session.fan.selection
                phase = .open(session)
                refreshPreview()
                return
            }
            let updated = LayoutWheelKeyboard.selection(
                for: key,
                from: session.selection,
                levelCount: wheel.effectiveLevelCount
            )
            guard updated != session.selection else { return }
            session.selection = updated
            phase = .open(session)
            refreshPreview()
        }
    }

    /// Drawing and selection share a center, including at screen edges.
    private func selection(
        for position: BTPoint,
        placement: LayoutWheelPlacement
    ) -> LayoutWheelSelection? {
        let geometry = presenter.usesLiquidGeometry ? liquidContent.wheelGeometry
            : effectiveMetrics.geometry(for: wheel.effectiveLevelCount)
        return geometry.selection(
            for: BTPoint(
                x: position.x - placement.center.x,
                y: position.y - placement.center.y
            ),
            levelCount: wheel.effectiveLevelCount
        )
    }

    private func presentation(for session: Session) -> LayoutWheelPresentation {
        LayoutWheelPresentation(
            configuration: wheel,
            overlayAppearance: configuration.overlayAppearance,
            placement: session.placement,
            selection: session.selection,
            unavailableCommands: Set(session.unavailableReasons.keys),
            fan: session.fan,
            pointer: presenter.usesLiquidGeometry ? session.pointerVector : nil,
            layoutAvailable: session.target.layoutMode == .tabbed,
            currentMode: session.target.layoutMode
        )
    }

    /// Previews are planning only. An unavailable command marks its sector and
    /// shows nothing, so the wheel never implies a placement that cannot happen.
    private func refreshPreview() {
        guard case var .open(session) = phase else { return }
        defer { presenter.update(presentation(for: session)) }
        if session.previewedFan != session.fan.openSector {
            session.previewedFan = session.fan.openSector
            if let sector = session.fan.openSector {
                for command in wheel.group(at: sector).options.compactMap({ $0 }) {
                    if case let .unavailable(reason) = previewHandler?(command, session.target) {
                        session.unavailableReasons[command] = reason
                    } else {
                        session.unavailableReasons.removeValue(forKey: command)
                    }
                }
            }
            phase = .open(session)
        }
        guard let command = command(for: session)
        else {
            presenter.hidePlacements()
            return
        }
        switch previewHandler?(command, session.target) {
        case let .ready(placements):
            session.unavailableReasons.removeValue(forKey: command)
            phase = .open(session)
            presenter.showPlacements(placements)
        case let .unavailable(reason):
            session.unavailableReasons[command] = reason
            phase = .open(session)
            presenter.hidePlacements()
            Self.log.debug("layout wheel command unavailable")
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
        let command = command(for: session)
        let sampleAge = session.lastSampleAt.map { (now() - $0) * 1000 } ?? -1
        // Counts and elapsed times only: a selection or distance comes from the pointer.
        recordActivation("wheel release: \(command == nil ? "cancel" : "commit") "
            + "samples=\(session.pointerSamples) lastSampleAge=\(String(format: "%.0f", sampleAge)) ms "
            + "sinceOpen=\(String(format: "%.0f", (now() - session.openedAt) * 1000)) ms")
        finish(command == nil ? .cancel : .commit)
        guard let command
        else { return }
        if let reason = session.unavailableReasons[command] {
            unavailableHandler?(reason, session.target)
        } else {
            commitHandler?(command, session.target)
        }
    }

    /// Debug diagnostics for a missed release: what the controller had received
    /// when the trigger came up. Called before a resample, so the numbers are
    /// the delivered ones.
    private func logRelease(_ event: String, session: Session, resampling: Bool) {
        let sampleAge = session.lastSampleAt.map { (now() - $0) * 1000 } ?? -1
        recordActivation("\(event): samples=\(session.pointerSamples) "
            + "lastSampleAge=\(String(format: "%.0f", sampleAge)) ms resampling=\(resampling)")
    }

    public func cancel(reason: CancellationReason = .requested) {
        guard case .open = phase else {
            cancelPendingActivation(reason: reason)
            return
        }
        recordActivationOutcome("cancel", reason: reason.rawValue)
        finish()
    }

    /// The captured window went away. The gesture ends rather than moving on to
    /// whatever replaced it.
    public func handleTargetLost(windowID: WindowID) {
        guard case let .open(session) = phase, session.target.windowID == windowID else { return }
        cancel()
    }

    public func handleApplicationDeactivated() {
        cancel(reason: .applicationDeactivated)
    }

    public func handleFocusedWindowChanged() {
        cancel(reason: .focusedWindowChanged)
    }

    private func finish(_ acknowledgment: LayoutWheelAcknowledgment = .cancel) {
        let endedWithKeyboard: Bool
        if case let .open(session) = phase {
            endedWithKeyboard = session.trigger != .middleClick
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
        presenter.end(acknowledgment)
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
    private(set) var hosting: NSHostingView<LayoutWheelRuntimeContent>?
    private(set) var scene: LayoutWheelRuntimeScene?
    private var presentationGeneration = 0
    private let renderer: LayoutWheelGlassRenderer
    private let systemAppearance: @MainActor () -> NSAppearance
    var isVisible: Bool { panel.isVisible }

    /// The system light or dark appearance. BetterTile's own Settings override
    /// sets `NSApp.appearance`, which never changes the global preference, so
    /// the wheel reads the preference directly and ignores the override.
    static func currentSystemAppearance() -> NSAppearance {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: dark ? .darkAqua : .aqua) ?? .currentDrawing()
    }

    init(renderer: LayoutWheelGlassRenderer = LayoutWheelGlassRenderer(),
         systemAppearance: @escaping @MainActor () -> NSAppearance = LayoutWheelPanelPresenter.currentSystemAppearance) {
        self.renderer = renderer
        self.systemAppearance = systemAppearance
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
        let began = ProcessInfo.processInfo.systemUptime
        presentationGeneration += 1
        panel.appearance = systemAppearance()
        if scene == nil { scene = LayoutWheelRuntimeScene(presentation, renderer: renderer) }
        guard let scene else { return }
        scene.renderer.configure(.init(presentation), newOpen: true)
        scene.presentation = presentation
        if hosting == nil {
            hosting = NSHostingView(rootView: LayoutWheelRuntimeContent(scene: scene))
            panel.contentView = hosting
        }
        position(at: presentation.placement, size: scene.renderer.intrinsicContentSize)
        panel.orderFrontRegardless()
        Logger(subsystem: "com.lmckarma.BetterTile", category: "LayoutWheel").debug("""
            wheel panel shown: visible=\(self.panel.isVisible, privacy: .public) \
            glass=\(scene.renderer.usesGlass, privacy: .public) \
            took \((ProcessInfo.processInfo.systemUptime - began) * 1000, format: .fixed(precision: 1), privacy: .public) ms
            """)
    }

    func update(_ presentation: LayoutWheelPresentation) {
        guard let scene else { return }
        scene.renderer.configure(.init(presentation))
        if scene.presentation != presentation { scene.presentation = presentation }
    }

    func close() {
        presentationGeneration += 1
        scene?.renderer.stop()
        panel.orderOut(nil)
    }

    func end(_ acknowledgment: LayoutWheelAcknowledgment) {
        guard let scene else { close(); return }
        guard scene.renderer.exitPresentation == nil else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        scene.renderer.beginExit(acknowledgment) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.scene?.renderer.stop()
        }
    }

    func showPlacements(_ placements: [Placement]) {
        placementPreviews.show(placements)
    }

    func hidePlacements() {
        placementPreviews.hide()
    }

    /// The wheel sits on the placement centre.
    private func position(at placement: LayoutWheelPlacement, size: NSSize) {
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        let frame = BTRect(
            x: placement.center.x - size.width / 2,
            y: placement.center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        let appKitFrame = CoordinateConverter.toAppKit(frame, mainScreenFrame: mainFrame)
        if panel.frame != appKitFrame { panel.setFrame(appKitFrame, display: true) }
    }
}

@MainActor final class LayoutWheelRuntimeScene: ObservableObject {
    @Published var presentation: LayoutWheelPresentation
    let renderer: LayoutWheelGlassRenderer
    init(_ presentation: LayoutWheelPresentation, renderer: LayoutWheelGlassRenderer = LayoutWheelGlassRenderer()) {
        self.presentation = presentation; self.renderer = renderer
    }
}

struct LayoutWheelRuntimeContent: View {
    @ObservedObject var scene: LayoutWheelRuntimeScene
    var body: some View {
        var view = LayoutWheelView(scene.presentation)
        view.retainedRenderer = scene.renderer
        return view
    }
}

private extension LayoutWheelView {
    init(_ presentation: LayoutWheelPresentation) {
        self.init(
            configuration: presentation.configuration,
            overlayAppearance: presentation.overlayAppearance,
            selection: presentation.selection,
            unavailableCommands: presentation.unavailableCommands,
            fan: presentation.fan,
            layoutAvailable: presentation.layoutAvailable,
            currentMode: presentation.currentMode
        )
    }
}
