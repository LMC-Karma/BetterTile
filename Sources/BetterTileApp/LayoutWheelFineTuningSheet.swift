// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import BetterTileMacOS
import SwiftUI

enum LayoutWheelFineTuningTab: String, CaseIterable {
    case look = "Look", motion = "Motion", feel = "Feel", submenus = "Sub-menus"
    var title: String { switch self { case .look: "Look"; case .motion: "Motion"; case .feel: "Feel"; case .submenus: "Sub-menus" } }
}

struct LayoutWheelFineTuningSheet: View {
    @Binding var appearance: LayoutWheelAppearance
    @Environment(\.dismiss) private var dismiss
    private var configuration: LayoutWheelConfiguration
    private var overlayAppearance: OverlayAppearance
    private var currentMode: LayoutMode
    @State private var playback: LayoutWheelPreviewPlayback?
    @State private var playbackGeneration = 0
    @State private var tab: LayoutWheelFineTuningTab

    init(appearance: Binding<LayoutWheelAppearance>, initialTab: LayoutWheelFineTuningTab = .look,
         configuration: LayoutWheelConfiguration = .init(style: .grouped, levelCount: .two),
         overlayAppearance: OverlayAppearance = .init(), currentMode: LayoutMode = .manual) {
        self.configuration = configuration
        self.overlayAppearance = overlayAppearance
        self.currentMode = currentMode
        _appearance = appearance
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsSpacing.s3) {
                Text("Fine-Tuning").font(SettingsFont.title)
                Spacer()
                Text("Style: \(appearance.liquid.preset.title)")
                if appearance.liquid.isModified { Text("Modified").foregroundStyle(.secondary) }
            }.padding(SettingsSpacing.s6)
            Picker("Fine-Tuning", selection: $tab) {
                ForEach(LayoutWheelFineTuningTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize().padding(.bottom, SettingsSpacing.s4)
            HStack(alignment: .top, spacing: SettingsSpacing.s4) {
                ScrollView {
                    tabContent.padding(.bottom, SettingsSpacing.s2)
                }.frame(maxWidth: .infinity)
                preview.frame(width: 200)
            }.padding(.horizontal, SettingsSpacing.s6).frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: SettingsSpacing.s3) {
                Button("Reset to style defaults") { appearance.liquid.resetToStyleDefaults() }
                    .wheelControlBounds(.resetStyleDefaults)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(SettingsSpacing.s4)
        }
        .font(SettingsFont.body)
        .frame(width: 760, height: 576)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .look:
            VStack(alignment: .leading, spacing: SettingsSpacing.s4) {
                SettingsGroup {
                    choice("Highlight color", selection: $appearance.liquid.look.highlightColour,
                           values: LayoutWheelLiquidSettings.HighlightColour.allCases, title: \.title)
                    choice("Names", selection: $appearance.liquid.look.names,
                           values: LayoutWheelLiquidSettings.Names.allCases, title: \.title)
                    SettingsRow("Action tint") {
                        Toggle("Action tint", isOn: $appearance.liquid.look.actionTint).labelsHidden().toggleStyle(.switch)
                    }
                } footer: {
                    HelpText("Action tint colors the highlight by the kind of action.")
                }
                SettingsGroup {
                    LayoutWheelLabelledSlider(title: "Light translucency", help: "How much of the backdrop shows in Light appearance.",
                        ends: ("Opaque", "Transparent"), value: $appearance.liquid.translucency.light)
                    LayoutWheelLabelledSlider(title: "Dark translucency", help: "How much of the backdrop shows in Dark appearance.",
                        ends: ("Opaque", "Transparent"), value: $appearance.liquid.translucency.dark)
                }
            }
        case .motion:
            SettingsGroup {
                motionChoice("Opening", selection: $appearance.liquid.motion.opening,
                             values: [.quick, .calm, .rise, .bloom], title: \.title)
                motionChoice("Closing", selection: $appearance.liquid.motion.closing,
                             values: LayoutWheelLiquidSettings.Closing.allCases, title: \.title)
                SettingsRow("Pointer lean", caption: "Let the wheel lean toward the pointer.") {
                    Toggle("Pointer lean", isOn: $appearance.liquid.motion.pointerLean).labelsHidden().toggleStyle(.switch)
                }
                LayoutWheelFeelSlider(control: .leanAmount, settings: $appearance.liquid)
                    .disabled(!appearance.liquid.motion.pointerLean)
            }
        case .feel:
            SettingsGroup {
                ForEach(LayoutWheelFeelControl.allCases.filter { $0 != .leanAmount }, id: \.self) { control in
                    LayoutWheelFeelSlider(control: control, settings: $appearance.liquid)
                }
            }
        case .submenus:
            SettingsGroup {
                choice("Arrangement", selection: $appearance.liquid.submenus.arrangement,
                       values: LayoutWheelLiquidSettings.Arrangement.allCases, title: \.title)
                SettingsRow("Keep sub-menu open", caption: "When the pointer leaves the wheel.") {
                    Picker("Keep sub-menu open", selection: $appearance.liquid.submenus.keepOpen) {
                        ForEach(LayoutWheelLiquidSettings.KeepOpen.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }.labelsHidden().frame(width: 170)
                }
            }
        }
    }

    private var preview: some View {
        var wheel = configuration
        wheel.appearance = appearance
        return VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
            LayoutWheelSettingsPreview(configuration: wheel, overlayAppearance: overlayAppearance,
                currentMode: currentMode, compact: true, playback: playback)
            Button { play(.opening) } label: { Label("Play opening", systemImage: "play.fill") }
                .help("Play opening").wheelControlBounds(.playPreview)
            HelpText("Play to feel the change.")
        }
    }

    private func play(_ motion: LayoutWheelPreviewPlayback.Motion) {
        playbackGeneration += 1
        playback = .init(generation: playbackGeneration, motion: motion)
    }

    private func choice<Value: Hashable>(_ label: String, selection: Binding<Value>, values: [Value],
                                         title: KeyPath<Value, String>) -> some View {
        SettingsRow(label) {
            Picker(label, selection: selection) {
                ForEach(values, id: \.self) { Text($0[keyPath: title]).tag($0) }
            }.labelsHidden().frame(width: 170)
        }
    }

    private func motionChoice<Value: Hashable>(_ label: String, selection: Binding<Value>,
                                               values: [Value], title: KeyPath<Value, String>) -> some View {
        SettingsRow(label) {
            Picker(label, selection: selection) {
                ForEach(values, id: \.self) { Text($0[keyPath: title]).tag($0) }
            }.labelsHidden().frame(width: 170)
            Button {
                play(label == "Opening" ? .opening : .closing)
            } label: { Label("Play", systemImage: "play.fill") }
                .help(label == "Opening" ? "Play opening" : "Play closing")
        }
    }
}

extension LayoutWheelLiquidSettings.Preset {
    var title: String { switch self { case .ice: "Ice"; case .warm: "Ember"; case .frosted: "Mist"; case .mono: "Clear" } }
    var detail: String { switch self {
        case .ice: "Cool blue glow"
        case .warm: "Warm gold, lively feel"
        case .frosted: "Soft white glow"
        case .mono: "Colorless highlight"
    } }
}
extension LayoutWheelLiquidSettings.Appearance {
    var title: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
}
extension LayoutWheelLiquidSettings.Material {
    var title: String { switch self { case .automatic: "Automatic"; case .frosted: "Frosted"; case .smoked: "Smoked"; case .clear: "Clear" } }
}
extension LayoutWheelLiquidSettings.HighlightColour {
    var title: String {
        switch self { case .iceBlue: "Ice"; case .champagne: "Ember"; case .violet: "Violet"
        case .smokeGrey: "Mist"; case .noHighlight: "None"; case .systemAccent: "System accent" }
    }
}
extension LayoutWheelLiquidSettings.Names {
    var title: String { switch self { case .centre: "In center"; case .underIcons: "Under icons"; case .hidden: "Hidden" } }
}
extension LayoutWheelLiquidSettings.Arrangement {
    var title: String { switch self { case .fan: "Fan"; case .cluster: "Cluster"; case .clusterAboveThree: "Cluster above 3" } }
}
extension LayoutWheelLiquidSettings.KeepOpen {
    var title: String { switch self { case .always: "Always"; case .withinGroupAngle: "Only near its group" } }
}

extension LayoutWheelLiquidSettings.Opening {
    var title: String { switch self { case .quick: "Fade In"; case .calm: "Zoom In"; case .rise: "Bounce In"; case .bloom: "Ripple In" } }
}
extension LayoutWheelLiquidSettings.Closing {
    var title: String { switch self { case .calm: "Fade Out"; case .quick: "Quick Fade Out"; case .sink: "Zoom Out" } }
}
extension LayoutWheelSize {
    var title: String { switch self { case .small: "Small"; case .medium: "Medium"; case .large: "Large" } }
}
