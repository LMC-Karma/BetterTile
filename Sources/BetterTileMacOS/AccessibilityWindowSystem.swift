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
    private var observers: [pid_t: AXObserver] = [:]
    private struct Registration: Hashable {
        var windowID: WindowID?
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

    public init() {
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

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.35)
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window: AXUIElement = value(attribute, from: appElement),
                   let snapshot = snapshot(
                       window,
                       pid: pid,
                       bundleIdentifier: application.bundleIdentifier
                   ) {
                    retainRecent(snapshot.id)
                    registerWindowNotifications(window, snapshot: snapshot)
                    return snapshot
                }
            }
            let windows: [AXUIElement] = value(kAXWindowsAttribute, from: appElement) ?? []
            if let snapshot = windows.lazy.compactMap({
                self.snapshot($0, pid: pid, bundleIdentifier: application.bundleIdentifier)
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
        let interval = Self.signposter.beginInterval("visibleWindows")
        defer { Self.signposter.endInterval("visibleWindows", interval) }
        try ensurePermission()
        let onscreen = onscreenWindowFrames()
        let hasWindowServerSnapshot = !onscreen.isEmpty
        var snapshots: [WindowSnapshot] = []
        var refreshedElements: [WindowID: AXUIElement] = [:]
        for application in NSWorkspace.shared.runningApplications where Self.shouldManageApplication(
            processIdentifier: application.processIdentifier,
            ownProcessIdentifier: getpid(),
            activationPolicy: application.activationPolicy,
            isHidden: application.isHidden,
            includeHidden: false
        ) {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let windows: [AXUIElement] = value(kAXWindowsAttribute, from: appElement) ?? []
            for window in windows {
                guard let snapshot = snapshot(window, pid: application.processIdentifier, bundleIdentifier: application.bundleIdentifier) else { continue }
                if hasWindowServerSnapshot,
                   !isOnscreen(snapshot, candidates: onscreen[application.processIdentifier] ?? []) { continue }
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
        return snapshots.sorted { $0.id < $1.id }
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

    func windowSnapshot(id: WindowID) throws -> WindowSnapshot? {
        try ensurePermission()
        guard let element = elements[id] ?? refreshElement(for: id) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return snapshot(
            element,
            pid: pid,
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
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

    public func setFrame(_ frame: BTRect, for windowID: WindowID) throws {
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

        // Several applications clamp position against their current size.
        // The recovered tiler avoids that race by setting size, then position,
        // then size once more so the requested outer edge lands exactly.
        let initialSizeError = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let positionError = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        let finalSizeError = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let accepted: [AXError] = [.success, .attributeUnsupported]
        guard accepted.contains(initialSizeError),
              accepted.contains(positionError),
              accepted.contains(finalSizeError)
        else {
            elements.removeValue(forKey: windowID)
            throw WindowSystemError.operationFailed(
                "macOS rejected the window frame update (\(initialSizeError.rawValue), \(positionError.rawValue), \(finalSizeError.rawValue))."
            )
        }
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
        let activePIDs = Set(applications.map(\.processIdentifier))
        for pid in observers.keys where !activePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            registrations.removeValue(forKey: pid)
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
        let application = AXUIElementCreateApplication(pid)
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
        let registration = Registration(windowID: windowID, notification: notification)
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
            recentWindowIDs.removeAll { $0 == windowID }
            minimizedWindowIDs.remove(windowID)
            if let existing = registrations[event.processIdentifier] {
                registrations[event.processIdentifier] = Set(
                    existing.filter { $0.windowID != windowID }
                )
            }
            minimumSizeLearner.remove(windowID)
        }
        eventHandler?(event)
    }

    private func snapshot(_ element: AXUIElement, pid: pid_t, bundleIdentifier: String?) -> WindowSnapshot? {
        guard let role: String = value(kAXRoleAttribute, from: element), role == kAXWindowRole,
              let position: CGPoint = axValue(kAXPositionAttribute, from: element, type: .cgPoint),
              let size: CGSize = axValue(kAXSizeAttribute, from: element, type: .cgSize),
              size.width > 20, size.height > 20
        else { return nil }
        let frame = BTRect(x: position.x, y: position.y, width: size.width, height: size.height)
        guard let display = display(containing: frame.center) else { return nil }
        let id = WindowID(rawValue: "\(pid):\(CFHash(element))")
        elements[id] = element
        let minimized: Bool = value(kAXMinimizedAttribute, from: element) ?? false
        let fullScreen: Bool = value("AXFullScreen", from: element) ?? false
        let movable = isSettable(kAXPositionAttribute, on: element)
        let resizable = isSettable(kAXSizeAttribute, on: element)
        let title: String = value(kAXTitleAttribute, from: element) ?? ""
        let constraints = minimumSizeLearner.merging(
            WindowConstraints(isMovable: movable, isResizable: resizable),
            for: id
        )
        return WindowSnapshot(
            id: id,
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            title: title,
            frame: frame,
            displayID: display.id,
            constraints: constraints,
            isMinimized: minimized,
            isFullScreen: fullScreen,
            isHidden: false
        )
    }

    private func display(containing point: BTPoint) -> DisplaySnapshot? {
        let available = displays()
        return available.first(where: { $0.frame.contains(point) })
            ?? available.max(by: { ($0.frame.intersection(BTRect(x: point.x, y: point.y, width: 1, height: 1))?.area ?? 0) < ($1.frame.intersection(BTRect(x: point.x, y: point.y, width: 1, height: 1))?.area ?? 0) })
    }

    private func refreshElement(for windowID: WindowID) -> AXUIElement? {
        _ = try? visibleWindows()
        return elements[windowID]
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

    private func isOnscreen(_ snapshot: WindowSnapshot, candidates: [BTRect]) -> Bool {
        candidates.contains { OnscreenWindowMatcher.matches(accessibilityFrame: snapshot.frame, windowServerFrame: $0) }
    }

    private func onscreenWindowFrames() -> [pid_t: [BTRect]] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return [:] }
        var result: [pid_t: [BTRect]] = [:]
        for item in info {
            guard let layer = item[kCGWindowLayer] as? Int, layer == 0,
                  let owner = item[kCGWindowOwnerPID] as? Int,
                  let bounds = item[kCGWindowBounds] as? [String: Any],
                  let x = number(bounds["X"]), let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]), let height = number(bounds["Height"])
            else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            // CGWindow bounds use the same global top-left convention as Accessibility.
            result[pid_t(owner), default: []].append(BTRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        }
        return result
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
    let windowID = kind == .focused ? nil : WindowID(rawValue: "\(pid):\(CFHash(element))")
    let event = WindowSystemEvent(kind: kind, windowID: windowID, processIdentifier: pid)
    let address = UInt(bitPattern: refcon)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let system = Unmanaged<AccessibilityWindowSystem>.fromOpaque(pointer).takeUnretainedValue()
        system.receiveWindowEvent(event)
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
