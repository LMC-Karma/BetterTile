// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import SwiftUI

/// Only the App layer translates plain slider directions into physical values.
enum LayoutWheelFeelControl: CaseIterable {
    case wobbleSpeed, wobbleLength, hoverSwell, pointerPull, ripples, snapBounce, submenuSpeed, leanAmount

    var title: String {
        switch self {
        case .wobbleSpeed: "Wobble speed"
        case .wobbleLength: "Wobble length"
        case .hoverSwell: "Hover swell"
        case .pointerPull: "Pointer pull"
        case .ripples: "Ripples"
        case .snapBounce: "Snap bounce"
        case .submenuSpeed: "Sub-menu speed"
        case .leanAmount: "Lean amount"
        }
    }
    var ends: (String, String) {
        switch self {
        case .wobbleSpeed, .submenuSpeed: ("Slow", "Fast")
        case .wobbleLength: ("Short", "Long")
        case .hoverSwell: ("None", "Big")
        case .pointerPull: ("None", "Far")
        case .ripples: ("Calm", "Lively")
        case .snapBounce: ("None", "Bouncy")
        case .leanAmount: ("Small", "Large")
        }
    }
    var help: String {
        switch self {
        case .wobbleSpeed: "How quickly the edge jiggles after you move."
        case .wobbleLength: "How long the edge keeps jiggling before it settles."
        case .hoverSwell: "How much the slot under the pointer bulges out."
        case .pointerPull: "How far the edge reaches toward the pointer when you move outside."
        case .ripples: "How strongly the edge ripples on arrival, release and sub-menu pop."
        case .snapBounce: "How much the highlight overshoots when it snaps to a slot."
        case .submenuSpeed: "How fast sub-menu bubbles move into place."
        case .leanAmount: "How far the wheel leans toward the pointer."
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .wobbleSpeed: 1...6
        case .wobbleLength: 0.1...1
        case .hoverSwell, .leanAmount: 0...16
        case .pointerPull: 0...60
        case .ripples: 0...3
        case .snapBounce: 0.3...1
        case .submenuSpeed: 0.15...0.8
        }
    }
    private var inverted: Bool { [.wobbleLength, .snapBounce, .submenuSpeed].contains(self) }
    func physicalValue(at position: Double) -> Double {
        let position = min(1, max(0, position))
        let span = range.upperBound - range.lowerBound
        return inverted ? range.upperBound - position * span : range.lowerBound + position * span
    }
    func position(for value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        let position = inverted ? (range.upperBound - value) / span : (value - range.lowerBound) / span
        return min(1, max(0, position))
    }
    var keyPath: WritableKeyPath<LayoutWheelLiquidSettings, Double> {
        switch self {
        case .wobbleSpeed: \.feel.tension
        case .wobbleLength: \.feel.ringing
        case .hoverSwell: \.feel.bulge
        case .pointerPull: \.feel.stretch
        case .ripples: \.feel.splash
        case .snapBounce: \.feel.magnetDamping
        case .submenuSpeed: \.feel.dropletResponse
        case .leanAmount: \.motion.leanAmount
        }
    }
}

struct LayoutWheelFeelSlider: View {
    let control: LayoutWheelFeelControl
    @Binding var settings: LayoutWheelLiquidSettings

    var body: some View {
        LayoutWheelLabelledSlider(title: control.title, help: control.help, ends: control.ends,
            value: Binding(get: { control.position(for: settings[keyPath: control.keyPath]) },
                           set: { settings[keyPath: control.keyPath] = control.physicalValue(at: $0) }))
    }
}

struct LayoutWheelLabelledSlider: View {
    let title: String
    let help: String
    let ends: (String, String)
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.s1) {
            HStack(alignment: .center, spacing: SettingsSpacing.s3) {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    Slider(value: $value, in: 0...1) { Text(title) }.labelsHidden()
                    HStack { Text(ends.0); Spacer(); Text(ends.1) }
                        .font(SettingsFont.caption).foregroundStyle(.secondary)
                }.frame(width: 180)
            }
            Text(help).font(SettingsFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(SettingsSpacing.s3)
    }
}
