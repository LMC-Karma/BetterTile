import Testing
@testable import BetterTileCore

struct WindowEventLifetimeTests {
    @Test func aLongHoldKeepsLiveFrameEventsButReleasesClosedWindowKeys() {
        var buffer = WindowEventBuffer()
        let live = WindowID(rawValue: "live")
        buffer.record(.init(kind: .resized, windowID: live, processIdentifier: 42))
        for index in 0..<10_000 {
            let id = WindowID(rawValue: "closed-\(index)")
            buffer.record(.init(kind: .moved, windowID: id, processIdentifier: 43))
            buffer.record(.init(kind: .resized, windowID: id, processIdentifier: 43))
            buffer.record(.init(kind: .destroyed, windowID: id, processIdentifier: 43))
        }
        #expect(buffer.frameEventWindowIDs == [live])
        #expect(buffer.resizedWindowIDs == [live])
        #expect(buffer.topologyChanged)
        let events = buffer.drain()
        #expect(events.frameEventWindowIDs == [live])
        #expect(events.topologyChanged)
        #expect(buffer.isEmpty)
    }
}
