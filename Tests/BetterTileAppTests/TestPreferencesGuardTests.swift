import Foundation
import Testing

/// Named preference suites leave plists behind even after their persistent domain is removed.
/// Scan every test target, including this guard. Tests must use memory-only preferences.
@Test(.appTestApplication) func testsCreateNoNamedPreferenceSuites() throws {
    let tests = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var files: [URL] = []
    for target in ["BetterTileAppTests", "BetterTileMacOSTests", "BetterTileCoreTests"] {
        let folder = tests.appending(path: target)
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        let sources = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!sources.isEmpty, "No Swift sources found in \(target)")
        files += sources
    }
    // Covers UserDefaults(...), UserDefaults.init(...), UserDefaults?(...), and a bare .init(...) with a known type.
    let pattern = try Regex(#"(UserDefaults\s*\??\s*(\.\s*init\s*)?|\.\s*init\s*)\(\s*suiteName\s*:"#)
    let offenders = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(pattern) }
        .map { $0.path.replacingOccurrences(of: tests.path + "/", with: "") }.sorted()
    #expect(offenders.isEmpty, Comment(rawValue: "Named preference suites in: \(offenders.joined(separator: ", "))"))
    let typeName = "UserDefaults", initializer = "init" // Interpolated so this file does not match the guard.
    #expect("\(typeName).\(initializer)(suiteName: name)".contains(pattern))
    #expect("\(typeName)( suiteName: name)".contains(pattern))
    #expect("let defaults: \(typeName)? = .\(initializer)(suiteName: name)".contains(pattern))
    #expect("\(typeName)?(suiteName: name)".contains(pattern))
    #expect("\(typeName)?.\(initializer)(suiteName: name)".contains(pattern))
    #expect(!"MemoryDefaults()".contains(pattern))
}
