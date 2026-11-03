import BetterTileCore
import Testing
@testable import BetterTileMacOS

@Suite(.macOSTestApplication) struct DisplayFingerprintReaderTests {
    private func raw(_ id: UInt32, uuid: String = "U", mirrors: Bool = false) -> DisplayFingerprintReader.Raw {
        .init(id: id, uuid: uuid.isEmpty ? "" : uuid + String(id), vendor: 1552, model: 41010, serial: 7, builtIn: false, name: "Display \(id)",
              bounds: BTRect(x: Double(id) * 100, y: 0, width: 100, height: 50), mirrorsDisplay: mirrors)
    }

    @Test func aMirroringDisplayCountsOnce() {
        let live = DisplayFingerprintReader.liveDisplays(from: [raw(1), raw(2, mirrors: true), raw(3)])
        #expect(live.map(\.id.rawValue) == ["1", "3"])
    }

    @Test func aDisplayWithoutAUUIDIsLeftOut() {
        #expect(DisplayFingerprintReader.liveDisplays(from: [raw(1, uuid: "")]).isEmpty)
    }

    @Test func theFingerprintKeepsIdentityAndFrame() throws {
        let live = try #require(DisplayFingerprintReader.liveDisplays(from: [raw(4)]).first)
        #expect(live.fingerprint.uuid == "U4")
        #expect(live.fingerprint.serial == 7)
        #expect(live.fingerprint.frame == BTRect(x: 400, y: 0, width: 100, height: 50))
    }

    @MainActor @Test func theLiveReadingNeverCrashesAndHasUniqueIDs() {
        let live = DisplayFingerprintReader.current()
        #expect(Set(live.map(\.id)).count == live.count)
        #expect(live.allSatisfy { !$0.fingerprint.uuid.isEmpty })
    }
}
