import Foundation
import Testing
@testable import BetterTileApp

@Test func appIconChoiceRestoresAndFallsBackToClassic() throws {
    let suite = "BetterTileIconTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(AppIconStyle.selected(in: defaults) == .classic)
    defaults.set("ice", forKey: AppIconStyle.defaultsKey)
    let restoredDefaults = try #require(UserDefaults(suiteName: suite))
    #expect(AppIconStyle.selected(in: restoredDefaults) == .ice)
    defaults.set("unknown-future-icon", forKey: AppIconStyle.defaultsKey)
    #expect(AppIconStyle.selected(in: defaults) == .classic)
    defaults.set("classic", forKey: AppIconStyle.defaultsKey)
    #expect(AppIconStyle.selected(in: defaults) == .classic)
}

@Test func appIconVariantsPreserveSourceGeometryAndEffects() throws {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    let source = resources.appendingPathComponent("AppIcon.icon")
    func document(_ bundle: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("icon.json"))) as? [String: Any])
    }
    var expected = try document(source)
    expected.removeValue(forKey: "fill")
    for name in ["AppIconIce", "AppIconDebug", "AppIconIceDebug"] {
        let bundle = resources.appendingPathComponent("\(name).icon")
        var actual = try document(bundle)
        actual.removeValue(forKey: "fill")
        if name.hasSuffix("Debug") {
            var groups = try #require(actual["groups"] as? [[String: Any]])
            #expect(groups.last?["name"] as? String == "Debug")
            groups.removeLast()
            actual["groups"] = groups
        }
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected), "\(name) must preserve the source layers and effects")
        for file in ["00-TrafficLights.svg", "01-LeftPanes.svg", "02-RightPane.svg"] {
            let original = try String(contentsOf: source.appendingPathComponent("Assets/\(file)"), encoding: .utf8)
            let copy = try String(contentsOf: bundle.appendingPathComponent("Assets/\(file)"), encoding: .utf8)
            #expect(copy == original, "\(name)/\(file) must remain an exact copy")
        }
    }
}
