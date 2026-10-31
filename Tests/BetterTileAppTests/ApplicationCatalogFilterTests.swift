import Foundation
import Testing
@testable import BetterTileApp

private struct ApplicationFilterFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    @discardableResult
    func application(_ path: String, identifier: String, metadata: [String: Any] = [:]) throws -> URL {
        let url = root.appending(path: path)
        let contents = url.appending(path: "Contents")
        let executable = contents.appending(path: "MacOS/TestExecutable")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var metadata = metadata
        metadata["CFBundleIdentifier"] = identifier
        metadata["CFBundleExecutable"] = "TestExecutable"
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.appTestApplication)
struct ApplicationCatalogFilterTests {
    @Test func appCatalogListsOnlyForegroundApplications() throws {
        let fixture = ApplicationFilterFixture()
        defer { fixture.remove() }
        let cases: [(String, [String: Any], Bool)] = [
            ("normal", [:], true),
            ("agent-bool", ["LSUIElement": true], false),
            ("agent-number", ["LSUIElement": NSNumber(value: 1)], false),
            ("agent-string", ["LSUIElement": "1"], false),
            ("agent-true", ["LSUIElement": "TrUe"], false),
            ("agent-yes", ["LSUIElement": "yEs"], false),
            ("background-bool", ["LSBackgroundOnly": true], false),
            ("background-number", ["LSBackgroundOnly": NSNumber(value: 1)], false),
            ("background-string", ["LSBackgroundOnly": "YES"], false),
            ("background-true", ["LSBackgroundOnly": "TRUE"], false),
            ("background-one", ["LSBackgroundOnly": "1"], false),
            ("foreground-bool", ["LSUIElement": false], true),
            ("foreground-zero", ["LSUIElement": "0"], true),
            ("foreground-number", ["LSBackgroundOnly": NSNumber(value: 0)], true),
            ("foreground-false", ["LSBackgroundOnly": "false"], true),
            // Package type does not decide: Passwords on macOS 26 is an XPC! bundle with windows.
            ("xpc", ["CFBundlePackageType": "XPC!"], true),
            ("application", ["CFBundlePackageType": "APPL"], true),
        ]
        for (name, metadata, _) in cases {
            try fixture.application("\(name).app", identifier: "test.\(name)", metadata: metadata)
        }
        let listed = ApplicationCatalog.enumerate(directories: [fixture.root])
        #expect(Set(listed.map(\.id)) == Set(cases.filter { $0.2 }.map { "test.\($0.0)" }))
    }

    @Test func appCatalogSkipsHelperPathsAndKeepsUtilities() throws {
        let fixture = ApplicationFilterFixture()
        defer { fixture.remove() }
        let host = try fixture.application("Host.app", identifier: "test.host")
        try fixture.application("Host.app/Contents/Library/LoginItems/Agent.app", identifier: "test.nested")
        let paths = ["Vendor/Library/Helper.app", "Vendor/Helpers/X.app", "Vendor/contents/X.app",
                     "Vendor/FRAMEWORKS/X.app", "Vendor/PlugIns/X.app", "Vendor/XPCServices/X.app",
                     "Vendor/LoginItems/X.app", "Vendor/Container.APP/X.app"]
        for (index, path) in paths.enumerated() {
            try fixture.application(path, identifier: "test.helper.\(index)")
        }
        let terminal = try fixture.application("Utilities/Terminal Fixture.app", identifier: "test.terminal")
        let listed = ApplicationCatalog.enumerate(directories: [fixture.root])
        #expect(listed.map(\.id) == ["test.host", "test.terminal"])
        #expect(listed.map { $0.url.resolvingSymlinksInPath() } == [host, terminal].map { $0.resolvingSymlinksInPath() })
        // A scan root named Library is not an intermediate helper folder.
        #expect(ApplicationCatalog.enumerate(directories: [fixture.root.appending(path: "Vendor/Library")]).map(\.id)
                == ["test.helper.0"])
    }

    @Test func appCatalogListsVendorFoldersWebAppsAndSystemInformation() throws {
        let fixture = ApplicationFilterFixture()
        defer { fixture.remove() }
        try fixture.application("Setapp/CleanShot X.app", identifier: "test.setapp")
        try fixture.application("Chrome Apps.localized/YouTube.app", identifier: "test.webapp")
        // System Information is an agent on macOS 26 but opens a normal window.
        try fixture.application("Utilities/System Information.app", identifier: "com.apple.SystemProfiler",
                                metadata: ["LSUIElement": true])
        try fixture.application("Utilities/Other Agent.app", identifier: "test.agent", metadata: ["LSUIElement": true])
        let listed = ApplicationCatalog.enumerate(directories: [fixture.root])
        #expect(listed.map(\.id) == ["test.setapp", "com.apple.SystemProfiler", "test.webapp"])
    }

    @Test func appCatalogBrowseStillAcceptsAgentsAndNestedHelpers() throws {
        let fixture = ApplicationFilterFixture()
        defer { fixture.remove() }
        let agent = try fixture.application("Agent.app", identifier: "test.agent", metadata: ["LSUIElement": true])
        try fixture.application("Host.app", identifier: "test.host")
        let nested = try fixture.application("Host.app/Contents/Library/LoginItems/Agent.app", identifier: "test.nested",
                                             metadata: ["LSBackgroundOnly": "YES", "CFBundlePackageType": "XPC!"])
        #expect(ApplicationCatalog.application(at: agent)?.id == "test.agent")
        #expect(ApplicationCatalog.application(at: nested)?.id == "test.nested")
        #expect(ApplicationCatalog.enumerate(directories: [fixture.root]).map(\.id) == ["test.host"])
    }

    @Test func appCatalogUsesFinderNameInsteadOfMetadata() throws {
        let fixture = ApplicationFilterFixture()
        defer { fixture.remove() }
        let url = try fixture.application("Folder Name.app", identifier: "test.name",
                                          metadata: ["CFBundleDisplayName": "Display Name", "CFBundleName": "Metadata Name"])
        #expect(ApplicationCatalog.application(at: url)?.name == "Folder Name")
    }

    @Test func appCatalogLocalizedFixtureUsesObservedFinderName() throws {
        let fixture = ApplicationFilterFixture()
        defer { fixture.remove() }
        let url = try fixture.application("Folder Name.app", identifier: "test.localized",
                                          metadata: ["CFBundleName": "Metadata Name", "CFBundleDisplayName": "Metadata Display",
                                                     "CFBundleDevelopmentRegion": "en", "LSHasLocalizedDisplayName": true])
        let resources = url.appending(path: "Contents/Resources/en.lproj")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("CFBundleDisplayName = \"Localized Name\";".utf8).write(to: resources.appending(path: "InfoPlist.strings"))
        // Neither Finder-name API localizes this unregistered temporary bundle.
        #expect(FileManager.default.displayName(atPath: url.path) == "Folder Name")
        #expect(try url.resourceValues(forKeys: [.localizedNameKey]).localizedName == "Folder Name")
        #expect(ApplicationCatalog.application(at: url)?.name == "Folder Name")
    }

    @Test func appCatalogKeepsDuplicateNamesAndFirstBundleIdentifier() throws {
        let fixture = ApplicationFilterFixture()
        defer { fixture.remove() }
        let first = try fixture.application("First/Shared.app", identifier: "test.z")
        let second = try fixture.application("First/Vendor/Shared.app", identifier: "test.a")
        try fixture.application("Second/Other.app", identifier: "test.z")
        try fixture.application("First/Blank.app", identifier: " \n ")
        let listed = ApplicationCatalog.enumerate(directories: [fixture.root.appending(path: "First"),
                                                                fixture.root.appending(path: "Second")])
        #expect(listed.map(\.id) == ["test.a", "test.z"])
        #expect(listed.map(\.name) == ["Shared", "Shared"])
        #expect(listed.map { $0.url.resolvingSymlinksInPath() } == [second, first].map { $0.resolvingSymlinksInPath() })
    }

    @Test func appCatalogDisplayNameFallsBackWhenFinderNameIsEmpty() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: ".app")
        #expect(FileManager.default.displayName(atPath: url.path) == ".app")
        let uppercase = url.deletingLastPathComponent().appending(path: "Missing.APP")
        #expect(ApplicationCatalog.displayName(for: uppercase, metadata: nil) == "Missing")
        #expect(ApplicationCatalog.displayName(for: url, metadata: ["CFBundleDisplayName": "Display", "CFBundleName": "Name"])
                == "Display")
        #expect(ApplicationCatalog.displayName(for: url, metadata: ["CFBundleName": "Name"]) == "Name")
        #expect(ApplicationCatalog.displayName(for: url, metadata: [:]) == url.deletingPathExtension().lastPathComponent)
        #expect(ApplicationCatalog.displayName(for: url, metadata: nil) == url.deletingPathExtension().lastPathComponent)
    }

    @Test @MainActor func recentApplicationsRecordsMostRecentFirstAndCapsAtEight() throws {
        let defaults = MemoryDefaults()
        let recent = RecentApplications(defaults: defaults)
        #expect(recent.bundleIdentifiers.isEmpty)
        for index in 0..<10 { recent.record("test.app.\(index)") }
        #expect(recent.bundleIdentifiers == (2..<10).reversed().map { "test.app.\($0)" })
        recent.record("  test.app.5\n")
        #expect(recent.bundleIdentifiers == ["test.app.5", "test.app.9", "test.app.8", "test.app.7", "test.app.6",
                                             "test.app.4", "test.app.3", "test.app.2"])
        let beforeInvalidRecords = recent.bundleIdentifiers
        recent.record(" \n ")
        recent.record(String(repeating: "x", count: 256))
        #expect(recent.bundleIdentifiers == beforeInvalidRecords)
        #expect(defaults.object(forKey: RecentApplications.defaultsKey) as? [String] == recent.bundleIdentifiers)
        #expect(RecentApplications(defaults: defaults).bundleIdentifiers == recent.bundleIdentifiers)
        recent.clear()
        #expect(recent.bundleIdentifiers.isEmpty)
        #expect(defaults.object(forKey: RecentApplications.defaultsKey) == nil)
    }

    @Test @MainActor func recentApplicationsSanitizesStoredIdentifiersAndWritesSanitizedResult() throws {
        let defaults = MemoryDefaults()
        let key = "fixture.recents"
        let longest = String(repeating: "x", count: 255)
        let messy = [" test.first ", "", "\n ", "test.first", String(repeating: "x", count: 256), longest,
                     "test.second", " test.second\n", "test.third", "test.fourth"]
        defaults.set(messy, forKey: key)
        let recent = RecentApplications(defaults: defaults, key: key, limit: 3)
        #expect(recent.bundleIdentifiers == ["test.first", longest, "test.second"])
        #expect(defaults.object(forKey: key) as? [String] == messy)
        recent.record(" test.second ")
        #expect(recent.bundleIdentifiers == ["test.second", "test.first", longest])
        #expect(defaults.object(forKey: key) as? [String] == recent.bundleIdentifiers)
        #expect(defaults.object(forKey: RecentApplications.defaultsKey) == nil)
        recent.clear()
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test @MainActor func recentApplicationsRejectsWrongStoredTypes() throws {
        let defaults = MemoryDefaults()
        let recent = RecentApplications(defaults: defaults)
        let values: [Any] = ["test.app", 1, ["identifier": "test.app"], ["test.app", 1] as [Any]]
        for value in values {
            defaults.set(value, forKey: RecentApplications.defaultsKey)
            #expect(recent.bundleIdentifiers.isEmpty)
            recent.record("test.valid")
            #expect(defaults.object(forKey: RecentApplications.defaultsKey) as? [String] == ["test.valid"])
        }
    }

    @Test @MainActor func recentApplicationsHandlesZeroAndNegativeLimits() throws {
        let defaults = MemoryDefaults()
        for limit in [0, -1] {
            defaults.set(["test.app"], forKey: RecentApplications.defaultsKey)
            let recent = RecentApplications(defaults: defaults, limit: limit)
            #expect(recent.bundleIdentifiers.isEmpty)
            recent.record("test.other")
            #expect(defaults.object(forKey: RecentApplications.defaultsKey) as? [String] == [])
        }
    }

}
