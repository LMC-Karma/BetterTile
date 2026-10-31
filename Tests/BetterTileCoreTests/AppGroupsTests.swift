import Foundation
import Testing
@testable import BetterTileCore

@Suite struct AppGroupsTests {
    @Test(arguments: ["", "   ", "\n"])
    func emptyGroupName(name: String) throws {
        try rejects(.init(groups: [.init(name: name, apps: [])]), path: "$.groups[0].name")
    }

    @Test(arguments: ["browser", "BRÓWSER"])
    func duplicateGroupName(name: String) throws {
        try rejects(.init(groups: [.init(name: "Browser", apps: []), .init(name: name, apps: [])]), path: "$.groups[1].name")
    }

    @Test(arguments: [AppGroupEntry(), AppGroupEntry(name: "  ")])
    func missingEntry(entry: AppGroupEntry) throws {
        try rejects(.init(groups: [.init(name: "Browser", apps: [entry])]), path: "$.groups[0].apps[0]")
    }

    @Test(arguments: ["", "single", ".app", "com..app", "com.app_thing", "com.app "])
    func invalidBundleID(id: String) throws {
        try rejects(.init(groups: [.init(name: "Browser", apps: [.init(bundleID: id)])]), path: "$.groups[0].apps[0].bundleID")
    }

    @Test(arguments: [
        [AppGroupEntry(name: "One", bundleID: "com.example.app"), .init(name: "Two", bundleID: "com.example.app")],
        [AppGroupEntry(name: "Brave"), .init(name: "bravé")]
    ])
    func duplicateEntry(entries: [AppGroupEntry]) throws {
        try rejects(.init(groups: [.init(name: "Browser", apps: entries)]), path: "$.groups[0].apps[1]")
    }

    @Test func headersAndRoundTrip() throws {
        let document = AppGroupsDocument(groups: [.init(name: "Browser", apps: [.init(name: "Safari", bundleID: "com.apple.Safari"), .init(name: "Brave")])])
        let encoded = try document.encode()
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.hasPrefix(AppGroupsDocument.fileHeader))
        #expect(try AppGroupsDocument.decode(encoded) == document)
        let body = String(text.dropFirst(AppGroupsDocument.fileHeader.count))
        #expect(try AppGroupsDocument.decode(Data(body.utf8)) == document)
        #expect(text.contains("\"name\" : \"Safari\""))
    }

    @Test func versionCheckedFirst() throws {
        do {
            _ = try AppGroupsDocument.decode(Data("{\"version\":2,\"groups\":false}".utf8))
            Issue.record("Expected version refusal")
        } catch let error as SavedLayoutValidationError {
            #expect(error.issues.first?.path == "$.version")
            #expect(error.errorDescription?.contains("version 2") == true)
        }
    }

    @Test func expansion() {
        let resolved = AppGroupEntry(name: "Brave")
        let owned = AppGroupEntry(name: "Safari", bundleID: "com.apple.Safari")
        let document = AppGroupsDocument(groups: [.init(name: "Brówsér", apps: [owned, resolved, .init(name: "Missing"), .init(bundleID: "com.first.app")])])
        let result = document.expand([.app("com.first.app"), .group("BROWSER"), .app("com.brave.app"), .group("Absent")],
            resolvedBundleIDs: [resolved: "com.brave.app", owned: "com.wrong.app"])
        #expect(result.bundleIDs == ["com.first.app", "com.apple.Safari", "com.brave.app"])
        #expect(result.unknownGroups == ["Absent"])
        #expect(result.unresolvedEntries == ["Missing"])
    }

    @Test func rename() throws {
        let document = AppGroupsDocument(groups: [.init(name: "Browser", apps: []), .init(name: "Coding", apps: [])])
        let renamed = try document.renamingGroup("browser", to: "Web")
        #expect(renamed.groups.map(\.name) == ["Web", "Coding"])
        #expect(document.groups[0].name == "Browser")
        #expect(throws: SavedLayoutValidationError.self) { try document.renamingGroup("Browser", to: "códing") }
        #expect(throws: SavedLayoutValidationError.self) { try document.renamingGroup("Browser", to: "  ") }
        #expect(throws: SavedLayoutValidationError.self) { try document.renamingGroup("Missing", to: "Web") }
    }

    @Test(arguments: [
        ("{\"version\":1,\"groups\":[],\"extra\":true}", "$.extra"),
        ("{\"version\":1,\"groups\":[{\"name\":\"X\",\"apps\":[],\"extra\":0}]}", "$.groups[0].extra"),
        ("{\"version\":1,\"groups\":[{\"name\":\"X\",\"apps\":[{\"name\":\"X\",\"bundleId\":\"com.a.b\"}]}]}", "$.groups[0].apps[0].bundleId"),
        ("{\"version\":1,\"groups\":[{\"name\":\"X\",\"apps\":[{\"group\":\"Coding\"}]}]}", "$.groups[0].apps[0].group")
    ])
    func unknownKeys(input: String, path: String) throws {
        try rejectsData(Data(input.utf8), path: path, message: "Unknown field")
    }

    @Test(arguments: [
        ("{\"version\":1,\"groups\":[{\"name\":\"X\"}]}", "$.groups[0].apps", "Add the required apps field."),
        ("{\"version\":1,\"groups\":false}", "$.groups", "This value has the wrong JSON type."),
        ("{\"version\":1,\"groups\":null}", "$.groups", "This value cannot be null."),
        ("not JSON", "$", "This is not valid App Groups JSON."),
        ("", "$", "This is not valid App Groups JSON.")
    ])
    func decodingFailures(input: String, path: String, message: String) throws {
        try rejectsData(Data(input.utf8), path: path, message: message)
    }

    @Test func sizeLimit() throws {
        try rejectsData(Data(repeating: 32, count: SavedLayoutValidator.maximumBytes + 1), path: "$", message: "1 MiB")
    }

    @Test func validateAndEncodeRejectInvalid() throws {
        let document = AppGroupsDocument(groups: [.init(name: "", apps: [])])
        #expect(document.validate().first?.path == "$.groups[0].name")
        #expect(throws: SavedLayoutValidationError.self) { try document.encode() }
    }

    @Test func commentsAndOptionalName() throws {
        let input = AppGroupsDocument.fileHeader + "// User note\n{\n// before version\n\"version\": 1,\n// before groups\n\"groups\": [{\"name\": \"X\", \"apps\": [{\"bundleID\": \"com.a.b\"}]}]}"
        let document = try AppGroupsDocument.decode(Data(input.utf8))
        let text = try #require(String(data: document.encode(), encoding: .utf8))
        let body = String(text.dropFirst(AppGroupsDocument.fileHeader.count))
        #expect(!body.contains("\"name\" : \"com.a.b\""))
        let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let groups = try #require(object["groups"] as? [[String: Any]])
        let apps = try #require(groups.first?["apps"] as? [[String: Any]])
        #expect(apps.first?["name"] == nil)
    }

    @Test func bundleIDsIgnoreCase() throws {
        let entries = [AppGroupEntry(bundleID: "com.apple.Safari"), .init(bundleID: "COM.APPLE.safari")]
        try rejects(.init(groups: [.init(name: "X", apps: entries)]), path: "$.groups[0].apps[1]")
        let document = AppGroupsDocument(groups: [.init(name: "X", apps: [entries[1]])])
        #expect(document.expand([.app("com.apple.Safari"), .group("X")]).bundleIDs == ["com.apple.Safari"])
    }

    private func rejectsData(_ data: Data, path: String, message: String) throws {
        do {
            _ = try AppGroupsDocument.decode(data)
            Issue.record("Expected validation error at \(path)")
        } catch let error as SavedLayoutValidationError {
            #expect(error.issues.contains { $0.path == path && $0.message.contains(message) })
        }
    }

    private func rejects(_ document: AppGroupsDocument, path: String) throws {
        let data = try JSONEncoder().encode(document)
        do {
            _ = try AppGroupsDocument.decode(data)
            Issue.record("Expected validation error at \(path)")
        } catch let error as SavedLayoutValidationError {
            #expect(error.issues.contains { $0.path == path && !$0.message.isEmpty })
        }
    }
}

extension AppGroupsTests {
    @Test(arguments: ["{version: 1, \"groups\": []}", "{'version': 1, 'groups': []}", "{/* comment */ \"version\": 1, \"groups\": []}"])
    func rejectsOtherJSON5Syntax(_ input: String) {
        #expect(throws: (any Error).self) { try AppGroupsDocument.decode(Data(input.utf8)) }
    }

    @Test func trailingCommasRemainAccepted() throws {
        #expect(try AppGroupsDocument.decode(Data("{\"version\":1,\"groups\":[],}".utf8)).groups.isEmpty)
    }
}

extension AppGroupsTests {
    @Test func lineCommentsPreserveStringsAndEndOfFile() throws {
        let source = #"{"version":1,"groups":[{"name":"Web // group","apps":[{"name":"https://x"}]}]}// last"#
        let doc = try AppGroupsDocument.decode(Data(source.utf8))
        #expect(doc.groups[0].name == "Web // group")
        #expect(doc.groups[0].apps[0].name == "https://x")
        #expect(!String(decoding: try doc.encode(), as: UTF8.self).contains("// last"))
    }
}
