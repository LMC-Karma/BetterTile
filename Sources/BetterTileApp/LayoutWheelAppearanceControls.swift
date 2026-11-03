// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

struct LayoutWheelAppearanceControls: View {
    @Binding var appearance: LayoutWheelAppearance
    @State private var snapshots = LayoutWheelStyleSnapshots()
    @Environment(\.colorScheme) private var colorScheme
    let openFineTuning: () -> Void

    init(appearance: Binding<LayoutWheelAppearance>, snapshots: LayoutWheelStyleSnapshots = .init(),
         openFineTuning: @escaping () -> Void) {
        _appearance = appearance
        _snapshots = State(initialValue: snapshots)
        self.openFineTuning = openFineTuning
    }

    var body: some View {
        SettingsGroup("Wheel appearance") {
            VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
                HStack {
                    Text("Style").font(SettingsFont.headline)
                    Spacer()
                    if appearance.liquid.isModified { Text("Modified").foregroundStyle(.secondary) }
                }
                HStack(spacing: SettingsSpacing.s3) {
                    ForEach(LayoutWheelLiquidSettings.Preset.allCases, id: \.self) { preset in
                        PictureChoice(preset.title, detail: preset.detail, isSelected: appearance.liquid.preset == preset,
                            thumbnailHeight: 72, action: { appearance.liquid.selectPreset(preset) }) {
                                LayoutWheelStylePicture(preset: preset, size: appearance.size, snapshots: snapshots)
                            }.wheelControlBounds(.style(preset))
                    }
                }
            }.padding(SettingsSpacing.s3)
            SettingsRow("Appearance", caption: "Independent of Settings appearance.") {
                Picker("Appearance", selection: Binding(
                    get: { appearance.liquid.appearance }, set: { appearance.selectAppearance($0) })) {
                    ForEach(LayoutWheelLiquidSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize().wheelControlBounds(.appearance)
            }
            VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
                Text("Size").font(SettingsFont.headline)
                HStack(spacing: SettingsSpacing.s3) {
                    ForEach(LayoutWheelSize.allCases, id: \.self) { size in
                        PictureChoice(size.title, isSelected: appearance.size == size, thumbnailHeight: 50,
                                      action: { appearance.size = size }) {
                            Circle().strokeBorder(.secondary, lineWidth: 8 * size.scale)
                                .frame(width: 34 * size.scale, height: 34 * size.scale)
                        }
                    }
                }
            }.padding(SettingsSpacing.s3)
            Button(action: openFineTuning) {
                HStack(spacing: SettingsSpacing.s3) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(SettingsColor.purple)
                        .font(.system(size: 20)).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: SettingsSpacing.s1) {
                        Text("Fine-Tuning…").font(SettingsFont.headline)
                        Text("Look, motion, feel and sub-menus").font(SettingsFont.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.padding(SettingsSpacing.s3).contentShape(Rectangle())
            }.buttonStyle(.plain).wheelControlBounds(.fineTuning)
        } footer: {
            HStack(alignment: .top, spacing: SettingsSpacing.s3) {
                HelpText("Style changes restore its fine-tuning defaults. Appearance and Size stay independent.")
                Spacer(minLength: SettingsSpacing.s2)
                Button("Reset appearance") { appearance.resetLiquidAppearance() }.buttonStyle(.link).fixedSize().wheelControlBounds(.resetAppearance)
            }.padding(.horizontal, SettingsSpacing.s1)
        }.task(id: "\(colorScheme)-\(appearance.size)-\(snapshots.isActive)") {
            await snapshots.load(dark: colorScheme == .dark, size: appearance.size)
        }.background(LayoutWheelSnapshotLifetime(snapshots: snapshots).frame(width: 0, height: 0))
            .onDisappear { snapshots.removeAll() }
    }
}

extension LayoutWheelAppearance {
    /// Restore System appearance for both renderers while retaining every legacy strength.
    mutating func resetLiquidAppearance() {
        liquid = .init()
        selectAppearance(.system)
        size = .medium
    }
}

/// Cached real renderer images; the illustration remains a no-Metal fallback.
struct LayoutWheelStylePicture: View {
    let preset: LayoutWheelLiquidSettings.Preset
    var size: LayoutWheelSize = .medium
    var snapshots: LayoutWheelStyleSnapshots
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        switch preset {
        case .ice: Color(nsColor: LayoutWheelLiquidDefaults.iceBlue)
        case .warm: Color(red: 0.93, green: 0.77, blue: 0.53)
        case .frosted: colorScheme == .dark ? .white : Color(white: 0.78)
        case .mono: .white
        }
    }
    var body: some View {
        if let image = snapshots.image(preset: preset, dark: colorScheme == .dark, size: size) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    HStack(spacing: SettingsSpacing.s1) {
                        RoundedRectangle.settings(SettingsRadius.mini).fill(SettingsColor.teal.opacity(0.25))
                        RoundedRectangle.settings(SettingsRadius.mini).fill(SettingsColor.purple.opacity(0.2))
                    }.padding(SettingsSpacing.s2).background(SettingsColor.fill)
                }.clipShape(.settings(SettingsRadius.inner))
        } else { approximation }
    }
    private var approximation: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) * 0.8
            ZStack {
                SettingsColor.fill
                HStack(spacing: SettingsSpacing.s1) {
                    RoundedRectangle.settings(SettingsRadius.mini).fill(SettingsColor.teal.opacity(0.25))
                    RoundedRectangle.settings(SettingsRadius.mini).fill(SettingsColor.purple.opacity(0.2))
                }.padding(SettingsSpacing.s2)
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
                    .overlay {
                        Circle().fill(RadialGradient(colors: [tint.opacity(preset == .frosted ? 0.7 : preset == .mono ? 0.18 : 0.32), tint.opacity(0)], center: .center, startRadius: 0, endRadius: side * 0.4))
                            .frame(width: side * 0.8, height: side * 0.8)
                            .offset(x: side * 0.23)
                    }
                    .overlay {
                        if preset == .mono && colorScheme == .light {
                            Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1).blur(radius: 2)
                                .frame(width: side * 0.65, height: side * 0.7).offset(x: side * 0.23)
                        }
                    }
                    .overlay { Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5) }
                    .overlay {
                        ForEach(0..<8) { index in
                            Image(systemName: index == 2 ? "display" : "rectangle.split.2x2")
                                .font(.system(size: max(5, side * 0.085)))
                                .offset(y: -side * 0.36).rotationEffect(.degrees(Double(index) * 45))
                        }
                    }
                    .overlay {
                        Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: side * 0.36, height: side * 0.36)
                            .overlay(Image(systemName: "xmark").font(.system(size: max(5, side * 0.08))).foregroundStyle(.secondary))
                    }
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            }.clipShape(.settings(SettingsRadius.inner))
        }
    }
}

/// Layout anchors let offscreen tests locate controls without depending on row sizes.
enum LayoutWheelSettingsControl: Hashable {
    case style(LayoutWheelLiquidSettings.Preset)
    case appearance, fineTuning, resetAppearance, resetStyleDefaults, playPreview
}

struct LayoutWheelSettingsControlBounds: PreferenceKey {
    static var defaultValue: [LayoutWheelSettingsControl: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [LayoutWheelSettingsControl: Anchor<CGRect>],
                       nextValue: () -> [LayoutWheelSettingsControl: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func wheelControlBounds(_ control: LayoutWheelSettingsControl) -> some View {
        anchorPreference(key: LayoutWheelSettingsControlBounds.self, value: .bounds) { [control: $0] }
    }
}

private struct LayoutWheelSnapshotLifetime: NSViewRepresentable {
    let snapshots: LayoutWheelStyleSnapshots
    func makeNSView(context: Context) -> Host { Host(snapshots: snapshots) }
    func updateNSView(_ view: Host, context: Context) {}
    final class Host: NSView {
        weak var snapshots: LayoutWheelStyleSnapshots?
        init(snapshots: LayoutWheelStyleSnapshots) { self.snapshots = snapshots; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); snapshots?.observe(window: window) }
    }
}
