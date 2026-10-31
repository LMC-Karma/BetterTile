import AppKit
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

/// Capture the actual editable control while it remains in its production glass host.
/// Native glass optics require WindowServer; this checks the field's own pixels over
/// both extreme backdrops, without substituting an opaque offscreen glass fallback.
@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct PopupSearchContrastTests {
    @Test(arguments: [GlassPopupSnapshotTests.Surface.ruleSheet, .panePicker],
          [(false, false, false), (false, true, false), (true, false, false), (true, true, false),
           (false, false, true), (false, true, true), (true, false, true), (true, true, true)])
    func enteredSearchAndPlaceholderStayReadableInRealGlass(surface: GlassPopupSnapshotTests.Surface,
                                                           options: (Bool, Bool, Bool)) async throws {
        let (dark, white, solid) = options
        _ = NSApplication.shared
        let previous = NSApp.appearance
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        let scene = try await GlassPopupScene.make(surface, dark: dark, reduceTransparency: solid)
        defer { scene.close() }
        let field = try #require(panelViews(scene.root, NSSearchField.self).first)
        let cell = try #require(field.cell as? ApplicationPickerSearchCell)
        let glass = try #require(panelViews(scene.root, OverlayGlassView.self).first)
        #expect(glass.showsGlass == !solid)
        #expect(field.isDescendant(of: try #require(glass.popupContent)))
        if !solid { #expect(field.isDescendant(of: try #require(glass.glass.contentView))) }
        let window = try #require(field.window)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        let savedPlaceholder = field.placeholderAttributedString
        field.placeholderAttributedString = NSAttributedString(string: "")
        scene.root.layoutSubtreeIfNeeded()
        let blank = try SearchFieldPixels(field, root: try #require(glass.popupContent), white: white)
        field.placeholderAttributedString = savedPlaceholder
        editor.insertText("MMMMMMMM", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        try await panelReady(scene.root) { field.stringValue == "MMMMMMMM" }
        scene.root.layoutSubtreeIfNeeded()
        let textRect = cell.searchTextRect(forBounds: field.bounds)
        let inkRect = NSRect(x: textRect.minX + 2, y: field.bounds.midY - 5,
                             width: min(50, textRect.width - 4), height: 10)
        let typed = try SearchFieldPixels(field, root: try #require(glass.popupContent), white: white)
        let background = typed.pixel(NSPoint(x: textRect.maxX - 12, y: field.bounds.midY))
        let typedRatio = typed.peakContrast(in: inkRect, background: blank)
        let label = PickerText.searchLabelColor(in: appearance)
        let expectedInk = zip([label.redComponent, label.greenComponent, label.blueComponent], background)
            .map { $0 * label.alphaComponent + $1 * (1 - label.alphaComponent) }
        #expect(zip(typed.ink(in: inkRect, dark: dark), expectedInk).allSatisfy { abs($0 - $1) <= 2.0 / 255 },
                "Typed text must render the window's full labelColor, without vibrant dimming")
        #expect(typedRatio >= 4.5, "\(surface) dark=\(dark) white=\(white): entered text \(typedRatio):1")
        var fieldColor: NSColor!, caretColor: NSColor!
        appearance.performAsCurrentDrawingAppearance {
            fieldColor = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
            caretColor = editor.insertionPointColor.usingColorSpace(.sRGB)
        }
        let expectedBackground = [fieldColor.redComponent, fieldColor.greenComponent, fieldColor.blueComponent]
        #expect(zip(background, expectedBackground).allSatisfy { abs($0 - $1) < 2.0 / 255 })
        let caret = zip([caretColor.redComponent, caretColor.greenComponent, caretColor.blueComponent], background)
            .map { $0 * caretColor.alphaComponent + $1 * (1 - caretColor.alphaComponent) }
        let caretRatio = SearchFieldPixels.contrast(caret, background)
        let material = try SearchFieldPixels(field, root: scene.root, white: white)
        let materialBackground = material.pixel(NSPoint(x: textRect.maxX - 12, y: field.bounds.midY))
        let materialRatio = material.peakContrast(in: inkRect, background: materialBackground)
        #expect(zip(materialBackground, expectedBackground).allSatisfy { abs($0 - $1) < 2.0 / 255 },
                "The real glass host must preserve the opaque field surface")
        #expect(zip(material.ink(in: inkRect, dark: dark), expectedInk).allSatisfy { abs($0 - $1) <= 2.0 / 255 })
        #expect(materialRatio >= 4.5, "Entered text with native glass included: \(materialRatio):1")
        #expect(caretRatio >= 3, "Caret contrast: \(caretRatio):1")
        let clearRatio = typed.peakContrast(in: cell.cancelButtonRect(forBounds: field.bounds), background: background)
        #expect(clearRatio >= 3, "Clear glyph contrast: \(clearRatio):1")
        editor.selectAll(nil)
        let selected = try SearchFieldPixels(field, root: try #require(glass.popupContent), white: white)
        let selectionBackground = selected.dominantColor(in: inkRect)
        let selectionRatio = selected.peakContrast(in: inkRect, background: selectionBackground)
        #expect(selectionRatio >= 4.5, "Selected text contrast: \(selectionRatio):1")
        print("POPUP_SEARCH_FIELD \(surface) dark=\(dark) white=\(white) vibrant=\(field.allowsVibrancy) backgroundEnabled=\(field.drawsBackground) fieldInk=\(String(describing: field.textColor)) editorInk=\(String(describing: editor.textColor)) solid=\(solid) background=\(background) typed=\(typedRatio) material=\(materialRatio) caret=\(caretRatio) clear=\(clearRatio) selected=\(selectionRatio)")
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        try await panelReady(scene.root) { field.stringValue.isEmpty }
        let placeholder = try SearchFieldPixels(field, root: try #require(glass.popupContent), white: white)
        let placeholderRatio = placeholder.peakContrast(in: inkRect, background: blank)
        let magnifierRatio = placeholder.peakContrast(in: cell.searchButtonRect(forBounds: field.bounds), background: background)
        #expect(magnifierRatio >= 3, "Magnifier contrast: \(magnifierRatio):1")
        print("POPUP_SEARCH_PLACEHOLDER \(surface) dark=\(dark) white=\(white) solid=\(solid) placeholder=\(placeholderRatio) magnifier=\(magnifierRatio)")
        #expect(typedRatio > placeholderRatio, "Typed contrast \(typedRatio) must exceed placeholder contrast \(placeholderRatio)")
        #expect(materialRatio > placeholderRatio)
        #expect(placeholderRatio >= 4.5, "\(surface) dark=\(dark) white=\(white): placeholder \(placeholderRatio):1")
        if let directory = ProcessInfo.processInfo.environment["BT_PANEL_PIXEL_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try typed.write(to: folder.appendingPathComponent("\(surface.rawValue)-\(dark ? "dark" : "light")-\(white ? "white" : "black")-\(solid ? "solid" : "glass")-typed.png"))
            try material.write(to: folder.appendingPathComponent("\(surface.rawValue)-\(dark ? "dark" : "light")-\(white ? "white" : "black")-\(solid ? "solid" : "glass")-material.png"))
            try selected.write(to: folder.appendingPathComponent("\(surface.rawValue)-\(dark ? "dark" : "light")-\(white ? "white" : "black")-\(solid ? "solid" : "glass")-selected.png"))
            try placeholder.write(to: folder.appendingPathComponent("\(surface.rawValue)-\(dark ? "dark" : "light")-\(white ? "white" : "black")-\(solid ? "solid" : "glass")-placeholder.png"))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func searchPlaceholderOpacityIsTheLowestPassingPercent(dark: Bool, solid: Bool) async throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }
        let scene = try await GlassPopupScene.make(.panePicker, dark: dark, reduceTransparency: solid)
        defer { scene.close() }
        let field = try #require(panelViews(scene.root, NSSearchField.self).first)
        let glass = try #require(panelViews(scene.root, OverlayGlassView.self).first)
        let cell = try #require(field.cell as? ApplicationPickerSearchCell)
        field.window?.makeFirstResponder(nil)
        var label: NSColor!
        appearance.performAsCurrentDrawingAppearance { label = NSColor.labelColor.usingColorSpace(.sRGB) }
        let original = try #require(field.placeholderAttributedString)
        let rect = cell.searchTextRect(forBounds: field.bounds)
        let ink = NSRect(x: rect.minX + 2, y: field.bounds.midY - 5, width: 50, height: 10)
        #expect(PickerText.lightSearchPlaceholderOpacity == 0.64)
        #expect(PickerText.darkSearchPlaceholderOpacity == 0.54)
        let chosen = dark ? PickerText.darkSearchPlaceholderOpacity : PickerText.lightSearchPlaceholderOpacity
        for opacity in [chosen - 0.01, chosen] {
            let placeholder = NSMutableAttributedString(attributedString: original)
            placeholder.addAttribute(.foregroundColor, value: label.withAlphaComponent(label.alphaComponent * opacity),
                                     range: NSRange(location: 0, length: placeholder.length))
            field.placeholderAttributedString = placeholder
            let pixels = try SearchFieldPixels(field, root: try #require(glass.popupContent), white: !dark)
            let background = pixels.pixel(NSPoint(x: rect.maxX - 12, y: field.bounds.midY))
            let contrast = pixels.peakContrast(in: ink, background: background)
            if opacity == chosen { #expect(contrast >= 4.5) }
            else { #expect(contrast < 4.5, "The next lower opacity already passes") }
            print("PLACEHOLDER_CALIBRATION dark=\(dark) solid=\(solid) opacity=\(opacity) alpha=\(label.alphaComponent * opacity) contrast=\(contrast)")
        }
    }
}

@MainActor private struct SearchFieldPixels {
    let context: CGContext
    let scale = 4.0
    let flipped: Bool
    let height: CGFloat

    init(_ field: NSSearchField, root: NSView, white: Bool) throws {
        flipped = field.isFlipped
        height = field.bounds.height
        context = try #require(CGContext(data: nil, width: Int(field.bounds.width * scale),
            height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor((white ? NSColor.white : NSColor.black).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        if root.isFlipped {
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
        }
        let rect = field.convert(field.bounds, to: root)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.clip(to: rect)
        let graphics = NSGraphicsContext(cgContext: context, flipped: root.isFlipped)
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.displayIgnoringOpacity(root.bounds, in: graphics)
        }
    }

    func pixel(_ point: NSPoint) -> [Double] {
        let x = min(context.width - 1, max(0, Int(point.x * scale)))
        let y = min(context.height - 1, max(0, Int((flipped ? point.y : height - point.y) * scale)))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (0..<3).map { Double(bytes[offset + $0]) / 255 }
    }

    func peakContrast(in rect: NSRect, background: Self) -> Double {
        var ratio = 1.0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let point = NSPoint(x: Double(x) / scale, y: Double(y) / scale)
                let ink = Self.luminance(pixel(point))
                let backdrop = Self.luminance(background.pixel(point))
                ratio = max(ratio, (max(ink, backdrop) + 0.05) / (min(ink, backdrop) + 0.05))
            }
        }
        return ratio
    }

    func peakContrast(in rect: NSRect, background: [Double]) -> Double {
        var ratio = 1.0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                ratio = max(ratio, Self.contrast(pixel(NSPoint(x: Double(x) / scale, y: Double(y) / scale)), background))
            }
        }
        return ratio
    }

    func ink(in rect: NSRect, dark: Bool) -> [Double] {
        var result = pixel(rect.origin)
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let candidate = pixel(NSPoint(x: Double(x) / scale, y: Double(y) / scale))
                if dark ? Self.luminance(candidate) > Self.luminance(result) : Self.luminance(candidate) < Self.luminance(result) {
                    result = candidate
                }
            }
        }
        return result
    }

    func dominantColor(in rect: NSRect) -> [Double] {
        var histogram: [[UInt8]: Int] = [:]
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let rgb = pixel(NSPoint(x: Double(x) / scale, y: Double(y) / scale)).map { UInt8(($0 * 255).rounded()) }
                histogram[rgb, default: 0] += 1
            }
        }
        return histogram.max { $0.value < $1.value }!.key.map { Double($0) / 255 }
    }

    static func contrast(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let a = luminance(lhs), b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func luminance(_ rgb: [Double]) -> Double {
        let c = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
    }

    func write(to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
