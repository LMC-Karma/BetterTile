// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma
// Contains portions adapted from Vorssaint, Copyright (C) 2026 Vorssaint.

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

struct ZoneSettings: View {
    @Bindable var model: BetterTileModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedArea: SnapArea = .topLeft
    @State private var showsCustomActivation: Bool
    @State private var reachAdjustment: String?

    init(model: BetterTileModel, showsCustomActivation: Bool = false, reachAdjustment: String? = nil) {
        self.model = model
        _showsCustomActivation = State(initialValue: showsCustomActivation)
        _reachAdjustment = State(initialValue: reachAdjustment)
    }

    var body: some View {
        Form {
            Section {
                SettingsRow("Drag snapping", caption: "Hold Option (⌥) while dragging to skip snapping.") {
                    Toggle("Drag snapping", isOn: configurationBinding(\.snappingEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } footer: {
                Text("Your zone actions stay saved when Drag snapping is disabled.")
            }
            if !model.configuration.macOSTilingRecommendationAcknowledged {
                Section {
                    HStack(alignment: .top, spacing: SettingsSpacing.s3) {
                        Label("macOS tiling also reacts to drags. Turn it off if both previews appear.",
                              systemImage: "info.circle")
                            .font(SettingsFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: SettingsSpacing.s2)
                        Button("Desktop & Dock…") {
                            guard let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") else { return }
                            NSWorkspace.shared.open(url)
                        }
                        Button("Dismiss") {
                            model.updateConfiguration { $0.macOSTilingRecommendationAcknowledged = true }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !model.configuration.snappingEnabled {
                Section {
                    HStack {
                        Label("Drag snapping is off. Edits stay saved until you turn it on.", systemImage: "info.circle")
                            .font(SettingsFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Turn On") { model.updateConfiguration { $0.snappingEnabled = true } }
                    }
                }
            }
            Section {
                SnapZoneDiagram(selectedArea: $selectedArea, bindings: model.configuration.snapAreaBindings,
                                edgeWidth: activation.edge, cornerExtension: activation.cornerExtension)
                    .frame(minHeight: 360)
                HStack(alignment: .center, spacing: SettingsSpacing.s4) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedArea.title).font(.headline)
                        Text(selectedAction.map { "Window placement: \($0.title)" } ?? "Disabled")
                            .font(SettingsFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Action for \(selectedArea.title)", selection: snapActionBinding(selectedArea)) {
                        Label("Disabled", systemImage: "minus.rectangle").tag(nil as WindowAction?)
                        ForEach(WindowAction.snapAssignableActions) { action in
                            Label { Text(action.title) } icon: { WindowActionGlyph.image(for: action) }
                                .tag(Optional(action))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
            } header: {
                HStack {
                    Text("Screen edge actions")
                    Spacer()
                    Button("Reset to Default") {
                        model.updateConfiguration { $0.snapAreaBindings = BetterTileConfiguration.defaultSnapAreaBindings }
                    }
                }
            } footer: {
                Text("Assignments apply across displays. Hold Option (⌥) while dragging to skip snapping. The accent marker shows where to drag. The window shows the resulting placement.")
            }
            activationControls
            Section("Window top") {
                Toggle("Double-click the top of a window to maximize or restore",
                       isOn: configurationBinding(\.doubleClickTitleBarToMaximize))
                Text("Choose Maximize in System Settings › Desktop & Dock for native handling, or Do Nothing to let BetterTile provide maximize and restore.")
                    .font(SettingsFont.caption)
                    .foregroundStyle(.secondary)
            }
            StatusMessage(model: model)
        }
        .modifier(SettingsFormPresentation())
    }

    private var activation: SnapZoneActivation {
        .init(edge: model.configuration.snapEdgeActivationDistance,
              cornerExtension: model.configuration.snapCornerActivationSize)
    }

    private var selectedPreset: SnapZonePreset? {
        showsCustomActivation ? nil : SnapZonePreset.matching(activation)
    }

    private var activationControls: some View {
        Section {
            SettingsRow("Activation area", caption: "Edge width · corner reach. Same on every display.") {
                HStack(alignment: .top, spacing: SettingsSpacing.s2) {
                    ForEach(SnapZonePreset.allCases) { preset in
                        PictureChoice(preset.title,
                                      detail: "\(preset.activation.edge.formatted()) pt · \(preset.activation.reach.formatted()) pt",
                                      isSelected: selectedPreset == preset, action: {
                            showsCustomActivation = false
                            reachAdjustment = nil
                            setActivation(preset.activation)
                        }) { SnapActivationThumbnail(preset: preset) }
                    }
                    PictureChoice("Custom", detail: "\(activation.edge.formatted()) pt · \(activation.reach.formatted()) pt",
                                  isSelected: selectedPreset == nil, action: {
                        showsCustomActivation = true
                        reachAdjustment = nil
                    }) { SnapActivationThumbnail(preset: nil) }
                }
                .frame(width: 344)
                .padding(.vertical, SettingsSpacing.s2)
            }
            if selectedPreset == nil {
                VStack(spacing: 0) {
                    StepperRow("Edge width", caption: "How close to a display edge the pointer must be. 1 to 40 pt.",
                               value: Binding(get: { activation.edge }, set: { changeEdge($0) }),
                               in: SnapZoneDetector.edgeActivationRange, unit: "pt")
                    Divider().padding(.horizontal, SettingsSpacing.s3)
                    StepperRow("Corner reach", caption: reachCaption,
                               value: Binding(get: { activation.reach }, set: {
                        showsCustomActivation = true
                        reachAdjustment = nil
                        setActivation(activation.settingReach($0))
                    }), in: activation.reachRange, unit: "pt")
                }
                .clipped()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        } footer: {
            Text("Choose Custom to adjust the edge width and corner reach. Settings apply live.")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedPreset == nil)
    }

    private var reachCaption: String {
        let range = activation.reachRange
        let caption = "From the display edge. \(range.lowerBound.formatted()) to \(range.upperBound.formatted()) pt (edge + 16 to edge + 160)."
        return reachAdjustment.map { caption + " " + $0 } ?? caption
    }

    private func changeEdge(_ edge: Double) {
        showsCustomActivation = true
        let previous = activation
        let next = previous.settingEdge(edge)
        reachAdjustment = next.reach == previous.reach ? nil
            : "Reach \(next.reach > previous.reach ? "rose" : "fell") to \(next.reach.formatted()) pt."
        setActivation(next)
    }

    private func setActivation(_ value: SnapZoneActivation) {
        model.updateConfiguration {
            $0.snapEdgeActivationDistance = value.edge
            $0.snapCornerActivationSize = value.cornerExtension
        }
    }

    private var selectedAction: WindowAction? {
        model.configuration.snapAreaBindings.first(where: { $0.area == selectedArea })?.action
    }

    private func snapActionBinding(_ area: SnapArea) -> Binding<WindowAction?> {
        Binding(get: { model.configuration.snapAreaBindings.first(where: { $0.area == area })?.action }, set: { action in
            model.updateConfiguration { configuration in
                guard let index = configuration.snapAreaBindings.firstIndex(where: { $0.area == area }) else { return }
                configuration.snapAreaBindings[index].action = action
            }
        })
    }

    private func configurationBinding<Value>(_ keyPath: WritableKeyPath<BetterTileConfiguration, Value>) -> Binding<Value> {
        Binding(get: { model.configuration[keyPath: keyPath] }, set: { value in
            model.updateConfiguration { $0[keyPath: keyPath] = value }
        })
    }
}

private struct SnapActivationThumbnail: View {
    let preset: SnapZonePreset?

    var body: some View {
        GeometryReader { proxy in
            // Picture choices exaggerate the bands so each preset reads at a glance.
            let edge: CGFloat = preset == .narrow ? 2 : preset == .wide ? 12 : 5
            let reach: CGFloat = preset == .narrow ? 10 : preset == .wide ? 32 : 20
            ZStack {
                SettingsColor.indigo.opacity(0.18)
                SnapActivationBands(edge: edge, reach: reach, selectedArea: nil, dashed: preset == nil)
                if preset == nil {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 24))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(.settings(SettingsRadius.inner))
        }
        .accessibilityHidden(true)
    }
}

enum SnapZonePreviewGeometry {
    static let display = DisplaySnapshot(
        id: DisplayID(rawValue: "snap-zone-preview"),
        frame: BTRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: BTRect(x: 0, y: 0, width: 1600, height: 1000),
        isMain: true
    )
    static let window = WindowSnapshot(
        id: WindowID(rawValue: "snap-zone-preview"),
        processIdentifier: 0,
        frame: BTRect(x: 480, y: 300, width: 640, height: 400),
        displayID: display.id
    )

    static func placement(for action: WindowAction?) -> NormalizedRect? {
        guard let action,
              let frame = StandardActionEngine().targetFrame(
                  for: action,
                  window: window,
                  display: display
              )
        else { return nil }
        return NormalizedRect(frame: frame, in: display.visibleFrame)
    }

    static func marker(for area: SnapArea, in size: CGSize) -> CGRect {
        let corner: CGFloat = 22
        let edge: CGFloat = 7
        switch area {
        case .topLeft: return CGRect(x: 0, y: 0, width: corner, height: corner)
        case .topRight: return CGRect(x: size.width - corner, y: 0, width: corner, height: corner)
        case .bottomLeft: return CGRect(x: 0, y: size.height - corner, width: corner, height: corner)
        case .bottomRight: return CGRect(x: size.width - corner, y: size.height - corner, width: corner, height: corner)
        case .top: return CGRect(x: 20, y: 0, width: size.width - 40, height: edge)
        case .bottom: return CGRect(x: 20, y: size.height - edge, width: size.width - 40, height: edge)
        case .left: return CGRect(x: 0, y: 20, width: edge, height: size.height - 40)
        case .right: return CGRect(x: size.width - edge, y: 20, width: edge, height: size.height - 40)
        }
    }

    /// The band the Snap Zones diagram draws for one area.
    static func activationBand(
        for area: SnapArea, in size: CGSize, edgeWidth: Double, cornerExtension: Double
    ) -> CGRect {
        SnapActivationBands.diagram(width: size.width, edgeWidth: edgeWidth, cornerExtension: cornerExtension,
                                    selectedArea: nil)
            .band(for: area, in: size)
    }

    static func trigger(for area: SnapArea) -> NormalizedRect {
        switch area {
        case .topLeft: .init(x: 0, y: 0, width: 0.3, height: 0.36)
        case .top: .init(x: 0.3, y: 0, width: 0.4, height: 0.12)
        case .topRight: .init(x: 0.7, y: 0, width: 0.3, height: 0.36)
        case .left: .init(x: 0, y: 0.36, width: 0.12, height: 0.28)
        case .right: .init(x: 0.88, y: 0.36, width: 0.12, height: 0.28)
        case .bottomLeft: .init(x: 0, y: 0.64, width: 0.3, height: 0.36)
        case .bottom: .init(x: 0.3, y: 0.88, width: 0.4, height: 0.12)
        case .bottomRight: .init(x: 0.7, y: 0.64, width: 0.3, height: 0.36)
        }
    }
}

struct SnapZoneLayout {
    var width: CGFloat
    var isWide: Bool { width >= 620 }
    var columns: Int { width >= 300 ? 2 : 1 }
    var monitorWidth: CGFloat { max(1, min(480, isWide ? width - 280 : width)) }
    var height: CGFloat {
        monitorWidth / 1.6 + (isWide ? 156 : CGFloat(8 / columns) * 76 + 8) + 36
    }
}

private struct SnapZoneDiagram: View {
    @Binding var selectedArea: SnapArea
    let bindings: [SnapAreaBinding]
    let edgeWidth: Double
    let cornerExtension: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableWidth: CGFloat = 640

    var body: some View {
        GeometryReader { proxy in
            let layout = SnapZoneLayout(width: proxy.size.width)
            VStack(spacing: 16) {
                if layout.isWide {
                    Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            zoneControl(.topLeft).frame(width: 128)
                            zoneControl(.top).frame(width: layout.monitorWidth)
                            zoneControl(.topRight).frame(width: 128)
                        }
                        GridRow {
                            zoneControl(.left).frame(width: 128)
                            screen.frame(width: layout.monitorWidth, height: layout.monitorWidth / 1.6)
                            zoneControl(.right).frame(width: 128)
                        }
                        GridRow {
                            zoneControl(.bottomLeft).frame(width: 128)
                            zoneControl(.bottom).frame(width: layout.monitorWidth)
                            zoneControl(.bottomRight).frame(width: 128)
                        }
                    }
                } else {
                    screen.frame(width: layout.monitorWidth, height: layout.monitorWidth / 1.6)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: layout.columns), spacing: 8) {
                        ForEach(SnapArea.allCases) { zoneControl($0) }
                    }
                }
                HStack(spacing: 16) {
                    Label("Drag here", systemImage: "arrow.up.left")
                        .foregroundStyle(Color.accentColor)
                    Label("Window placement", systemImage: "rectangle")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: SnapZoneLayout(width: availableWidth).height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func select(_ area: SnapArea) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selectedArea = area }
    }

    private func zoneControl(_ area: SnapArea) -> some View {
        let assignedAction = assignment(for: area)
        return Button { select(area) } label: {
            HStack(spacing: 8) {
                if let assignedAction {
                    WindowActionGlyph(action: assignedAction)
                } else {
                    Image(systemName: "minus.rectangle")
                        .font(.system(size: 20))
                        .frame(width: 30, height: 26)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(area.shortTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text(assignedAction?.title ?? "Disabled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68,
                   alignment: area == .top || area == .bottom ? .center : .leading)
            .background(
                selectedArea == area ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle.settings(SettingsRadius.inner)
            )

        }
        .buttonStyle(SnapZoneButtonStyle(isSelected: selectedArea == area))
        .accessibilityLabel(area.title)
        .accessibilityValue(assignedAction?.title ?? "Disabled")
        .accessibilityAddTraits(selectedArea == area ? .isSelected : [])
    }

    private var screen: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let content = CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 14)
            ZStack(alignment: .topLeading) {
                RoundedRectangle.settings(SettingsRadius.inner)
                    .fill(.background.opacity(0.5))
                    .overlay(RoundedRectangle.settings(SettingsRadius.inner).stroke(.secondary.opacity(0.5), lineWidth: 1.5))

                if let action = assignment(for: selectedArea),
                   let placement = SnapZonePreviewGeometry.placement(for: action) {
                    RoundedRectangle.settings(SettingsRadius.mini)
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay(RoundedRectangle.settings(SettingsRadius.mini).stroke(.secondary.opacity(0.7), lineWidth: 1))
                        .overlay { WindowActionGlyph(action: action) }
                        .frame(width: content.width * placement.width, height: content.height * placement.height)
                        .offset(x: content.minX + content.width * placement.x,
                                y: content.minY + content.height * placement.y)
                        .allowsHitTesting(false)
                }

                SnapActivationBands.diagram(width: size.width, edgeWidth: edgeWidth, cornerExtension: cornerExtension,
                                            selectedArea: selectedArea)

                // Generous selection targets are separate from the small edge
                // markers. Neither changes the actual snap detector.
                ForEach(SnapArea.allCases) { area in
                    let trigger = SnapZonePreviewGeometry.trigger(for: area)
                    Button { select(area) } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: size.width * trigger.width, height: size.height * trigger.height)
                    .offset(x: size.width * trigger.x, y: size.height * trigger.y)
                    .accessibilityLabel("Select \(area.title)")
                    .accessibilityAddTraits(selectedArea == area ? .isSelected : [])
                }
            }
            .clipShape(.settings(SettingsRadius.inner))
            .overlay(alignment: .bottom) {
                Capsule().fill(.secondary).frame(width: size.width * 0.4, height: 2).offset(y: 6)
            }
        }
    }

    private func assignment(for area: SnapArea) -> WindowAction? {
        bindings.first(where: { $0.area == area })?.action
    }
}

/// Preserve the shipped selector surfaces while using the diagram's inner radius.
private struct SnapZoneButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle.settings(SettingsRadius.inner)
                    .fill(PanelSurface.card(for: scheme))
                    .overlay {
                        if isHovered || configuration.isPressed {
                            RoundedRectangle.settings(SettingsRadius.inner)
                                .fill(Color.accentColor.opacity(configuration.isPressed ? 0.2 : 0.08))
                        }
                    }
            }
            .overlay {
                RoundedRectangle.settings(SettingsRadius.inner)
                    .strokeBorder(isSelected || isHovered ? Color.accentColor :
                        PanelSurface.border(for: scheme, increaseContrast: contrast == .increased),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SnapActivationBands: View {
    let edge: CGFloat
    let reach: CGFloat
    let selectedArea: SnapArea?
    var dashed = false

    /// The diagram's bands at display scale. An edge band is at least 4 points thick so that it stays visible.
    static func diagram(
        width: CGFloat, edgeWidth: Double, cornerExtension: Double, selectedArea: SnapArea?
    ) -> Self {
        let scale = width / SnapZonePreviewGeometry.display.frame.size.width
        return Self(edge: max(4, edgeWidth * scale), reach: (edgeWidth + cornerExtension) * scale,
                    selectedArea: selectedArea)
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(SnapArea.allCases) { area in
                let rect = band(for: area, in: proxy.size)
                RoundedRectangle.settings(SettingsRadius.mini)
                    .fill(dashed ? Color.clear : Color.accentColor.opacity(opacity(for: area)))
                    .overlay {
                        if selectedArea == area {
                            RoundedRectangle.settings(SettingsRadius.mini)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        }
                        if dashed {
                            RoundedRectangle.settings(SettingsRadius.mini)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func opacity(for area: SnapArea) -> Double {
        if selectedArea == area { return 0.9 }
        let corner = ![SnapArea.top, .bottom, .left, .right].contains(area)
        if selectedArea == nil { return corner ? 0.35 : 0.8 }
        return corner ? 0.12 : 0.18
    }

    /// A corner is never thinner than the edge band beside it, as on a real display.
    func band(for area: SnapArea, in size: CGSize) -> CGRect {
        let limit = min(size.width, size.height) / 2
        let edge = min(limit, edge)
        let corner = min(limit, max(edge, reach))
        switch area {
        case .topLeft: return CGRect(x: 0, y: 0, width: corner, height: corner)
        case .topRight: return CGRect(x: size.width - corner, y: 0, width: corner, height: corner)
        case .bottomLeft: return CGRect(x: 0, y: size.height - corner, width: corner, height: corner)
        case .bottomRight: return CGRect(x: size.width - corner, y: size.height - corner, width: corner, height: corner)
        case .top: return CGRect(x: corner, y: 0, width: size.width - 2 * corner, height: edge)
        case .bottom: return CGRect(x: corner, y: size.height - edge, width: size.width - 2 * corner, height: edge)
        case .left: return CGRect(x: 0, y: corner, width: edge, height: size.height - 2 * corner)
        case .right: return CGRect(x: size.width - edge, y: corner, width: edge, height: size.height - 2 * corner)
        }
    }
}

private extension SnapArea {
    var shortTitle: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }
}
