// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import SwiftUI

enum SetupPage: Int, CaseIterable, Identifiable {
    case welcome
    case accessibility
    case compatibility
    case features

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .accessibility: "Accessibility"
        case .compatibility: "macOS Compatibility"
        case .features: "Features & Feedback"
        }
    }

    init?(diagnosticName: String) {
        switch diagnosticName.lowercased() {
        case "welcome": self = .welcome
        case "accessibility": self = .accessibility
        case "compatibility": self = .compatibility
        case "features": self = .features
        default: return nil
        }
    }
}

struct SetupAssistantView: View {
    static let currentVersion = 1

    @Bindable var model: BetterTileModel
    @State private var page: SetupPage
    let close: () -> Void

    init(model: BetterTileModel, initialPage: SetupPage, close: @escaping () -> Void) {
        self.model = model
        _page = State(initialValue: initialPage)
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                pageContent
                    .frame(maxWidth: 610, alignment: .topLeading)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
            }
            Divider()
            navigation
        }
        .frame(minWidth: 680, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BetterTile Setup")
                        .font(.headline)
                    Text(page.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Step \(page.rawValue + 1) of \(SetupPage.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(page.rawValue + 1),
                total: Double(SetupPage.allCases.count)
            )
            .accessibilityLabel("Setup progress")
            .accessibilityValue("Step \(page.rawValue + 1) of \(SetupPage.allCases.count)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .welcome:
            welcomePage
        case .accessibility:
            accessibilityPage
        case .compatibility:
            compatibilityPage
        case .features:
            featuresPage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Welcome to BetterTile")
                            .font(.largeTitle.weight(.semibold))
                        Text("BETA")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.16), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Text("A native macOS window manager that resizes neighboring windows together.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Setup takes about two minutes. You can close this assistant and return at any time.")
                .font(.body)

            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    welcomePoint(
                        "One required permission",
                        detail: "Accessibility lets BetterTile move and resize the windows you choose.",
                        symbol: "hand.raised.fill"
                    )
                    welcomePoint(
                        "Private by default",
                        detail: "Your configuration and window layout information stay on this Mac.",
                        symbol: "lock.shield.fill"
                    )
                    welcomePoint(
                        "You stay in control",
                        detail: "The macOS compatibility recommendations are optional and can be skipped.",
                        symbol: "checklist"
                    )
                }
                .padding(6)
            }
        }
    }

    private var accessibilityPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Allow BetterTile to manage windows")
                .font(.largeTitle.weight(.semibold))
            Text(
                "BetterTile uses the public macOS Accessibility API to read, move, and resize "
                    + "eligible windows. It does not request Screen Recording."
            )
            .font(.body)
            .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    AccessibilityPermissionStatus(model: model)

                    if !model.hasAccessibilityPermission {
                        Text("1. Request access or open Accessibility settings.")
                        Text("2. Turn on BetterTile in the application list.")
                        Text("3. Return here; the status updates automatically.")

                        HStack(spacing: 10) {
                            Button("Request Access…") { model.requestAccessibilityPermission() }
                                .buttonStyle(.borderedProminent)
                            Button("Open Accessibility Settings") {
                                model.openAccessibilitySettings()
                            }
                            Button("Check Again") { model.recheckAccessibilityPermission() }
                        }

                    } else {
                        Text("BetterTile is ready to manage windows. You can continue setup.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            Label(
                "Accessibility is the only required setup item. You may view the remaining pages now, but Finish stays disabled until access is granted.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var compatibilityPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("BetterTile and macOS window tiling")
                .font(.largeTitle.weight(.semibold))
            Text(
                "macOS has its own window tiling. BetterTile is built to sit alongside it, "
                    + "so you do not have to give either one up."
            )
            .foregroundStyle(.secondary)

            RecommendationCard(
                title: "Move & Resize keeps working",
                symbol: "rectangle.split.2x1",
                explanation:
                    "Window ▸ Move & Resize and its keyboard equivalents work as they always did. "
                        + "Bento recognises where macOS put a window and adopts that arrangement, "
                        + "so you can tile with either and carry on resizing with BetterTile's dividers.",
                directions: [
                    "Nothing to change. Use whichever you reach for.",
                ],
                isAcknowledged: nil
            )

            RecommendationCard(
                title: "Pick one way to drag",
                symbol: "hand.draw",
                explanation:
                    "Dragging to a screen edge is the one place the two overlap: macOS and BetterTile "
                        + "would both try to interpret the same drag. Bento adopts the result either way, "
                        + "so this is about which one you want to feel.",
                directions: [
                    "Keep BetterTile Drag Snapping on for BetterTile's zones and previews, or",
                    "Turn it off in Settings ▸ General and use macOS's edge tiling instead.",
                    "Your snap zones are kept either way.",
                ],
                isAcknowledged: configurationBinding(
                    \.macOSTilingRecommendationAcknowledged
                )
            )

            RecommendationCard(
                title: "Turn off Stage Manager",
                symbol: "uiwindow.split.2x1",
                explanation: "BetterTile ignores Stage Manager thumbnails, but Bento behavior is most predictable when Stage Manager is off.",
                directions: [
                    "In Desktop & Dock, go to Desktop & Stage Manager.",
                    "Turn Stage Manager off, or use Stage Manager in Control Center.",
                ],
                isAcknowledged: configurationBinding(
                    \.stageManagerRecommendationAcknowledged
                )
            )

            Button("Open Desktop & Dock Settings") { openDesktopAndDockSettings() }
            Text("If the button does not reach the section directly, choose Desktop & Dock in the System Settings sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Start arranging your workspace")
                .font(.largeTitle.weight(.semibold))
            Text("BetterTile is in beta. Feedback on real workflows will shape what improves next.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    featurePoint(
                        "Drag snapping",
                        detail: "Preview an edge or corner zone before releasing a window.",
                        symbol: "arrow.up.left.and.arrow.down.right"
                    )
                    featurePoint(
                        "Linked resizing",
                        detail: "Resize neighboring windows together along their shared boundary.",
                        symbol: "arrow.left.and.right"
                    )
                    featurePoint(
                        "Adaptive Bento layouts",
                        detail: "Arrange visible windows into a stable split layout that adapts as windows change.",
                        symbol: "rectangle.split.2x2"
                    )
                    featurePoint(
                        "Keyboard actions",
                        detail: "Assign conflict-checked shortcuts for common positions, sizes, and displays.",
                        symbol: "keyboard"
                    )
                    featurePoint(
                        "Placement history",
                        detail: "Restore a window’s previous BetterTile placement when an action misses the mark.",
                        symbol: "arrow.uturn.backward"
                    )
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Help improve BetterTile")
                    .font(.headline)
                Text("Bug reports and feature ideas are public on GitHub and greatly appreciated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Link(
                        "Report a Bug",
                        destination: URL(
                            string: "https://github.com/LMC-Karma/BetterTile/issues/new?template=bug.yml"
                        )!
                    )
                    Link(
                        "Suggest an Improvement",
                        destination: URL(
                            string: "https://github.com/LMC-Karma/BetterTile/issues/new?template=feature.yml"
                        )!
                    )
                    Link(
                        "View on GitHub",
                        destination: URL(string: "https://github.com/LMC-Karma/BetterTile")!
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button("Set Up Later", action: close)
                .keyboardShortcut(.cancelAction)

            Spacer()

            if page != .welcome {
                Button("Back") {
                    page = SetupPage(rawValue: page.rawValue - 1) ?? .welcome
                }
            }

            if page != .features {
                Button("Continue") {
                    page = SetupPage(rawValue: page.rawValue + 1) ?? .features
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                if !model.hasAccessibilityPermission {
                    Label("Accessibility is still required", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Finish") { finishSetup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasAccessibilityPermission)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func welcomePoint(_ title: String, detail: String, symbol: String) -> some View {
        featurePoint(title, detail: detail, symbol: symbol)
    }

    private func featurePoint(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func configurationBinding(
        _ keyPath: WritableKeyPath<BetterTileConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.configuration[keyPath: keyPath] },
            set: { value in
                model.updateConfiguration { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func openDesktopAndDockSettings() {
        let paneURL = URL(
            string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
        )!
        guard !NSWorkspace.shared.open(paneURL),
              let settingsURL = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: "com.apple.systempreferences"
              )
        else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func finishSetup() {
        guard model.hasAccessibilityPermission else { return }
        model.updateConfiguration {
            $0.setupCompletionVersion = Self.currentVersion
        }
        model.flushConfiguration()
        close()
    }
}

struct AccessibilityPermissionStatus: View {
    @Bindable var model: BetterTileModel

    var body: some View {
        HStack(spacing: 8) {
            Label(
                model.hasAccessibilityPermission
                    ? "Accessibility Granted"
                    : "Accessibility Required",
                systemImage: model.hasAccessibilityPermission
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(model.hasAccessibilityPermission ? .green : .red)
            Spacer()
            if model.isWaitingForAccessibilityPermission {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            model.isWaitingForAccessibilityPermission
                ? "Accessibility status: checking for access"
                : model.hasAccessibilityPermission
                ? "Accessibility status: granted"
                : "Accessibility status: required"
        )
    }
}

private struct RecommendationCard: View {
    let title: String
    let symbol: String
    let explanation: String
    let directions: [String]
    /// Nil for a card that only explains something, with nothing for the user
    /// to confirm.
    var isAcknowledged: Binding<Bool>?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        if let isAcknowledged {
                            Label(
                                isAcknowledged.wrappedValue
                                    ? "Confirmed by you"
                                    : "Your choice — either works",
                                systemImage: isAcknowledged.wrappedValue
                                    ? "checkmark.circle.fill"
                                    : "questionmark.circle.fill"
                            )
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isAcknowledged.wrappedValue ? .green : .secondary)
                        } else {
                            Label("Nothing to change", systemImage: "checkmark.circle.fill")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(directions.enumerated()), id: \.offset) { index, direction in
                        Text("\(index + 1). \(direction)")
                            .font(.caption)
                    }
                }

                if let isAcknowledged {
                    Toggle("Done — I have chosen", isOn: isAcknowledged)
                }
            }
            .padding(6)
        }
    }
}
