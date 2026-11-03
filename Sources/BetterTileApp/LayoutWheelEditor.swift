import BetterTileCore
import BetterTileMacOS
import SwiftUI

/// Selection and edits belong to Settings, not the runtime gesture.
enum LayoutWheelEditorSelection: Equatable {
    case slot(LayoutWheelSelection)
    case group(LayoutWheelSector)
    case child(LayoutWheelSector, Int)

    var group: LayoutWheelSector? {
        switch self {
        case .slot: nil
        case let .group(sector), let .child(sector, _): sector
        }
    }

    func command(in wheel: LayoutWheelConfiguration) -> LayoutWheelCommand? {
        switch self {
        case let .slot(slot): wheel.command(at: slot)
        case let .group(sector): wheel.group(at: sector).quickAction
        case let .child(sector, index):
            wheel.group(at: sector).options.indices.contains(index) ? wheel.group(at: sector).options[index] : nil
        }
    }

    func assign(_ command: LayoutWheelCommand?, in wheel: inout LayoutWheelConfiguration) {
        switch self {
        case let .slot(slot):
            if wheel.style == .grouped {
                wheel.groupedInnerSlots[slot.sector.rawValue] = command
            } else if slot.ring == .inner {
                wheel.innerSlots[slot.sector.rawValue] = command
            } else {
                wheel.outerSlots[slot.sector.rawValue] = command
            }
        case let .group(sector):
            var contents = wheel.group(at: sector)
            contents.quickAction = command
            wheel.setGroup(contents, at: sector)
        case let .child(sector, index):
            var contents = wheel.group(at: sector)
            guard contents.options.indices.contains(index) else { return }
            contents.options[index] = command
            wheel.setGroup(contents, at: sector)
        }
    }

    mutating func moveChild(by offset: Int, in wheel: inout LayoutWheelConfiguration) {
        guard case let .child(sector, index) = self else { return }
        var group = wheel.group(at: sector)
        let next = index + offset
        guard group.options.indices.contains(index), group.options.indices.contains(next) else { return }
        group.options.swapAt(index, next)
        wheel.setGroup(group, at: sector)
        self = .child(sector, next)
    }

    mutating func addChild(in wheel: inout LayoutWheelConfiguration) {
        guard let sector = group else { return }
        var group = wheel.group(at: sector)
        guard group.options.count < LayoutWheelGroupContents.maximumChildren else { return }
        group.options.append(nil)
        wheel.setGroup(group, at: sector)
        self = .child(sector, group.options.count - 1)
    }

    mutating func removeChild(in wheel: inout LayoutWheelConfiguration) {
        guard case let .child(sector, index) = self else { return }
        var group = wheel.group(at: sector)
        guard group.options.indices.contains(index) else { return }
        group.options.remove(at: index)
        wheel.setGroup(group, at: sector)
        self = group.options.isEmpty ? .group(sector) : .child(sector, min(index, group.options.count - 1))
    }
}

/// Expanded editing geometry. Runtime fan positions stay in BetterTileCore.
struct LayoutWheelEditorDiagram: View {
    let wheel: LayoutWheelConfiguration
    let currentMode: LayoutMode
    let selection: LayoutWheelEditorSelection
    let allFans: Bool
    let expanded: Set<LayoutWheelSector>
    let select: (LayoutWheelEditorSelection) -> Void
    let toggleFan: (LayoutWheelSector) -> Void
    @State private var hovered: String?

    private let canvasSize = 640.0
    private var two: Bool { wheel.levelCount == .two }
    private var radius: Double { two ? 188 : 162 }
    private var parentRadius: Double { two ? 158 : 128 }

    var contentBounds: CGRect {
        guard !allFans else { return CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize) }
        // Include chevrons, the plate shadow, and each visible child's hit area.
        var top = canvasSize / 2 - radius - 32
        var bottom = canvasSize / 2 + radius + 32
        if wheel.style == .grouped {
            for sector in expanded {
                for index in wheel.group(at: sector).options.indices {
                    let child = childPoint(sector, index: index)
                    top = min(top, child.y - 36)
                    bottom = max(bottom, child.y + 36)
                }
            }
        }
        return CGRect(x: 0, y: top, width: canvasSize, height: bottom - top)
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / canvasSize
            ZStack {
                Circle().fill(SettingsColor.fillStrong)
                    .frame(width: radius * 2, height: radius * 2)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var lines = Path()
                    for sector in LayoutWheelSector.allCases {
                        let angle = Double(sector.rawValue) * .pi / 4 + .pi / 8
                        lines.move(to: CGPoint(x: center.x + sin(angle) * 62, y: center.y - cos(angle) * 62))
                        lines.addLine(to: CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius))
                    }
                    if two { lines.addEllipse(in: CGRect(x: center.x - 115, y: center.y - 115, width: 230, height: 230)) }
                    context.stroke(lines, with: .color(SettingsColor.separator.opacity(0.5)), lineWidth: 1)
                    for sector in expanded where wheel.style == .grouped {
                        for index in wheel.group(at: sector).options.indices {
                            var connector = Path()
                            connector.move(to: point(angle: Double(sector.rawValue) * 45, radius: radius + 25))
                            connector.addLine(to: childPoint(sector, index: index))
                            context.stroke(connector, with: .color(SettingsColor.separator.opacity(0.45)), lineWidth: 1)
                        }
                    }
                }
                .allowsHitTesting(false)
                ForEach(LayoutWheelSector.allCases, id: \.self) { sector in
                    sectorNodes(sector)
                }
                VStack(spacing: 5) {
                    Text(selection.group.map { LayoutWheelGroup.at($0).title } ?? "Layout Wheel")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(hovered ?? LayoutWheelSlot(command: selection.command(in: wheel)).label)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                .padding(10).frame(width: 124, height: 124)
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .allowsHitTesting(false)
            }
            .frame(width: canvasSize, height: canvasSize)
            .offset(y: -contentBounds.minY)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .aspectRatio(canvasSize / contentBounds.height, contentMode: .fit)
    }

    @ViewBuilder private func sectorNodes(_ sector: LayoutWheelSector) -> some View {
        let angle = Double(sector.rawValue) * 45
        if wheel.style == .custom {
            node(.slot(.init(ring: .inner, sector: sector)), at: point(angle: angle, radius: two ? 87 : 128))
            if two { node(.slot(.init(ring: .outer, sector: sector)), at: point(angle: angle, radius: 158)) }
        } else {
            if two { node(.slot(.init(ring: .inner, sector: sector)), at: point(angle: angle, radius: 87)) }
            node(.group(sector), at: point(angle: angle, radius: parentRadius))
            if !wheel.group(at: sector).options.isEmpty {
                Button { toggleFan(sector) } label: {
                    Image(systemName: expanded.contains(sector) ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .rotationEffect(.degrees(angle))
                .help("\(expanded.contains(sector) ? "Collapse" : "Expand") \(LayoutWheelGroup.at(sector).title)")
                .position(point(angle: angle, radius: radius + 15))
                if expanded.contains(sector) {
                    ForEach(wheel.group(at: sector).options.indices, id: \.self) { index in
                        node(.child(sector, index), at: childPoint(sector, index: index))
                    }
                }
            }
        }
    }

    private func node(_ item: LayoutWheelEditorSelection, at point: CGPoint) -> some View {
        let command = item.command(in: wheel)
        let label = item.group.map { LayoutWheelGroup.at($0).title } ?? LayoutWheelSlot(command: command).label
        let child: Bool = if case .child = item { true } else { false }
        return Button { select(item) } label: {
            ZStack {
                Circle().fill(child ? SettingsColor.controlBackground : Color.clear)
                Circle().stroke(selection == item ? Color.accentColor : (child ? SettingsColor.controlBorder : .clear),
                                lineWidth: selection == item ? 2 : 1)
                if case let .group(sector) = item {
                    let group = LayoutWheelGroup.at(sector)
                    VStack(spacing: 3) {
                        if let glyph = group.glyph(currentMode: currentMode) {
                            LayoutGlyphView(glyph, size: 28)
                        } else {
                            Image(systemName: group.symbolName).font(.system(size: 24, weight: .regular))
                        }
                        if !wheel.group(at: sector).options.isEmpty { Circle().frame(width: 4, height: 4) }
                    }
                } else {
                    LayoutWheelCommandIcon(command: command, size: child ? 28 : 24)
                }
            }
            .frame(width: child ? 48 : 46, height: child ? 48 : 46)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(child ? LayoutWheelSlot(command: command).label : label)
        .onHover { hovered = $0 ? (child ? LayoutWheelSlot(command: command).label : label) : nil }
        .position(point)
    }

    private func childPoint(_ sector: LayoutWheelSector, index: Int) -> CGPoint {
        let count = wheel.group(at: sector).options.count
        let angle = Double(sector.rawValue) * 45
        if allFans {
            let row = index / 3
            let rowCount = min(3, count - row * 3)
            return point(angle: angle + (Double(index % 3) - Double(rowCount - 1) / 2) * 14,
                         radius: (two ? 236 : 222) + Double(row) * 52)
        }
        return point(angle: angle + (Double(index) - Double(count - 1) / 2) * 17, radius: two ? 257 : 246)
    }

    private func point(angle: Double, radius: Double) -> CGPoint {
        CGPoint(x: canvasSize / 2 + sin(angle * .pi / 180) * radius,
                y: canvasSize / 2 - cos(angle * .pi / 180) * radius)
    }
}

struct LayoutWheelCommandIcon: View {
    let command: LayoutWheelCommand?
    var size: CGFloat = 16
    var body: some View {
        let slot = LayoutWheelSlot(command: command)
        Group {
            if let glyph = slot.glyph {
                LayoutGlyphView(glyph, size: size * 1.265)
            } else if case let .windowAction(action) = command {
                LayoutWheelActionGlyph(action: action, tint: .primary, fontSize: size)
            } else {
                Image(systemName: slot.symbolName).font(.system(size: size, weight: .regular))
            }
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

struct LayoutWheelCommandPicker: View {
    let choose: (LayoutWheelCommand?) -> Void
    @State private var query = ""

    static let commands: [LayoutWheelCommand?] = [nil]
        + LayoutWheelActionGroup.groupedActions.map { .windowAction($0) }
        + [.windowAction(.showTabBar), .repairBento]
        + LayoutMode.allCases.map { .setMode($0) }
        + TabbedPreset.allCases.map { .chooseLayout($0) }

    static func matches(_ query: String) -> [LayoutWheelCommand?] {
        commands.filter { query.isEmpty || LayoutWheelSlot(command: $0).label.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search commands", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.matches(query), id: \.self) { command in
                        Button { choose(command) } label: {
                            HStack(spacing: 10) {
                                LayoutWheelCommandIcon(command: command)
                                Text(LayoutWheelSlot(command: command).label)
                                Spacer(minLength: 0)
                            }
                            .padding(6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if Self.matches(query).isEmpty { Text("No commands match.").foregroundStyle(.secondary).padding(6) }
                }
            }
        }
        .padding(16).frame(width: 290, height: 330)
    }
}
