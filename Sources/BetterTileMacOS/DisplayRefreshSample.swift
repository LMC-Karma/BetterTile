import AppKit

/// Shares the latest pointer sample between native event delivery and a display pass.
@MainActor final class DisplayRefreshSample<Value> {
    private let ticks: ResizeDisplayLink
    private let screen: () -> NSScreen?
    private let consume: (Value) -> Void
    private var latest: Value?
    var isPending: Bool { latest != nil }

    init(ticks: ResizeDisplayLink = ResizeDisplayLink(),
         screen: @escaping () -> NSScreen? = {
             NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
         }, consume: @escaping (Value) -> Void) {
        self.ticks = ticks
        self.screen = screen
        self.consume = consume
    }

    func submit(_ value: Value) {
        let wasPending = isPending
        latest = value
        guard !wasPending else { return }
        if !ticks.requestFrame(screen: screen(), tick: { [weak self] in self?.flush() }) {
            flush()
        }
    }

    func flush() {
        guard let value = latest else { return }
        cancel()
        consume(value)
    }

    func cancel() { latest = nil; ticks.pause() }
    isolated deinit { ticks.stop() }
}
