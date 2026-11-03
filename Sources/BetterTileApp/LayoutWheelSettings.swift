// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

struct LayoutWheelSettings: View {
    // Enable only after the actual keyboard and Jump client preserve right-side identity.
    private static let rightControlIsValidated = false
    @Bindable var model: BetterTileModel
    @State private var editing: LayoutWheelEditorSelection = .slot(.init(ring: .inner, sector: .top))
    @State private var allFans = false
    @State private var expanded: Set<LayoutWheelSector> = [.top]
    @State private var showingPicker = false
    @State private var confirmingReset = false
    @State private var showingFineTuning = false

    init(model: BetterTileModel, initiallyShowsAllFans: Bool = false) {
        self.model = model
        _allFans = State(initialValue: initiallyShowsAllFans)
    }

    private var wheel: LayoutWheelConfiguration { model.configuration.layoutWheel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsSpacing.s6) {
                ForEach(activationProblems, id: \.self) { problem in
                    NoticeBanner(.problem, title: problem)
                }
                if !wheel.isEnabled {
                    NoticeBanner(.info, title: "The Layout Wheel is off",
                                 message: "You can still edit it. Changes apply when you turn it on.")
                }
                SettingsGroup {
                    SettingsRow("Layout Wheel", caption: "Hold your trigger, point to an action, then release to apply. Release in the center or press Escape to cancel.") {
                        Toggle("Layout Wheel", isOn: binding(\.isEnabled)).labelsHidden().toggleStyle(.switch)
                    }
                }
                contentControls
                HStack(alignment: .top, spacing: SettingsSpacing.s4) {
                    VStack(alignment: .leading, spacing: SettingsSpacing.s2) {
                        HStack {
                            Text("Edit wheel").font(SettingsFont.headline)
                            Spacer()
                            if wheel.style == .grouped {
                                Picker("Visible fans", selection: $allFans) {
                                    Text("All fans").tag(true)
                                    Text("One fan").tag(false)
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Click an icon to assign it").font(SettingsFont.caption).foregroundStyle(.secondary)
                                .padding([.top, .horizontal], 12)
                            LayoutWheelEditorDiagram(wheel: wheel, currentMode: model.activeLayoutMode,
                                selection: editing, allFans: allFans, expanded: expanded,
                                select: select, toggleFan: toggleFan)
                            HStack {
                                Text(allFans ? "Fans spread apart for editing" : "One group at a time")
                                    .font(SettingsFont.caption).foregroundStyle(.secondary)
                                Spacer()
                                if wheel.style == .grouped {
                                    Button(expanded.isEmpty ? "Expand fans" : "Collapse fans") {
                                        expanded = expanded.isEmpty ? visibleFans : []
                                    }.buttonStyle(.link).font(SettingsFont.caption)
                                }
                            }.padding(12)
                        }
                        .background(SettingsColor.fill, in: .settings(SettingsRadius.inner))
                        HelpText(wheel.style == .grouped
                            ? "Chevrons open each group. A dot marks a sub-menu."
                            : "Empty cancels the gesture. Hidden outer assignments stay saved.")
                        if wheel.style == .custom {
                            Button("Swap Inner and Outer Rings") { update { $0.swapRings() } }
                        }
                    }
                    inspector.frame(width: 228).padding(.top, 32)
                }
                appearance
                triggers
                LayoutWheelSettingsPreview(configuration: wheel,
                    overlayAppearance: model.configuration.overlayAppearance, currentMode: model.activeLayoutMode)
                Divider()
                HStack {
                    Text("Edits are reflected in the preview.").font(SettingsFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Layout Wheel…") { confirmingReset = true }
                }
            }
            .padding(SettingsSpacing.s6)
        }
        .font(SettingsFont.body)
        .onAppear { resetSelection() }
        .onChange(of: wheel.style) { resetSelection() }
        .onChange(of: wheel.levelCount) { resetSelection() }
        .onChange(of: allFans) { expanded = visibleFans }
        .alert("Reset Layout Wheel?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Layout Wheel", role: .destructive) {
                update { $0 = .init() }
                allFans = false
                resetSelection()
            }
        } message: {
            Text("Restore all assignments, appearance, size, levels and triggers to their defaults.")
        }
    }

    private var contentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Content")
                Picker("Content", selection: binding(\.style)) {
                    Text("Custom").tag(LayoutWheelStyle.custom)
                    Text("Grouped").tag(LayoutWheelStyle.grouped)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Spacer(minLength: 12)
                Text("Levels")
                Picker("Levels", selection: binding(\.levelCount)) {
                    Text("One Level").tag(LayoutWheelLevelCount.one)
                    Text("Two Levels").tag(LayoutWheelLevelCount.two)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
            HelpText(wheel.style == .grouped
                ? (wheel.levelCount == .one ? "Eight groups in one ring. Your Custom assignments stay saved."
                   : "Eight groups and a separate inner ring. Your Custom assignments stay saved.")
                : "Assign any command to a slot. Grouped assignments stay saved.")
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LayoutWheelCommandIcon(command: editing.command(in: wheel), size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectionTitle).font(SettingsFont.caption).foregroundStyle(.secondary)
                    Text(selectionDetail).font(SettingsFont.headline).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(editing.group == nil ? "Release on this slot to use its command."
                 : "Choose a quick-flick command or a child after its fan opens.")
                .font(SettingsFont.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { showingPicker = true } label: {
                HStack(spacing: 8) {
                    LayoutWheelCommandIcon(command: editing.command(in: wheel))
                    Text(LayoutWheelSlot(command: editing.command(in: wheel)).label).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .popover(isPresented: $showingPicker) {
                LayoutWheelCommandPicker { command in
                    update { editing.assign(command, in: &$0) }
                    showingPicker = false
                }
            }
            if editing.command(in: wheel) == nil { HelpText("Empty cancels the gesture.") }
            if let sector = editing.group {
                groupInspector(sector)
            } else {
                Button("Reset Slot") {
                    guard case let .slot(slot) = editing else { return }
                    let defaults = LayoutWheelConfiguration(style: wheel.style, levelCount: wheel.levelCount)
                    update { editing.assign(defaults.command(at: slot), in: &$0) }
                }.buttonStyle(.link)
            }
        }
    }

    private func groupInspector(_ sector: LayoutWheelSector) -> some View {
        let group = wheel.group(at: sector)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Group contents").font(SettingsFont.headline)
                Spacer()
                Text("\(group.options.count) of 6").font(SettingsFont.caption).foregroundStyle(.secondary)
            }
            assignmentRow(.group(sector), title: "Quick flick")
            ForEach(group.options.indices, id: \.self) { index in
                HStack(spacing: 2) {
                    assignmentRow(.child(sector, index), title: LayoutWheelSlot(command: group.options[index]).label)
                    Button {
                        editing = .child(sector, index)
                        update { editing.moveChild(by: -1, in: &$0) }
                    } label: { Image(systemName: "chevron.up") }
                    .help("Earlier").disabled(index == 0)
                    Button {
                        editing = .child(sector, index)
                        update { editing.moveChild(by: 1, in: &$0) }
                    } label: { Image(systemName: "chevron.down") }
                    .help("Later").disabled(index == group.options.count - 1)
                }.controlSize(.small)
            }
            HStack {
                Button("Add child") {
                    update { editing.addChild(in: &$0) }
                    expanded.insert(sector)
                    showingPicker = true
                }.disabled(group.options.count >= LayoutWheelGroupContents.maximumChildren)
                Spacer(minLength: 0)
                Button("Remove child") { update { editing.removeChild(in: &$0) } }
                    .disabled(!isChildSelected)
            }.buttonStyle(.link).font(SettingsFont.caption).padding(.top, 8)
            Button("Reset \(LayoutWheelGroup.at(sector).title) group") {
                update { $0.groupOverrides.removeValue(forKey: sector.rawValue) }
                editing = .group(sector)
            }.buttonStyle(.link).padding(.top, 12)
        }
    }

    private func assignmentRow(_ item: LayoutWheelEditorSelection, title: String) -> some View {
        Button { select(item) } label: {
            HStack(spacing: 8) {
                LayoutWheelCommandIcon(command: item.command(in: wheel))
                Text(title).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(editing == item ? SettingsColor.accentSoft : .clear, in: .settings(SettingsRadius.control))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var appearance: some View {
        LayoutWheelAppearanceControls(appearance: binding(\.appearance)) { showingFineTuning = true }
            .sheet(isPresented: $showingFineTuning) {
                LayoutWheelFineTuningSheet(appearance: binding(\.appearance), configuration: wheel,
                    overlayAppearance: model.configuration.overlayAppearance, currentMode: model.activeLayoutMode)
            }
    }

    private var triggers: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Open the wheel", reset: { update { $0.triggers = .init() } })
            SettingsGroup {
                SettingsRow("Keyboard modifiers", caption: "Hold the keys, point, then release.") {
                    Toggle("Keyboard modifiers", isOn: binding(\.triggers.keyboardEnabled)).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Modifier keys") { modifierKeycaps }
                SettingsRow("Hold delay") { Text("220 ms · fixed").foregroundStyle(.secondary) }
                SettingsRow("Mouse trigger", caption: "Reserves only the chosen click in every app.") {
                    Picker("Mouse trigger", selection: binding(\.triggers.mouse)) {
                        Text("Off").tag(LayoutWheelTriggers.Mouse.off)
                        Text("Middle click").tag(LayoutWheelTriggers.Mouse.middleClick)
                        Text("Option + Middle click").tag(LayoutWheelTriggers.Mouse.optionMiddleClick)
                    }.labelsHidden().frame(width: 210)
                }
            }
            HelpText("Keyboard: arrows and Tab select; Return applies. Any other key or modifier cancels. Pressing another key before the wheel opens cancels the hold. Mouse: release the middle button to apply.")
            if wheel.triggers.mouse != .off {
                HelpText(wheel.triggers.mouse == .middleClick
                    ? "BetterTile reserves plain middle clicks in every app. Modified middle clicks keep their normal action."
                    : "Hold Option, press the middle button, then release the button to apply. Plain middle clicks keep their normal action. Option–middle clicks are reserved in every app.")
            }
        }
    }

    /// A row of toggle buttons, one for each modifier, as on the earlier Layout Wheel page.
    /// Right Control, once validated, is one more button of the same kind. It replaces the chord.
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
            if Self.rightControlIsValidated {
                Toggle(isOn: rightControlBinding) {
                    HStack(spacing: 5) {
                        Text("⌃").font(.body.monospaced())
                        Text("Right Control")
                    }
                }
                .toggleStyle(.button)
                .accessibilityLabel("Right Control")
                .accessibilityHint("Use only the right Control key as the trigger.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trigger modifiers")
    }

    /// The wheel needs two modifiers, so the last two stay switched on rather
    /// than letting Settings write a state the configuration would reject.
    private func isLockedModifier(_ modifier: ShortcutModifiers) -> Bool {
        wheel.triggers.isLocked(modifier)
    }

    /// While Right Control is the trigger, no chord button is on. Pressing one returns to the
    /// stored chord.
    private func modifierBinding(_ modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding(
            get: { wheel.triggers.isOn(modifier) },
            set: { isOn in update { $0.triggers.setModifier(modifier, enabled: isOn) } }
        )
    }

    private var rightControlBinding: Binding<Bool> {
        Binding(
            get: { wheel.triggers.keyboard == .rightControl },
            set: { isOn in update { $0.triggers.keyboard = isOn ? .rightControl : .modifiers } }
        )
    }

    private func sectionHeader(_ title: String, reset: @escaping () -> Void) -> some View {
        HStack { Text(title).font(SettingsFont.headline); Spacer(); Button("Reset", action: reset).buttonStyle(.link) }
    }

    private var selectionTitle: String {
        switch editing {
        case let .slot(slot): "\(slot.sector.displayName) · \(slot.ring == .inner ? "Inner" : "Outer") ring"
        case let .group(sector), let .child(sector, _): "\(LayoutWheelGroup.at(sector).title) · \(wheel.group(at: sector).options.count) children"
        }
    }
    private var selectionDetail: String {
        if case .group = editing { return "Quick flick" }
        return LayoutWheelSlot(command: editing.command(in: wheel)).label
    }
    private var isChildSelected: Bool { if case .child = editing { true } else { false } }
    private var visibleFans: Set<LayoutWheelSector> {
        allFans ? Set(LayoutWheelSector.allCases.filter { !wheel.group(at: $0).options.isEmpty }) : [editing.group ?? .top]
    }
    private func resetSelection() {
        editing = wheel.style == .grouped ? .group(.top) : .slot(.init(ring: .inner, sector: .top))
        expanded = visibleFans
        showingPicker = false
    }
    private func select(_ item: LayoutWheelEditorSelection) {
        editing = item
        showingPicker = false
        if let sector = item.group {
            if !allFans { expanded = [sector] } else { expanded.insert(sector) }
        }
    }
    private func toggleFan(_ sector: LayoutWheelSector) {
        if expanded.contains(sector) { expanded.remove(sector) }
        else { if !allFans { expanded.removeAll() }; expanded.insert(sector) }
    }
    private var activationProblems: [String] {
        var problems: [String] = []
        if let failure = model.layoutWheelMonitoringFailure { problems.append(failure) }
        if wheel.triggers.keyboard == .rightControl, !Self.rightControlIsValidated {
            problems.append("Right Control has not been validated on this keyboard and remote connection. Choose a modifier chord until it is validated.")
        }
        if !model.hasAccessibilityPermission { problems.append("Accessibility permission is required before the Layout Wheel can move a window.") }
        if wheel.isEnabled, !wheel.triggers.keyboardEnabled, wheel.triggers.mouse == .off {
            problems.append("The Layout Wheel is on but has no trigger. Turn on keyboard modifiers or choose a mouse trigger.")
        }
        return problems
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<LayoutWheelConfiguration, Value>) -> Binding<Value> {
        Binding(get: { wheel[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }
    private func update(_ change: (inout LayoutWheelConfiguration) -> Void) {
        model.updateConfiguration { change(&$0.layoutWheel) }
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
