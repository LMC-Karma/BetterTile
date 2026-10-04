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

@Test func appIconVariantsPreserveSourceGeometry() throws {
    let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    let source = resources.appendingPathComponent("AppIcon.icon")
    func document(_ bundle: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("icon.json"))) as? [String: Any])
    }
    func geometry(_ document: [String: Any]) throws -> [String: Any] {
        var result = document
        result.removeValue(forKey: "fill")
        result["groups"] = try #require(result["groups"] as? [[String: Any]]).map { group in
            var group = group
            group.removeValue(forKey: "shadow")
            group.removeValue(forKey: "translucency")
            return group
        }
        return result
    }
    func outlines(_ url: URL) throws -> [[String: String]] {
        let svg = try XMLDocument(contentsOf: url)
        let marked = try svg.nodes(forXPath: "//*[local-name()='rect' and contains(@id, '-outline')]")
        let rectangles = try marked.isEmpty ? svg.nodes(forXPath: "//*[local-name()='rect']") : marked
        return try rectangles.map { node in
            let element = try #require(node as? XMLElement)
            return Dictionary(uniqueKeysWithValues: try ["x", "y", "width", "height", "rx"].map { name in
                (name, try #require(element.attribute(forName: name)?.stringValue))
            })
        }
    }
    let expected = try geometry(document(source))
    for name in ["AppIconIce", "AppIconDebug", "AppIconIceDebug"] {
        let bundle = resources.appendingPathComponent("\(name).icon")
        var actual = try document(bundle)
        if name.hasSuffix("Debug") {
            var groups = try #require(actual["groups"] as? [[String: Any]])
            let badgeIndex = try #require(groups.firstIndex { $0["name"] as? String == "Debug" })
            if name == "AppIconIceDebug" {
                #expect(badgeIndex == 0, "The Debug badge must be above the opaque Ice panes")
            }
            groups.remove(at: badgeIndex)
            actual["groups"] = groups
        }
        #expect(try NSDictionary(dictionary: geometry(actual)).isEqual(to: expected), "\(name) must preserve the source layers and positions")
        for file in ["00-TrafficLights.svg", "01-LeftPanes.svg", "02-RightPane.svg"] {
            let originalURL = source.appendingPathComponent("Assets/\(file)")
            let copyURL = bundle.appendingPathComponent("Assets/\(file)")
            if name.contains("Ice") && file != "00-TrafficLights.svg" {
                #expect(try outlines(copyURL) == outlines(originalURL), "\(name)/\(file) must preserve each pane outline")
                let originalRoot = try #require(XMLDocument(contentsOf: originalURL).rootElement())
                let copyRoot = try #require(XMLDocument(contentsOf: copyURL).rootElement())
                for attribute in ["width", "height", "viewBox"] {
                    #expect(copyRoot.attribute(forName: attribute)?.stringValue == originalRoot.attribute(forName: attribute)?.stringValue)
                }
            } else {
                #expect(try Data(contentsOf: copyURL) == Data(contentsOf: originalURL), "\(name)/\(file) must remain an exact copy")
            }
        }
        if name.hasSuffix("Debug") {
            let base = resources.appendingPathComponent("\(name.replacingOccurrences(of: "Debug", with: "")).icon")
            #expect(try NSDictionary(dictionary: actual).isEqual(to: document(base)), "\(name) must match its base appearance plus the Debug badge")
            for file in ["00-TrafficLights.svg", "01-LeftPanes.svg", "02-RightPane.svg"] {
                #expect(try Data(contentsOf: bundle.appendingPathComponent("Assets/\(file)")) == Data(contentsOf: base.appendingPathComponent("Assets/\(file)")))
            }
        }
    }
}
