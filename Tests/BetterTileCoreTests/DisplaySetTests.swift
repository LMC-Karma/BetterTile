import Foundation
import Testing
@testable import BetterTileCore

@Suite struct DisplaySetTests {
    private func display(_ uuid: String, model: UInt32 = 41010, serial: UInt32 = 0, x: Double = 0,
                         builtIn: Bool = false, name: String = "Studio Display") -> DisplayFingerprint {
        .init(uuid: uuid, vendor: 1552, model: model, serial: serial, builtIn: builtIn, name: name,
              frame: BTRect(x: x, y: 0, width: 2560, height: 1440))
    }

    @Test func theSameSetMatchesExactly() {
        let set = [display("A", serial: 11), display("B", model: 41022, x: -1512, builtIn: true)]
        let match = DisplaySetMatcher.match(stored: set, live: set)
        #expect(match.kind == .exact)
        #expect(match.pairs == [0: 0, 1: 1])
    }

    @Test func orderDoesNotMatter() {
        let a = display("A", serial: 11), b = display("B", model: 41022, serial: 22)
        let match = DisplaySetMatcher.match(stored: [a, b], live: [b, a])
        #expect(match.kind == .exact)
        #expect(match.pairs == [0: 1, 1: 0])
    }

    @Test func aResolutionOrArrangementChangeStillMatches() {
        let stored = display("A", serial: 11)
        var live = stored
        live.frame = BTRect(x: 400, y: 90, width: 1920, height: 1080)
        #expect(DisplaySetMatcher.match(stored: [stored], live: [live]).kind == .exact)
    }

    @Test func aMissingOrExtraDisplayIsNoMatch() {
        let a = display("A", serial: 11), b = display("B", model: 41022, serial: 22)
        #expect(DisplaySetMatcher.match(stored: [a, b], live: [a]).kind == .none)
        #expect(DisplaySetMatcher.match(stored: [a], live: [a, b]).kind == .none)
        #expect(DisplaySetMatcher.match(stored: [], live: []).kind == .none)
    }

    @Test func theSameModelWithAnotherSerialIsNoMatch() {
        #expect(DisplaySetMatcher.match(stored: [display("A", serial: 11)], live: [display("Z", serial: 12)]).kind == .none)
        // A serial on one side only is not enough to say it is the same display.
        #expect(DisplaySetMatcher.match(stored: [display("A", serial: 11)], live: [display("Z", serial: 0)]).kind == .none)
    }

    @Test func aNewUUIDWithTheSameNonzeroSerialStillMatches() {
        let match = DisplaySetMatcher.match(stored: [display("A", serial: 11)], live: [display("Z", serial: 11)])
        #expect(match.kind == .exact)
    }

    @Test func uuidsCompareWithoutCase() {
        #expect(DisplaySetMatcher.match(stored: [display("ab-12")], live: [display("AB-12")]).kind == .exact)
    }

    @Test func aDifferentModelWithoutASerialIsNoMatch() {
        #expect(DisplaySetMatcher.match(stored: [display("A")], live: [display("Z", model: 99)]).kind == .none)
    }

    @Test func twoIdenticalDisplaysWithoutSerialsAreToldApartByPositionAndAreUncertain() {
        let stored = [display("L", x: 0), display("R", x: 2560)]
        let live = [display("right-b", x: 2560), display("left-b", x: 0)]
        let match = DisplaySetMatcher.match(stored: stored, live: live)
        #expect(match.kind == .uncertain)
        #expect(match.pairs == [0: 1, 1: 0])
    }

    @Test func oneKnownUUIDKeepsTheOtherDisplayUncertainOnlyWhenItHasNoSerial() {
        let stored = [display("L", x: 0), display("R", x: 2560)]
        let match = DisplaySetMatcher.match(stored: stored, live: [display("L", x: 0), display("right-b", x: 2560)])
        #expect(match.kind == .uncertain)
        #expect(match.pairs == [0: 0, 1: 1])
        let withSerial = [display("L", x: 0), display("R", serial: 5, x: 2560)]
        #expect(DisplaySetMatcher.match(stored: withSerial, live: [display("L", x: 0), display("right-b", serial: 6, x: 2560)]).kind == .none)
    }

    @Test func identicalDisplaysThatShareOneSerialAreUncertainNotExactAndSwapped() {
        let shared: UInt32 = 0x0101_0101
        let stored = [display("L", serial: shared, x: 0), display("R", serial: shared, x: 2560)]
        let live = [display("right-b", serial: shared, x: 2560), display("left-b", serial: shared, x: 0)]
        let match = DisplaySetMatcher.match(stored: stored, live: live)
        #expect(match.kind == .uncertain)
        #expect(match.pairs == [0: 1, 1: 0])
        // A different serial on one side still gives no match.
        #expect(DisplaySetMatcher.match(stored: stored, live: [live[0], display("left-b", serial: 5, x: 0)]).kind == .none)
        // A unique serial stays exact when another display in the set has a different one.
        let mixed = [display("A", serial: 11), display("B", serial: shared, x: 2560)]
        #expect(DisplaySetMatcher.match(stored: mixed, live: [display("A-live", serial: 11), display("B-live", serial: shared, x: 2560)]).kind == .exact)
    }

}
