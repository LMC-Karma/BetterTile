import AppKit
import BetterTileCore
import Darwin

/// Reads the system facts for Copy Diagnostics. It reads versions and the
/// CPU architecture only: no user, computer, serial or hardware identifier.
public enum DiagnosticsEnvironmentReader {
    public static func current(
        accessibilityGranted: Bool,
        automaticUpdateChecks: Bool?,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> DiagnosticsReport.Environment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return DiagnosticsReport.Environment(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOSVersion: macOSVersion,
            macOSBuild: systemString("kern.osversion") ?? "unknown",
            architecture: architecture,
            accessibilityGranted: accessibilityGranted,
            privateAPIsDisabled: defaults.bool(forKey: "disablePrivateAPIs"),
            automaticUpdateChecks: automaticUpdateChecks
        )
    }

    /// The architecture this build runs as. "under Rosetta" marks an Intel
    /// build that runs on Apple silicon.
    static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return systemInteger("sysctl.proc_translated") == 1 ? "x86_64 (under Rosetta)" : "x86_64"
#else
        return "unknown"
#endif
    }

    private static func systemString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func systemInteger(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

public enum DiagnosticsPasteboard {
    /// Replaces the pasteboard's contents with `text` as plain text. The
    /// report goes only to the pasteboard; nothing is sent or saved.
    @MainActor @discardableResult
    public static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

extension DiagnosticsResultKind {
    public init(_ kind: ResultPillFeedback.Kind) {
        switch kind {
        case .success: self = .success
        case .warning: self = .warning
        case .failure: self = .failure
        }
    }
}

extension DiagnosticsResultLog {
    /// Records the pill's kind and, when it is a fixed title, its title. The
    /// detail line is never recorded.
    public mutating func record(_ feedback: ResultPillFeedback) {
        record(kind: DiagnosticsResultKind(feedback.kind), title: feedback.message)
    }
}
