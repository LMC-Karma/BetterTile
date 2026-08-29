// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

/// Editing state only. Choosing a sector here assigns a command; it never
/// previews or applies a layout, so Settings cannot move a window.
struct LayoutWheelSettings: View {
    @Bindable var model: BetterTileModel
    @State private var editing = LayoutWheelSelection(ring: .inner, sector: .top)

    private var wheel: LayoutWheelConfiguration { model.configuration.layoutWheel }
    private var customZones: [CustomZone] { model.configuration.customZones }

    var body: some View {
        Form {
            Section("Layout Wheel") {
                Toggle("Layout Wheel", isOn: wheelBinding(\.isEnabled))
                Text(
                    "Hold the trigger to open the wheel over the focused window, move the "
                        + "pointer to a sector, then release to apply that layout. Release in "
                        + "the middle, or press Escape, to cancel."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Rings") {
                Picker("Levels", selection: levelCountBinding) {
                    Text("One Level").tag(LayoutWheelLevelCount.one)
                    Text("Two Levels").tag(LayoutWheelLevelCount.two)
                }
                .pickerStyle(.segmented)
                Text(
                    "One Level hides the outer ring and keeps everything assigned to it, "
                        + "ready for when you switch back."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Sectors") {
                // Adjacent while the window is wide enough, stacked at the
                // minimum size, so neither the wheel nor the inspector clips.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        editor
                        inspector.frame(width: 236)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        editor.frame(maxWidth: .infinity)
                        inspector
                    }
                }
                HStack {
                    Text("Sectors you leave Empty cancel the gesture when you release on them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults", action: restoreDefaults)
                }
            }

            Section("Activation") {
                Toggle("Keyboard modifiers", isOn: wheelBinding(\.keyboardTriggerEnabled))
                modifierKeycaps
                Text(
                    "Hold the selected modifiers for a moment to open the wheel. Pressing any "
                        + "other key cancels it, so your existing \(wheel.keyboardModifiers.displayText) "
                        + "shortcuts keep working."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Middle click", isOn: middleClickBinding)
                Label(
                    "When enabled, BetterTile reserves middle-click system-wide. Other apps "
                        + "will not receive middle-click until you turn this off.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(activationProblems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
                if !model.hasAccessibilityPermission {
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Editor

    private var editor: some View {
        LayoutWheelView(
            configuration: wheel,
            customZones: customZones,
            selection: editing,
            onSelect: { editing = $0 }
        )
        .accessibilityHint("Choose a sector, then set its command in the inspector.")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sectorTitle)
                .font(.headline)
            Picker("Command", selection: assignmentBinding) {
                Text("Empty").tag(LayoutWheelCommand?.none)
                ForEach(LayoutWheelActionGroup.all, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.actions) { action in
                            Text(action.title)
                                .tag(Optional(LayoutWheelCommand.windowAction(action)))
                        }
                    }
                }
                if !customZones.isEmpty {
                    Section("Custom Zones") {
                        ForEach(customZones) { zone in
                            Text(zone.name)
                                .tag(Optional(LayoutWheelCommand.customZone(zone.id)))
                        }
                    }
                }
                Section("Bento") {
                    Text("Repair Bento").tag(Optional(LayoutWheelCommand.repairBento))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Command for \(sectorTitle)")
            Text(assignmentExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectorTitle: String {
        let ring = wheel.levelCount == .one
            ? ""
            : (editing.ring == .inner ? " (inner ring)" : " (outer ring)")
        return "\(editing.sector.displayName)\(ring)"
    }

    private var assignmentExplanation: String {
        switch assignment {
        case .none:
            "Releasing here cancels without changing the window."
        case .repairBento:
            "Available only while the window's display is in Bento mode."
        case .customZone:
            "Deleting this zone leaves the sector Empty."
        case .windowAction:
            "Applies exactly this layout. Wheel sectors never cycle."
        }
    }

    // MARK: - Activation

    private var modifierKeycaps: some View {
        HStack(spacing: 8) {
            ForEach(LayoutWheelModifier.all, id: \.modifier) { keycap in
                Toggle(isOn: modifierBinding(keycap.modifier)) {
                    HStack(spacing: 5) {
                        Text(keycap.symbol).font(.body.monospaced())
                        Text(keycap.name)
                    }
                }
                .toggleStyle(.button)
                .disabled(isLockedModifier(keycap.modifier))
                .accessibilityLabel(keycap.name)
                .accessibilityHint(
                    isLockedModifier(keycap.modifier)
                        ? "Locked. The wheel needs at least two modifiers."
                        : "Include in the Layout Wheel trigger."
                )
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trigger modifiers")
    }

    /// Concrete, checkable problems only. Event-tap and hot-key registration
    /// failures belong to the controllers that own them.
    private var activationProblems: [String] {
        var problems: [String] = []
        if !model.hasAccessibilityPermission {
            problems.append(
                "Accessibility permission is required before the Layout Wheel can move a window."
            )
        }
        if wheel.isEnabled, !wheel.keyboardTriggerEnabled, !wheel.middleClickTriggerEnabled {
            problems.append(
                "The Layout Wheel is on but has no trigger. Turn on keyboard modifiers or middle click."
            )
        }
        return problems
    }

    /// The wheel needs two modifiers, so the last two stay switched on rather
    /// than letting Settings write a state the configuration would reject.
    private func isLockedModifier(_ modifier: ShortcutModifiers) -> Bool {
        wheel.keyboardModifiers.contains(modifier)
            && wheel.keyboardModifiers.rawValue.nonzeroBitCount <= 2
    }

    // MARK: - Bindings

    private var assignment: LayoutWheelCommand? {
        let slots = editing.ring == .inner ? wheel.innerSlots : wheel.outerSlots
        return slots.indices.contains(editing.sector.rawValue)
            ? slots[editing.sector.rawValue]
            : nil
    }

    private var assignmentBinding: Binding<LayoutWheelCommand?> {
        Binding(
            get: { assignment },
            set: { command in
                updateWheel { wheel in
                    let index = editing.sector.rawValue
                    if editing.ring == .inner {
                        wheel.innerSlots[index] = command
                    } else {
                        wheel.outerSlots[index] = command
                    }
                }
            }
        )
    }

    private var levelCountBinding: Binding<LayoutWheelLevelCount> {
        Binding(
            get: { wheel.levelCount },
            set: { levelCount in
                updateWheel { $0.levelCount = levelCount }
                // One Level hides the outer ring; keep editing something visible.
                if levelCount == .one { editing.ring = .inner }
            }
        )
    }

    private var middleClickBinding: Binding<Bool> {
        wheelBinding(\.middleClickTriggerEnabled)
    }

    private func modifierBinding(_ modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding(
            get: { wheel.keyboardModifiers.contains(modifier) },
            set: { isOn in
                updateWheel { wheel in
                    var modifiers = wheel.keyboardModifiers
                    if isOn {
                        modifiers.insert(modifier)
                    } else {
                        modifiers.remove(modifier)
                    }
                    guard modifiers.rawValue.nonzeroBitCount >= 2 else { return }
                    wheel.keyboardModifiers = modifiers
                }
            }
        )
    }

    private func wheelBinding<Value>(
        _ keyPath: WritableKeyPath<LayoutWheelConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { wheel[keyPath: keyPath] },
            set: { value in updateWheel { $0[keyPath: keyPath] = value } }
        )
    }

    private func updateWheel(_ update: (inout LayoutWheelConfiguration) -> Void) {
        model.updateConfiguration { update(&$0.layoutWheel) }
    }

    private func restoreDefaults() {
        updateWheel { $0 = LayoutWheelConfiguration() }
        editing = LayoutWheelSelection(ring: .inner, sector: .top)
    }
}

struct LayoutWheelModifier {
    let modifier: ShortcutModifiers
    let name: String
    let symbol: String

    static let all: [Self] = [
        Self(modifier: .control, name: "Control", symbol: "⌃"),
        Self(modifier: .option, name: "Option", symbol: "⌥"),
        Self(modifier: .shift, name: "Shift", symbol: "⇧"),
        Self(modifier: .command, name: "Command", symbol: "⌘"),
    ]
}
