// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import SwiftUI

struct SavedLayoutWindowChoiceList: View {
    let appName: String
    let windows: [WindowSnapshot]
    var chosen: WindowID? = nil
    let choose: (WindowID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(appName) · \(windows.count) windows on this desktop")
                .font(SettingsFont.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text("Choose the window for this pane.")
                .font(SettingsFont.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(windows, id: \.id) { window in
                        Button { choose(window.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "macwindow").foregroundStyle(.secondary)
                                Text(window.title.isEmpty ? "Untitled window" : window.title)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                if chosen == window.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .padding(.horizontal, 8).frame(height: SettingsSpacing.s8)
                            .contentShape(Rectangle())
                            .background(chosen == window.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle.settings(SettingsRadius.control))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: min(CGFloat(windows.count) * SettingsSpacing.s8, 256))
        }.font(SettingsFont.body).padding(16).frame(width: 340)
    }
}
