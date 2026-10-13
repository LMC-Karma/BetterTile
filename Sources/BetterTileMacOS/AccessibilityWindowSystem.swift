import AppKit
@preconcurrency import ApplicationServices
import BetterTileCore
import os
import Synchronization

@MainActor
public final class AccessibilityWindowSystem: TargetedWindowSystem, WindowEventSource {
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "Accessibility"
    )

    private var elements: [WindowID: AXUIElement] = [:]
    /// Bundle identifiers of observed windows, for per-application minimum
    /// size seeds.
    private var applicationKeys: [WindowID: String] = [:]
    /// Open while a continuous gesture writes on every display tick.
    private var continuousWriteDepth = 0
    private var continuousSettable: [WindowID: Bool] = [:]
    /// Size settability, checked once per continuous gesture like moving.
    private var continuousSizeSettable: [WindowID: Bool] = [:]
    private var lastWriteReadback: [WindowID: BTRect] = [:]
    /// Decided popup classifications, kept for each window's lifetime.
    private var popupVerdicts: [WindowID: PopupWindowClassifier.Verdict] = [:]
    private var identities = WindowIdentityRegistry()
    private let privateAPIsDisabled: Bool
    private let exactWindowIDResolver: ExactWindowIDResolver
    private let nativeDesktopProvider: NativeDesktopObservationProvider
    private let stageManagerGroupResolver: StageManagerGroupResolver
    private var snapshotCache = WindowSnapshotCache()
    private var snapshotGeneration: UInt64 = 0
    private var nativeObservationGeneration: UInt64?
    private var lastNativeDesktopObservation: NativeDesktopObservation?
    private struct LaunchRecord {
        var launchToken: UInt64?
        var instance: ApplicationLaunchInstance
        /// Kept because a process that quit can no longer report it.
        var bundleIdentifier: String? = nil
    }
    private var launchRecords: [pid_t: LaunchRecord] = [:]
    private var nextLaunchGeneration: UInt64 = 0
    private var loggedBatchFallback = false
    private var observers: [pid_t: AXObserver] = [:]
    private var observationCallbackContext: AccessibilityCallbackContext?
    private struct Registration: Hashable {
        var windowID: WindowID?
        var accessibilityHash: CFHashCode?
        var notification: String
    }
    private var registrations: [pid_t: Set<Registration>] = [:]
    private var managedWindowIDs: Set<WindowID> = []
    private var recentWindowIDs: [WindowID] = []
    private var minimizedWindowIDs: Set<WindowID> = []
    private var eventHandler: (@MainActor (WindowSystemEvent) -> Void)?
    private var minimumSizeLearner = WindowMinimumSizeLearner()
    private let dockFootprintMonitor = DockFootprintMonitor()
    private var recentApplicationPIDs: [pid_t] = []
    private var activationObserver: NSObjectProtocol?
    private var displayReconfigurationHandler: (@MainActor () -> Void)?
    private var isMonitoringDisplayReconfiguration = false
    private var displayCallbackContext: AccessibilityCallbackContext?

    /// The process-wide default, set once on the system-wide element. Reads are
    /// the bulk of the traffic and a stalled application should be skipped
    /// rather than block the main actor, so this stays short.
    ///
    /// This has to be set process-wide rather than per element: the API sets a
    /// timeout "only for that object, not for other accessibility objects that
    /// are equal to it", and every sweep hands back fresh element instances for
    /// windows already known, so per-element overrides do not survive.
    private static let defaultMessagingTimeout: Float = 0.35
    /// Raised on a window element for the duration of a frame write only, then
    /// released back to the process default. A spuriously timed-out write is
    /// worse than a slow one.
    private nonisolated static let frameWriteMessagingTimeout: Float = 1.5
    /// Shared by the main actor and the per-application write threads.
    private nonisolated static let unresponsiveApplications = Mutex(UnresponsiveApplicationGate())
    private nonisolated static let acceptedWriteErrors: [AXError] = [.success, .attributeUnsupported]
    static let unresponsiveApplicationMessage = "The application is not responding, so its window cannot move right now."
    private nonisolated static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private nonisolated static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "Accessibility"
    )

    /// How frame writes treat `AXEnhancedUserInterface`. Owned by the app layer
    /// and refreshed from configuration.
    public var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy = .disableAndRestore
    private var frameWriteSuspensions: [pid_t: EnhancedUserInterfaceSuspension]?

    public init() {
        let privateAPIsDisabled = UserDefaults.standard.bool(forKey: "disablePrivateAPIs")
        self.privateAPIsDisabled = privateAPIsDisabled
        exactWindowIDResolver = ExactWindowIDResolver(disabled: privateAPIsDisabled)
        nativeDesktopProvider = NativeDesktopObservationProvider(disabled: privateAPIsDisabled)
        stageManagerGroupResolver = StageManagerGroupResolver(disabled: privateAPIsDisabled)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.defaultMessagingTimeout)
        if let application = NSWorkspace.shared.frontmostApplication {
            recordActivation(of: application)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            Task { @MainActor in self?.recordActivation(of: application) }
        }
    }

    isolated deinit {
        stopWindowObservation()
        stopDisplayReconfigurationMonitoring()
        dockFootprintMonitor.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    public func startDockFootprintMonitoring(onChange: @escaping () -> Void) {
        dockFootprintMonitor.start(onChange: onChange)
    }

    public func triggerDockFootprintCheck() {
        dockFootprintMonitor.triggerTransitionCheck()
    }

    public func stopDockFootprintMonitoring() {
        dockFootprintMonitor.stop()
    }

    public func startDisplayReconfigurationMonitoring(
        onChange: @escaping @MainActor () -> Void
    ) {
        displayReconfigurationHandler = onChange
        guard !isMonitoringDisplayReconfiguration else { return }
        let context = AccessibilityCallbackContext(system: self)
        let result = CGDisplayRegisterReconfigurationCallback(
            betterTileDisplayReconfigurationCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
        guard result == .success else {
            Self.log.notice("display callback unavailable; retaining AppKit screen notifications")
            return
        }
        displayCallbackContext = context
        isMonitoringDisplayReconfiguration = true
    }

    public func stopDisplayReconfigurationMonitoring() {
        guard isMonitoringDisplayReconfiguration, let context = displayCallbackContext else {
            displayReconfigurationHandler = nil
            return
        }
        CGDisplayRemoveReconfigurationCallback(
            betterTileDisplayReconfigurationCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
        context.system = nil
        displayCallbackContext = nil
        isMonitoringDisplayReconfiguration = false
        displayReconfigurationHandler = nil
    }

    fileprivate func displayConfigurationChanged() {
        displayReconfigurationHandler?()
    }

    public func setWindowEventHandler(_ handler: (@MainActor (WindowSystemEvent) -> Void)?) {
        eventHandler = handler
    }

    public func startWindowObservation() {
        guard AXIsProcessTrusted() else { return }
        synchronizeObservers()
    }

    public func refreshApplicationObservers() {
        guard AXIsProcessTrusted() else { return }
        synchronizeObservers()
        retryPendingEnhancedUserInterfaceRestores()
    }

    public func stopWindowObservation() {
        observationCallbackContext?.system = nil
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        registrations.removeAll()
        observationCallbackContext = nil
    }

    public func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func resetCachedWindows() {
        elements.removeAll()
        identities.removeAll()
        snapshotCache.invalidate()
        snapshotGeneration &+= 1
        nativeObservationGeneration = nil
        lastNativeDesktopObservation = nil
        launchRecords.removeAll()
        managedWindowIDs.removeAll()
        recentWindowIDs.removeAll()
        minimizedWindowIDs.removeAll()
        minimumSizeLearner = WindowMinimumSizeLearner()
        stopWindowObservation()
    }

    @discardableResult
    public func observeApplicationEnforcedMinimum(
        windowID: WindowID,
        requested: BTRect,
        baseline: BTRect,
        actual: BTRect
    ) -> Bool {
        minimumSizeLearner.observe(
            windowID: windowID,
            requested: requested,
            baseline: baseline,
            actual: actual
        )
    }

    /// Measures the minimum size of windows that just appeared, before their
    /// first placement. No application reports its minimum, but each clamps
    /// a size write synchronously: asking for a tiny size and reading the
    /// size back gives the exact minimum in about 10 ms. The original size is
    /// restored at once. Only for new windows, which are animating in and
    /// about to move, and for a hidden tab about to be shown; never for
    /// settled, visible windows. Each window is probed at most once.
    public func probeMinimumSizes(for ids: Set<WindowID>) -> Set<WindowID> {
        guard AXIsProcessTrusted() else { return [] }
        var measured = false
        var unrestored: Set<WindowID> = []
        // A window with its own measurement is not probed again. A window
        // that has only its application's seed is: the seed came from another
        // window, which can have a larger minimum. Until the probe measures
        // the window, it plans with the seed. Its own measurement then
        // replaces the seed for it and becomes the application's new seed.
        for id in minimumSizeLearner.windowsNeedingMeasurement(ids) {
            guard let element = elements[id] ?? refreshElement(for: id),
                  isSettable(kAXSizeAttribute, on: element),
                  (try? requireResponsive(element)) != nil,
                  let position: CGPoint = axValue(kAXPositionAttribute, from: element, type: .cgPoint),
                  let original: CGSize = axValue(kAXSizeAttribute, from: element, type: .cgSize) else { continue }
            var tiny = CGSize(width: 1, height: 1)
            var restore = original
            guard let tinyValue = AXValueCreate(.cgSize, &tiny),
                  let restoreValue = AXValueCreate(.cgSize, &restore) else { continue }
            // As for a frame write: with enhanced accessibility on, an
            // application can reinterpret the size writes.
            let enhancedUserInterface = suspendEnhancedUserInterfaceIfNeeded(for: element)
            defer { if frameWriteSuspensions == nil { finish(enhancedUserInterface) } }
            AXUIElementSetMessagingTimeout(element, Self.frameWriteMessagingTimeout)
            defer { AXUIElementSetMessagingTimeout(element, 0) }
            guard Self.setFrameAttribute(element, kAXSizeAttribute, tinyValue) == .success else { continue }
            minimumSizeLearner.recordProbe(of: id)
            let clamped: CGSize? = axValue(kAXSizeAttribute, from: element, type: .cgSize)
            // Confirm the original size; try once more before reporting it.
            let sizeRestored = (0..<2).contains { _ in
                // Not gated: putting the user's window back outweighs a timeout.
                _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, restoreValue)
                guard let size: CGSize = axValue(kAXSizeAttribute, from: element, type: .cgSize) else { return false }
                return abs(size.width - original.width) <= 1 && abs(size.height - original.height) <= 1
            }
            // Some applications move a window to keep it on screen when it
            // shrinks; put its position back too, even when the size stayed off.
            let positionRestored = Self.restorePosition(element, to: position)
            if !sizeRestored || !positionRestored { unrestored.insert(id) }
            guard let clamped else { continue }
            let before = BTRect(x: position.x, y: position.y, width: original.width, height: original.height)
            if minimumSizeLearner.observeWriteReadback(
                windowID: id, application: applicationKeys[id],
                requested: BTRect(x: position.x, y: position.y, width: 1, height: 1),
                previous: before,
                actual: BTRect(x: position.x, y: position.y, width: clamped.width, height: clamped.height)
            ) {
                measured = true
            } else if abs(clamped.width - original.width) <= 1, abs(clamped.height - original.height) <= 1,
                      !unrestored.contains(id), Self.confirmsSynchronousWrites(element, at: position),
                      minimumSizeLearner.observeConfirmedClamp(
                          windowID: id, application: applicationKeys[id],
                          requested: BTSize(width: 1, height: 1),
                          actual: BTSize(width: clamped.width, height: clamped.height)
                      ) {
                // A window already at its minimum keeps its size, which an
                // ignored write would also do. The position nudge proves the
                // application handles writes at once, as for a frame write.
                measured = true
            }
            // The window had no measurement before this probe.
            let application = applicationKeys[id] ?? "unknown"
            if let size = minimumSizeLearner.learnedSizes[id] {
                Self.log.debug("""
                    probe measured a \(application, privacy: .private) window: \
                    minimum \(size.width, format: .fixed(precision: 0)) x \(size.height, format: .fixed(precision: 0))
                    """)
            } else {
                Self.log.debug("probe measured nothing for a \(application, privacy: .private) window")
            }
        }
        if measured { snapshotGeneration &+= 1 }
        return unrestored
    }

    public func focusedWindow() throws -> WindowSnapshot? {
        let interval = Self.signposter.beginInterval("focusedWindow")
        defer { Self.signposter.endInterval("focusedWindow", interval) }
        try ensurePermission()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = ([frontmostPID].compactMap { $0 } + recentApplicationPIDs)
            .reduce(into: [pid_t]()) { result, pid in
                if !result.contains(pid) { result.append(pid) }
            }

        let availableDisplays = displays()
        for pid in candidates {
            guard let application = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == pid
            }),
            Self.shouldManageApplication(
                processIdentifier: application.processIdentifier,
                ownProcessIdentifier: getpid(),
                activationPolicy: application.activationPolicy,
                isHidden: application.isHidden,
                includeHidden: false
            )
            else { continue }

            let appElement = makeApplicationElement(pid: pid)
            let applicationInstance = applicationInstance(for: application)
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window: AXUIElement = value(attribute, from: appElement),
                   let snapshot = snapshot(
                       window,
                       application: applicationInstance,
                       bundleIdentifier: application.bundleIdentifier,
                       displays: availableDisplays
                   ),
                   let classified = classifyByNativeMembership(snapshot) {
                    retainRecent(classified.id)
                    registerWindowNotifications(window, snapshot: classified)
                    return classified
                }
            }
            let windows: [AXUIElement] = value(kAXWindowsAttribute, from: appElement) ?? []
            if let snapshot = windows.lazy.compactMap({
                self.snapshot(
                    $0,
                    application: applicationInstance,
                    bundleIdentifier: application.bundleIdentifier,
                    displays: availableDisplays
                ).flatMap(self.classifyByNativeMembership)
            }).first {
                retainRecent(snapshot.id)
                if let element = elements[snapshot.id] {
                    registerWindowNotifications(element, snapshot: snapshot)
                }
                return snapshot
            }
            // A front application that stopped answering still has the
            // user's focus. Falling back to a recent application would act
            // on a window the user is not looking at.
            if pid == frontmostPID, Self.isUnresponsive(pid) {
                throw WindowSystemError.operationFailed(Self.unresponsiveApplicationMessage)
            }
        }
        return nil
    }

    public func visibleWindows() throws -> [WindowSnapshot] {
        let interval = Self.signposter.beginInterval("completeSweep")
        defer { Self.signposter.endInterval("completeSweep", interval) }
        try ensurePermission()
        let windowServer = windowServerIndex()
        // Enumerated once per sweep. Resolving the containing display per
        // window used to re-read every NSScreen for every window.
        let availableDisplays = displays()
        var snapshots: [WindowSnapshot] = []
        var refreshedElements: [WindowID: AXUIElement] = [:]
        var observedApplications: [ApplicationLaunchInstance: Set<CFHashCode>] = [:]
        for application in NSWorkspace.shared.runningApplications where Self.shouldManageApplication(
            processIdentifier: application.processIdentifier,
            ownProcessIdentifier: getpid(),
            activationPolicy: application.activationPolicy,
            isHidden: application.isHidden,
            includeHidden: false
        ) {
            let applicationInstance = applicationInstance(for: application)
            let appElement = makeApplicationElement(pid: application.processIdentifier)
            guard let windows: [AXUIElement] = value(kAXWindowsAttribute, from: appElement) else { continue }
            observedApplications[applicationInstance] = Set(windows.map { CFHash($0) })
            for window in windows {
                guard let snapshot = snapshot(
                    window,
                    application: applicationInstance,
                    bundleIdentifier: application.bundleIdentifier,
                    displays: availableDisplays
                ) else { continue }
                if let windowServer,
                   !windowServer.contains(
                       snapshot,
                       exactWindowID: identities.exactWindowID(for: snapshot.id)
                   ) { continue }
                snapshots.append(snapshot)
                refreshedElements[snapshot.id] = window
                if managedWindowIDs.contains(snapshot.id) || recentWindowIDs.contains(snapshot.id) {
                    registerWindowNotifications(window, snapshot: snapshot)
                }
            }
        }
        let retainedIDs = managedWindowIDs.union(recentWindowIDs).union(minimizedWindowIDs)
        elements = elements.filter { retainedIDs.contains($0.key) }
        elements.merge(refreshedElements) { _, latest in latest }
        removeCachedState(for: identities.removeClosedWindowsAfterSweep(
            observedApplications: observedApplications,
            windowServer: windowServer,
            accessibilityStatus: { windowID in
                guard let element = elements[windowID] else { return nil }
                var role: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            }
        ), notifyClosure: true)
        let sorted = snapshots.sorted { $0.id < $1.id }
        snapshotCache.recordFullSweep(sorted)
        snapshotGeneration &+= 1
        nativeObservationGeneration = nil
        let classified = nativeDesktopObservation()?.windowsOnCurrentSpaces(sorted) ?? sorted
        snapshotCache.recordFullSweep(classified)
        return classified
    }

    public func updateManagedWindowIDs(_ ids: Set<WindowID>) {
        let releasedIDs = managedWindowIDs
            .subtracting(ids)
            .subtracting(recentWindowIDs)
            .subtracting(minimizedWindowIDs)
        for id in releasedIDs {
            if let element = elements[id] {
                unregisterWindowNotifications(element, windowID: id)
            }
        }
        managedWindowIDs = ids
        for id in ids {
            guard let element = elements[id],
                  let snapshot = try? windowSnapshot(id: id)
            else { continue }
            registerWindowNotifications(element, snapshot: snapshot)
        }
        elements = elements.filter {
            ids.contains($0.key)
                || recentWindowIDs.contains($0.key)
                || minimizedWindowIDs.contains($0.key)
        }
    }

    public func windowSnapshots(ids: Set<WindowID>) throws -> [WindowSnapshot] {
        try ids.sorted().compactMap { try windowSnapshot(id: $0) }
    }

    public func cachedVisibleWindows(
        refreshing ids: Set<WindowID>
    ) throws -> [WindowSnapshot]? {
        let interval = Self.signposter.beginInterval("targetedRefresh")
        defer { Self.signposter.endInterval("targetedRefresh", interval) }
        guard !ids.isEmpty, snapshotCache.snapshots != nil else { return nil }
        let exactIDs = Dictionary(uniqueKeysWithValues: ids.compactMap { windowID in
            identities.exactWindowID(for: windowID).map { (windowID, $0) }
        })
        guard exactIDs.count == ids.count,
              let windowServer = targetedWindowServerIndex(ids: Set(exactIDs.values))
        else {
            snapshotCache.invalidate()
            return nil
        }
        let refreshed = try windowSnapshots(ids: ids)
        guard Set(refreshed.map(\.id)) == ids,
              refreshed.allSatisfy({ snapshot in
                  windowServer.contains(
                      snapshot,
                      exactWindowID: exactIDs[snapshot.id]
                  )
              })
        else {
            snapshotCache.invalidate()
            return nil
        }
        return snapshotCache.merge(refreshed, expectedWindowIDs: ids)
    }

    func windowSnapshot(id: WindowID) throws -> WindowSnapshot? {
        try ensurePermission()
        guard let element = elements[id] ?? refreshElement(for: id) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return snapshot(
            element,
            application: applicationInstance(forPID: pid),
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            displays: displays()
        ).flatMap(classifyByNativeMembership)
    }

    func windowSnapshot(exactWindowID: CGWindowID) throws -> WindowSnapshot? {
        if let windowID = identities.windowID(forExactWindowID: exactWindowID),
           let snapshot = try windowSnapshot(id: windowID) {
            return snapshot
        }
        _ = try visibleWindows()
        guard let windowID = identities.windowID(forExactWindowID: exactWindowID) else { return nil }
        return try windowSnapshot(id: windowID)
    }

    func stageManagerWindowID(at point: BTPoint) -> CGWindowID? {
        guard let observation = stageManagerGroupResolver.observation(at: point) else { return nil }
        guard let records = targetedWindowServerRecords(ids: Set(observation.windowIDs)) else {
            stageManagerGroupResolver.logValidationFallbackOnce()
            return nil
        }
        let runningApplications = NSWorkspace.shared.runningApplications
        let knownOwnerPIDs = Set(runningApplications.map(\.processIdentifier))
        let rejectedOwnerPIDs = Set(runningApplications.compactMap { application in
            application.bundleIdentifier == "com.apple.WindowManager"
                ? application.processIdentifier
                : nil
        }).union([getpid(), observation.windowManagerPID])
        let selected = StageManagerGroupResolver.frontmostValidWindowID(
            groupWindowIDs: observation.windowIDs,
            targetedRecords: records,
            frontToBackWindowIDs: frontToBackWindowIDs(in: Set(observation.windowIDs)),
            rejectedOwnerPIDs: rejectedOwnerPIDs,
            knownOwnerPIDs: knownOwnerPIDs
        )
        if selected == nil { stageManagerGroupResolver.logValidationFallbackOnce() }
        return selected
    }

    func recordStageManagerWindowExposureFailure() {
        stageManagerGroupResolver.logExposureFallbackOnce()
    }

    public func displays() -> [DisplaySnapshot] {
        let screens = NSScreen.screens
        guard let mainFrame = screens.first?.frame else { return [] }
        return screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = DisplayID(rawValue: number?.stringValue ?? String(screen.hash))
            let frame = CoordinateConverter.toTopLeft(screen.frame, mainScreenFrame: mainFrame)
            let appKitVisibleFrame = CoordinateConverter.toTopLeft(screen.visibleFrame, mainScreenFrame: mainFrame)
            return DisplaySnapshot(
                id: id,
                frame: frame,
                visibleFrame: dockFootprintMonitor.effectiveFrame(
                    displayID: id,
                    fullFrame: frame,
                    appKitVisibleFrame: appKitVisibleFrame
                ),
                scaleFactor: screen.backingScaleFactor,
                isMain: screen == NSScreen.main
            )
        }.sorted { lhs, rhs in
            lhs.frame.minX == rhs.frame.minX ? lhs.frame.minY < rhs.frame.minY : lhs.frame.minX < rhs.frame.minX
        }
    }

    /// Returns nil whenever the native topology is unavailable or rejected.
    /// Callers must keep their public-API inference path for that result.
    public func nativeDesktopObservation() -> NativeDesktopObservation? {
        if nativeObservationGeneration == snapshotGeneration {
            return lastNativeDesktopObservation
        }
        return refreshNativeDesktopObservation()
    }

    /// Space notifications change topology without changing the snapshot
    /// cache. Force a fresh read before selecting the exact runtime session.
    public func refreshNativeDesktopObservation() -> NativeDesktopObservation? {
        // Retained identities include windows temporarily omitted by AX and
        // windows on inactive Spaces. Their membership corroborates presence.
        let hiddenPIDs = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier))
        let exactWindowIDs = Dictionary(uniqueKeysWithValues: identities.records.values.compactMap { record -> (WindowID, CGWindowID)? in
            guard !hiddenPIDs.contains(record.application.processIdentifier),
                  !minimizedWindowIDs.contains(record.windowID),
                  let exactID = record.exactWindowID
            else { return nil }
            return (record.windowID, exactID)
        })
        let observation = nativeDesktopProvider.observation(
            displays: displays(),
            exactWindowIDs: exactWindowIDs
        )
        lastNativeDesktopObservation = observation
        nativeObservationGeneration = snapshotGeneration
        return observation
    }

    public func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        try writeFrame(frame, knownCurrentFrame: knownCurrentFrame, for: windowID)
    }

    /// One window's intermediate sample takes the same path as a batch, so
    /// the two cannot diverge.
    public func setIntermediateFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        try setIntermediateFrames(
            [Placement(windowID: windowID, frame: frame)],
            knownCurrentFrames: knownCurrentFrame.map { [windowID: $0] } ?? [:]
        )
    }

    private func writeFrame(
        _ frame: BTRect,
        knownCurrentFrame: BTRect?,
        for windowID: WindowID
    ) throws {
        try ensurePermission()
        guard let element = elements[windowID] ?? refreshElement(for: windowID) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        try requireResponsive(element)
        // A continuous gesture checks once whether the window can move.
        let movable: Bool
        if continuousWriteDepth > 0, let cached = continuousSettable[windowID] {
            movable = cached
        } else {
            movable = try movability(of: element)
            if continuousWriteDepth > 0 { continuousSettable[windowID] = movable }
        }
        guard movable else {
            throw WindowSystemError.unsupportedWindow(windowID)
        }

        var position = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.size.width, height: frame.size.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { throw WindowSystemError.operationFailed("Could not encode the target frame.") }

        // AppKit and Chromium reinterpret geometry writes while enhanced
        // accessibility is active, so the window lands somewhere other than the
        // requested frame. Disable it for the duration of the write. The
        // attribute is only ever touched when the application had it enabled.
        let enhancedUserInterface = suspendEnhancedUserInterfaceIfNeeded(for: element)
        defer { if frameWriteSuspensions == nil { finish(enhancedUserInterface) } }

        // A frame write deserves more patience than a bulk read. Passing 0
        // returns this element to the process-wide default afterwards.
        AXUIElementSetMessagingTimeout(element, Self.frameWriteMessagingTimeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }

        // Several applications clamp position against their current size, so the
        // sequence is size, position, size. When the size is not changing the
        // leading write asks for the value the window already has, so it is
        // skipped; the trailing write still corrects any clamping.
        var plan = FrameWritePlanner.plan(target: frame, knownCurrentFrame: knownCurrentFrame)
        // A measurement belongs to one write; an older one is not evidence.
        lastWriteReadback.removeValue(forKey: windowID)
        // A fixed-size window, such as Calculator, rejects any size write.
        if try !sizeIsSettable(windowID, on: element) { plan.writesInitialSize = false; plan.writesFinalSize = false }
        var errors: [AXError] = []
        // A refused call fails the write, so the sequence stops there: a hung
        // application makes every further call wait out its timeout.
        func proceeds() -> Bool { errors.allSatisfy { Self.acceptedWriteErrors.contains($0) } }
        if plan.writesInitialSize {
            errors.append(Self.setFrameAttribute(element, kAXSizeAttribute, sizeValue))
        }
        if plan.writesPosition, proceeds() {
            errors.append(Self.setFrameAttribute(element, kAXPositionAttribute, positionValue))
        }
        if plan.writesFinalSize, proceeds() {
            errors.append(Self.setFrameAttribute(element, kAXSizeAttribute, sizeValue))
        }

        guard proceeds() else {
            elements.removeValue(forKey: windowID)
            throw WindowSystemError.operationFailed(
                "macOS rejected the window frame update (\(errors.map { String($0.rawValue) }.joined(separator: ", ")))."
            )
        }
        // Applications clamp a size synchronously. Reading it straight back
        // measures the minimum exactly, before anything is shown as settled.
        let learnedMinimum = minimumSizeLearner.learnedSizes[windowID]
        if plan.writesInitialSize || plan.writesFinalSize,
           let actualPosition: CGPoint = axValue(kAXPositionAttribute, from: element, type: .cgPoint),
           let actualSize: CGSize = axValue(kAXSizeAttribute, from: element, type: .cgSize) {
            let actual = BTRect(x: actualPosition.x, y: actualPosition.y,
                                width: actualSize.width, height: actualSize.height)
            lastWriteReadback[windowID] = actual
            if minimumSizeLearner.observeWriteReadback(
                windowID: windowID, application: applicationKeys[windowID],
                requested: frame, previous: knownCurrentFrame, actual: actual
            ) {
                snapshotGeneration &+= 1
            } else if WriteReadbackPolicy.needsClampConfirmation(
                requested: frame, previous: knownCurrentFrame, actual: actual, learnedMinimum: learnedMinimum
            ), Self.confirmsSynchronousWrites(element, at: actualPosition) {
                // The window kept its size at the same origin, which an
                // ignored write would also do. A 1 pt position nudge that the
                // application follows proves it processes writes at once, so
                // the kept size is its minimum.
                if minimumSizeLearner.observeConfirmedClamp(
                    windowID: windowID, application: applicationKeys[windowID],
                    requested: frame.size, actual: actual.size
                ) { snapshotGeneration &+= 1 }
            }
        }
    }

    /// Moves the window 1 pt and back. True when the application followed the
    /// move synchronously and returned. The nudge is not visible. Nonisolated,
    /// so a single-window write and a batched committed write share it.
    private nonisolated static func confirmsSynchronousWrites(_ element: AXUIElement, at position: CGPoint) -> Bool {
        var nudged = CGPoint(x: position.x + 1, y: position.y)
        guard let nudgedValue = AXValueCreate(.cgPoint, &nudged),
              Self.setFrameAttribute(element, kAXPositionAttribute, nudgedValue) == .success
        else { return false }
        let observed = readPosition(element)
        let returned = restorePosition(element, to: position)
        return WriteReadbackPolicy.nudgeConfirmsSynchronousWrites(
            nudged: BTPoint(x: nudged.x, y: nudged.y),
            observed: observed.map { BTPoint(x: $0.x, y: $0.y) },
            returned: returned
        )
    }

    private nonisolated static func readPosition(_ element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw) == .success,
              let raw else { return nil }
        return decodedAXValue(raw, type: .cgPoint)
    }

    /// Writes a window's position back and reads it, trying once more. True
    /// when the window is at `position`, already or after the write.
    private nonisolated static func restorePosition(_ element: AXUIElement, to position: CGPoint) -> Bool {
        func isBack() -> Bool {
            guard let now = readPosition(element) else { return false }
            return abs(now.x - position.x) <= 0.5 && abs(now.y - position.y) <= 0.5
        }
        if isBack() { return true }
        var target = position
        guard let value = AXValueCreate(.cgPoint, &target) else { return false }
        return (0..<2).contains { _ in
            // Not gated: putting the user's window back outweighs a timeout.
            _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
            return isBack()
        }
    }

    public func beginContinuousWrites() {
        if continuousWriteDepth == 0, frameWriteSuspensions == nil { frameWriteSuspensions = [:] }
        continuousWriteDepth += 1
    }

    /// Whether a window's size can be written. A continuous gesture asks the
    /// application once, not on every tick. An application that does not
    /// answer fails the write without a verdict, so a gesture does not keep
    /// the window as fixed-size after the application recovers.
    private func sizeIsSettable(_ windowID: WindowID, on element: AXUIElement) throws -> Bool {
        if continuousWriteDepth > 0, let cached = continuousSizeSettable[windowID] { return cached }
        guard let settable = settable(kAXSizeAttribute, on: element) else {
            throw WindowSystemError.operationFailed(Self.unresponsiveApplicationMessage)
        }
        if continuousWriteDepth > 0 { continuousSizeSettable[windowID] = settable }
        return settable
    }

    public func endContinuousWrites() {
        guard continuousWriteDepth > 0 else { return }
        continuousWriteDepth -= 1
        guard continuousWriteDepth == 0 else { return }
        continuousSettable.removeAll()
        continuousSizeSettable.removeAll()
        let suspensions = frameWriteSuspensions ?? [:]
        frameWriteSuspensions = nil
        finish(suspensions)
    }

    public func measuredFrameAfterWrite(for windowID: WindowID) -> BTRect? { lastWriteReadback[windowID] }

    public func isApplicationUnresponsive(for windowID: WindowID) -> Bool {
        // The identity record outlives the cached element, which a failed
        // write drops.
        guard let pid = identities.records[windowID]?.application.processIdentifier else { return false }
        return Self.isUnresponsive(pid)
    }


    /// One application's share of a concurrent intermediate write.
    private struct IntermediateJob: @unchecked Sendable {
        let windowID: WindowID
        let element: AXUIElement
        let frame: BTRect
        let previous: BTRect?
        let plan: FrameWritePlan
    }

    private struct IntermediateResult: @unchecked Sendable {
        let windowID: WindowID
        let errors: [AXError]
        let actual: BTRect?
    }

    /// Writes each application's windows on its own thread. Accessibility
    /// calls block until the target application handles them, and some
    /// applications lay out synchronously for over 10 ms; writing them
    /// one after another overran the display frame.
    public func setIntermediateFrames(_ writes: [Placement], knownCurrentFrames: [WindowID: BTRect]) throws {
        try ensurePermission()
        var groups: [pid_t: [IntermediateJob]] = [:]
        // Every window is checked before any is written, so a failure here
        // leaves every window where it was.
        do { for write in writes {
            guard let element = elements[write.windowID] ?? refreshElement(for: write.windowID) else {
                throw WindowSystemError.windowNotFound(write.windowID)
            }
            try requireResponsive(element)
            let movable: Bool
            if let cached = continuousSettable[write.windowID] { movable = cached } else {
                movable = try movability(of: element)
                if continuousWriteDepth > 0 { continuousSettable[write.windowID] = movable }
            }
            guard movable else { throw WindowSystemError.unsupportedWindow(write.windowID) }
            _ = suspendEnhancedUserInterfaceIfNeeded(for: element)
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let previous = knownCurrentFrames[write.windowID]
            var plan = FrameWritePlanner.plan(target: write.frame, knownCurrentFrame: previous, correctsClamping: false)
            if try !sizeIsSettable(write.windowID, on: element) { plan.writesInitialSize = false }
            groups[pid, default: []].append(IntermediateJob(windowID: write.windowID, element: element,
                                                            frame: write.frame, previous: previous, plan: plan))
        } } catch {
            throw FrameWritesNotStarted(error)
        }
        let jobs = Array(groups.values)
        let lock = NSLock()
        nonisolated(unsafe) var results: [(job: IntermediateJob, result: IntermediateResult)] = []
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            for job in jobs[index] {
                let result = Self.performIntermediateWrite(job)
                lock.lock(); results.append((job, result)); lock.unlock()
            }
        }
        let accepted: [AXError] = [.success, .attributeUnsupported]
        var failure: WindowID?
        for (job, result) in results {
            lastWriteReadback.removeValue(forKey: result.windowID)
            if !result.errors.allSatisfy({ accepted.contains($0) }) {
                elements.removeValue(forKey: result.windowID)
                failure = failure ?? result.windowID
                continue
            }
            guard let actual = result.actual else { continue }
            lastWriteReadback[result.windowID] = actual
            if minimumSizeLearner.observeWriteReadback(
                windowID: result.windowID, application: applicationKeys[result.windowID],
                requested: job.frame, previous: job.previous, actual: actual
            ) { snapshotGeneration &+= 1 }
        }
        if failure != nil {
            throw WindowSystemError.operationFailed("macOS rejected the window frame update.")
        }
    }

    /// One window's share of a concurrent committed write.
    private struct CommittedJob: @unchecked Sendable {
        let windowID: WindowID
        let element: AXUIElement
        let frame: BTRect
        let previous: BTRect?
        let plan: FrameWritePlan
        /// The minimum learned before this write. A clamp it explains needs
        /// no position nudge.
        let learnedMinimum: BTSize?
    }

    private struct CommittedResult: @unchecked Sendable {
        let windowID: WindowID
        let errors: [AXError]
        let actual: BTRect?
        /// The window kept a larger size at the requested origin, followed a
        /// 1 pt position nudge, and returned, so the kept size is its minimum.
        let confirmedClamp: Bool
    }

    /// Splits a batch into a shrinking pass and a growing pass, each in the
    /// batch's order. A window with an unknown frame grows, as in
    /// `WindowCoordinator`'s order.
    nonisolated static func shrinkingFirstPasses(
        _ writes: [Placement], knownCurrentFrames: [WindowID: BTRect]
    ) -> [[Placement]] {
        func shrinks(_ write: Placement) -> Bool {
            guard let old = knownCurrentFrames[write.windowID] else { return false }
            return write.frame.size.width < old.size.width - 0.5 || write.frame.size.height < old.size.height - 0.5
        }
        return [writes.filter(shrinks), writes.filter { !shrinks($0) }].filter { !$0.isEmpty }
    }

    /// Writes final frames for each application on its own thread, so a
    /// layout lands at once instead of one application after another. Every
    /// window is checked before any write. Shrinking windows are written
    /// first, in every application at once, then growing windows, so a
    /// growing window never covers a neighbour from another application that
    /// has not yet made room. Within one application the writes keep their
    /// order.
    public func setFrames(_ writes: [Placement], knownCurrentFrames: [WindowID: BTRect]) -> FrameBatchResult {
        guard writes.count > 1 else {
            var attempted: [WindowID] = []
            for write in writes {
                attempted.append(write.windowID)
                do { try setFrame(write.frame, knownCurrentFrame: knownCurrentFrames[write.windowID], for: write.windowID) }
                catch { return FrameBatchResult(attempted: attempted, failure: (write.windowID, error)) }
            }
            return FrameBatchResult(attempted: attempted, failure: nil)
        }
        var prepared: [WindowID: (pid: pid_t, job: CommittedJob)] = [:]
        var preparing = writes[0].windowID
        do {
            try ensurePermission()
            for write in writes {
                preparing = write.windowID
                guard let element = elements[write.windowID] ?? refreshElement(for: write.windowID) else {
                    throw WindowSystemError.windowNotFound(write.windowID)
                }
                try requireResponsive(element)
                // An application that stops answering here is reported as not
                // responding, not as a window that cannot move.
                guard try movability(of: element) else {
                    throw WindowSystemError.unsupportedWindow(write.windowID)
                }
                _ = suspendEnhancedUserInterfaceIfNeeded(for: element)
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                let previous = knownCurrentFrames[write.windowID]
                var plan = FrameWritePlanner.plan(target: write.frame, knownCurrentFrame: previous, correctsClamping: true)
                if try !sizeIsSettable(write.windowID, on: element) { plan.writesInitialSize = false; plan.writesFinalSize = false }
                prepared[write.windowID] = (pid, CommittedJob(
                    windowID: write.windowID, element: element, frame: write.frame, previous: previous,
                    plan: plan, learnedMinimum: minimumSizeLearner.learnedSizes[write.windowID]
                ))
            }
        } catch {
            // Nothing was written yet.
            return FrameBatchResult(attempted: [], failure: (preparing, error))
        }
        let lock = NSLock()
        nonisolated(unsafe) var results: [WindowID: CommittedResult] = [:]
        let accepted: [AXError] = [.success, .attributeUnsupported]
        for pass in Self.shrinkingFirstPasses(writes, knownCurrentFrames: knownCurrentFrames) {
            // A failed shrink leaves no room for the growing windows; stop
            // before the next pass, and the caller rolls back.
            guard results.values.allSatisfy({ $0.errors.allSatisfy { accepted.contains($0) } }) else { break }
            var groups: [pid_t: [CommittedJob]] = [:]
            var pidOrder: [pid_t] = []
            for write in pass {
                guard let entry = prepared[write.windowID] else { continue }
                if groups[entry.pid] == nil { pidOrder.append(entry.pid) }
                groups[entry.pid, default: []].append(entry.job)
            }
            let jobs = pidOrder.compactMap { groups[$0] }
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                for job in jobs[index] {
                    let result = Self.performCommittedWrite(job)
                    lock.lock(); results[job.windowID] = result; lock.unlock()
                }
            }
        }
        var failure: (windowID: WindowID, error: Error)?
        for write in writes {
            lastWriteReadback.removeValue(forKey: write.windowID)
            guard let result = results[write.windowID] else { continue }
            guard result.errors.allSatisfy({ accepted.contains($0) }) else {
                elements.removeValue(forKey: write.windowID)
                if failure == nil {
                    failure = (write.windowID, WindowSystemError.operationFailed(
                        "macOS rejected the window frame update (\(result.errors.map { String($0.rawValue) }.joined(separator: ", ")))."
                    ))
                }
                continue
            }
            guard let actual = result.actual else { continue }
            lastWriteReadback[write.windowID] = actual
            if minimumSizeLearner.observeWriteReadback(
                windowID: write.windowID, application: applicationKeys[write.windowID],
                requested: write.frame, previous: knownCurrentFrames[write.windowID], actual: actual
            ) {
                snapshotGeneration &+= 1
            } else if result.confirmedClamp, minimumSizeLearner.observeConfirmedClamp(
                windowID: write.windowID, application: applicationKeys[write.windowID],
                requested: write.frame.size, actual: actual.size
            ) {
                snapshotGeneration &+= 1
            }
        }
        return FrameBatchResult(attempted: writes.map(\.windowID).filter { results[$0] != nil }, failure: failure)
    }

    /// Size, position, size, then a readback; the same sequence as
    /// `writeFrame`, including the nudge that confirms a same-origin clamp.
    private nonisolated static func performCommittedWrite(_ job: CommittedJob) -> CommittedResult {
        var position = CGPoint(x: job.frame.minX, y: job.frame.minY)
        var size = CGSize(width: job.frame.size.width, height: job.frame.size.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return CommittedResult(windowID: job.windowID, errors: [.failure], actual: nil, confirmedClamp: false)
        }
        AXUIElementSetMessagingTimeout(job.element, frameWriteMessagingTimeout)
        defer { AXUIElementSetMessagingTimeout(job.element, 0) }
        var errors: [AXError] = []
        // As in `writeFrame`, a refusal ends the sequence and skips the
        // readback: the write has failed, and the caller ignores the frame.
        func proceeds() -> Bool { errors.allSatisfy { acceptedWriteErrors.contains($0) } }
        if job.plan.writesInitialSize {
            errors.append(Self.setFrameAttribute(job.element, kAXSizeAttribute, sizeValue))
        }
        if job.plan.writesPosition, proceeds() {
            errors.append(Self.setFrameAttribute(job.element, kAXPositionAttribute, positionValue))
        }
        if job.plan.writesFinalSize, proceeds() {
            errors.append(Self.setFrameAttribute(job.element, kAXSizeAttribute, sizeValue))
        }
        guard proceeds(), job.plan.writesInitialSize || job.plan.writesFinalSize else {
            return CommittedResult(windowID: job.windowID, errors: errors, actual: nil, confirmedClamp: false)
        }
        func read() -> BTRect? {
            var p: CFTypeRef?, s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(job.element, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(job.element, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s,
                  // A value of another type is no measurement, not a zero frame.
                  let point: CGPoint = decodedAXValue(p, type: .cgPoint),
                  let extent: CGSize = decodedAXValue(s, type: .cgSize) else { return nil }
            return BTRect(x: point.x, y: point.y, width: extent.width, height: extent.height)
        }
        guard let actual = read() else {
            return CommittedResult(windowID: job.windowID, errors: errors, actual: nil, confirmedClamp: false)
        }
        let confirmed = WriteReadbackPolicy.needsClampConfirmation(
            requested: job.frame, previous: job.previous, actual: actual, learnedMinimum: job.learnedMinimum
        ) && confirmsSynchronousWrites(job.element, at: CGPoint(x: actual.minX, y: actual.minY))
        return CommittedResult(windowID: job.windowID, errors: errors, actual: actual, confirmedClamp: confirmed)
    }

    private nonisolated static func performIntermediateWrite(_ job: IntermediateJob) -> IntermediateResult {
        var position = CGPoint(x: job.frame.minX, y: job.frame.minY)
        var size = CGSize(width: job.frame.size.width, height: job.frame.size.height)
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return IntermediateResult(windowID: job.windowID, errors: [.failure], actual: nil)
        }
        AXUIElementSetMessagingTimeout(job.element, frameWriteMessagingTimeout)
        defer { AXUIElementSetMessagingTimeout(job.element, 0) }
        var errors: [AXError] = []
        func proceeds() -> Bool { errors.allSatisfy { acceptedWriteErrors.contains($0) } }
        if job.plan.writesInitialSize {
            errors.append(Self.setFrameAttribute(job.element, kAXSizeAttribute, sizeValue))
        }
        if job.plan.writesPosition, proceeds() {
            errors.append(Self.setFrameAttribute(job.element, kAXPositionAttribute, positionValue))
        }
        var actual: BTRect?
        var p: CFTypeRef?, s: CFTypeRef?
        if proceeds(), AXUIElementCopyAttributeValue(job.element, kAXPositionAttribute as CFString, &p) == .success,
           AXUIElementCopyAttributeValue(job.element, kAXSizeAttribute as CFString, &s) == .success,
           let p, let s,
           // A value of another type is no measurement, not a zero frame.
           let point: CGPoint = decodedAXValue(p, type: .cgPoint),
           let extent: CGSize = decodedAXValue(s, type: .cgSize) {
            actual = BTRect(x: point.x, y: point.y, width: extent.width, height: extent.height)
        }
        return IntermediateResult(windowID: job.windowID, errors: errors, actual: actual)
    }

    public func withFrameWriteBatch(_ updates: () throws -> Void) rethrows {
        if frameWriteSuspensions != nil { try updates(); return }
        retryPendingEnhancedUserInterfaceRestores()
        frameWriteSuspensions = [:]
        defer {
            let suspensions = frameWriteSuspensions ?? [:]
            frameWriteSuspensions = nil
            finish(suspensions)
        }
        try updates()
    }

    /// Result of a suspend request. `restore` is a no-op unless BetterTile
    /// actually disabled the attribute and the policy asks for it back.
    private struct EnhancedUserInterfaceSuspension {
        var applicationElement: AXUIElement?
        var shouldRestore: Bool

        /// Returns false when the application is held as unresponsive or
        /// did not answer in time; the caller keeps the restore and retries.
        func restore() -> Bool {
            guard shouldRestore, let applicationElement else { return true }
            // Restoring is what makes Chromium rebuild its accessibility tree,
            // so this is the slowest write in the whole sequence and needs the
            // full budget rather than the short read default. It is gated, so
            // a hung application costs nothing here; a refused restore waits
            // for a later batch, an application event, or the quit.
            let error = AccessibilityWindowSystem.gatedCall(applicationElement) {
                AccessibilityWindowSystem.writeEnhancedUserInterface(true, to: applicationElement)
            }
            if error == .cannotComplete { return false }
            guard error != .success else { return true }
            // Deliberately not thrown: the frame write already succeeded, and
            // failing it here would roll back a correct placement. Logged
            // because a silent failure downgrades disableAndRestore to
            // disableOnly for assistive technology.
            AccessibilityWindowSystem.log.warning(
                "Could not restore AXEnhancedUserInterface (\(error.rawValue, privacy: .public))."
            )
            return true
        }
    }

    /// Restores that waited for an application to answer again, by process.
    private var pendingEnhancedUserInterfaceRestores: [pid_t: EnhancedUserInterfaceSuspension] = [:]

    private func finish(_ suspension: EnhancedUserInterfaceSuspension) {
        guard let element = suspension.applicationElement, !suspension.restore() else { return }
        pendingEnhancedUserInterfaceRestores[Self.processIdentifier(of: element)] = suspension
    }

    private func finish(_ suspensions: [pid_t: EnhancedUserInterfaceSuspension]) {
        for (pid, suspension) in suspensions where !suspension.restore() {
            pendingEnhancedUserInterfaceRestores[pid] = suspension
        }
    }

    /// Puts back the setting of every application still waiting, without the
    /// gate, because no later write will retry it. Only for quitting:
    /// an application that is still hung costs one frame-write timeout. A
    /// restore that fails stays pending.
    public func restoreEnhancedUserInterfaceBeforeQuit() {
        guard !pendingEnhancedUserInterfaceRestores.isEmpty, AXIsProcessTrusted() else { return }
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        pendingEnhancedUserInterfaceRestores = pendingEnhancedUserInterfaceRestores.filter { pid, suspension in
            guard running.contains(pid), suspension.shouldRestore,
                  let element = suspension.applicationElement else { return false }
            let error = Self.writeEnhancedUserInterface(true, to: element)
            guard error != .success else { return false }
            Self.log.warning("Could not restore AXEnhancedUserInterface (\(error.rawValue, privacy: .public)).")
            return true
        }
    }

    /// Puts back the setting of applications that answer again. One that is
    /// still held keeps waiting; one that quit needs nothing.
    private func retryPendingEnhancedUserInterfaceRestores() {
        guard !pendingEnhancedUserInterfaceRestores.isEmpty else { return }
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let pending = pendingEnhancedUserInterfaceRestores.filter { running.contains($0.key) }
        pendingEnhancedUserInterfaceRestores = [:]
        finish(pending)
    }

    /// Both enhanced-accessibility writes run on the application element, which
    /// otherwise carries the short read timeout. Passing 0 afterwards releases
    /// it back to the process default.
    private nonisolated static func writeEnhancedUserInterface(
        _ isEnabled: Bool,
        to applicationElement: AXUIElement
    ) -> AXError {
        AXUIElementSetMessagingTimeout(applicationElement, frameWriteMessagingTimeout)
        defer { AXUIElementSetMessagingTimeout(applicationElement, 0) }
        // The disable is not gated: it runs only after a gated read found the
        // attribute on. The restore is gated and waits in
        // `pendingEnhancedUserInterfaceRestores`; the last try, when
        // BetterTile quits, is not gated.
        return AXUIElementSetAttributeValue(
            applicationElement,
            enhancedUserInterfaceAttribute as CFString,
            isEnabled ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    private func suspendEnhancedUserInterfaceIfNeeded(
        for window: AXUIElement
    ) -> EnhancedUserInterfaceSuspension {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            return EnhancedUserInterfaceSuspension(applicationElement: nil, shouldRestore: false)
        }
        if let existing = frameWriteSuspensions?[pid] { return existing }
        var suspension = EnhancedUserInterfaceSuspension(applicationElement: nil, shouldRestore: false)
        defer { frameWriteSuspensions?[pid] = suspension }
        let applicationElement = makeApplicationElement(pid: pid)
        let isEnabled: Bool = value(
            Self.enhancedUserInterfaceAttribute,
            from: applicationElement
        ) ?? false
        let decision = EnhancedUserInterfaceCoordinator.decision(
            policy: enhancedUserInterfacePolicy,
            isCurrentlyEnabled: isEnabled
        )
        guard decision.shouldDisableBeforeWrite else {
            return EnhancedUserInterfaceSuspension(applicationElement: nil, shouldRestore: false)
        }
        let error = Self.writeEnhancedUserInterface(false, to: applicationElement)
        if error != .success {
            // Best effort. A failed disable usually still produces a mostly
            // correct placement, whereas refusing to move the window at all is
            // a visible regression. Read-back verification is the real remedy.
            Self.log.warning(
                "Could not disable AXEnhancedUserInterface (\(error.rawValue, privacy: .public)); frame may land imprecisely."
            )
        }
        suspension = EnhancedUserInterfaceSuspension(
            applicationElement: applicationElement,
            // Only ask for a restore if the disable actually took.
            shouldRestore: decision.shouldRestoreAfterWrite && error == .success
        )
        return suspension
    }

    public func setMinimized(_ minimized: Bool, for windowID: WindowID) throws {
        try ensurePermission()
        guard let element = elements[windowID] ?? refreshElement(for: windowID) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        guard isSettable(kAXMinimizedAttribute, on: element) else {
            throw WindowSystemError.unsupportedWindow(windowID)
        }
        let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
        guard result == .success else {
            throw WindowSystemError.operationFailed("macOS rejected the minimize update (\(result.rawValue)).")
        }
    }

    /// Every application element is created here. The process-wide default set
    /// in `init` already bounds these; repeating it keeps the bound explicit if
    /// the process default is ever changed.
    private func makeApplicationElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.defaultMessagingTimeout)
        return element
    }

    private func ensurePermission() throws {
        guard AXIsProcessTrusted() else { throw WindowSystemError.accessibilityPermissionRequired }
    }

    private func recordActivation(of application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard Self.shouldManageApplication(
            processIdentifier: pid,
            ownProcessIdentifier: getpid(),
            activationPolicy: application.activationPolicy,
            isHidden: application.isHidden,
            includeHidden: true
        ) else { return }
        _ = applicationInstance(for: application)
        recentApplicationPIDs.removeAll { $0 == pid }
        recentApplicationPIDs.insert(pid, at: 0)
        if recentApplicationPIDs.count > 12 {
            recentApplicationPIDs.removeLast(recentApplicationPIDs.count - 12)
        }
    }

    private func synchronizeObservers() {
        let interval = Self.signposter.beginInterval("synchronizeObservers")
        defer { Self.signposter.endInterval("synchronizeObservers", interval) }
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningPIDs = Set(runningApplications.map(\.processIdentifier))
        // A failed observer installation must not prevent termination cleanup.
        // Hidden or policy-filtered running applications are not terminated.
        let knownPIDs = Set(launchRecords.keys).union(identities.records.values.map { $0.application.processIdentifier })
        var quitApplications: Set<String> = []
        for pid in knownPIDs.subtracting(runningPIDs) {
            let closed = identities.remove(processIdentifier: pid)
            quitApplications.formUnion(bundleIdentifiers(of: pid, windows: closed))
            removeCachedState(for: closed, notifyClosure: true)
            launchRecords.removeValue(forKey: pid)
        }
        forgetMinimumSizeSeeds(of: quitApplications)
        let applications = runningApplications.filter {
            Self.shouldManageApplication(
                processIdentifier: $0.processIdentifier,
                ownProcessIdentifier: getpid(),
                activationPolicy: $0.activationPolicy,
                isHidden: $0.isHidden,
                includeHidden: true
            )
        }
        let activePIDs = Set(applications.map { application -> pid_t in
            _ = applicationInstance(for: application)
            return application.processIdentifier
        })
        for pid in observers.keys where !activePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            registrations.removeValue(forKey: pid)
            removeCachedState(for: identities.remove(processIdentifier: pid))
            launchRecords.removeValue(forKey: pid)
        }
        for application in applications where observers[application.processIdentifier] == nil {
            installObserver(for: application.processIdentifier)
        }
    }

    private func unregisterWindowNotifications(
        _ window: AXUIElement,
        windowID: WindowID
    ) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let observer = observers[pid],
              let existing = registrations[pid]
        else { return }
        // A window of a hung application drops out of a sweep, and each
        // removal would wait out the timeout. A removal that did not complete
        // stays recorded, since the notification may still be registered.
        let removed = existing.filter { registration in
            registration.windowID == windowID && Self.gatedCall(window) {
                AXObserverRemoveNotification(observer, window, registration.notification as CFString)
            } != .cannotComplete
        }
        registrations[pid] = existing.subtracting(removed)
    }

    private func installObserver(for pid: pid_t) {
        var observer: AXObserver?
        let error = AXObserverCreate(pid, betterTileAXObserverCallback, &observer)
        guard error == .success, let observer else { return }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let application = makeApplicationElement(pid: pid)
        register(kAXWindowCreatedNotification, element: application, observer: observer, pid: pid)
        register(kAXFocusedWindowChangedNotification, element: application, observer: observer, pid: pid)
    }

    private func registerWindowNotifications(
        _ window: AXUIElement,
        snapshot: WindowSnapshot
    ) {
        let pid = snapshot.processIdentifier
        guard let observer = observers[pid] else { return }
        for notification in [
            kAXMovedNotification,
            kAXResizedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ] {
            register(
                notification,
                element: window,
                observer: observer,
                pid: pid,
                windowID: snapshot.id
            )
        }
    }

    private func register(
        _ notification: String,
        element: AXUIElement,
        observer: AXObserver,
        pid: pid_t,
        windowID: WindowID? = nil
    ) {
        let registration = Registration(
            windowID: windowID,
            accessibilityHash: windowID == nil ? nil : CFHash(element),
            notification: notification
        )
        guard registrations[pid, default: []].insert(registration).inserted else { return }
        let context = observationCallbackContext ?? AccessibilityCallbackContext(system: self)
        observationCallbackContext = context
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let result = AXObserverAddNotification(observer, element, notification as CFString, pointer)
        if result != .success, result != .notificationAlreadyRegistered {
            registrations[pid]?.remove(registration)
        }
    }

    fileprivate func receiveWindowEvent(_ event: WindowSystemEvent) {
        if event.kind == .minimized, let windowID = event.windowID {
            minimizedWindowIDs.insert(windowID)
            retainRecent(windowID)
        } else if event.kind == .restored, let windowID = event.windowID {
            minimizedWindowIDs.remove(windowID)
            retainRecent(windowID)
        }
        if event.kind == .destroyed, let windowID = event.windowID {
            if let element = elements[windowID] {
                unregisterWindowNotifications(element, windowID: windowID)
            }
            elements.removeValue(forKey: windowID)
            identities.remove(windowID)
            recentWindowIDs.removeAll { $0 == windowID }
            minimizedWindowIDs.remove(windowID)
            if let existing = registrations[event.processIdentifier] {
                registrations[event.processIdentifier] = Set(
                    existing.filter { $0.windowID != windowID }
                )
            }
            minimumSizeLearner.remove(windowID)
            popupVerdicts.removeValue(forKey: windowID)
            applicationKeys.removeValue(forKey: windowID)
            lastWriteReadback.removeValue(forKey: windowID)
            continuousSettable.removeValue(forKey: windowID)
            continuousSizeSettable.removeValue(forKey: windowID)
        }
        if event.kind != .moved, event.kind != .resized, event.kind != .focused {
            snapshotCache.invalidate()
        }
        eventHandler?(event)
    }

    fileprivate func receiveAXEvent(
        kind: WindowSystemEvent.Kind,
        processIdentifier: pid_t,
        accessibilityHash: CFHashCode
    ) {
        let windowID: WindowID?
        if kind == .focused {
            windowID = nil
        } else {
            let application = applicationInstance(forPID: processIdentifier)
            windowID = identities.windowID(
                application: application,
                accessibilityHash: accessibilityHash
            ) ?? identities.resolve(
                application: application,
                accessibilityHash: accessibilityHash,
                exactWindowID: nil
            )
        }
        receiveWindowEvent(WindowSystemEvent(
            kind: kind,
            windowID: windowID,
            processIdentifier: processIdentifier
        ))
    }

    struct SnapshotAttributes: Equatable {
        var role: String
        var position: CGPoint
        var size: CGSize
        var minimized: Bool
        var fullScreen: Bool
        var title: String
        var subrole: String?
        var minimumSizes: [BTSize]
    }

    private nonisolated static let snapshotAttributeNames = [
        kAXRoleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXMinimizedAttribute,
        "AXFullScreen",
        kAXTitleAttribute,
        kAXSubroleAttribute,
        "AXMinSize",
        "AXMinimumSize",
    ]

    private func snapshot(
        _ element: AXUIElement,
        application: ApplicationLaunchInstance,
        bundleIdentifier: String?,
        displays availableDisplays: [DisplaySnapshot]
    ) -> WindowSnapshot? {
        guard let attributes = snapshotAttributes(element),
              attributes.role == kAXWindowRole,
              attributes.size.width > 20, attributes.size.height > 20
        else { return nil }
        let frame = BTRect(
            x: attributes.position.x,
            y: attributes.position.y,
            width: attributes.size.width,
            height: attributes.size.height
        )
        guard let display = display(containing: frame.center, in: availableDisplays) else { return nil }
        let id = identities.resolve(
            application: application,
            accessibilityHash: CFHash(element),
            exactWindowID: exactWindowIDResolver.windowID(for: element)
        )
        elements[id] = element
        let movable = isSettable(kAXPositionAttribute, on: element)
        let resizable = isSettable(kAXSizeAttribute, on: element)
        let minimumSize = MinimumSizeHintValidator.merged(
            defaultSize: WindowConstraints().minimumSize,
            hints: attributes.minimumSizes,
            displaySize: display.frame.size
        )
        if let bundleIdentifier {
            applicationKeys[id] = bundleIdentifier
            // A process registered while macOS could not name it learns its
            // bundle identifier from its windows, so its seed is still
            // dropped when it quits after its last window closed.
            let pid = application.processIdentifier
            if let record = launchRecords[pid], Self.recordLearnsBundleIdentifier(
                recordInstance: record.instance, recordBundleIdentifier: record.bundleIdentifier, windowInstance: application
            ) {
                launchRecords[pid]?.bundleIdentifier = bundleIdentifier
            }
        }
        minimumSizeLearner.observeAcceptedSize(windowID: id, application: bundleIdentifier, size: frame.size)
        let constraints = minimumSizeLearner.merging(
            WindowConstraints(
                minimumSize: minimumSize,
                isMovable: movable,
                isResizable: resizable
            ),
            for: id,
            application: bundleIdentifier
        )
        return WindowSnapshot(
            id: id,
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            title: attributes.title,
            frame: frame,
            displayID: display.id,
            constraints: constraints,
            isMinimized: attributes.minimized || minimizedWindowIDs.contains(id),
            isFullScreen: attributes.fullScreen,
            isHidden: false,
            isFloating: WindowFloatingClassifier.isFloating(subrole: attributes.subrole)
                || popupVerdict(for: id, element: element, attributes: attributes, bundleIdentifier: bundleIdentifier) == .popup
        )
    }

    /// Classifies a window once, when it is first decidable: popups such as
    /// file pickers and settings dialogs float instead of joining a layout.
    /// A window's buttons change while a sheet is attached, so a decided
    /// verdict is kept for the window's lifetime.
    private func popupVerdict(
        for id: WindowID, element: AXUIElement, attributes: SnapshotAttributes, bundleIdentifier: String?
    ) -> PopupWindowClassifier.Verdict {
        if let cached = popupVerdicts[id] { return cached }
        let verdict = PopupWindowClassifier.classify(PopupWindowClassifier.Attributes(
            subrole: attributes.subrole,
            fullScreenButton: buttonState(kAXFullScreenButtonAttribute, of: element),
            closeButton: buttonState(kAXCloseButtonAttribute, of: element),
            minimizeButton: buttonState(kAXMinimizeButtonAttribute, of: element),
            isModal: value("AXModal", from: element) ?? false,
            isMinimized: attributes.minimized || attributes.fullScreen,
            bundleIdentifier: bundleIdentifier
        ))
        if verdict != .undetermined { popupVerdicts[id] = verdict }
        return verdict
    }

    private func buttonState(_ attribute: String, of element: AXUIElement) -> PopupWindowClassifier.ButtonState {
        var raw: CFTypeRef?
        let reference = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard reference == .success else { return Self.buttonState(reference: reference, enabled: nil) }
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .missing }
        var enabled: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(unsafeDowncast(raw, to: AXUIElement.self), kAXEnabledAttribute as CFString, &enabled)
        return Self.buttonState(reference: reference, enabled: (error, enabled as? Bool))
    }

    /// Maps the reads of a title-bar button to its state. Only an absent
    /// attribute means absent; any other failed read is unreadable, so the
    /// window is judged again later.
    nonisolated static func buttonState(reference: AXError, enabled: (error: AXError, value: Bool?)?) -> PopupWindowClassifier.ButtonState {
        switch reference {
        case .success: break
        case .attributeUnsupported, .noValue: return .missing
        default: return .unreadable
        }
        guard let enabled else { return .missing }
        switch enabled.error {
        case .success: return enabled.value == false ? .disabled : .enabled
        // A button without an enabled state can be pressed.
        case .attributeUnsupported, .noValue: return .enabled
        default: return .unreadable
        }
    }

    private func snapshotAttributes(_ element: AXUIElement) -> SnapshotAttributes? {
        if let attributes = batchedSnapshotAttributes(element) { return attributes }
        guard let role: String = value(kAXRoleAttribute, from: element),
              let position: CGPoint = axValue(
                  kAXPositionAttribute,
                  from: element,
                  type: .cgPoint
              ),
              let size: CGSize = axValue(kAXSizeAttribute, from: element, type: .cgSize)
        else { return nil }
        return SnapshotAttributes(
            role: role,
            position: position,
            size: size,
            minimized: value(kAXMinimizedAttribute, from: element) ?? false,
            fullScreen: value("AXFullScreen", from: element) ?? false,
            title: value(kAXTitleAttribute, from: element) ?? "",
            subrole: value(kAXSubroleAttribute, from: element),
            minimumSizes: privateAPIsDisabled ? [] : ["AXMinSize", "AXMinimumSize"].compactMap {
                (axValue($0, from: element, type: .cgSize) as CGSize?).map {
                    BTSize(width: $0.width, height: $0.height)
                }
            }
        )
    }

    private func batchedSnapshotAttributes(_ element: AXUIElement) -> SnapshotAttributes? {
        var copiedValues: CFArray?
        let names = privateAPIsDisabled
            ? Array(Self.snapshotAttributeNames.prefix(7))
            : Self.snapshotAttributeNames
        let error = Self.gatedCall(element) {
            AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &copiedValues)
        }
        guard error == .success,
              let values = copiedValues as? [Any],
              values.count == names.count
        else {
            logBatchFallbackOnce(reason: "batch request unavailable")
            return nil
        }
        let parsed = Self.parsedBatchedSnapshotAttributes(
            values + Array(repeating: NSNull(), count: Self.snapshotAttributeNames.count - values.count)
        )
        if parsed == nil { logBatchFallbackOnce(reason: "required batch value malformed") }
        return parsed
    }

    private func logBatchFallbackOnce(reason: String) {
        guard !loggedBatchFallback else { return }
        loggedBatchFallback = true
        Self.log.notice("AX snapshot batching fallback: \(reason, privacy: .public)")
    }

    nonisolated static func parsedBatchedSnapshotAttributes(
        _ values: [Any]
    ) -> SnapshotAttributes? {
        guard values.count == snapshotAttributeNames.count,
              let role = values[0] as? String,
              let position: CGPoint = decodedAXValue(values[1], type: .cgPoint),
              let size: CGSize = decodedAXValue(values[2], type: .cgSize)
        else { return nil }
        let minimumSizes = values[7...8].compactMap { raw -> BTSize? in
            guard let size: CGSize = decodedAXValue(raw, type: .cgSize) else { return nil }
            return BTSize(width: size.width, height: size.height)
        }
        return SnapshotAttributes(
            role: role,
            position: position,
            size: size,
            minimized: values[3] as? Bool ?? false,
            fullScreen: values[4] as? Bool ?? false,
            title: values[5] as? String ?? "",
            subrole: values[6] as? String,
            minimumSizes: minimumSizes
        )
    }

    private func display(containing point: BTPoint, in available: [DisplaySnapshot]) -> DisplaySnapshot? {
        return available.first(where: { $0.frame.contains(point) })
            ?? available.max(by: { ($0.frame.intersection(BTRect(x: point.x, y: point.y, width: 1, height: 1))?.area ?? 0) < ($1.frame.intersection(BTRect(x: point.x, y: point.y, width: 1, height: 1))?.area ?? 0) })
    }

    private func refreshElement(for windowID: WindowID) -> AXUIElement? {
        _ = try? visibleWindows()
        return elements[windowID]
    }

    public func window(at point: BTPoint) throws -> WindowSnapshot? {
        let interval = Self.signposter.beginInterval("dragResolution")
        defer { Self.signposter.endInterval("dragResolution", interval) }
        try ensurePermission()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        let hitElement,
        let window = containingWindow(for: hitElement)
        else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let runningApplication = NSRunningApplication(processIdentifier: pid),
              Self.shouldManageApplication(
                  processIdentifier: pid,
                  ownProcessIdentifier: getpid(),
                  activationPolicy: runningApplication.activationPolicy,
                  isHidden: runningApplication.isHidden,
                  includeHidden: false
              ),
              let snapshot = snapshot(
                  window,
                  application: applicationInstance(for: runningApplication),
                  bundleIdentifier: runningApplication.bundleIdentifier,
                  displays: displays()
              )
        else { return nil }

        if let exactWindowID = identities.exactWindowID(for: snapshot.id) {
            guard let windowServer = targetedWindowServerIndex(ids: [exactWindowID]),
                  windowServer.contains(snapshot, exactWindowID: exactWindowID)
            else { return nil }
        }
        return classifyByNativeMembership(snapshot)
    }

    private func classifyByNativeMembership(_ window: WindowSnapshot) -> WindowSnapshot? {
        guard let lastNativeDesktopObservation else { return window }
        return lastNativeDesktopObservation.windowsOnCurrentSpaces([window]).first
    }

    private func containingWindow(for element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<8 {
            if let role: String = value(kAXRoleAttribute, from: current), role == kAXWindowRole {
                return current
            }
            if let window: AXUIElement = value(kAXWindowAttribute, from: current) {
                return window
            }
            guard let parent: AXUIElement = value(kAXParentAttribute, from: current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private func retainRecent(_ windowID: WindowID) {
        recentWindowIDs.removeAll { $0 == windowID }
        recentWindowIDs.insert(windowID, at: 0)
        if recentWindowIDs.count > 12 {
            let evicted = Array(recentWindowIDs.dropFirst(12))
            recentWindowIDs.removeLast(recentWindowIDs.count - 12)
            for id in evicted where !managedWindowIDs.contains(id) {
                if let element = elements[id] {
                    unregisterWindowNotifications(element, windowID: id)
                }
            }
        }
    }

    private func applicationInstance(
        for application: NSRunningApplication
    ) -> ApplicationLaunchInstance {
        let pid = application.processIdentifier
        let launchToken = application.launchDate?.timeIntervalSinceReferenceDate.bitPattern
        let previous = launchRecords[pid]
        if let previous, previous.launchToken == launchToken {
            return previous.instance
        }
        // A changed launch at a known process identifier means the previous
        // process quit, and its windows close with it.
        let closed = identities.remove(processIdentifier: pid)
        let quitApplications = previous == nil ? [] : bundleIdentifiers(of: pid, windows: closed)
        nextLaunchGeneration &+= 1
        let instance = ApplicationLaunchInstance(
            processIdentifier: pid,
            generation: nextLaunchGeneration
        )
        launchRecords[pid] = LaunchRecord(
            launchToken: launchToken, instance: instance, bundleIdentifier: application.bundleIdentifier
        )
        removeCachedState(for: closed, notifyClosure: true)
        if !quitApplications.isEmpty {
            forgetMinimumSizeSeeds(of: quitApplications)
        }
        return instance
    }

    /// The bundle identifiers a process had, read before its windows are
    /// removed from the cache.
    private func bundleIdentifiers(of pid: pid_t, windows: [WindowIdentityRecord]) -> Set<String> {
        Self.quitApplicationBundles(
            closedWindowIDs: windows.map(\.windowID),
            applicationKeys: applicationKeys,
            launchBundleIdentifier: launchRecords[pid]?.bundleIdentifier
        )
    }

    /// The applications a quit process belonged to, from the windows it had
    /// and from its launch record. The caller reads both before they leave
    /// the cache.
    nonisolated static func quitApplicationBundles(
        closedWindowIDs: [WindowID],
        applicationKeys: [WindowID: String],
        launchBundleIdentifier: String?
    ) -> Set<String> {
        var result = Set(closedWindowIDs.compactMap { applicationKeys[$0] })
        if let launchBundleIdentifier { result.insert(launchBundleIdentifier) }
        return result
    }

    /// Drops the minimum-size seeds of applications that quit, so a relaunch,
    /// perhaps of an updated version, starts without an old value. Only a real
    /// termination calls this; a hidden application or one that BetterTile no
    /// longer observes keeps its seed. Another running process of the same
    /// application loses the seed too: running processes cannot tell a second
    /// instance from a relaunch, and each new window is measured anyway.
    private func forgetMinimumSizeSeeds(of quitApplications: Set<String>) {
        for bundleIdentifier in Self.forgetSeeds(of: quitApplications, in: &minimumSizeLearner) {
            Self.log.debug("forgot minimum-size seed of \(bundleIdentifier, privacy: .private) after it quit")
        }
    }

    /// A launch record takes its bundle identifier from a window only when it
    /// has none and the window belongs to the same launch. A record left from
    /// an earlier process at a reused identifier is never relabelled.
    nonisolated static func recordLearnsBundleIdentifier(
        recordInstance: ApplicationLaunchInstance,
        recordBundleIdentifier: String?,
        windowInstance: ApplicationLaunchInstance
    ) -> Bool {
        recordBundleIdentifier == nil && recordInstance == windowInstance
    }

    /// Drops the seeds of `quitApplications` and returns those it dropped.
    /// Measurements of individual windows stay.
    nonisolated static func forgetSeeds(
        of quitApplications: Set<String>,
        in learner: inout WindowMinimumSizeLearner
    ) -> [String] {
        let dropped = quitApplications.sorted().filter { learner.applicationSizes[$0] != nil }
        for bundleIdentifier in dropped { learner.forgetApplication(bundleIdentifier) }
        return dropped
    }

    private func applicationInstance(forPID pid: pid_t) -> ApplicationLaunchInstance {
        if let application = NSRunningApplication(processIdentifier: pid) {
            return applicationInstance(for: application)
        }
        if let record = launchRecords[pid] { return record.instance }
        nextLaunchGeneration &+= 1
        let instance = ApplicationLaunchInstance(
            processIdentifier: pid,
            generation: nextLaunchGeneration
        )
        launchRecords[pid] = LaunchRecord(launchToken: nil, instance: instance)
        return instance
    }

    private func removeCachedState(for records: [WindowIdentityRecord], notifyClosure: Bool = false) {
        guard !records.isEmpty else { return }
        if notifyClosure {
            for record in records.sorted(by: { $0.windowID < $1.windowID }) {
                receiveWindowEvent(WindowSystemEvent(
                    kind: .destroyed, windowID: record.windowID,
                    processIdentifier: record.application.processIdentifier
                ))
            }
        } else {
            let windowIDs = Set(records.map(\.windowID))
            for windowID in windowIDs {
                elements.removeValue(forKey: windowID)
                minimumSizeLearner.remove(windowID)
                popupVerdicts.removeValue(forKey: windowID)
                minimizedWindowIDs.remove(windowID)
            }
            recentWindowIDs.removeAll { windowIDs.contains($0) }
            snapshotCache.invalidate()
        }
    }

    private func windowServerIndex() -> WindowServerIndex? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        return WindowServerIndex(records: windowServerRecords(from: info, defaultOnscreen: false))
    }

    private func targetedWindowServerIndex(ids: Set<CGWindowID>) -> WindowServerIndex? {
        targetedWindowServerRecords(ids: ids).map(WindowServerIndex.init(records:))
    }

    private func targetedWindowServerRecords(ids: Set<CGWindowID>) -> [WindowServerRecord]? {
        guard !ids.isEmpty,
              let info = CGWindowListCreateDescriptionFromArray(
                  makeWindowServerIDArray(ids)
              ) as? [[CFString: Any]]
        else { return nil }
        return windowServerRecords(from: info, defaultOnscreen: false)
    }

    private func frontToBackWindowIDs(in candidates: Set<CGWindowID>) -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }
        return info.compactMap { item in
            guard let number = item[kCGWindowNumber] as? NSNumber,
                  candidates.contains(number.uint32Value)
            else { return nil }
            return number.uint32Value
        }
    }

    private func windowServerRecords(
        from info: [[CFString: Any]],
        defaultOnscreen: Bool
    ) -> [WindowServerRecord] {
        info.compactMap { item in
            guard let windowNumber = item[kCGWindowNumber] as? NSNumber,
                  let layer = item[kCGWindowLayer] as? NSNumber,
                  let owner = item[kCGWindowOwnerPID] as? NSNumber,
                  let bounds = item[kCGWindowBounds] as? [String: Any],
                  let x = number(bounds["X"]), let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]), let height = number(bounds["Height"])
            else { return nil }
            return WindowServerRecord(
                windowID: windowNumber.uint32Value,
                processIdentifier: pid_t(owner.int32Value),
                layer: layer.intValue,
                frame: BTRect(x: x, y: y, width: width, height: height),
                isOnscreen: item[kCGWindowIsOnscreen] as? Bool ?? defaultOnscreen
            )
        }
    }

    private func value<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var rawValue: CFTypeRef?
        guard Self.gatedCall(element, { AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) }) == .success
        else { return nil }
        return rawValue as? T
    }

    private func axValue<T>(_ attribute: String, from element: AXUIElement, type: AXValueType) -> T? {
        guard let value: AXValue = value(attribute, from: element), AXValueGetType(value) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(value, type, pointer) else { return nil }
        return pointer.pointee
    }

    private nonisolated static func decodedAXValue<T>(
        _ raw: Any,
        type: AXValueType
    ) -> T? {
        let rawValue = raw as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = rawValue as! AXValue
        guard AXValueGetType(value) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(value, type, pointer) else { return nil }
        return pointer.pointee
    }

    private func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        settable(attribute, on: element) ?? false
    }

    /// Whether an attribute can be set, or nil when the application did not
    /// answer in time or is held as unresponsive.
    private func settable(_ attribute: String, on element: AXUIElement) -> Bool? {
        var settable = DarwinBoolean(false)
        switch Self.gatedCall(element, { AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) }) {
        case .success: return settable.boolValue
        case .cannotComplete: return nil
        default: return false
        }
    }

    /// Whether a frame write can move or resize the window. An application
    /// that did not answer fails this write without a verdict, so a gesture
    /// does not keep a window it could not ask about as unmovable.
    private func movability(of element: AXUIElement) throws -> Bool {
        let position = settable(kAXPositionAttribute, on: element)
        let size = position == true ? true : settable(kAXSizeAttribute, on: element)
        guard let movable = Self.movability(position: position, size: size) else {
            throw WindowSystemError.operationFailed(Self.unresponsiveApplicationMessage)
        }
        return movable
    }

    /// True when either attribute can be set, false only when both answered
    /// that they cannot, nil when the answer is not known.
    nonisolated static func movability(position: Bool?, size: Bool?) -> Bool? {
        if position == true || size == true { return true }
        if position == false, size == false { return false }
        return nil
    }

    /// An Accessibility call to one application. While the application is
    /// held as unresponsive it fails at once, as a timed-out call would, so a
    /// hung application costs one timeout instead of one per call. A sweep
    /// already treats a failed read as an unreadable application and keeps
    /// its windows. Calls without an application are not gated.
    private nonisolated static func gatedCall(_ element: AXUIElement, _ call: () -> AXError) -> AXError {
        let pid = processIdentifier(of: element)
        guard pid > 0 else { return call() }
        if isUnresponsive(pid) { return .cannotComplete }
        let start = ProcessInfo.processInfo.systemUptime
        let error = call()
        recordCall(pid, error: error, since: start)
        return error
    }

    private nonisolated static func setFrameAttribute(
        _ element: AXUIElement, _ attribute: String, _ value: CFTypeRef
    ) -> AXError {
        gatedCall(element) { AXUIElementSetAttributeValue(element, attribute as CFString, value) }
    }

    private nonisolated static func processIdentifier(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : 0
    }

    private nonisolated static func isUnresponsive(_ pid: pid_t) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return unresponsiveApplications.withLock { $0.isHeld(pid, now: now) }
    }

    private nonisolated static func recordCall(_ pid: pid_t, error: AXError, since start: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        unresponsiveApplications.withLock {
            $0.record(pid, cannotComplete: error == .cannotComplete, elapsed: now - start, now: now)
        }
    }

    /// Fails a frame write before it makes any call that would wait out a
    /// timeout on an application held as unresponsive.
    private func requireResponsive(_ element: AXUIElement) throws {
        if Self.isUnresponsive(Self.processIdentifier(of: element)) {
            throw WindowSystemError.operationFailed(Self.unresponsiveApplicationMessage)
        }
    }

    private func number(_ value: Any?) -> CGFloat? {
        (value as? NSNumber).map(CGFloat.init(truncating:))
    }

    nonisolated static func shouldManageApplication(
        processIdentifier: pid_t,
        ownProcessIdentifier: pid_t,
        activationPolicy: NSApplication.ActivationPolicy,
        isHidden: Bool,
        includeHidden: Bool
    ) -> Bool {
        processIdentifier != ownProcessIdentifier
            && activationPolicy == .regular
            && (includeHidden || !isHidden)
    }
}

/// The window system retains this context while native callbacks are installed.
/// Queued delivery keeps a weak reference, never an unowned raw address.
@MainActor
private final class AccessibilityCallbackContext {
    weak var system: AccessibilityWindowSystem?
    init(system: AccessibilityWindowSystem) { self.system = system }
}

private func betterTileDisplayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let context = Unmanaged<AccessibilityCallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor [weak context] in
        context?.system?.displayConfigurationChanged()
    }
}

private func betterTileAXObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let name = notification as String
    let kind: WindowSystemEvent.Kind
    switch name {
    case kAXMovedNotification: kind = .moved
    case kAXResizedNotification: kind = .resized
    case kAXWindowCreatedNotification: kind = .created
    case kAXUIElementDestroyedNotification: kind = .destroyed
    case kAXWindowMiniaturizedNotification: kind = .minimized
    case kAXWindowDeminiaturizedNotification: kind = .restored
    case kAXFocusedWindowChangedNotification: kind = .focused
    default: return
    }
    let accessibilityHash = CFHash(element)
    let context = Unmanaged<AccessibilityCallbackContext>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor [weak context] in
        context?.system?.receiveAXEvent(
            kind: kind,
            processIdentifier: pid,
            accessibilityHash: accessibilityHash
        )
    }
}

public enum OnscreenWindowMatcher {
    /// Rejects scaled Stage Manager thumbnails while tolerating decoration, shadow, and reporting differences.
    public static func matches(accessibilityFrame: BTRect, windowServerFrame: BTRect) -> Bool {
        guard accessibilityFrame.area > 0, windowServerFrame.area > 0 else { return false }
        let areaRatio = windowServerFrame.area / accessibilityFrame.area
        guard (0.45...2.2).contains(areaRatio) else { return false }
        let overlap = accessibilityFrame.intersection(windowServerFrame)?.area ?? 0
        return overlap / min(accessibilityFrame.area, windowServerFrame.area) >= 0.5
    }
}

extension AccessibilityWindowSystem: TabbedWindowSystem {
    public func windowNumbers(for windows: [WindowSnapshot]) -> [WindowID: Int] {
        let exactIDs = Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            identities.exactWindowID(for: window.id).map { (window.id, $0) }
        })
        guard let index = targetedWindowServerIndex(ids: Set(exactIDs.values)) else { return [:] }
        return windows.reduce(into: [:]) { result, window in
            guard window.isEligible, let number = exactIDs[window.id], number != 0,
                  index.contains(window, exactWindowID: number) else { return }
            result[window.id] = Int(number)
        }
    }

    public func stackingOrder(for windows: [WindowSnapshot], excluding windowNumbers: Set<Int>) -> [TabbedStackEntry]? {
        var managed: [CGWindowID: WindowSnapshot] = [:]
        for window in windows {
            if let number = identities.exactWindowID(for: window.id), number != 0 { managed[number] = window }
        }
        guard !managed.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]] else { return nil }
        return windowServerRecords(from: info, defaultOnscreen: true).compactMap { record in
            guard record.layer == 0, record.isOnscreen, !windowNumbers.contains(Int(record.windowID)) else { return nil }
            // An identity whose process no longer matches is not addressable.
            let window = managed[record.windowID].flatMap { $0.processIdentifier == record.processIdentifier ? $0 : nil }
            return TabbedStackEntry(windowID: window?.id, frame: record.frame)
        }
    }

    public var frontmostProcessIdentifier: Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    public func raiseWindow(_ id: WindowID, activate: Bool) throws {
        try ensurePermission()
        guard let element = elements[id] ?? refreshElement(for: id) else { throw WindowSystemError.windowNotFound(id) }
        if activate {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success,
                  let app = NSRunningApplication(processIdentifier: pid) else {
                throw WindowSystemError.operationFailed("The application could not be activated.")
            }
            // Activation makes the application's main window key. Make the
            // target main first; otherwise the app's previous main window,
            // which can be a selected tab in another pane, takes focus.
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            let application = makeApplicationElement(pid: pid)
            let focusResult = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, element)
            if focusResult != .success && focusResult != .attributeUnsupported {
                throw WindowSystemError.operationFailed("The application rejected window focus.")
            }
            // Some windows, such as Calculator's, do not offer the raise
            // action (reported as an unsupported action or attribute);
            // activation still brings them forward.
            let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            guard [.success, .actionUnsupported, .attributeUnsupported].contains(raised) else {
                throw WindowSystemError.operationFailed("The application rejected window ordering.")
            }
            // Activating through Accessibility returns in about 8 ms and shows
            // the window 20-40 ms sooner than NSRunningApplication.activate,
            // which blocks for about 50 ms. Fall back when an app refuses it.
            if AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
                guard app.activate(options: []) else {
                    throw WindowSystemError.operationFailed("The application could not be activated.")
                }
            }
            return
        }
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard [.success, .actionUnsupported, .attributeUnsupported].contains(raised) else {
            throw WindowSystemError.operationFailed("The application rejected window ordering.")
        }
    }

    public func requestCloseWindow(_ id: WindowID) throws {
        try ensurePermission()
        guard let element = elements[id] ?? refreshElement(for: id) else { throw WindowSystemError.windowNotFound(id) }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(unsafeDowncast(button, to: AXUIElement.self), kAXPressAction as CFString) == .success else {
            throw WindowSystemError.operationFailed("This window could not be closed. Use its application's close command.")
        }
    }
}

extension AccessibilityWindowSystem: WindowStackReading {
    public func windowServerFrames(for ids: Set<WindowID>) -> [WindowID: BTRect]? {
        var exact: [CGWindowID: WindowID] = [:]
        for id in ids {
            guard let number = identities.exactWindowID(for: id) else { return nil }
            exact[number] = id
        }
        guard let records = targetedWindowServerRecords(ids: Set(exact.keys)) else { return nil }
        var frames: [WindowID: BTRect] = [:]
        for record in records { if let id = exact[record.windowID] { frames[id] = record.frame } }
        return frames.count == ids.count ? frames : nil
    }

    public func onScreenStack(labeling ids: Set<WindowID>) -> [SeamStackEntry]? {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] else { return nil }
        return SeamStackRecord.parseStack(records, identities: identities, labeling: ids)
    }
}

extension AccessibilityWindowSystem: MinimumSizeProbing {}
