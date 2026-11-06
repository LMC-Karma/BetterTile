import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor @Suite(.appTestApplication, .serialized) struct WindowLayoutSettingsSnapshotTests {
    private enum State: String, CaseIterable {
        case adaptive, tabbed, modified
    }

    @Test func rendersWindowLayoutStates() throws {
        let directory = ProcessInfo.processInfo.environment["BT_SNAPSHOT_DIR"]
        let states: [State] = directory == nil ? [.adaptive, .modified] : State.allCases
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
                $0.keepsDesktopLayoutsAcrossDisplays = false
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
                // layout. macOS 26 does not deliver a queued synthetic drag to a control that tracks the press, so the
                // test clicks the track instead: the same native press moves the knob to the clicked point.
                let trackX = width - 12 - 44 - 8 - 220
                let gapTrack = CGRect(x: trackX, y: 40, width: 220, height: 20)
                let glassTrack = CGRect(x: trackX, y: 131, width: 220, height: 20)
                func point(on track: CGRect, at fraction: Double) -> CGPoint {
                    host.view.convert(CGPoint(x: track.minX + 8 + (track.width - 16) * fraction, y: track.midY), to: nil)
                }
                // Just inside the track's end, past the knob's last centre, every slider clamps to its maximum.
                func end(of track: CGRect) -> CGPoint { host.view.convert(CGPoint(x: track.maxX - 2, y: track.midY), to: nil) }
                let picture = CGRect(x: gapTrack.minX - 8 - 64, y: gapTrack.midY - 20, width: 64, height: 40)
                let preview = try #require(previewViews(host.view).max { $0.bounds.width < $1.bounds.width })
                let lens = try #require(preview as? DividerLensPreviewView)
                let previewFrame = preview.convert(preview.bounds, to: host.view)
                let grip = CGRect(x: previewFrame.midX - 30, y: previewFrame.midY - 30, width: 60, height: 60)
                // A click is handled within a few layout passes. These waits suspend between polls and never turn the
                // main run loop, so other tests keep running; the short budget makes a missed click fail fast.
                let clickBudget = Duration.seconds(5)
                let before = try png(host)
                let beforePicture = try png(host, in: picture)
                // Check only the picture, excluding the label and readout. A stale picture must fail independently.
                try performNativeMouseClick(at: end(of: gapTrack), in: host.window)
                try await waitForSettingsUI("the clicked pane gap and its picture", in: host.view, timeout: clickBudget) {
                    model.configuration.bentoInnerGap == 12 && (try? png(host, in: picture)) != beforePicture
                }
                #expect(model.configuration.bentoInnerGap == 12)
                let afterPicture = try png(host, in: picture)
                #expect(afterPicture != beforePicture)
                host.settle()
                let beforeGlass = try png(host, in: grip)
                // The same click as the pane gap's: just inside the track's end, so the slider clamps to its maximum.
                try performNativeMouseClick(at: end(of: glassTrack), in: host.window)
                func glassState() -> String {
                    "transparency=\(model.configuration.overlayAppearance.transparency) "
                        + "preview=\(lens.handleView.overlayAppearance.transparency) glass=\(lens.handleView.showsGlass) "
                        + "frost=\(lens.handleView.showsFrost) opaque=\(lens.handleView.showsSolid)"
                }
                do {
                    try await waitForSettingsUI("the clicked glass transparency", in: host.view, timeout: clickBudget) {
                        model.configuration.overlayAppearance.transparency > 0.8
                    }
                    try await waitForSettingsUI("the glass preview to take the transparency", in: host.view, timeout: clickBudget) {
                        lens.handleView.overlayAppearance == model.configuration.overlayAppearance
                    }
                    // Only the glass surface draws the transparency. Frost and the opaque grip, chosen by Liquid Glass
                    // availability or the host's Reduce Transparency and Increase Contrast, correctly ignore it.
                    if lens.handleView.showsGlass {
                        try await waitForSettingsUI("the glass preview's picture", in: host.view, timeout: clickBudget) {
                            (try? png(host, in: grip)) != beforeGlass
                        }
                    }
                } catch {
                    print("LIVE_SLIDER dark=\(dark) width=\(width) \(glassState())")
                    throw error
                }
                print("LIVE_SLIDER dark=\(dark) width=\(width) \(glassState())")
                #expect(model.configuration.overlayAppearance.transparency > 0.8)
                let afterGlass = try png(host, in: grip)
                #expect(afterGlass != beforeGlass || !lens.handleView.showsGlass, Comment(rawValue: glassState()))
                host.settle()
                let after = try png(host)
                if let directory {
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let suffix = "\(dark ? "dark" : "light")-\(Int(width)).png"
                    try before.write(to: folder.appendingPathComponent("window-layout-live-controls-before-" + suffix))
                    try after.write(to: folder.appendingPathComponent("window-layout-live-controls-after-" + suffix))
                    try beforePicture.write(to: folder.appendingPathComponent("pane-gap-picture-before-" + suffix))
                    try afterPicture.write(to: folder.appendingPathComponent("pane-gap-picture-after-" + suffix))
                    try beforeGlass.write(to: folder.appendingPathComponent("glass-preview-before-" + suffix))
                    try afterGlass.write(to: folder.appendingPathComponent("glass-preview-after-" + suffix))
                }
                model.updateConfiguration { $0.overlayAppearance.useLiquidGlass = false }
                host.settle()
                let disabledValue = model.configuration.overlayAppearance.transparency
                // A disabled slider ignores a click on its track.
                try performNativeMouseClick(at: point(on: glassTrack, at: 0), in: host.window)
                host.settle()
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
