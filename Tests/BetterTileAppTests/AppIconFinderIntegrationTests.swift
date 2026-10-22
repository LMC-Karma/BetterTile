import AppKit
import Foundation
import Testing
@testable import BetterTileApp

/// Uses only a disposable app bundle. No installed app or live window is changed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERTILE_TEST_FINDER_ICON"] == "1"))
@MainActor func finderIconChangesPreserveSignedContentsAndRestoreThePrimaryIcon() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("BetterTile-Icon-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    let app = root.appendingPathComponent("Probe.app")
    let contents = app.appendingPathComponent("Contents")
    try fileManager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try fileManager.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/Probe").path)
    let info = [
        "CFBundleIdentifier": "com.lmckarma.BetterTile.icon-test",
        "CFBundleExecutable": "Probe",
        "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))

    func codesign(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments + [app.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain before waiting so diagnostics cannot fill the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    func expectCodesignSuccess(_ arguments: [String]) throws {
        let result = try codesign(arguments)
        #expect(result.status == 0, "\(result.output)")
    }
    func signedContents() throws -> [String: Data] {
        let enumerator = try #require(fileManager.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.path] = try Data(contentsOf: url)
            }
        }
        return files
    }
    func iconIsBlue() throws -> Bool {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        // Finder can lighten the source color when it renders the icon.
        // Identify the blue fixture by channel separation from the pale primary icon.
        return color.blueComponent - color.redComponent > 0.5
            && color.blueComponent - color.greenComponent > 0.2
    }

    try expectCodesignSuccess(["--force", "--sign", "-"])
    try expectCodesignSuccess(["--verify", "--deep", "--strict"])
    let originalContents = try signedContents()
    #expect(try !iconIsBlue())
    let blue = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
        return true
    }
    #expect(AppIconStyle.classic.updateFinderIcon(at: app, loadImage: { _ in blue }))
    #expect(try iconIsBlue())
    #expect(try signedContents() == originalContents)
    try expectCodesignSuccess(["--verify", "--deep"])
    let strictOverride = try codesign(["--verify", "--deep", "--strict"])
    #expect(strictOverride.status != 0, "Strict verification must reject custom Finder metadata")
    #expect(strictOverride.output.contains("resource fork, Finder information, or similar detritus not allowed"),
            "\(strictOverride.output)")

    #expect(AppIconStyle.dark.updateFinderIcon(at: app))
    #expect(try !iconIsBlue())
    #expect(try signedContents() == originalContents)
    try expectCodesignSuccess(["--verify", "--deep", "--strict"])
}
