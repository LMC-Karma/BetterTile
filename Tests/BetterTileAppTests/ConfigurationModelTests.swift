import BetterTileCore
import Foundation
import Testing
@testable import BetterTileApp

private func temporaryConfigurationStore() throws -> ConfigurationStore {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
}

@Test @MainActor func futureConfigurationSurvivesSessionChangesAndEverySavePath() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = ConfigurationStore(fileURL: directory.appending(path: "configuration.json"))
    let original = Data("{\n  \"schemaVersion\": 999, \"futurePreference\": \"keep-me\"\n}\n".utf8)
    try original.write(to: store.fileURL)
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationLoadError as? ConfigurationError == .unsupportedFutureVersion(999))
    let explanation = try #require(model.configurationSaveBlockedReason)
    #expect(explanation.contains("only for this session"))
    #expect(explanation.contains(store.fileURL.path))

    model.updateConfiguration { $0.menuBarActions = [.rightHalf, .leftHalf] }
    #expect(model.configuration.menuBarActions == [.rightHalf, .leftHalf])
    model.statusMessage = "A transient action failed."
    #expect(model.configurationSaveBlockedReason == explanation)
    model.statusMessage = nil
    #expect(model.configurationSaveBlockedReason == explanation)
    try await Task.sleep(for: .milliseconds(400))
    #expect(try Data(contentsOf: store.fileURL) == original)
    model.flushConfiguration()
    #expect(try Data(contentsOf: store.fileURL) == original)
    model.updateConfiguration { $0.showDockIcon.toggle() }
    model.shutdown()
    #expect(try Data(contentsOf: store.fileURL) == original)
}

@Test(arguments: [
    ("{\n  broken JSON\n}", ConfigurationError.invalidFile),
    (#"{"schemaVersion":12,"dividerThickness":1}"#, ConfigurationError.invalidDividerThickness),
])
@MainActor func invalidConfigurationRetainsItsFailureAndBytes(json: String, failure: ConfigurationError) throws {
    let store = try temporaryConfigurationStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let original = Data(json.utf8)
    try original.write(to: store.fileURL)
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationLoadError as? ConfigurationError == failure)

    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    model.flushConfiguration()
    model.shutdown()
    #expect(model.configuration.menuBarActions == [.rightHalf])
    #expect(try Data(contentsOf: store.fileURL) == original)
}

@Test(arguments: [true, false])
@MainActor func inaccessibleConfigurationRemainsProtectedAfterAccessReturns(denyLookup: Bool) throws {
    let store = try temporaryConfigurationStore()
    let directory = store.fileURL.deletingLastPathComponent()
    let protectedURL = denyLookup ? directory : store.fileURL
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedURL.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let original = Data(#"{"schemaVersion":12,"showDockIcon":true}"#.utf8)
    try original.write(to: store.fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: protectedURL.path)
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    let failure = try #require(model.configurationLoadError) as NSError
    #expect(failure.domain == NSCocoaErrorDomain)
    #expect(failure.code == CocoaError.fileReadNoPermission.rawValue)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedURL.path)
    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    model.flushConfiguration()
    model.shutdown()
    #expect(try Data(contentsOf: store.fileURL) == original)
}

@Test @MainActor func restoringValidConfigurationRequiresRelaunchToSaveAgain() throws {
    let store = try temporaryConfigurationStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    try Data("invalid".utf8).write(to: store.fileURL)
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    let repaired = Data(#"{"schemaVersion":12,"showDockIcon":true}"#.utf8)
    try repaired.write(to: store.fileURL)

    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    model.flushConfiguration()
    model.shutdown()
    #expect(try Data(contentsOf: store.fileURL) == repaired)
    #expect(model.configurationSaveBlockedReason != nil)

    let relaunched = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { relaunched.shutdown() }
    #expect(relaunched.configurationLoadError == nil)
    #expect(relaunched.configurationSaveBlockedReason == nil)
    #expect(relaunched.configuration.showDockIcon)
    relaunched.updateConfiguration { $0.menuBarActions = [.leftHalf] }
    relaunched.flushConfiguration()
    #expect(try store.load().menuBarActions == [.leftHalf])
}

@Test @MainActor func configurationDirectoryAndItsContentsArePreservedAfterReadFailure() throws {
    let store = try temporaryConfigurationStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
    let child = store.fileURL.appending(path: "keep-me")
    let original = Data("original contents".utf8)
    try original.write(to: child)
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationLoadError != nil)
    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    model.flushConfiguration()
    model.shutdown()
    #expect(try Data(contentsOf: child) == original)
}

@Test @MainActor func danglingConfigurationSymlinkIsNotTreatedAsMissing() throws {
    let store = try temporaryConfigurationStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    let destination = store.fileURL.deletingLastPathComponent().appending(path: "missing.json")
    try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: destination)
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationLoadError != nil)
    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    model.flushConfiguration()
    model.shutdown()
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.fileURL.path) == destination.path)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test(arguments: [7, 12])
@MainActor func supportedConfigurationStillLoadsAndSaves(schemaVersion: Int) throws {
    let store = try temporaryConfigurationStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
    try Data("{\"schemaVersion\":\(schemaVersion),\"showDockIcon\":true}".utf8).write(to: store.fileURL)
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationSaveBlockedReason == nil)
    #expect(model.configuration.showDockIcon)
    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    model.shutdown()
    #expect(try store.load().menuBarActions == [.rightHalf])
}

@Test @MainActor func ordinarySaveFailureRemainsRetryable() throws {
    let store = try temporaryConfigurationStore()
    let directory = store.fileURL.deletingLastPathComponent()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    model.flushConfiguration()
    #expect(model.statusMessage != nil)
    #expect(model.configurationLoadError == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    model.flushConfiguration()
    #expect(try store.load().menuBarActions == [.rightHalf])
}

@Test @MainActor func missingConfigurationAllowsDelayedSaving() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(fileURL: directory.appending(path: "nested/configuration.json"))
    let model = BetterTileModel(store: store, system: FakeAppWindowSystem(), startRuntime: false)
    defer { model.shutdown() }
    #expect(model.configurationLoadError == nil)
    #expect(model.configurationSaveBlockedReason == nil)
    model.updateConfiguration { $0.menuBarActions = [.rightHalf] }
    let saved = await waitFor { (try? store.load().menuBarActions) == [.rightHalf] }
    #expect(saved, "The delayed configuration save did not complete.")
}
