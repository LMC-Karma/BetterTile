import BetterTileCore
import CoreGraphics
import Foundation
import os

enum LayoutWheelMiddleClickEventKind: Equatable, Sendable {
    case down
    case dragged
    case up
}

struct LayoutWheelMiddleClickEvent: Equatable, Sendable {
    var kind: LayoutWheelMiddleClickEventKind
    var position: BTPoint
    var button: Int64
    var modifiers: ShortcutModifiers
    var timestamp: UInt64

    init(
        kind: LayoutWheelMiddleClickEventKind,
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

    static func reserves(button: Int64, modifiers: ShortcutModifiers) -> Bool {
        button == 2 && modifiers.isEmpty
    }
}

/// Ownership is decided by the down event and lasts through its matching up.
/// This prevents a modifier change during a reserved click from leaking only
/// the drag or release to the source application.
struct LayoutWheelMiddleClickReservation {
    private(set) var ownsGesture = false

    mutating func shouldReserve(
        kind: LayoutWheelMiddleClickEventKind,
        button: Int64,
        modifiers: ShortcutModifiers
    ) -> Bool {
        guard button == 2 else { return false }
        switch kind {
        case .down:
            ownsGesture = LayoutWheelMiddleClickEvent.reserves(
                button: button,
                modifiers: modifiers
            )
            return ownsGesture
        case .dragged:
            return ownsGesture
        case .up:
            let reserved = ownsGesture
            ownsGesture = false
            return reserved
        }
    }
}

enum LayoutWheelMiddleClickTapMessage: Sendable {
    case event(LayoutWheelMiddleClickEvent)
    case failed
}

@MainActor
protocol LayoutWheelMiddleClickMonitoring: AnyObject {
    var eventHandler: ((LayoutWheelMiddleClickEvent) -> Void)? { get set }
    var failureHandler: ((String?) -> Void)? { get set }
    var isRunning: Bool { get }
    @discardableResult func start() -> Bool
    func stop()
}

protocol LayoutWheelMiddleClickTapWorking: AnyObject {
    func start() -> Bool
    func stop()
}

/// Owns the optional suppressing event tap. It exists only while middle-click
/// activation is enabled and forwards only scalar button-2 gesture data.
@MainActor
final class LayoutWheelMiddleClickMonitor: LayoutWheelMiddleClickMonitoring {
    var eventHandler: ((LayoutWheelMiddleClickEvent) -> Void)?
    var failureHandler: ((String?) -> Void)?
    private(set) var isRunning = false

    private static let log = Logger(
        subsystem: "com.lmckarma.BetterTile",
        category: "LayoutWheel"
    )
    private let disabled: Bool
    private let now: () -> TimeInterval
    private let makeWorker: (
        @escaping @Sendable (LayoutWheelMiddleClickTapMessage) -> Void
    ) -> LayoutWheelMiddleClickTapWorking
    private var worker: LayoutWheelMiddleClickTapWorking?
    private var generationGate = GestureEventGenerationGate()
    private var retryGate: GestureEventTapRetryGate

    convenience init() {
        self.init(cooldown: GestureEventTapRetryGate.defaultCooldown)
    }

    init(
        disabled: Bool = UserDefaults.standard.bool(forKey: "disableLayoutWheelMiddleClick"),
        cooldown: TimeInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeWorker: @escaping (
            @escaping @Sendable (LayoutWheelMiddleClickTapMessage) -> Void
        ) -> LayoutWheelMiddleClickTapWorking = { LayoutWheelMiddleClickTapWorker(handler: $0) }
    ) {
        self.disabled = disabled
        self.now = now
        self.makeWorker = makeWorker
        retryGate = GestureEventTapRetryGate(cooldown: cooldown)
    }

    @discardableResult
    func start() -> Bool {
        if disabled {
            failureHandler?("Middle-click activation is disabled by the recovery setting.")
            return false
        }
        if isRunning { return true }
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
            failureHandler?("BetterTile could not reserve middle-click. Keyboard activation remains available.")
            return false
        }
        self.worker = worker
        isRunning = true
        retryGate.recordSuccess()
        failureHandler?(nil)
        Self.log.notice("Layout Wheel middle-click reservation active")
        return true
    }

    func stop() {
        generationGate.end()
        worker?.stop()
        worker = nil
        isRunning = false
    }

    private func receive(_ message: LayoutWheelMiddleClickTapMessage, generation: Int) {
        guard generationGate.accepts(generation) else { return }
        switch message {
        case let .event(event):
            guard isRunning else { return }
            GestureEventLatency.record(
                timestamp: event.timestamp,
                source: .eventTap,
                consumer: "layoutWheel",
                kind: event.kind.signpostName
            )
            eventHandler?(event)
        case .failed:
            guard isRunning else { return }
            stop()
            retryGate.recordFailure(at: now())
            failureHandler?(
                "BetterTile lost the middle-click reservation. Keyboard activation remains available."
            )
        }
    }
}

final class LayoutWheelMiddleClickTapWorker: LayoutWheelMiddleClickTapWorking, @unchecked Sendable {
    private static let eventMask = [
        CGEventType.otherMouseDown,
        .otherMouseDragged,
        .otherMouseUp,
    ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    private let handler: @Sendable (LayoutWheelMiddleClickTapMessage) -> Void
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var isStopping = false
    private var reservation = LayoutWheelMiddleClickReservation()

    init(handler: @escaping @Sendable (LayoutWheelMiddleClickTapMessage) -> Void) {
        self.handler = handler
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in run(ready: ready) }
        thread.name = "BetterTile Layout Wheel middle click"
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

    private func recoverTap() -> Bool {
        guard let tap = lock.withLock({ self.tap }) else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func fail() {
        handler(.failed)
        stop()
    }

    private func run(ready: DispatchSemaphore) {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
        if stoppedUnexpectedly { handler(.failed) }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let worker = Unmanaged<LayoutWheelMiddleClickTapWorker>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !worker.recoverTap() { worker.fail() }
            return Unmanaged.passUnretained(event)
        }
        guard let kind = LayoutWheelMiddleClickEventKind(type) else {
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let modifiers = ShortcutModifiers(event.flags)
        guard worker.reservation.shouldReserve(
            kind: kind,
            button: button,
            modifiers: modifiers
        ) else {
            return Unmanaged.passUnretained(event)
        }
        worker.handler(.event(LayoutWheelMiddleClickEvent(
            kind: kind,
            position: GlobalGestureEvent.position(cgEventLocation: event.location),
            button: button,
            modifiers: modifiers,
            timestamp: GestureEventClock.nanoseconds(cgEventTimestamp: event.timestamp)
        )))
        return nil
    }
}

private extension LayoutWheelMiddleClickEventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .otherMouseDown: self = .down
        case .otherMouseDragged: self = .dragged
        case .otherMouseUp: self = .up
        default: return nil
        }
    }

    var signpostName: String {
        switch self {
        case .down: "down"
        case .dragged: "drag"
        case .up: "up"
        }
    }
}
