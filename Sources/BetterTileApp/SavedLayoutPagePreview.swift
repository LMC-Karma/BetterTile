// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import SwiftUI

/// Read-only geometry shares the editor's calculation and ordered preference labels.
struct SavedLayoutPagePreview: View {
    let document: SavedLayoutDocument
    var applications: [String: ApplicationChoice]
    var workArea: BTRect? = nil
    var states: [String: SavedLayoutSlotStatus] = [:]
    var choice: (String, @escaping () -> Void) -> AnyView? = { _, _ in nil }
    var appGroups: AppGroupsDocument = .init()
    @State private var choosingSlot: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle.settings(SettingsRadius.inner)
                    .fill(LinearGradient(colors: [.blue.opacity(0.42), .purple.opacity(0.30), .orange.opacity(0.28)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                ForEach(document.layout.map { SavedLayoutCanvas.leaves($0, paneGap: document.paneGap) } ?? []) { leaf in
                    tile(SavedLayoutCanvas.slotIDs(in: leaf.node, document: document), rect: leaf.rect, size: proxy.size)
                }
                ForEach(Array((document.windows + document.floats).enumerated()), id: \.element.slot) { index, rectangle in
                    tile([rectangle.slot], rect: rectangle.rect, size: proxy.size, label: "Rectangle \(index + 1)")
                }
            }
        }
        .aspectRatio(workArea.map { $0.size.width / max(1, $0.size.height) } ?? 1.6, contentMode: .fit)
    }

    private func tile(_ slots: [String], rect: NormalizedRect, size: CGSize, label: String? = nil) -> some View {
        let width = max(1, size.width * rect.width - 12)
        let height = max(1, size.height * rect.height - 12)
        return ScrollView {
            SavedLayoutPreviewTileContent(document: document, slots: slots, height: height, label: label,
                applications: applications, appGroups: appGroups, choice: choice, choosingSlot: $choosingSlot)
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: height)
        .background(.background.opacity(0.85), in: RoundedRectangle.settings(SettingsRadius.inner))
        .position(x: size.width * (rect.x + rect.width / 2), y: size.height * (rect.y + rect.height / 2))
    }

    static func needsRecovery(_ state: SavedLayoutSlotStatus?) -> Bool {
        switch state { case .failed, .needsChoice: true; default: false }
    }
}


/// Pane content has an intrinsic height so compact layouts can choose a native action that fits.
struct SavedLayoutPreviewTileContent: View {
    let document: SavedLayoutDocument
    let slots: [String]
    let height: CGFloat
    var label: String? = nil
    var applications: [String: ApplicationChoice]
    var appGroups: AppGroupsDocument = .init()
    var choice: (String, @escaping () -> Void) -> AnyView?
    @Binding var choosingSlot: String?

    var body: some View {
        Group {
            if height < 120 { compactContent }
            else { expandedContent }
        }
        .frame(maxWidth: .infinity, minHeight: max(1, height - 16)).padding(8)
    }

    private var availableChoices: [String] { slots.filter { choice($0, { choosingSlot = nil }) != nil } }

    var compactChoicePresentation: Binding<Bool> {
        let choices = availableChoices
        return Binding(get: { choosingSlot.map { choices.contains($0) } == true },
            set: { if !$0, let id = choosingSlot, slots.contains(id) { choosingSlot = nil } })
    }

    @ViewBuilder private var compactContent: some View {
        let choices = availableChoices
        if choices.count == 1, let id = choices.first, let chooser = choice(id, { choosingSlot = nil }) {
            Button("Choose Window") { choosingSlot = id }
                .font(SettingsFont.caption).controlSize(.small)
                .popover(isPresented: Binding(get: { choosingSlot == id }, set: { if !$0 { choosingSlot = nil } })) { chooser }
        } else if !choices.isEmpty {
            Menu("Choose Window") {
                ForEach(choices, id: \.self) { id in
                    Button(preferenceTitle(id)) { choosingSlot = id }
                }
            }
            .font(SettingsFont.caption).controlSize(.small)
            .popover(isPresented: compactChoicePresentation) {
                if let id = choosingSlot, let chooser = choice(id, { choosingSlot = nil }) { chooser }
            }
        } else {
            Text(slots.first.map(preferenceTitle) ?? label ?? "Empty pane")
                .font(SettingsFont.caption).lineLimit(1).foregroundStyle(.secondary)
        }
    }

    private func preferenceTitle(_ id: String) -> String {
        guard let slot = document.slots.first(where: { $0.id == id }), let first = slot.prefer.first else { return "Any window" }
        return SavedLayoutPreferencePresentation(first, applications: applications, groups: appGroups).title
    }

    private var expandedContent: some View {
        VStack(spacing: 8) {
            if let label { Text(label).font(SettingsFont.caption).foregroundStyle(.secondary) }
            if slots.isEmpty { Text("Empty pane").font(SettingsFont.caption).foregroundStyle(.secondary) }
            ForEach(slots, id: \.self) { id in
                if let slot = document.slots.first(where: { $0.id == id }) {
                    SavedLayoutPreferenceLabel(preferences: slot.prefer, applications: applications, groups: appGroups,
                        compact: height < 180 || slots.count > 1)
                    if let chooser = choice(id, { choosingSlot = nil }) {
                        Button("Choose Window") { choosingSlot = id }
                            .font(SettingsFont.caption)
                            .popover(isPresented: Binding(get: { choosingSlot == id }, set: { if !$0 { choosingSlot = nil } })) { chooser }
                    }
                }
            }
        }
    }
}
