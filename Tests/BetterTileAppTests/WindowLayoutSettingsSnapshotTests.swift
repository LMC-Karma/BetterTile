import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized) struct WindowLayoutSettingsSnapshotTests {
    private enum State: String, CaseIterable {
        case adaptive, tabbed, modified
    }

    @Test func rendersWindowLayoutStates() throws {
        let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]
        let states: [State] = directory == nil ? [.adaptive] : State.allCases
        let themes = directory == nil ? [false] : [false, true]
        let widths: [Double] = directory == nil ? [770] : [770, 980, 1280]
        let glassValues = directory == nil ? [true] : [true, false]
        for state in states {
            for dark in themes {
                for width in widths {
                    for glass in glassValues {
                        try render(state: state, dark: dark, width: width, glass: glass, directory: directory)
                    }
                }
            }
        }
    }

    private func render(state: State, dark: Bool, width: Double, glass: Bool, directory: String?) throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration { $0.overlayAppearance.useLiquidGlass = glass }
        let mode: LayoutMode = state == .tabbed ? .tabbed : .bento
        model.hasAccessibilityPermission = true
        model.setActiveMode(mode)
        if state == .modified {
            model.assign(shortcut: nil, to: .leftHalf)
            model.updateConfiguration {
                $0.bentoInnerGap = 11
                $0.overlayAppearance.transparency = 0.73
                $0.dividerThickness = 12
            }
        }
        let original = model.configuration
        let host = try SettingsSnapshotHost(
            WindowLayoutSettings(model: model, settingsMode: mode),
            dark: dark, width: width, height: 3200, fitHeight: false
        )
        defer { host.close() }
        let bitmap = try host.render()
        #expect(bitmap.pixelsWide >= Int(width))
        #expect(bitmap.pixelsHigh >= 3200)
        #expect(model.configuration == original)
        guard let directory else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "window-layout-\(state.rawValue)-\(dark ? "dark" : "light")-\(Int(width))-\(glass ? "glass" : "solid").png"
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name))
    }
}

// Native pointer capture and window ordering are process-wide. Share the UI
// lease with other pointer tests so an ordered snapshot host cannot steal input.
@MainActor @Suite(.appTestApplication, .serialized, .settingsUI) struct FeedbackPageControlInputTests {
    @Test func rendersLiveSliderChanges() async throws {
        let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]
        for dark in [false, true] {
            for width in [980.0, 1280] {
                let model = makeModel(system: FakeAppWindowSystem())
                defer { model.shutdown() }
                model.updateConfiguration {
                    $0.bentoInnerGap = 4
                    $0.overlayAppearance.transparency = 0.25
                }
                let host = try SettingsSnapshotHost(LiveLayoutControls(model: model), dark: dark,
                                                    width: width, height: 1100, fitHeight: false)
                defer { host.close() }
                // SwiftUI dispatches pointer input only for ordered windows.
                // The test runner's window stays offscreen; no BetterTile app runs.
                host.window.setFrameOrigin(CGPoint(x: 12000, y: 0))
                host.window.orderFront(nil)
                try await waitForSettingsUI("the live controls", in: host.view) { !previewViews(host.view).isEmpty }
                host.settle()
                // SwiftUI draws these sliders itself, with no AppKit view to measure, so the tracks come from the row
                // layout. A drag ends past the track's end, where every slider clamps to its maximum, whatever the
                // knob's inset on this system.
                let trackX = width - 12 - 44 - 8 - 220
                let gapTrack = CGRect(x: trackX, y: 40, width: 220, height: 20)
                let glassTrack = CGRect(x: trackX, y: 131, width: 220, height: 20)
                func point(on track: CGRect, at fraction: Double) -> CGPoint {
                    host.view.convert(CGPoint(x: track.minX + 8 + (track.width - 16) * fraction, y: track.midY), to: nil)
                }
                func beyond(_ track: CGRect) -> CGPoint { host.view.convert(CGPoint(x: track.maxX + 24, y: track.midY), to: nil) }
                let picture = CGRect(x: gapTrack.minX - 8 - 64, y: gapTrack.midY - 20, width: 64, height: 40)
                let preview = try #require(previewViews(host.view).max { $0.bounds.width < $1.bounds.width })
                let previewFrame = preview.convert(preview.bounds, to: host.view)
                let grip = CGRect(x: previewFrame.midX - 30, y: previewFrame.midY - 30, width: 60, height: 60)
                let before = try png(host)
                let beforePicture = try png(host, in: picture)
                // Check only the picture while the drag is still active, excluding
                // the label and readout. A stale picture must fail independently.
                var afterPicture: Data?
                let gapDragged = try performNativeDrag(from: point(on: gapTrack, at: 1.0 / 3), to: beyond(gapTrack),
                                                       in: host.window) {
                    host.view.layoutSubtreeIfNeeded()
                    guard model.configuration.bentoInnerGap == 12, let now = try? png(host, in: picture),
                          now != beforePicture else { return false }
                    afterPicture = now
                    return true
                }
                #expect(gapDragged, "The dragged pane gap and its picture must update during the drag: gap \(model.configuration.bentoInnerGap), picture \(afterPicture == nil ? "unchanged" : "changed")")
                #expect(model.configuration.bentoInnerGap == 12)
                #expect(afterPicture != nil && afterPicture != beforePicture)
                host.settle()
                let beforeGlass = try png(host, in: grip)
                var afterGlass: Data?
                let glassDragged = try performNativeDrag(from: point(on: glassTrack, at: 0.25), to: point(on: glassTrack, at: 0.9),
                                                         in: host.window) {
                    host.view.layoutSubtreeIfNeeded()
                    guard model.configuration.overlayAppearance.transparency > 0.8, let now = try? png(host, in: grip),
                          now != beforeGlass else { return false }
                    afterGlass = now
                    return true
                }
                #expect(glassDragged, "The dragged glass transparency and its preview must update during the drag: \(model.configuration.overlayAppearance.transparency)")
                #expect(model.configuration.overlayAppearance.transparency > 0.8)
                #expect(afterGlass != nil && afterGlass != beforeGlass)
                host.settle()
                let after = try png(host)
                if let directory {
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let suffix = "\(dark ? "dark" : "light")-\(Int(width)).png"
                    try before.write(to: folder.appendingPathComponent("window-layout-live-controls-before-" + suffix))
                    try after.write(to: folder.appendingPathComponent("window-layout-live-controls-after-" + suffix))
                    try beforePicture.write(to: folder.appendingPathComponent("pane-gap-picture-before-" + suffix))
                    try afterPicture?.write(to: folder.appendingPathComponent("pane-gap-picture-after-" + suffix))
                    try beforeGlass.write(to: folder.appendingPathComponent("glass-preview-before-" + suffix))
                    try afterGlass?.write(to: folder.appendingPathComponent("glass-preview-after-" + suffix))
                }
                model.updateConfiguration { $0.overlayAppearance.useLiquidGlass = false }
                host.settle()
                let disabledValue = model.configuration.overlayAppearance.transparency
                // A disabled slider ignores the drag: the value stays the same during it and after it.
                var draggedValue: Double?
                _ = try performNativeDrag(from: point(on: glassTrack, at: 1), to: point(on: glassTrack, at: 0),
                                          in: host.window, attempts: 3) {
                    draggedValue = model.configuration.overlayAppearance.transparency
                    return false
                }
                #expect(draggedValue == disabledValue)
                #expect(model.configuration.overlayAppearance.transparency == disabledValue)
            }
        }
    }

    private func previewViews(_ view: NSView) -> [NSView] {
        let own = String(describing: type(of: view)) == "DividerLensPreviewView" ? [view] : []
        return own + view.subviews.flatMap(previewViews)
    }

    private func png(_ host: SettingsSnapshotHost, in rect: CGRect? = nil) throws -> Data {
        guard let rect else { return try #require(host.render().representation(using: .png, properties: [:])) }
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: rect))
        let appearance = try #require(host.view.appearance)
        appearance.performAsCurrentDrawingAppearance { host.view.cacheDisplay(in: rect, to: bitmap) }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func dragSnappingSwitchTurnsOffAndOnWithoutChangingAssignments() async throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        model.updateConfiguration {
            $0.snappingEnabled = true
            $0.macOSTilingRecommendationAcknowledged = true
        }
        let assignments = model.configuration.snapAreaBindings
        let host = try SettingsSnapshotHost(ZoneSettings(model: model), dark: false,
                                            width: 980, height: 1400, fitHeight: false)
        defer { host.close() }
        host.window.setFrameOrigin(CGPoint(x: 12000, y: 0))
        host.window.orderFront(nil)
        func switches(_ view: NSView) -> [NSView] {
            let own = String(describing: type(of: view)) == "PlatformSwitch" ? [view] : []
            return own + view.subviews.flatMap(switches)
        }
        try await waitForSettingsUI("the Snap Zones switches", in: host.view) { !switches(host.view).isEmpty }
        host.settle()
        let toggle = try #require(switches(host.view).min {
            $0.convert($0.bounds, to: host.view).minY < $1.convert($1.bounds, to: host.view).minY
        })
        let frame = try await waitForStableFrame(of: toggle, in: host, "the Drag snapping switch")
        // The first switch belongs to the first group, ahead of the zone diagram.
        #expect(frame.midY < 100)
        for expected in [false, true] {
            try performNativeMouseClick(at: host.view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil), in: host.window)
            try await waitForSettingsUI("Drag snapping \(expected ? "on" : "off")", in: host.view) {
                model.configuration.snappingEnabled == expected
            }
            #expect(model.configuration.snappingEnabled == expected)
            #expect(model.configuration.snapAreaBindings == assignments)
        }
    }

}

/// Keep the model reads inside a SwiftUI body so the production rows observe
/// configuration changes exactly as they do in WindowLayoutSettings.body.
private struct LiveLayoutControls: View {
    @Bindable var model: BetterTileModel

    var body: some View {
        let settings = WindowLayoutSettings(model: model, settingsMode: .bento)
        VStack(spacing: 0) {
            settings.paneGapRow.frame(height: 100)
            settings.glassTransparencyRow.frame(height: 100)
            settings.resizeGroup
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
