import Foundation

/// Chooses how glyph mask tests check the bundled artwork on this host.
///
/// The images are generated once and ship on every supported macOS release.
/// SwiftUI and SF Symbols output can change with the OS build and the
/// toolchain, so a byte comparison with a live render is valid only on the
/// host that generated the images. Every other host, CI included, uses
/// tolerance checks. Every test logs the mode that ran.
public enum GlyphMaskTestMode: Equatable, Sendable, CustomStringConvertible {
    /// The host matches the generator: freshness and parity are exact.
    case exact
    /// Any other host: decode, semantics and a bounded difference from a live render.
    case tolerance(reason: String)

    /// The recorded fields that must match the host for exact mode.
    public static let hostKeys = ["build", "architecture", "toolchain"]

    /// Set `BT_GLYPH_MASK_TEST_MODE` to `exact` or `tolerance` to force a mode.
    public static func current(generator: [String: String],
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               host: () -> [String: String] = { GlyphMaskTestHost.current }) -> GlyphMaskTestMode {
        switch environment["BT_GLYPH_MASK_TEST_MODE"] {
        case "exact": return .exact
        case "tolerance": return .tolerance(reason: "BT_GLYPH_MASK_TEST_MODE=tolerance")
        default: break
        }
        let host = host()
        var different: [String] = []
        for key: String in hostKeys where host[key] == nil || host[key] != generator[key] { different.append(key) }
        if different.isEmpty { return .exact }
        var reasons: [String] = []
        for key: String in different {
            let hostValue: String = summary(host[key]), generatorValue: String = summary(generator[key])
            reasons.append("\(key) \(hostValue) differs from generator \(generatorValue)")
        }
        return .tolerance(reason: reasons.joined(separator: "; "))
    }

    public var isExact: Bool { self == .exact }

    public var description: String {
        switch self {
        case .exact: "exact (host matches the generator's OS build, architecture and toolchain)"
        case .tolerance(let reason): "tolerance (\(reason))"
        }
    }

    /// Print the mode so a test log always shows which checks ran.
    public func log(_ test: String) {
        print("Glyph mask test mode=\(isExact ? "exact" : "tolerance") test=\(test): \(self)")
    }

    private static func summary(_ value: String?) -> String {
        guard let value else { return "(missing)" }
        return "\"" + (value.split(separator: "\n").first.map(String.init) ?? value) + "\""
    }
}

/// The host fields that the glyph mask generator records.
public enum GlyphMaskTestHost {
    public static let current: [String: String] = [
        "macOS": run("/usr/bin/sw_vers", ["-productVersion"]),
        "build": run("/usr/bin/sw_vers", ["-buildVersion"]),
        "architecture": run("/usr/bin/arch", []),
        "toolchain": run("/usr/bin/xcrun", ["swift", "--version"]),
    ].compactMapValues { $0 }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Compares two premultiplied RGBA8 glyph rasters for tolerance mode.
public struct GlyphRasterDifference: Equatable, Sendable, CustomStringConvertible {
    /// Largest accepted `inkDifference` for the same glyph on another host.
    public static let inkDifferenceLimit = 0.35
    /// Largest accepted difference of the mean ink colour, per channel, out of 255.
    public static let inkColorLimit = 8
    /// Largest accepted size difference, in pixels per axis. The rasters are centred.
    public static let sizeLimit = 4

    /// Sum of absolute alpha differences divided by the larger total alpha.
    /// 0 means the same coverage; 1 means no shared coverage.
    public let inkDifference: Double
    /// Largest per-channel difference of the mean unpremultiplied ink colour.
    public let inkColorDelta: Int
    public let maxAlphaDelta: Int
    public let sizeDelta: Int
    /// True when one raster has coverage and the other has none.
    public let oneSideEmpty: Bool

    public var isWithinLimits: Bool {
        let sized: Bool = sizeDelta <= Self.sizeLimit
        let covered: Bool = inkDifference <= Self.inkDifferenceLimit
        let inked: Bool = inkColorDelta <= Self.inkColorLimit
        return sized && covered && inked
    }

    public var description: String {
        String(format: "inkDifference=%.4f (limit %.2f) inkColorDelta=%d (limit %d) maxAlphaDelta=%d sizeDelta=%d",
               inkDifference, Self.inkDifferenceLimit, inkColorDelta, Self.inkColorLimit, maxAlphaDelta, sizeDelta)
    }

    public init(_ a: [UInt8], width aWidth: Int, height aHeight: Int,
                _ b: [UInt8], width bWidth: Int, height bHeight: Int) {
        let width = max(aWidth, bWidth), height = max(aHeight, bHeight)
        let left = Self.centred(a, aWidth, aHeight, width, height)
        let right = Self.centred(b, bWidth, bHeight, width, height)
        var difference = 0, leftTotal = 0, rightTotal = 0, maxAlpha = 0
        for offset in stride(from: 3, to: left.count, by: 4) {
            let l = Int(left[offset]), r = Int(right[offset])
            difference += abs(l - r)
            leftTotal += l
            rightTotal += r
            maxAlpha = max(maxAlpha, abs(l - r))
        }
        let total: Int = max(leftTotal, rightTotal, 1)
        inkDifference = Double(difference) / Double(total)
        maxAlphaDelta = maxAlpha
        sizeDelta = max(abs(aWidth - bWidth), abs(aHeight - bHeight))
        oneSideEmpty = (leftTotal == 0) != (rightTotal == 0)
        let leftInk = Self.inkColor(left), rightInk = Self.inkColor(right)
        if let leftInk, let rightInk {
            var largest: Int = 0
            for (left, right) in zip(leftInk, rightInk) { largest = max(largest, abs(left - right)) }
            inkColorDelta = largest
        } else {
            inkColorDelta = 0
        }
    }

    /// Mean unpremultiplied colour of pixels at least half covered.
    public static func inkColor(_ pixels: [UInt8]) -> [Int]? {
        var sums = [0.0, 0.0, 0.0], count = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] >= 128 {
            let alpha = Double(pixels[offset + 3])
            for channel: Int in 0..<3 {
                let value: Double = Double(pixels[offset + channel])
                sums[channel] += value * 255 / alpha
            }
            count += 1
        }
        guard count > 0 else { return nil }
        var result: [Int] = []
        for sum: Double in sums { result.append(Int((sum / count).rounded())) }
        return result
    }

    private static func centred(_ pixels: [UInt8], _ width: Int, _ height: Int,
                                _ targetWidth: Int, _ targetHeight: Int) -> [UInt8] {
        if width == targetWidth && height == targetHeight { return pixels }
        var result = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        let x0 = (targetWidth - width) / 2, y0 = (targetHeight - height) / 2
        for y in 0..<height {
            let source = y * width * 4, target = ((y + y0) * targetWidth + x0) * 4
            result.replaceSubrange(target..<(target + width * 4), with: pixels[source..<(source + width * 4)])
        }
        return result
    }
}
