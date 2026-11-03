#!/usr/bin/env swift
import AppKit

// Measure actual PNG crops. The manifest supplies logical-point label/icon
// boxes and image scale (2 for the gate). Use the per-channel median as the
// background, then average the 10% of pixels furthest from it in RGB space.
// This measures the rendered crop, including antialiasing, alpha and backdrop.
// It cannot establish live backdrop blur from an offscreen image.
struct Box: Decodable { var name: String; var kind: String; var box: [Double]; var part: String }
struct Accent: Decodable { var point: [Double]; var rgb: [Double]; var glyph: [Double] }
struct Capture: Decodable { var image: String; var combination: String; var state: String; var scale: Double; var boxes: [Box]; var accent: Accent? }
struct Result: Encodable {
    var image: String; var name: String; var kind: String; var part: String
    var ratio: Double; var target: Double; var passes: Bool; var exempt: Bool
    var background: [Double]; var foreground: [Double]
}
/// Decode through the image's own profile, then redraw into 8-bit sRGB and read
/// bytes. `NSBitmapImageRep.colorAt(...).usingColorSpace(.sRGB)` treats these
/// PNGs as Generic RGB on macOS 27 and shifts mid greys up by about 0.07.
struct Raster {
    let width: Int, height: Int, bytes: [UInt8]
    init(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { fatalError("Cannot decode image") }
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w; height = h; bytes = buffer
    }
    func rgb(_ x: Int, _ y: Int) -> [Double] {
        let i = (y * width + x) * 4
        return [Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255]
    }
}
func luminance(_ rgb: [Double]) -> Double {
    let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055)/1.055, 2.4) }
    return zip(linear, [0.2126, 0.7152, 0.0722]).map(*).reduce(0,+)
}
guard CommandLine.arguments.count == 3 || (CommandLine.arguments.count == 5 && CommandLine.arguments[3] == "--estimate-dark-floor") else {
    fatalError("Usage: swift Tools/measure-wheel-contrast.swift <contrast-boxes.json> <output-directory>")
}
let input = URL(filePath: CommandLine.arguments[1]), output = URL(filePath: CommandLine.arguments[2])
let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: input))
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var results: [Result] = []
for capture in captures {
    let data = try Data(contentsOf: input.deletingLastPathComponent().appendingPathComponent(capture.image))
    let bitmap = Raster(data: data)
    for box in capture.boxes {
        let b = box.box
        let minX = max(0, Int(floor(b[0]*capture.scale))), minY = max(0, Int(floor(b[1]*capture.scale)))
        let maxX = min(bitmap.width, Int(ceil((b[0]+b[2])*capture.scale)))
        let maxY = min(bitmap.height, Int(ceil((b[1]+b[3])*capture.scale)))
        guard minX < maxX, minY < maxY else { fatalError("Empty crop: \(capture.image) \(box.name)") }
        var pixels: [[Double]] = []
        for y in minY..<maxY {
            for x in minX..<maxX {
                pixels.append(bitmap.rgb(x, y))
            }
        }
        let median = (0..<3).map { channel in pixels.map { $0[channel] }.sorted()[pixels.count/2] }
        func distance(_ p: [Double]) -> Double { zip(p, median).map { pow($0-$1,2) }.reduce(0,+) }
        let foregroundPixels = pixels.sorted { distance($0) > distance($1) }.prefix(max(1, Int(ceil(Double(pixels.count)*0.1))))
        let foreground = (0..<3).map { channel in foregroundPixels.map { $0[channel] }.reduce(0,+) / Double(foregroundPixels.count) }
        let l1 = luminance(median), l2 = luminance(foreground)
        let ratio = (max(l1,l2)+0.05)/(min(l1,l2)+0.05)
        let exit = capture.state.contains("cancel") || capture.state.contains("commit")
        // Disabled items are exempt. Their ratio is still reported.
        let disabled = box.kind == "unavailable" && ProcessInfo.processInfo.environment["WHEEL_CONTRAST_DISABLED_EXEMPT"] != nil
        let lightIdle = capture.combination == "B" && ["idle", "opaque-idle"].contains(capture.state)
        let target = box.kind == "unavailable" ? (lightIdle ? 3.3 : 3.0) : (box.kind == "hub" ? 3.0 : 4.5)
        results.append(.init(image: capture.image, name: box.name, kind: box.kind, part: box.part,
            ratio: ratio, target: target, passes: exit || disabled || ratio >= target, exempt: exit || disabled, background: median, foreground: foreground))
    }
}
struct AccentResult: Encodable {
    var image: String; var rgb: [Double]; var hueError: Double; var saturation: Double; var passes: Bool
}
func hsv(_ rgb: [Double]) -> (hue: Double, saturation: Double) {
    let high = rgb.max()!, low = rgb.min()!, delta = high-low
    guard delta > 0 else { return (0,0) }
    let hue: Double
    if high == rgb[0] { hue = (rgb[1]-rgb[2])/delta }
    else if high == rgb[1] { hue = (rgb[2]-rgb[0])/delta+2 }
    else { hue = (rgb[0]-rgb[1])/delta+4 }
    return ((hue*60+360).truncatingRemainder(dividingBy:360), high == 0 ? 0 : delta/high)
}
var accents: [AccentResult] = []
for capture in captures {
    guard let accent = capture.accent else { continue }
    let bitmap = Raster(data: try Data(contentsOf: input.deletingLastPathComponent().appendingPathComponent(capture.image)))
    let glyph = CGRect(x: accent.glyph[0], y: accent.glyph[1], width: accent.glyph[2], height: accent.glyph[3])
    var pixels: [[Double]] = []
    for y in Int((accent.point[1]-6)*capture.scale)..<Int((accent.point[1]+6)*capture.scale) {
        for x in Int((accent.point[0]-6)*capture.scale)..<Int((accent.point[0]+6)*capture.scale) {
            let point = CGPoint(x: Double(x)/capture.scale, y: Double(y)/capture.scale)
            guard !glyph.contains(point), x >= 0, y >= 0, x < bitmap.width, y < bitmap.height else { continue }
            pixels.append(bitmap.rgb(x, y))
        }
    }
    guard !pixels.isEmpty else { fatalError("Accent patch contains only glyph pixels: \(capture.image)") }
    let median = (0..<3).map { channel in pixels.map { $0[channel] }.sorted()[pixels.count/2] }
    let measured = hsv(median), expected = hsv(accent.rgb)
    let delta = abs(measured.hue-expected.hue), error = min(delta,360-delta)
    accents.append(.init(image: capture.image, rgb: median, hueError: error, saturation: measured.saturation,
        passes: error <= 20 && measured.saturation >= 0.25))
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
try encoder.encode(results).write(to: output.appendingPathComponent("contrast.json"))
try encoder.encode(accents).write(to: output.appendingPathComponent("accent.json"))
var table = "| Capture | Available min | Unavailable min | Selected min | Hub | Failures / crops |\n| --- | --- | --- | --- | --- | --- |\n"
func formatted(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }
for capture in captures {
    let rows = results.filter { $0.image == capture.image }
    let minima = ["available", "unavailable", "selected", "hub"].map { kind in formatted(rows.filter { $0.kind == kind }.map(\.ratio).min()) }
    table += "| \(capture.image) | \(minima.joined(separator: " | ")) | \(rows.filter { !$0.passes }.count) / \(rows.count) |\n"
}
table += "\nEvery crop (label and icon) is listed in contrast.json and contrast.csv. Values use the supplied PNG, not ideal text colors. Exit contrast is exempt; accent checks still apply. B idle unavailable ink must reach 3.3:1 and stay at most half the available minimum.\n"
var hierarchyFailures = 0
for capture in captures where capture.combination == "B" && ["idle", "opaque-idle"].contains(capture.state) {
    let rows = results.filter { $0.image == capture.image }
    if let available = rows.filter({ $0.kind == "available" }).map(\.ratio).min(),
       let unavailable = rows.first(where: { $0.kind == "unavailable" && $0.name == "Choose Layout" && $0.part == "label" }) {
        let passes = unavailable.ratio >= 3.3 && unavailable.ratio <= available / 2
        if !passes { hierarchyFailures += 1 }
        table += "\n\(capture.image) Choose Layout: \(formatted(unavailable.ratio)):1; available minimum \(formatted(available)):1; dimming gate \(passes ? "PASS" : "FAIL").\n"
    }
}
try table.write(to: output.appendingPathComponent("contrast-table.md"), atomically: true, encoding: .utf8)
func csv(_ s: String) -> String { "\""+s.replacingOccurrences(of: "\"", with: "\"\"")+"\"" }
let lines = results.map { [csv($0.image),csv($0.name),$0.kind,$0.part,String(format:"%.4f",$0.ratio),String($0.target),String($0.passes),String($0.exempt)].joined(separator:",") }
try ("image,name,kind,part,ratio,target,passes,exempt\n"+lines.joined(separator:"\n")+"\n")
    .write(to: output.appendingPathComponent("contrast.csv"), atomically: true, encoding: .utf8)
var accentTable = "| Capture | Accent hue error | Saturation | Pass |\n| --- | --- | --- | --- |\n"
for row in accents {
    accentTable += "| \(row.image) | \(formatted(row.hueError))° | \(formatted(row.saturation)) | \(row.passes) |\n"
}
try accentTable.write(to: output.appendingPathComponent("accent-table.md"), atomically: true, encoding: .utf8)
print(table)
print("\(results.filter { !$0.passes }.count) of \(results.count) rendered crops fail.")

// Optional design estimate from a previous live C idle crop. Invert the old
// 0.75 plate in sRGB and retain measured native-white ink coverage. The native
// blur response is assumed unchanged, so this is not a replacement for capture.
if CommandLine.arguments.count == 5 {
    let floor = Double(CommandLine.arguments[4])!
    let plate = 30.0 / 255
    let rows = results.filter { $0.image.hasPrefix("C-idle") && ["available", "unavailable"].contains($0.kind) }
    var estimates: [Result] = []
    for row in rows {
        let background = row.background.map { plate + ($0 - plate) * (1 - floor) / 0.25 }
        let foreground = zip(zip(row.foreground, row.background), background).map { pair, updated in
            1 - (1 - pair.0) * (1 - updated) / (1 - pair.1)
        }
        let ratio = (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
        estimates.append(.init(image: row.image, name: row.name, kind: row.kind, part: row.part,
            ratio: ratio, target: row.target, passes: ratio >= row.target, exempt: false,
            background: background, foreground: foreground))
    }
    try encoder.encode(estimates).write(to: output.appendingPathComponent("live-C-floor-estimates.json"))
    let available = estimates.filter { $0.kind == "available" }.map(\.ratio).min()
    let unavailable = estimates.filter { $0.kind == "unavailable" }.map(\.ratio).min()
    let note = "Live C crop estimate at floor \(floor): available \(formatted(available)):1, unavailable \(formatted(unavailable)):1. Inverse sRGB plate composition from 0.75, dark plate 30/255, measured white ink coverage. Assumes unchanged blur response; requires live confirmation.\n"
    try note.write(to: output.appendingPathComponent("live-C-floor-estimate.txt"), atomically: true, encoding: .utf8)
    print(note)
}

if results.contains(where: { !$0.passes }) || hierarchyFailures > 0 || accents.contains(where: { !$0.passes }) { exit(1) }
