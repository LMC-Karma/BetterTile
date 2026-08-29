import AppKit
import BetterTileCore
import CoreGraphics
import Foundation
import os

public enum GlobalGestureEventKind: Equatable, Sendable {
    case leftMouseDown
    case leftMouseDragged
    case leftMouseUp
}

public struct GlobalGestureEvent: Equatable, Sendable {
    public var kind: GlobalGestureEventKind
    public var position: BTPoint
    public var button: Int64
    public var modifiers: ShortcutModifiers
    /// Nanoseconds since system startup. Zero means the source reported no
    /// usable time.
    public var timestamp: UInt64

    public init(
        kind: GlobalGestureEventKind,
        position: BTPoint,
        button: Int64,
        modifiers: ShortcutModifiers,
        timestamp: UInt64
    ) {
        self.kind = kind
        self.position = position
        self.button = button
        self.modifiers = modifiers
        self.timestamp = timestamp
    }

    static func position(cgEventLocation: CGPoint) -> BTPoint {
        BTPoint(x: cgEventLocation.x, y: cgEventLocation.y)
    }

    static func position(
        nsEventMouseLocation: CGPoint,
        primaryScreenFrame: CGRect
    ) -> BTPoint {
        CoordinateConverter.pointToTopLeft(
            nsEventMouseLocation,
            mainScreenFrame: primaryScreenFrame
        )
    }

    @MainActor
    init?(_ event: NSEvent, kind: GlobalGestureEventKind) {
        guard let mainFrame = NSScreen.screens.first?.frame else { return nil }
        self.init(
            kind: kind,
            position: Self.position(
                nsEventMouseLocation: NSEvent.mouseLocation,
                primaryScreenFrame: mainFrame
            ),
            button: Int64(event.buttonNumber),
            modifiers: ShortcutModifiers(event.modifierFlags),
            timestamp: event.timestamp > 0
                ? UInt64(event.timestamp * 1_000_000_000)
                : 0
        )
    }
}

enum GestureEventSource: Equatable {
    case eventTap
    case nsEvent

    var signpostName: String {
        switch self {
        case .eventTap: "eventTap"
        case .nsEvent: "nsEvent"
        }
    }
}

/// One nanosecond time base for both gesture sources and delivery time.
enum GestureEventClock {
    /// `CGEventTimestamp` is already nanoseconds since system startup.
    static func nanoseconds(cgEventTimestamp timestamp: CGEventTimestamp) -> UInt64 {
        timestamp
    }

    static var uptimeNanoseconds: UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}

/// Measures how long a gesture event takes to reach the consumer that acts on
/// it. The shared event tap and the `NSEvent` monitors emit the same signpost,
/// so one trace answers whether the tap regresses the p95 delivery limit.
enum GestureEventLatency {
    private static let log = OSLog(
        subsystem: "com.lmckarma.BetterTile",
        category: "GestureEvents"
    )
    static let signposter = OSSignposter(logHandle: log)

    /// Returns nil when the source reported no time, or when the event appears
    /// to arrive before it happened. A negative interval means the two values
    /// came from different clocks and must not enter the measurement.
    static func nanoseconds(eventTimestamp: UInt64, deliveredAt: UInt64) -> UInt64? {
        guard eventTimestamp > 0, deliveredAt >= eventTimestamp else { return nil }
        return deliveredAt - eventTimestamp
    }

    static func record(
        _ event: GlobalGestureEvent,
        from source: GestureEventSource,
        consumer: StaticString
    ) {
        record(
            timestamp: event.timestamp,
            source: source,
            consumer: consumer,
            kind: event.kind.signpostName
        )
    }

    static func record(
        timestamp: UInt64,
        source: GestureEventSource,
        consumer: StaticString,
        kind: String
    ) {
        guard log.signpostsEnabled,
              let latency = nanoseconds(
                  eventTimestamp: timestamp,
                  deliveredAt: GestureEventClock.uptimeNanoseconds
              )
        else { return }
        signposter.emitEvent(
            "gestureDelivery",
            "consumer=\(consumer, privacy: .public) source=\(source.signpostName, privacy: .public) kind=\(kind, privacy: .public) latencyNanoseconds=\(latency, privacy: .public)"
        )
    }
}

extension GlobalGestureEventKind {
    var signpostName: String {
        switch self {
        case .leftMouseDown: "down"
        case .leftMouseDragged: "drag"
        case .leftMouseUp: "up"
        }
    }
}

struct GestureEventSourceGate {
    private(set) var usesEventTap = false

    mutating func setUsesEventTap(_ enabled: Bool) {
        usesEventTap = enabled
    }

    func accepts(_ source: GestureEventSource) -> Bool {
        source == (usesEventTap ? .eventTap : .nsEvent)
    }
}

/// Holds a requested switch to the shared event tap until the active gesture
/// ends. A gesture that started on the NSEvent monitors must keep receiving its
/// remaining drag and up events from that same source.
struct GestureEventSourceHandoff {
    private(set) var isPending = false

    /// Returns true when the caller can change the gesture source now.
    mutating func request(
        usesEventTap: Bool,
        currentlyUsesEventTap: Bool,
        isGestureActive: Bool
    ) -> Bool {
        isPending = usesEventTap && !currentlyUsesEventTap && isGestureActive
        return !isPending
    }

    /// Returns true once a deferred switch to the event tap can be applied.
    mutating func resolve() -> Bool {
        defer { isPending = false }
        return isPending
    }

    mutating func clear() {
        isPending = false
    }
}

struct GestureEventGenerationGate {
    private var nextGeneration = 0
    private var activeGeneration: Int?

    mutating func begin() -> Int {
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    mutating func end() {
        activeGeneration = nil
    }

    func accepts(_ generation: Int) -> Bool {
        activeGeneration == generation
    }
}

enum GestureEventTapRecovery {
    enum Action: Equatable {
        case resume
        case fallBack
    }

    static func action(isEnabledAfterRecovery: Bool) -> Action {
        isEnabledAfterRecovery ? .resume : .fallBack
    }
}

/// Suppresses repeated event-tap creation after a failure. Each attempt starts
/// a worker thread and blocks the caller until the tap is created, so a
/// persistent failure must not retry on every application activation.
struct GestureEventTapRetryGate {
    static let defaultCooldown: TimeInterval = 30

    private let cooldown: TimeInterval
    private var retryTime: TimeInterval?

    init(cooldown: TimeInterval = GestureEventTapRetryGate.defaultCooldown) {
        self.cooldown = cooldown
    }

    func allowsStart(at time: TimeInterval) -> Bool {
        guard let retryTime else { return true }
        return time >= retryTime
    }

    mutating func recordFailure(at time: TimeInterval) {
        retryTime = time + cooldown
    }

    mutating func recordSuccess() {
        retryTime = nil
    }
}

enum GestureEventTapMessage: Sendable {
    case event(GlobalGestureEvent)
    case fallback
}

protocol GestureEventTapWorking: AnyObject {
    func start() -> Bool
    func stop()
}

/// Owns one listen-only session event tap. The callback copies only scalar
/// gesture data before forwarding it to the main actor.
@MainActor
public final class SharedGestureEventMonitor {
    public var eventHandler: ((GlobalGestureEvent) -> Void)?
    public var fallbackHandler: (() -> Void)?
    public private(set) var isUsingEventTap = false

    private static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "GestureEvents"
    )
    private let now: () -> TimeInterval
    private let makeWorker: (
        @escaping @Sendable (GestureEventTapMessage) -> Void
    ) -> GestureEventTapWorking
    private var worker: GestureEventTapWorking?
    private var generationGate = GestureEventGenerationGate()
    private var retryGate: GestureEventTapRetryGate
    private var loggedAvailability = false
    private var loggedFallback = false
    private let disabled: Bool

    public convenience init() {
        self.init(cooldown: GestureEventTapRetryGate.defaultCooldown)
    }

    init(
        disabled: Bool = UserDefaults.standard.bool(forKey: "disableSharedGestureEvents"),
        cooldown: TimeInterval = GestureEventTapRetryGate.defaultCooldown,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeWorker: @escaping (
            @escaping @Sendable (GestureEventTapMessage) -> Void
        ) -> GestureEventTapWorking = { GestureEventTapWorker(handler: $0) }
    ) {
        self.disabled = disabled
        retryGate = GestureEventTapRetryGate(cooldown: cooldown)
        self.now = now
        self.makeWorker = makeWorker
        if disabled {
            Self.log.notice("shared gesture event tap disabled by user default")
        }
    }

    @discardableResult
    public func start() -> Bool {
        // The NSEvent monitors are the measurement baseline for the gesture
        // latency gate, so they must be selectable without breaking the tap.
        if disabled { return false }
        if isUsingEventTap { return true }
        let time = now()
        guard retryGate.allowsStart(at: time) else { return false }
        let generation = generationGate.begin()
        let worker = makeWorker { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                self?.receive(message, generation: generation)
            }
        }
        guard worker.start() else {
            generationGate.end()
            retryGate.recordFailure(at: time)
            logFallbackOnce("shared gesture event tap unavailable; using NSEvent monitors")
            return false
        }
        self.worker = worker
        isUsingEventTap = true
        retryGate.recordSuccess()
        if !loggedAvailability {
            loggedAvailability = true
            Self.log.notice("shared gesture event tap available")
        }
        return true
    }

    /// Stops the tap on request. An intentional stop is not a failure, so it
    /// leaves the retry cooldown untouched.
    public func stop() {
        generationGate.end()
        worker?.stop()
        worker = nil
        isUsingEventTap = false
    }

    private func receive(_ message: GestureEventTapMessage, generation: Int) {
        guard generationGate.accepts(generation) else { return }
        switch message {
        case let .event(event):
            guard isUsingEventTap else { return }
            eventHandler?(event)
        case .fallback:
            guard isUsingEventTap else { return }
            stop()
            retryGate.recordFailure(at: now())
            logFallbackOnce("shared gesture event tap recovery failed; using NSEvent monitors")
            fallbackHandler?()
        }
    }

    private func logFallbackOnce(_ message: String) {
        guard !loggedFallback else { return }
        loggedFallback = true
        Self.log.notice("\(message, privacy: .public)")
    }
}

final class GestureEventTapWorker: GestureEventTapWorking, @unchecked Sendable {
    private static let eventMask = [
        CGEventType.leftMouseDown,
        .leftMouseDragged,
        .leftMouseUp,
    ].reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << $1.rawValue)
    }

    private let handler: @Sendable (GestureEventTapMessage) -> Void
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var isStopping = false

    init(handler: @escaping @Sendable (GestureEventTapMessage) -> Void) {
        self.handler = handler
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in run(ready: ready) }
        thread.name = "BetterTile gesture events"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return lock.withLock { tap != nil }
    }

    func stop() {
        let runLoop = lock.withLock {
            isStopping = true
            return self.runLoop
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    private func fallBack() {
        handler(.fallback)
        stop()
    }

    private func recoverTap() -> Bool {
        guard let tap = lock.withLock({ self.tap }) else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func run(ready: DispatchSemaphore) {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        lock.withLock {
            self.tap = tap
            self.runLoop = runLoop
        }
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            lock.withLock {
                self.tap = nil
                self.runLoop = nil
            }
            ready.signal()
            return
        }
        ready.signal()
        CFRunLoopRun()
        CFMachPortInvalidate(tap)
        let stoppedUnexpectedly = lock.withLock {
            let stoppedUnexpectedly = !isStopping
            self.tap = nil
            self.runLoop = nil
            return stoppedUnexpectedly
        }
        if stoppedUnexpectedly { handler(.fallback) }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let worker = Unmanaged<GestureEventTapWorker>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if GestureEventTapRecovery.action(
                isEnabledAfterRecovery: worker.recoverTap()
            ) == .fallBack {
                worker.fallBack()
            }
            return Unmanaged.passUnretained(event)
        }
        guard let kind = GlobalGestureEventKind(type) else {
            return Unmanaged.passUnretained(event)
        }
        worker.handler(.event(GlobalGestureEvent(
            kind: kind,
            // CGEvent's global display coordinates already use the same
            // upper-left origin as BetterTile's logical coordinates.
            position: GlobalGestureEvent.position(cgEventLocation: event.location),
            button: event.getIntegerValueField(.mouseEventButtonNumber),
            modifiers: ShortcutModifiers(event.flags),
            timestamp: GestureEventClock.nanoseconds(cgEventTimestamp: event.timestamp)
        )))
        return Unmanaged.passUnretained(event)
    }
}

private extension GlobalGestureEventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseDragged: self = .leftMouseDragged
        case .leftMouseUp: self = .leftMouseUp
        default: return nil
        }
    }
}

extension ShortcutModifiers {
    init(_ flags: CGEventFlags) {
        var value: ShortcutModifiers = []
        if flags.contains(.maskCommand) { value.insert(.command) }
        if flags.contains(.maskAlternate) { value.insert(.option) }
        if flags.contains(.maskControl) { value.insert(.control) }
        if flags.contains(.maskShift) { value.insert(.shift) }
        self = value
    }
}

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.shift) { value.insert(.shift) }
        self = value
    }
}
