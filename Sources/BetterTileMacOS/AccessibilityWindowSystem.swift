import AppKit
@preconcurrency import ApplicationServices
import BetterTileCore
import os

@MainActor
public final class AccessibilityWindowSystem: TargetedWindowSystem, WindowEventSource {
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "Accessibility"
    )

    private var elements: [WindowID: AXUIElement] = [:]
    private var identities = WindowIdentityRegistry()
    private let privateAPIsDisabled: Bool
    private let exactWindowIDResolver: ExactWindowIDResolver
    private var snapshotCache = WindowSnapshotCache()
    private struct LaunchRecord {
        var launchToken: UInt64?
        var instance: ApplicationLaunchInstance
    }
    private var launchRecords: [pid_t: LaunchRecord] = [:]
    private var nextLaunchGeneration: UInt64 = 0
    private var loggedBatchFallback = false
    private var observers: [pid_t: AXObserver] = [:]
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
    private nonisolated static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private nonisolated static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "Accessibility"
    )

    /// How frame writes treat `AXEnhancedUserInterface`. Owned by the app layer
    /// and refreshed from configuration.
    public var enhancedUserInterfacePolicy: EnhancedUserInterfacePolicy = .disableAndRestore

    public init() {
        let privateAPIsDisabled = UserDefaults.standard.bool(forKey: "disablePrivateAPIs")
        self.privateAPIsDisabled = privateAPIsDisabled
        exactWindowIDResolver = ExactWindowIDResolver(disabled: privateAPIsDisabled)
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

    public func startDockFootprintMonitoring(onChange: @escaping () -> Void) {
        dockFootprintMonitor.start(onChange: onChange)
    }

    public func triggerDockFootprintCheck() {
        dockFootprintMonitor.triggerTransitionCheck()
    }

    public func stopDockFootprintMonitoring() {
        dockFootprintMonitor.stop()
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
    }

    public func stopWindowObservation() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        registrations.removeAll()
    }

    public func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func resetCachedWindows() {
        elements.removeAll()
        identities.removeAll()
        snapshotCache.invalidate()
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
                   ) {
                    retainRecent(snapshot.id)
                    registerWindowNotifications(window, snapshot: snapshot)
                    return snapshot
                }
            }
            let windows: [AXUIElement] = value(kAXWindowsAttribute, from: appElement) ?? []
            if let snapshot = windows.lazy.compactMap({
                self.snapshot(
                    $0,
                    application: applicationInstance,
                    bundleIdentifier: application.bundleIdentifier,
                    displays: availableDisplays
                )
            }).first {
                retainRecent(snapshot.id)
                if let element = elements[snapshot.id] {
                    registerWindowNotifications(element, snapshot: snapshot)
                }
                return snapshot
            }
        }
        return nil
    }

    public func visibleWindows() throws -> [WindowSnapshot] {
        let interval = Self.signposter.beginInterval("completeSweep")
        defer { Self.signposter.endInterval("completeSweep", interval) }
        try ensurePermission()
        let windowServer = onscreenWindowIndex()
        let hasWindowServerSnapshot = !windowServer.isEmpty
        // Enumerated once per sweep. Resolving the containing display per
        // window used to re-read every NSScreen for every window.
        let availableDisplays = displays()
        var snapshots: [WindowSnapshot] = []
        var refreshedElements: [WindowID: AXUIElement] = [:]
        for application in NSWorkspace.shared.runningApplications where Self.shouldManageApplication(
            processIdentifier: application.processIdentifier,
            ownProcessIdentifier: getpid(),
            activationPolicy: application.activationPolicy,
            isHidden: application.isHidden,
            includeHidden: false
        ) {
            let applicationInstance = applicationInstance(for: application)
            let appElement = makeApplicationElement(pid: application.processIdentifier)
            let windows: [AXUIElement] = value(kAXWindowsAttribute, from: appElement) ?? []
            for window in windows {
                guard let snapshot = snapshot(
                    window,
                    application: applicationInstance,
                    bundleIdentifier: application.bundleIdentifier,
                    displays: availableDisplays
                ) else { continue }
                if hasWindowServerSnapshot,
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
        let observedIDs = Set(snapshots.map(\.id))
        for staleID in Set(identities.records.keys).subtracting(retainedIDs.union(observedIDs)) {
            identities.remove(staleID)
            minimumSizeLearner.remove(staleID)
        }
        let sorted = snapshots.sorted { $0.id < $1.id }
        snapshotCache.recordFullSweep(sorted)
        return sorted
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
        )
    }

    public func displays() -> [DisplaySnapshot] {
        let screens = NSScreen.screens
        guard let mainFrame = NSScreen.main?.frame ?? screens.first?.frame else { return [] }
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

    public func setFrame(_ frame: BTRect, knownCurrentFrame: BTRect?, for windowID: WindowID) throws {
        try ensurePermission()
        guard let element = elements[windowID] ?? refreshElement(for: windowID) else {
            throw WindowSystemError.windowNotFound(windowID)
        }
        guard isSettable(kAXPositionAttribute, on: element) || isSettable(kAXSizeAttribute, on: element) else {
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
        defer { enhancedUserInterface.restore() }

        // A frame write deserves more patience than a bulk read. Passing 0
        // returns this element to the process-wide default afterwards.
        AXUIElementSetMessagingTimeout(element, Self.frameWriteMessagingTimeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }

        // Several applications clamp position against their current size, so the
        // sequence is size, position, size. When the size is not changing the
        // leading write asks for the value the window already has, so it is
        // skipped; the trailing write still corrects any clamping.
        let plan = FrameWritePlanner.plan(target: frame, knownCurrentFrame: knownCurrentFrame)
        var errors: [AXError] = []
        if plan.writesInitialSize {
            errors.append(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue))
        }
        if plan.writesPosition {
            errors.append(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue))
        }
        if plan.writesFinalSize {
            errors.append(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue))
        }

        let accepted: [AXError] = [.success, .attributeUnsupported]
        guard errors.allSatisfy({ accepted.contains($0) }) else {
            elements.removeValue(forKey: windowID)
            throw WindowSystemError.operationFailed(
                "macOS rejected the window frame update (\(errors.map { String($0.rawValue) }.joined(separator: ", ")))."
            )
        }
    }

    /// Result of a suspend request. `restore` is a no-op unless BetterTile
    /// actually disabled the attribute and the policy asks for it back.
    private struct EnhancedUserInterfaceSuspension {
        var applicationElement: AXUIElement?
        var shouldRestore: Bool

        func restore() {
            guard shouldRestore, let applicationElement else { return }
            // Restoring is what makes Chromium rebuild its accessibility tree,
            // so this is the slowest write in the whole sequence and needs the
            // full budget rather than the short read default.
            let error = AccessibilityWindowSystem.writeEnhancedUserInterface(
                true,
                to: applicationElement
            )
            guard error != .success else { return }
            // Deliberately not thrown: the frame write already succeeded, and
            // failing it here would roll back a correct placement. Logged
            // because a silent failure downgrades disableAndRestore to
            // disableOnly for assistive technology.
            AccessibilityWindowSystem.log.warning(
                "Could not restore AXEnhancedUserInterface (\(error.rawValue, privacy: .public))."
            )
        }
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
        return EnhancedUserInterfaceSuspension(
            applicationElement: applicationElement,
            // Only ask for a restore if the disable actually took.
            shouldRestore: decision.shouldRestoreAfterWrite && error == .success
        )
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
        let applications = NSWorkspace.shared.runningApplications.filter {
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
        let windowRegistrations = existing.filter { $0.windowID == windowID }
        for registration in windowRegistrations {
            AXObserverRemoveNotification(
                observer,
                window,
                registration.notification as CFString
            )
        }
        registrations[pid] = existing.subtracting(windowRegistrations)
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
        let pointer = Unmanaged.passUnretained(self).toOpaque()
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
        let constraints = minimumSizeLearner.merging(
            WindowConstraints(
                minimumSize: minimumSize,
                isMovable: movable,
                isResizable: resizable
            ),
            for: id
        )
        return WindowSnapshot(
            id: id,
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            title: attributes.title,
            frame: frame,
            displayID: display.id,
            constraints: constraints,
            isMinimized: attributes.minimized,
            isFullScreen: attributes.fullScreen,
            isHidden: false,
            isFloating: WindowFloatingClassifier.isFloating(subrole: attributes.subrole)
        )
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
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            [],
            &copiedValues
        )
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
        return snapshot
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
        if let record = launchRecords[pid], record.launchToken == launchToken {
            return record.instance
        }
        removeCachedState(for: identities.remove(processIdentifier: pid))
        nextLaunchGeneration &+= 1
        let instance = ApplicationLaunchInstance(
            processIdentifier: pid,
            generation: nextLaunchGeneration
        )
        launchRecords[pid] = LaunchRecord(launchToken: launchToken, instance: instance)
        return instance
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

    private func removeCachedState(for windowIDs: Set<WindowID>) {
        guard !windowIDs.isEmpty else { return }
        for windowID in windowIDs {
            elements.removeValue(forKey: windowID)
            minimumSizeLearner.remove(windowID)
            minimizedWindowIDs.remove(windowID)
        }
        recentWindowIDs.removeAll { windowIDs.contains($0) }
        snapshotCache.invalidate()
    }

    private func onscreenWindowIndex() -> WindowServerIndex {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return WindowServerIndex(records: []) }
        return WindowServerIndex(records: windowServerRecords(from: info, defaultOnscreen: true))
    }

    private func targetedWindowServerIndex(ids: Set<CGWindowID>) -> WindowServerIndex? {
        guard !ids.isEmpty,
              let info = CGWindowListCreateDescriptionFromArray(
                  ids.sorted().map { NSNumber(value: $0) } as CFArray
              ) as? [[CFString: Any]]
        else { return nil }
        return WindowServerIndex(records: windowServerRecords(from: info, defaultOnscreen: false))
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
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else { return nil }
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
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
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
    let address = UInt(bitPattern: refcon)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let system = Unmanaged<AccessibilityWindowSystem>.fromOpaque(pointer).takeUnretainedValue()
        system.receiveAXEvent(
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
