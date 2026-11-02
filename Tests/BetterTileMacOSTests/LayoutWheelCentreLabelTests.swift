import AppKit
import SwiftUI
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@MainActor @Suite(.macOSTestApplication, .serialized) struct LayoutWheelCentreLabelTests {
    private let scales = [0.8, 1.0, 1.2]
    private var commands: [LayoutWheelCommand?] {
        WindowAction.allCases.map { .windowAction($0) }
            + LayoutMode.allCases.map { .setMode($0) }
            + TabbedPreset.allCases.map { .chooseLayout($0) } + [.repairBento, nil]
    }
    private func input(style: LayoutWheelStyle = .custom, levels: LayoutWheelLevelCount = .two,
                       scale: Double = 1, worst: Bool = false) -> LayoutWheelSceneInput {
        var config = LayoutWheelConfiguration(style: style, levelCount: levels, scale: scale)
        if worst { config.innerSlots = Array(repeating: .windowAction(.bottomCenterSixth), count: 8) }
        return .init(configuration: config)
    }
    private func space(style: LayoutWheelStyle, levels: LayoutWheelLevelCount,
                       scale: Double, worst: Bool) -> LayoutWheelLabelSpace {
        let input = input(style: style, levels: levels, scale: scale, worst: worst)
        if style != .grouped || levels != .one { return .init(input) }
        // The one-ring Grouped presentation is not enabled by Core yet. Exercise
        // its label space with the fixed parents, without changing hit geometry.
        let boxes = LayoutWheelSector.allCases.map { sector in
            let group = LayoutWheelGroup.at(sector)
            let slot = LayoutWheelSlot(label: group.title, symbolName: group.symbolName,
                                      glyph: group.glyph(currentMode: .bento), isEmpty: false, isAvailable: true)
            let size = LayoutWheelLabelSpace.iconSize(slot, frame: 35 * scale, symbol: 18 * scale)
            let angle = sector.drawnCenterAngle.radians
            return CGRect(x: cos(angle) * 62 * scale - size.width * 1.08 / 2,
                          y: sin(angle) * 62 * scale - size.height * 1.08 / 2,
                          width: size.width * 1.08, height: size.height * 1.08)
        }
        let lenses = LayoutWheelSector.allCases.map { sector in
            let angle = sector.drawnCenterAngle.radians
            return LayoutWheelLabelSpace.Lens(center: CGPoint(x: cos(angle) * 62 * scale, y: sin(angle) * 62 * scale),
                                             radius: 19.5 * scale + 0.5)
        }
        return .init(scale: scale, wellRadius: 32 * scale, style: style,
                     levelCount: levels, iconBoxes: boxes, lenses: lenses)
    }
    private func names(style: LayoutWheelStyle) -> [(String, String?)] {
        if style == .custom { return commands.map { (LayoutWheelSlot(command: $0).label, nil) } }
        let parents = LayoutWheelSector.allCases.map { sector in
            let group = LayoutWheelGroup.at(sector)
            return (group.title, group.quickAction.map { LayoutWheelSlot(command: $0).label })
        }
        let leaves = LayoutWheelConfiguration.defaultInnerSlots
            + LayoutWheelSector.allCases.flatMap { LayoutWheelGroup.at($0).options.map(Optional.some) }
        return parents + leaves.map { (LayoutWheelSlot(command: $0).label, nil) }
    }

    private func permittedShorts(style: LayoutWheelStyle, levels: LayoutWheelLevelCount,
                                 scale: Double) -> Set<String> {
        guard style == .custom else { return [] }
        if levels == .one {
            return scale == 0.8 ? ["Move Tab to Previous Pane", "Bottom Right Quarter"] : []
        }
        if scale == 0.8 {
            return ["Move Tab to Previous Pane", "Move Tab to Next Pane", "Bottom Right Quarter",
                    "Bottom Center Sixth", "Bottom Left Quarter", "Top Center Sixth", "Bottom Right Sixth"]
        }
        return scale == 1 ? ["Move Tab to Previous Pane", "Move Tab to Next Pane"] : ["Move Tab to Previous Pane"]
    }

    @Test func everyCatalogNameFitsWithoutTruncation() {
        var records: [[String: Any]] = []
        for style in [LayoutWheelStyle.custom, .grouped] {
            for levels in [LayoutWheelLevelCount.one, .two] {
                for scale in scales {
                    for worst in [false, true] {
                        let space = space(style: style, levels: levels, scale: scale, worst: worst)
                        for (name, main) in names(style: style) {
                            let label = LayoutWheelCentreLabel(name: name, mainAction: main, space: space)
                            #expect(label.placement != .truncated,
                                "\(style) \(levels) \(scale) worst=\(worst): \(name), limit \(space.tagWidthLimit(height: label.height + 6 * scale)), width \(label.width)")
                            if label.usedShortName {
                                #expect(permittedShorts(style: style, levels: levels, scale: scale).contains(name))
                            }
                            #expect(label.lines.count <= 3)
                            if label.lines.count == 3 {
                                #expect(label.placement == .well && !label.usedShortName)
                                #expect(label.lines.allSatisfy { $0.fontSize == max(10, 11 * scale) && $0.height == max(12, 13 * scale) })
                            }
                            records.append(["style": style.rawValue, "levels": levels.rawValue, "scale": scale,
                                "worst": worst, "name": name, "main": main ?? "", "placement": String(describing: label.placement),
                                "short": label.usedShortName, "lines": label.lines.map(\.text), "font": label.lines.map(\.fontSize)])
                            #expect(!label.lines.contains { $0.text.contains("…") })
                            #expect(space.fits(label.lines, in: label.placement))
                        }
                    }
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["BT_WHEEL_FIT_SNAPSHOT"] {
            try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func strokedPartitionBoundsUseTheRenderedIcon() throws {
        let slot = LayoutWheelSlot(command: .windowAction(.bottomCenterSixth))
        let frame = 35.0 / 18 * 16
        let measured = LayoutWheelLabelSpace.iconSize(slot, frame: frame, symbol: 16)
        let renderer = ImageRenderer(content: LayoutWheelIcon(slot: slot, tint: .white, fontSize: 16)
            .frame(width: frame, height: frame).scaleEffect(1.08).padding(8))
        renderer.scale = 4
        let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        var minX = image.pixelsWide, maxX = 0
        for y in 0..<image.pixelsHigh {
            // Measure the stroke's 50% coverage contour. A scaled template
            // mask also has a faint filtering fringe outside the ink box.
            for x in 0..<image.pixelsWide where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        let width = Double(maxX - minX + 1) / 4
        #expect(abs(width - measured.width * 1.08) < 0.5)
        // Include the visible stroke, rather than using only the path's frame.
        let drawing = try #require(WindowActionPartitionGlyph.actions[.bottomCenterSixth])
            .drawing(pointSize: 16, weight: .semibold, displayScale: 2)
        #expect(measured == drawing.inkBounds.size)
        #expect(measured.width > drawing.frame.width)
    }

    @Test func fullNameUsesWellBeforeCompactAndTagBeforeShortening() {
        let space = LayoutWheelLabelSpace(input())
        let one = LayoutWheelCentreLabel(name: "Left Half", space: space)
        #expect(one.placement == .well && one.lines.count == 1 && one.lines[0].fontSize == 11)
        let two = LayoutWheelCentreLabel(name: "Left Two Thirds", space: space)
        #expect(two.placement == .well && two.lines.count == 2 && two.lines[0].fontSize == 11)
        let three = LayoutWheelCentreLabel(name: "Bottom Left Quarter", space: space)
        #expect(three.placement == .well && three.lines.map(\.text) == ["Bottom", "Left", "Quarter"])
        let tag = LayoutWheelCentreLabel(name: "Almost Maximize", space: .init(input(scale: 0.8)))
        #expect(tag.placement == .tag && !tag.usedShortName)
        let short = LayoutWheelCentreLabel(name: "Move Tab to Previous Pane", space: space)
        #expect(short.usedShortName && short.lines.map(\.text).joined(separator: " ") == "To Prev. Pane")
        // Unknown future names reach a detectable fallback rather than silently
        // pretending that an oversized measured line fits.
        let future = LayoutWheelCentreLabel(name: String(repeating: "W", count: 100), space: space)
        #expect(future.placement == .truncated)
    }

    @Test func shortNamesStayWithinTheirAllowedConfigurations() {
        let allowed = ["Move Tab to Previous Pane", "Move Tab to Next Pane", "Bottom Right Quarter",
                       "Bottom Center Sixth", "Bottom Left Quarter", "Top Center Sixth", "Bottom Right Sixth"]
        for style in [LayoutWheelStyle.custom, .grouped] {
            for levels in [LayoutWheelLevelCount.one, .two] {
                for scale in scales {
                    let space = space(style: style, levels: levels, scale: scale, worst: true)
                    for (name, _) in names(style: .custom) {
                        let alias = space.shortName(for: name)
                        if alias != nil {
                            #expect(style == .custom && allowed.contains(name))
                            switch name {
                            case "Move Tab to Previous Pane", "Bottom Right Quarter":
                                #expect(levels == .two || scale == 0.8)
                            case "Bottom Center Sixth": #expect(levels == .two)
                            case "Move Tab to Next Pane": #expect(levels == .two && scale <= 1)
                            default: #expect(levels == .two && scale == 0.8)
                            }
                        }
                        let label = LayoutWheelCentreLabel(name: name, space: space)
                        if label.usedShortName { #expect(alias != nil) }
                    }
                }
            }
        }
        #expect(LayoutWheelLabelSpace(input()).shortName(for: "Almost Maximize") == nil)
    }

    @Test func realFontsBalancedLinesAndCircularMargins() throws {
        for scale in scales {
            let space = LayoutWheelLabelSpace(input(scale: scale))
            for (name, main) in names(style: .custom) + names(style: .grouped) {
                let label = LayoutWheelCentreLabel(name: name, mainAction: main, space: space)
                for line in label.lines {
                    #expect(line.fontSize >= 9)
                    #expect(abs(line.font.pointSize - line.fontSize) < 0.001)
                    #expect(abs(line.width - (line.text as NSString).size(withAttributes: [.font: line.font]).width) < 0.001)
                }
                if label.placement == .well {
                    var y = -label.height / 2
                    for line in label.lines {
                        #expect(hypot(line.width / 2, max(abs(y), abs(y + line.height))) <= space.wellRadius - 2 * scale + 0.001)
                        y += line.height
                    }
                }
            }
            let lines = try #require(LayoutWheelCentreLabel.balanced("Left Two Thirds", size: 11, height: 13))
            #expect(lines.map(\.text) == ["Left Two", "Thirds"])
            let widest = try #require(lines.map(\.width).max())
            let alternative = LayoutWheelCentreLabel.measured("Two Thirds", size: 11, height: 13)
            #expect(widest < alternative.width)
        }
    }

    @Test func tagCapsuleClearsHoveredIconBoxesAndJoinsTheWell() throws {
        var tags = 0
        var inkCache: [String: (pixels: [CGPoint], bounds: CGRect)] = [:]
        for style in [LayoutWheelStyle.custom, .grouped] {
            for levels in [LayoutWheelLevelCount.one, .two] {
                for scale in scales {
                    for worst in [false, true] {
                        let space = space(style: style, levels: levels, scale: scale, worst: worst)
                        for (name, main) in names(style: style) {
                            let label = LayoutWheelCentreLabel(name: name, mainAction: main, space: space)
                            if label.placement == .well {
                                // Font line boxes include leading. Check the actual
                                // rendered ink against the leaned icon boxes.
                                let key = label.lines.map { "\($0.text)|\($0.fontSize)|\($0.height)|\($0.secondary)" }.joined(separator: "\n")
                                let ink: (pixels: [CGPoint], bounds: CGRect)
                                if let cached = inkCache[key] { ink = cached }
                                else {
                                    let renderer = ImageRenderer(content: LayoutWheelLabelText(label: label)
                                        .foregroundStyle(.white).padding(4))
                                    renderer.scale = 4
                                    let raster = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                                    var pixels: [CGPoint] = []
                                    var bounds = CGRect.null
                                    for y in 0..<raster.pixelsHigh {
                                        for x in 0..<raster.pixelsWide where (raster.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                                            let pixel = CGPoint(x: (Double(x) + 0.5) / 4 - Double(raster.pixelsWide) / 8,
                                                                y: (Double(y) + 0.5) / 4 - Double(raster.pixelsHigh) / 8)
                                            pixels.append(pixel)
                                            // Enclose each sample strictly inside its 4x pixel footprint.
                                            bounds = bounds.union(CGRect(x: pixel.x - 0.125, y: pixel.y - 0.125,
                                                                         width: 0.25, height: 0.25))
                                        }
                                    }
                                    ink = (pixels, bounds)
                                    inkCache[key] = ink
                                }
                                #expect(!ink.pixels.isEmpty)
                                for direction in LayoutWheelSector.allCases {
                                    let angle = direction.drawnCenterAngle.radians
                                    let dx = cos(angle) * LayoutWheelDrawnMetrics.leanDistance * scale
                                    let dy = sin(angle) * LayoutWheelDrawnMetrics.leanDistance * scale
                                    for box in space.iconBoxes {
                                        let leaned = box.offsetBy(dx: dx, dy: dy)
                                        let clearance = leaned.insetBy(dx: -2 * scale - 0.125, dy: -2 * scale - 0.125)
                                        let hit = ink.bounds.intersects(clearance)
                                            && ink.pixels.contains { clearance.contains($0) }
                                        #expect(!hit,
                                            "\(name), \(style), \(levels), \(scale), \(direction)")
                                    }
                                }
                            }
                            guard label.placement == .tag else { continue }
                            tags += 1
                            let size = CGSize(width: label.width + 8 * scale, height: label.height + 6 * scale)
                            let tag = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
                            for box in space.iconBoxes {
                                #expect(!tag.intersects(box.insetBy(dx: -2 * scale + 0.001, dy: -2 * scale + 0.001)))
                            }
                            let rect = CGRect(x: -space.wellRadius, y: -space.wellRadius,
                                              width: space.wellRadius * 2, height: space.wellRadius * 2)
                            let shape = LayoutWheelWellShape(tagSize: size).path(in: rect)
                            #expect(shape.contains(.zero))
                            #expect(shape.contains(CGPoint(x: size.width / 2 - 0.1, y: 0)))
                            #expect(!shape.contains(CGPoint(x: size.width / 2, y: size.height / 2)))
                        }
                    }
                }
            }
        }
        #expect(tags > 0)
    }

    private func bitmap(_ input: LayoutWheelSceneInput, motion: LayoutWheelMotion = .init()) throws -> NSBitmapImageRep {
        let view = LayoutWheelGlassView(input: input, motion: motion, reduceMotion: true, reduceTransparency: true)
            .frame(width: input.diameter, height: input.diameter).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }
    private func brightest(_ image: NSBitmapImageRep, in rect: CGRect, center: Double) -> Double {
        var maximum = 0.0
        for y in Int((center + rect.minY) * 2)..<Int((center + rect.maxY) * 2) {
            for x in Int((center + rect.minX) * 2)..<Int((center + rect.maxX) * 2) {
                let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                maximum = max(maximum, color?.redComponent ?? 0)
            }
        }
        return maximum
    }

    @Test func restAndMainActionRenderInFullInkWithoutAHalo() throws {
        let rest = input()
        let raster = try bitmap(rest)
        let center = rest.diameter / 2
        // Neutral ink has equal channels; an accent-coloured cross fails this.
        var crossPixels = 0
        for y in Int((center - 12) * 2)..<Int((center - 2) * 2) {
            for x in Int((center - 8) * 2)..<Int((center + 8) * 2) {
                let color = try #require(raster.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent > 0.8 {
                    crossPixels += 1
                    #expect(abs(color.redComponent - color.blueComponent) < 0.01)
                    #expect(abs(color.redComponent - color.greenComponent) < 0.01)
                }
            }
        }
        #expect(crossPixels > 0)
        #expect(brightest(raster, in: CGRect(x: -20, y: 2, width: 40, height: 12), center: center) > 0.9)
        var parent = input(style: .grouped)
        parent.selection = .init(ring: .outer, sector: .top)
        let image = try bitmap(parent)
        #expect(brightest(image, in: CGRect(x: -25, y: 1, width: 50, height: 11), center: parent.diameter / 2) > 0.9)
        try writeCentreLabelFixtures()
        // Inspect the actual text view on transparency: no extra shadow pixels
        // can exist beyond its measured block.
        let label = LayoutWheelCentreLabel(name: "Left Half", space: .init(rest))
        let renderer = ImageRenderer(content: LayoutWheelLabelText(label: label).foregroundStyle(.white)
            .padding(10))
        renderer.scale = 2
        let text = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        for x in 0..<text.pixelsWide {
            for y in [0, 1, text.pixelsHigh - 2, text.pixelsHigh - 1] {
                #expect((text.colorAt(x: x, y: y)?.alphaComponent ?? 1) == 0)
            }
        }
    }

    @Test func renderedParentIncludesItsFullInkMainAction() throws {
        var input = input(style: .grouped)
        input.selection = .init(ring: .outer, sector: .top)
        let image = try bitmap(input)
        let reference = ImageRenderer(content: ZStack {
            Color(white: 0.12)
            VStack(spacing: 0) {
                Text("Size").font(Font(NSFont.systemFont(ofSize: 11, weight: .semibold))).frame(height: 13)
                Text("Maximize").font(Font(NSFont.systemFont(ofSize: 9.5, weight: .medium))).frame(height: 11.5)
            }.foregroundStyle(Color.white.opacity(0.94))
        }.frame(width: 64, height: 64))
        reference.scale = 2
        let expected = NSBitmapImageRep(cgImage: try #require(reference.cgImage))
        let offset = Int((input.diameter / 2 - 32) * 2)
        var inkPixels = 0
        for y in 40..<90 {
            for x in 12..<116 {
                let target = try #require(expected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let actual = try #require(image.colorAt(x: offset + x, y: offset + y)?.usingColorSpace(.sRGB))
                if target.redComponent > 0.8 {
                    inkPixels += 1
                    #expect(abs(target.redComponent - actual.redComponent) < 0.02)
                }
            }
        }
        #expect(inkPixels > 20)
    }

    @Test func unavailableKeepsLayoutAndMarkClearsEveryName() {
        for style in [LayoutWheelStyle.custom, .grouped] {
            for levels in [LayoutWheelLevelCount.one, .two] {
                for scale in scales {
                    for worst in [false, true] {
                        let space = space(style: style, levels: levels, scale: scale, worst: worst)
                        #expect(space.markSize == (scale == 0.8 ? 9 : 10 * scale))
                        #expect(abs(space.markFrame.minY - (-space.wellRadius + scale)) < 0.001)
                        for (name, main) in names(style: style) {
                            let label = LayoutWheelCentreLabel(name: name, mainAction: main, space: space)
                            let top = -label.height / 2 - (label.placement == .tag ? 3 * scale : 0)
                            #expect(top - space.markFrame.maxY >= scale - 0.001, "\(name) at \(scale)")
                        }
                    }
                }
            }
        }
        for command in commands.compactMap({ $0 }) {
            var available = input()
            available.configuration.innerSlots[0] = command
            available.selection = .init(ring: .inner, sector: .top)
            var unavailable = available
            unavailable.unavailableCommands = [command]
            let a = available.centreContent!, b = unavailable.centreContent!
            #expect(a.name == b.name && a.mainAction == b.mainAction && a.available && !b.available)
            #expect(LayoutWheelCentreLabel(name: a.name, space: .init(available))
                == LayoutWheelCentreLabel(name: b.name, space: .init(unavailable)))
        }
    }

    private func referenceInk(opacity: Double, background: Double) throws -> Double {
        let renderer = ImageRenderer(content: Color.white.opacity(opacity)
            .background(Color(white: background)).frame(width: 4, height: 4))
        let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        return try #require(image.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)).redComponent
    }

    @Test func unavailableTextIconAndMarkRenderAtTheirSpecifiedOpacity() throws {
        var available = input()
        available.configuration.innerSlots[LayoutWheelSector.right.rawValue] = .windowAction(.rightHalf)
        available.selection = .init(ring: .inner, sector: .right)
        var unavailable = available
        unavailable.unavailableCommands = [.windowAction(.rightHalf)]
        let a = try bitmap(available), b = try bitmap(unavailable)
        let center = available.diameter / 2
        let text = CGRect(x: -27, y: -6, width: 54, height: 12)
        let full = brightest(a, in: text, center: center), dim = brightest(b, in: text, center: center)
        #expect(full > dim)
        #expect(abs(dim - (try referenceInk(opacity: 0.94 * 0.6, background: 0.12))) < 0.02)
        let icon = CGRect(x: 40, y: -10, width: 20, height: 20)
        let fullIcon = brightest(a, in: icon, center: center), dimIcon = brightest(b, in: icon, center: center)
        #expect(fullIcon > dimIcon)
        #expect(abs(dimIcon - (try referenceInk(opacity: 0.94 * 0.35, background: 0.18))) < 0.02)
        let space = LayoutWheelLabelSpace(unavailable)
        #expect(brightest(b, in: space.markFrame, center: center) > 0.7)
    }

    @Test func unavailableParentDimsChevronAndUsesANeutralLens() throws {
        var input = input(style: .grouped)
        input.selection = .init(ring: .outer, sector: .topRight)
        input.unavailableCommands = Set(LayoutWheelGroup.at(.topRight).options)
        var motion = LayoutWheelMotion()
        motion.retarget(selection: input.selection, fan: input.fan, geometry: input.metrics.fanGeometry, reduceMotion: false)
        motion.snap()
        let image = try bitmap(input, motion: motion)
        let drawn = LayoutWheelDrawnMetrics(input)
        let point = drawn.iconPoint(input.selection!)
        let center = input.diameter / 2
        // A point inside the lens, clear of the symbol and outline.
        let x = Int((center + point.x - 10) * 2), y = Int((center + point.y - 8) * 2)
        let lens = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        #expect(abs(lens.redComponent - lens.greenComponent) < 0.03)
        #expect(abs(lens.redComponent - lens.blueComponent) < 0.03)
        let chevron = drawn.chevronPoint(.topRight)
        let rect = CGRect(x: chevron.x - 3, y: chevron.y - 3, width: 6, height: 6)
        var dim = 0.0
        for y in Int((center + rect.minY) * 2)..<Int((center + rect.maxY) * 2) {
            for x in Int((center + rect.minX) * 2)..<Int((center + rect.maxX) * 2)
                where hypot(Double(x) / 2 - center, Double(y) / 2 - center) > 145 {
                dim = max(dim, image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 0)
            }
        }
        let expected = try referenceInk(opacity: 0.94 * 0.5, background: 0.18)
        #expect(abs(dim - expected) < 0.03, "chevron \(dim) expected \(expected)")
    }

    private func writeCentreLabelFixtures() throws {
        guard let directory = ProcessInfo.processInfo.environment["BT_WHEEL_LABEL_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [[String: String]] = []
        for scale in scales {
            for scheme in [ColorScheme.dark, .light] {
                for glass in [false, true] {
                    for state in ["rest", "leaf", "wrap", "tag", "parent", "child", "unavailable", "short-pane", "short-fraction"] {
                        var input = input(levels: state == "leaf" ? .one : .two, scale: scale)
                        switch state {
                        case "rest": break
                        case "parent", "child":
                            input.configuration.style = .grouped
                            input.fan.update(vector: .init(x: 0, y: -124 * scale), at: 0, geometry: input.metrics.fanGeometry)
                            input.fan.update(vector: .init(x: 0, y: -124 * scale), at: 0.2, geometry: input.metrics.fanGeometry)
                            if state == "child" {
                                input.fan.update(vector: input.metrics.fanGeometry.point(sector: .top, option: 0),
                                                 at: 0.21, geometry: input.metrics.fanGeometry)
                            }
                            input.selection = input.fan.selection
                        default:
                            let command: LayoutWheelCommand
                            switch state {
                            case "leaf": command = .windowAction(.leftHalf)
                            case "wrap": command = .windowAction(.leftTwoThirds)
                            case "tag": command = .windowAction(.bottomLeftQuarter)
                            case "unavailable": command = .repairBento
                            case "short-pane": command = .windowAction(.moveTabToPreviousPane)
                            default: command = .windowAction(.bottomCenterSixth)
                            }
                            input.configuration.innerSlots[LayoutWheelSector.right.rawValue] = command
                            input.selection = .init(ring: .inner, sector: .right)
                            if state == "unavailable" { input.unavailableCommands = [command] }
                        }
                        var motion = LayoutWheelMotion()
                        motion.retarget(selection: input.selection, fan: input.fan,
                                        geometry: input.metrics.fanGeometry, reduceMotion: false,
                                        suppressLean: input.centreLabel?.placement == .tag)
                        motion.snap()
                        let renderer = ImageRenderer(content: LayoutWheelGlassView(input: input, motion: motion,
                            reduceTransparency: !glass)
                            .environment(\.colorScheme, scheme)
                            .environment(\.layoutWheelGlassStandIn, .init(
                                body: Color(white: scheme == .dark ? 0.22 : 0.72),
                                well: Color(white: scheme == .dark ? 0.12 : 0.9))))
                        renderer.scale = 2
                        let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                        let file = "\(state)-\(scale)-\(scheme)-\(glass ? "glass" : "solid").png"
                        try image.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(file))
                        let content = input.centreContent
                        let label = content.map { LayoutWheelCentreLabel(name: $0.name, mainAction: $0.mainAction, space: .init(input)) }
                        records.append(["file": file, "text": label?.lines.map(\.text).joined(separator: " / ") ?? "× / Cancel",
                                        "placement": label.map { String(describing: $0.placement) } ?? "rest"])
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("manifest.json"))
    }

    @Test func centreFollowsCoreParentThenChildAndDoesNotRedrawAtRest() throws {
        var input = input(style: .grouped)
        let geometry = input.metrics.fanGeometry
        let parentPoint = BTPoint(x: 0, y: -124)
        input.fan.update(vector: parentPoint, at: 0, geometry: geometry)
        input.selection = input.fan.selection
        #expect(input.centreContent?.name == "Size" && input.centreContent?.mainAction == "Maximize")
        input.fan.update(vector: parentPoint, at: 0.199, geometry: geometry)
        #expect(input.fan.openSector == nil && input.fan.optionIndex == nil)
        input.fan.update(vector: parentPoint, at: 0.2, geometry: geometry)
        #expect(input.fan.openSector == .top && input.fan.optionIndex == nil)
        #expect(input.centreContent?.name == "Size")
        let clock = WheelTestClock()
        let renderer = LayoutWheelGlassRenderer(clock: clock)
        defer { renderer.stop() }
        renderer.configure(input, reduceMotion: false)
        clock.settle()
        let frames = renderer.renderedFrameCount
        for _ in 0..<100 { renderer.configure(input, reduceMotion: false); clock.frame() }
        #expect(!clock.isRunning && renderer.renderedFrameCount == frames)
        let child = geometry.point(sector: .top, option: 0)
        input.fan.update(vector: child, at: 0.21, geometry: geometry)
        input.selection = input.fan.selection
        #expect(input.fan.optionIndex == 0)
        #expect(input.centreContent?.name == "Almost Maximize" && input.centreContent?.mainAction == nil)
        renderer.configure(input, reduceMotion: false)
        #expect(renderer.renderedFrameCount > frames)
        #expect(LayoutWheelFanState.restDuration == 0.2)
    }

    @Test(arguments: [60.0, 120.0])
    func tagEasesLeanToZeroAndOtherLabelsRestoreIt(hz: Double) throws {
        let clock = WheelTestClock()
        let renderer = LayoutWheelGlassRenderer(clock: clock)
        defer { renderer.stop() }
        var input = input(scale: 0.8)
        input.configuration.innerSlots[LayoutWheelSector.bottomLeft.rawValue] = .windowAction(.almostMaximize)
        input.selection = .init(ring: .inner, sector: .right)
        renderer.configure(input, reduceMotion: false)
        clock.settle(hz: hz)
        #expect(renderer.motion.lean.value == 1)
        let before = try #require(renderer.hosting?.rootView.lean)
        #expect(abs(hypot(before.x, before.y) - LayoutWheelDrawnMetrics.leanDistance * 0.8) < 0.001)
        input.selection = .init(ring: .inner, sector: .bottomLeft)
        #expect(input.centreLabel?.placement == .tag)
        renderer.configure(input, reduceMotion: false)
        #expect(renderer.motion.lean.target == 0 && renderer.motion.lean.value == 1)
        #expect(clock.isRunning)
        clock.frame(hz: hz)
        #expect(renderer.motion.lean.value > 0 && renderer.motion.lean.value < 1)
        clock.settle(hz: hz)
        #expect(renderer.hosting?.rootView.lean == .init(x: 0, y: 0))
        #expect(!clock.isRunning)
        let frames = renderer.renderedFrameCount
        for _ in 0..<100 { clock.frame(hz: hz); renderer.configure(input, reduceMotion: false) }
        #expect(renderer.renderedFrameCount == frames)
        input.selection = .init(ring: .inner, sector: .right)
        renderer.configure(input, reduceMotion: false)
        #expect(renderer.motion.lean.target == 1 && renderer.motion.lean.value == 0)
        clock.settle(hz: hz)
        #expect(renderer.motion.lean.value == 1 && !clock.isRunning)
        input.selection = .init(ring: .inner, sector: .bottomLeft)
        renderer.configure(input, reduceMotion: true)
        #expect(renderer.hosting?.rootView.lean == .init(x: 0, y: 0))
        #expect(renderer.motion.isAtRest && !clock.isRunning)
    }

    @Test func centrePresentationLeavesGeometryAndPlateFloorsUnchanged() throws {
        for scale in scales {
            let input = input(scale: scale)
            let before = input
            _ = LayoutWheelCentreLabel(name: "Bottom Right Quarter", space: .init(input))
            #expect(input == before)
            #expect(input.metrics.geometry.hubRadius == 32 * scale)
            #expect(input.metrics.geometry.innerRingOuterRadius == 68 * scale)
            #expect(input.metrics.geometry.outerRingInnerRadius == 76 * scale)
            #expect(input.metrics.outerRingOuterRadius == 110 * scale)
        }
        #expect(LayoutWheelGlassTreatment.plateFloor == 0.20)
        #expect(LayoutWheelGlassTreatment.wellPlateFloor == 0.47)
        let renderer = LayoutWheelGlassRenderer(clock: WheelTestClock())
        defer { renderer.stop() }
        renderer.configure(input(), reduceMotion: true)
        #expect(renderer.hitTest(.zero) == nil)
        let frames = renderer.renderedFrameCount
        for _ in 0..<100 { renderer.configure(input(), reduceMotion: true) }
        #expect(renderer.renderedFrameCount == frames)
    }
}
