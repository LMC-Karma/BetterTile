import BetterTileCore
import BetterTileMacOS
import SwiftUI

/// Rehearsal only. Replacing the renderer later changes this view, not the editor.
struct LayoutWheelSettingsPreview: View {
    let configuration: LayoutWheelConfiguration
    let overlayAppearance: OverlayAppearance
    let currentMode: LayoutMode
    var compact = false
    var playback: LayoutWheelPreviewPlayback? = nil
    @State private var mode = LayoutWheelPreviewMode.liquid
    @State private var fan = LayoutWheelFanState()
    @State private var selection: LayoutWheelSelection?
    @State private var pointer: BTPoint?
    @State private var feedback = "No desktop windows will move."

    private var content: LayoutWheelLiquidContent {
        LayoutWheelLiquidDefaults.content(configuration: configuration, currentMode: currentMode)
    }
    private var geometry: LayoutWheelPreviewGeometry { .init(configuration: configuration, mode: mode) }
    private var diameter: Double { geometry.diameter }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(compact ? "Preview" : "Live preview").font(SettingsFont.headline)
                Spacer()
                if !compact { Text("Illustrated desktop").font(SettingsFont.caption).foregroundStyle(.secondary) }
            }
            GeometryReader { proxy in
                let scale = min(1, min(proxy.size.width, proxy.size.height) / diameter)
                ZStack {
                    LinearGradient(colors: [.blue.opacity(0.4), .purple.opacity(0.3), .orange.opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    HStack(alignment: .top, spacing: compact ? 8 : 36) {
                        sampleWindow("Project notes").offset(y: compact ? -8 : -28)
                        sampleWindow("Reference").offset(y: compact ? 8 : 28)
                    }.padding(compact ? 12 : 44)
                    LayoutWheelLiquidPreview(configuration: configuration, overlayAppearance: overlayAppearance,
                        selection: selection, fan: fan, pointer: pointer, currentMode: currentMode, playback: playback,
                        modeChanged: { mode = $0; cancel() })
                        .frame(width: diameter, height: diameter).scaleEffect(scale)
                        .allowsHitTesting(false)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
                .clipShape(.settings(SettingsRadius.inner))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        let vector = BTPoint(x: (location.x - proxy.size.width / 2) / scale, y: (location.y - proxy.size.height / 2) / scale)
                        pointer = vector
                        update(vector)
                    case .ended: cancel()
                    }
                }
                .onTapGesture {
                    let command = configuration.style == .grouped ? fan.command
                        : selection.flatMap { configuration.command(at: $0) }
                    if let command { feedback = "\(LayoutWheelSlot(command: command).label) · rehearsal only" }
                    else { cancel() }
                }
                .onExitCommand { cancel() }
            }
            .frame(height: compact ? 230 : max(360, diameter + 24))
            HelpText(compact ? "Hover to rehearse. Escape cancels." : "Hover to preview a name. Click to rehearse a choice. Escape or the center cancels.")
            HelpText(feedback)
        }
        .task(id: fan.deadline) {
            guard let deadline = fan.deadline else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            guard !Task.isCancelled, let pointer else { return }
            update(pointer)
        }
        .onChange(of: configuration) { cancel() }
    }

    private func sampleWindow(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.5)).frame(width: 5, height: 5) }
            }
            Text(title).font(compact ? SettingsFont.caption : SettingsFont.headline).lineLimit(compact ? 1 : nil)
            ForEach(0..<4) { index in
                Rectangle().fill(.secondary.opacity(0.16)).frame(height: 3)
                    .padding(.trailing, index == 3 ? 35 : 0)
            }
            Spacer(minLength: compact ? 8 : 30)
        }
        .padding(compact ? 8 : 16).frame(maxWidth: .infinity).frame(height: compact ? 130 : 210)
        .background(.background.opacity(0.8), in: .settings(SettingsRadius.inner))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }
    private func update(_ vector: BTPoint) {
        selection = geometry.update(vector: vector, at: ProcessInfo.processInfo.systemUptime, fan: &fan)
    }
    private func cancel() {
        fan.cancel(); selection = nil; pointer = nil
        feedback = "Cancelled. No desktop windows moved."
    }
}
