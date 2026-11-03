import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

/// The local pointer monitor shares the key monitor's event reader. A mouse
/// event has no key code, and asking for one throws inside AppKit, so the
/// wheel never saw pointer moves while BetterTile was the active app.
@Suite(.macOSTestApplication)
struct LayoutWheelLocalMonitorTests {
    @Test(arguments: [NSEvent.EventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged])
    func pointerEventsReadWithoutAKeyCode(type: NSEvent.EventType) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [.control, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))

        let input = LayoutWheelController.localMonitorInput(for: event)

        #expect(input.keyCode == 0)
        #expect(input.modifiers == ShortcutModifiers([.control, .option]))
    }

    @Test func keyEventsKeepTheirKeyCode() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))

        #expect(LayoutWheelController.localMonitorInput(for: event).keyCode == 53)
    }
}
