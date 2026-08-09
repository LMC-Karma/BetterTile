import Testing
@testable import BetterTileCore

@Test func windowEventBufferDefersFrameAndTopologyEventsUntilDrain() {
    let source = WindowID(rawValue: "source")
    var buffer = WindowEventBuffer()
    buffer.record(WindowSystemEvent(kind: .moved, windowID: source, processIdentifier: 1))
    buffer.record(WindowSystemEvent(kind: .resized, windowID: source, processIdentifier: 1))
    buffer.record(WindowSystemEvent(kind: .created, windowID: nil, processIdentifier: 2))
    buffer.record(WindowSystemEvent(kind: .focused, windowID: source, processIdentifier: 1))

    #expect(buffer.frameEventWindowIDs == [source])
    #expect(buffer.topologyChanged)
    let drained = buffer.drain()
    #expect(drained.frameEventWindowIDs == [source])
    #expect(drained.topologyChanged)
    #expect(buffer.frameEventWindowIDs.isEmpty)
    #expect(!buffer.topologyChanged)
}

@Test func windowEventBufferRetainsPendingAndLaterEventsUntilAcknowledged() {
    let first = WindowID(rawValue: "first")
    let later = WindowID(rawValue: "later")
    var buffer = WindowEventBuffer()
    buffer.record(WindowSystemEvent(kind: .moved, windowID: first, processIdentifier: 1))

    let pending = buffer
    #expect(buffer.frameEventWindowIDs == [first])
    buffer.record(WindowSystemEvent(kind: .resized, windowID: later, processIdentifier: 2))
    buffer.acknowledge(pending)

    #expect(buffer.frameEventWindowIDs == [later])
    #expect(buffer.resizedWindowIDs == [later])
}

@Test func windowEventRetryBackoffIsCappedAndResetsAfterSuccess() {
    var backoff = WindowEventRetryBackoff()

    #expect(backoff.nextDelayAfterFailure() == .milliseconds(240))
    #expect(backoff.nextDelayAfterFailure() == .milliseconds(480))
    #expect(backoff.nextDelayAfterFailure() == .milliseconds(960))
    #expect(backoff.nextDelayAfterFailure() == .milliseconds(1_920))
    #expect(backoff.nextDelayAfterFailure() == .milliseconds(1_920))
    backoff.reset()
    #expect(backoff.delay == WindowEventRetryBackoff.initialDelay)
}
