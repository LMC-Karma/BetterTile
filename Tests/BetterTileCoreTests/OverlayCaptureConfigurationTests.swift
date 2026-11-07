import Foundation
import Testing
@testable import BetterTileCore

struct OverlayCaptureConfigurationTests {
    private func captureValue(_ configuration: BetterTileConfiguration) throws -> Bool? {
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        return object["showsOverlaysInScreenRecordings"] as? Bool
    }

    @Test func overlaysAreExcludedByDefault() throws {
        #expect(try captureValue(BetterTileConfiguration()) == false)
    }

    @Test func missingCapturePreferenceDecodesAsFalse() throws {
        #expect(try captureValue(ConfigurationStore.decode(Data(#"{"schemaVersion":12}"#.utf8))) == false)
    }

    @Test(arguments: [false, true]) func capturePreferenceRoundTrips(enabled: Bool) throws {
        let input = Data("{\"schemaVersion\":12,\"showsOverlaysInScreenRecordings\":\(enabled)}".utf8)
        let restored = try ConfigurationStore.decode(input)
        #expect(try captureValue(restored) == enabled)
        #expect(try ConfigurationStore.decode(JSONEncoder().encode(restored)) == restored)
    }
}

@Test func overlayCaptureChangeSetIsOnlyOverlayCapture() {
    let original = BetterTileConfiguration()
    var changed = original
    changed.showsOverlaysInScreenRecordings = true
    #expect(ConfigurationChangeSet.between(original, changed) == [.overlayCapture])
    #expect(ConfigurationChangeSet.all.contains(.overlayCapture))
}
