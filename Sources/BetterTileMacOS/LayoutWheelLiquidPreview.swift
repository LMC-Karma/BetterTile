import AppKit
import BetterTileCore
import SwiftUI

public enum LayoutWheelPreviewMode: Sendable { case liquid, panel }

public struct LayoutWheelPreviewPlayback: Equatable, Sendable {
    public enum Motion: Sendable { case opening, closing }
    public var generation: Int
    public var motion: Motion
    public init(generation: Int, motion: Motion) { self.generation = generation; self.motion = motion }
}

/// Drawing and hit testing switch together when the embedded renderer falls back.
public struct LayoutWheelPreviewGeometry {
    public let configuration: LayoutWheelConfiguration
    public let mode: LayoutWheelPreviewMode
    public init(configuration: LayoutWheelConfiguration, mode: LayoutWheelPreviewMode) {
        self.configuration = configuration; self.mode = mode
    }
    public var content: LayoutWheelLiquidContent { LayoutWheelLiquidDefaults.content(configuration: configuration) }
    public var metrics: LayoutWheelMetrics {
        (configuration.style == .grouped ? LayoutWheelMetrics.grouped : .standard).scaled(by: configuration.scale)
    }
    public var diameter: Double {
        mode == .liquid ? content.diameter : configuration.style == .grouped
            ? metrics.groupedPresentationDiameter : metrics.presentationDiameter(for: configuration.effectiveLevelCount)
    }
    public func update(vector: BTPoint, at now: TimeInterval, fan: inout LayoutWheelFanState) -> LayoutWheelSelection? {
        if configuration.style == .grouped {
            if mode == .liquid, content.submenuLayout != nil {
                LayoutWheelLiquidDefaults.updateFan(&fan, vector: vector, at: now, content: content, configuration: configuration)
            } else {
                fan.update(vector: vector, at: now, geometry: metrics.fanGeometry(for: configuration))
            }
            return fan.selection
        }
        return (mode == .liquid ? content.wheelGeometry : metrics.geometry(for: configuration.effectiveLevelCount))
            .selection(for: vector, levelCount: configuration.effectiveLevelCount)
    }
}

/// A rehearsal with no window-system or command-dispatch callback.
public struct LayoutWheelLiquidPreview: NSViewRepresentable {
    public var configuration: LayoutWheelConfiguration
    public var overlayAppearance: OverlayAppearance
    public var selection: LayoutWheelSelection?
    public var fan: LayoutWheelFanState
    public var pointer: BTPoint?
    public var currentMode: LayoutMode?
    public var playback: LayoutWheelPreviewPlayback?
    public var modeChanged: (LayoutWheelPreviewMode) -> Void

    public init(configuration: LayoutWheelConfiguration, overlayAppearance: OverlayAppearance,
                selection: LayoutWheelSelection?, fan: LayoutWheelFanState, pointer: BTPoint?,
                currentMode: LayoutMode?, playback: LayoutWheelPreviewPlayback? = nil,
                modeChanged: @escaping (LayoutWheelPreviewMode) -> Void = { _ in }) {
        self.configuration = configuration; self.overlayAppearance = overlayAppearance
        self.selection = selection; self.fan = fan; self.pointer = pointer; self.currentMode = currentMode
        self.playback = playback; self.modeChanged = modeChanged
    }

    @MainActor public final class Coordinator: NSObject {
        let renderer: LayoutWheelLiquidPresenter
        var prepareHandler: @MainActor () -> Bool = LayoutWheelLiquidPresenter.prepare
        var openHandler: ((LayoutWheelLiquidContent, LayoutWheelLiquidState) -> Bool)?
        var endHandler: ((LayoutWheelLiquid.Ending) -> Void)?
        var content: LayoutWheelLiquidContent?
        private var contentInputs: (configuration: LayoutWheelConfiguration, mode: LayoutMode?)?
        var appearance: OverlayAppearance?
        var fallback: NSHostingView<LayoutWheelView>?
        var lastPlayback: LayoutWheelPreviewPlayback?
        private weak var host: NSView?
        private var currentState = LayoutWheelLiquidState()
        private var currentFan = LayoutWheelFanState()
        private var restoreTask: Task<Void, Never>?
        private var didInstall = false
        private var windowIsClosed = false
        private var quietResize = false
        private var motionBeforeResize: Bool?
        private var isShowing = false
        private var drawingContent: LayoutWheelLiquidContent?
        private var modeChanged: (LayoutWheelPreviewMode) -> Void = { _ in }

        init(renderer: LayoutWheelLiquidPresenter = .init()) {
            self.renderer = renderer
            super.init()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(refresh),
                name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSColor.systemColorsDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosed(_:)), name: NSWindow.willCloseNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowOpened(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
            // A rebuild that cannot draw the open wheel closes it. Use the panel
            // presentation, as a gesture does, instead of a blank or stale preview.
            renderer.onOpenWheelLost = { [weak self] in self?.rendererLost() }
            renderer.onClosed = { [weak self] in
                guard let self, !self.windowIsClosed, self.lastPlayback?.motion == .closing else { return }
                self.restoreTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled, let content = self.content, self.host?.window?.isVisible == true else { return }
                    self.show(content, state: self.currentState, settled: true)
                }
            }
        }
        isolated deinit {
            restoreTask?.cancel()
            renderer.onClosed = nil
            renderer.onOpenWheelLost = nil
            renderer.close()
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            DistributedNotificationCenter.default().removeObserver(self)
            NotificationCenter.default.removeObserver(self)
        }

        private func rendererLost() {
            restoreTask?.cancel(); restoreTask = nil
            isShowing = false
            drawingContent = nil
            guard fallback == nil else { return }
            installFallback()
            if let content, let appearance {
                _ = updateFallback(content.configuration, appearance, currentState, content.currentMode)
            }
        }

        @objc private func windowClosed(_ note: Notification) {
            guard note.object as? NSWindow === host?.window else { return }
            restoreTask?.cancel(); restoreTask = nil
            isShowing = false
            windowIsClosed = true
            renderer.close()
        }
        @objc private func windowOpened(_ note: Notification) {
            guard note.object as? NSWindow === host?.window else { return }
            windowIsClosed = false
            restoreTask?.cancel(); restoreTask = nil
            guard !isShowing, fallback == nil, let content else { return }
            show(content, state: currentState, settled: true)
        }

        @objc private func refresh() {
            guard !windowIsClosed else { return }
            guard let content, let appearance else { return }
            LayoutWheelLiquidDefaults.apply(to: renderer, configuration: content.configuration, appearance: appearance)
            renderer.refreshAppearance()
        }

        func update(_ view: NSView, configuration: LayoutWheelConfiguration, appearance: OverlayAppearance,
                    state: LayoutWheelLiquidState, fan: LayoutWheelFanState = .init(), currentMode: LayoutMode?, playback: LayoutWheelPreviewPlayback?,
                    modeChanged: @escaping (LayoutWheelPreviewMode) -> Void) {
            host = view
            self.modeChanged = modeChanged
            currentState = state
            currentFan = fan
            // Content is rebuilt only when the configuration or the mode changes, not for every hover sample.
            let next: LayoutWheelLiquidContent
            if let content, contentInputs?.configuration == configuration, contentInputs?.mode == currentMode {
                next = content
            } else {
                next = LayoutWheelLiquidScene.content(configuration: configuration, currentMode: currentMode)
                contentInputs = (configuration, currentMode)
            }
            let previous = content
            let overlayChanged = self.appearance != appearance
            let changed = previous != next || overlayChanged
            let styleChanged = previous?.configuration.appearance.liquid.preset != configuration.appearance.liquid.preset
            let sizeChanged = previous?.configuration.appearance.size != configuration.appearance.size
            let play = playback != nil && playback != lastPlayback
            if windowIsClosed {
                content = next
                self.appearance = appearance
                LayoutWheelLiquidDefaults.apply(to: renderer, configuration: configuration, appearance: appearance)
                return
            }
            if !didInstall {
                didInstall = true
                if prepareHandler() {
                    let drawing = renderer.makePreviewView()
                    drawing.removeFromSuperview()
                    view.addSubview(drawing)
                } else { installFallback() }
            }
            content = next
            self.appearance = appearance
            if updateFallback(configuration, appearance, state, currentMode) {
                lastPlayback = playback
                return
            }
            if changed {
                LayoutWheelLiquidDefaults.apply(to: renderer, configuration: configuration, appearance: appearance)
            }
            if !isShowing || styleChanged || play || sizeChanged {
                restoreTask?.cancel()
                show(next, state: state, settled: sizeChanged && !styleChanged && !play)
            } else {
                // Look edits refresh in place. Feel takes effect on Play or the next open.
                let drawing = drawingContent.flatMap { LayoutWheelLiquidDefaults.sameDrawingContent($0, next) ? $0 : nil } ?? next
                renderer.update(drawing, state: state)
                // The update can lose the renderer and install the fallback.
                if fallback != nil {
                    _ = updateFallback(configuration, appearance, state, currentMode)
                    lastPlayback = playback
                    return
                }
                drawingContent = drawing
                let lookChanged = previous?.configuration.appearance.liquid.look != configuration.appearance.liquid.look
                    || previous?.configuration.appearance.liquid.translucency != configuration.appearance.liquid.translucency
                    || previous?.configuration.appearance.liquid.appearance != configuration.appearance.liquid.appearance
                if lookChanged || overlayChanged || (previous.map { !LayoutWheelLiquidDefaults.sameDrawingContent($0, next) } ?? true) { renderer.refreshAppearance() }
            }
            if play, playback?.motion == .closing {
                if let endHandler { endHandler(.cancel) } else { renderer.end(.cancel) }
            }
            lastPlayback = playback
            renderer.previewView.frame = CGRect(x: 0, y: 0, width: next.diameter, height: next.diameter)
            // Open can install a fallback after the earlier check.
            _ = updateFallback(configuration, appearance, state, currentMode)
        }

        private func updateFallback(_ configuration: LayoutWheelConfiguration, _ appearance: OverlayAppearance,
                                    _ state: LayoutWheelLiquidState, _ mode: LayoutMode?) -> Bool {
            guard let fallback else { return false }
            fallback.rootView = fallbackView(configuration, appearance, state, mode)
            let diameter = LayoutWheelPreviewGeometry(configuration: configuration, mode: .panel).diameter
            fallback.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            return true
        }

        private func show(_ content: LayoutWheelLiquidContent, state: LayoutWheelLiquidState, settled: Bool) {
            if settled {
                if !quietResize { motionBeforeResize = renderer.reduceMotion }
                quietResize = true
                renderer.reduceMotion = true
            } else if quietResize {
                renderer.reduceMotion = motionBeforeResize
                quietResize = false
            }
            let opened = openHandler?(content, state)
                ?? renderer.open(content, center: .init(x: 0, y: 0), state: state, inPanel: false)
            if opened { isShowing = true; drawingContent = content }
            else { installFallback() }
        }

        private func installFallback() {
            renderer.close()
            renderer.previewView.removeFromSuperview()
            guard let host else { return }
            let view = NSHostingView(rootView: LayoutWheelView(configuration: .init()))
            fallback = view
            host.addSubview(view)
            // Defer SwiftUI's geometry update until after the representable update.
            Task { @MainActor [weak self] in self?.modeChanged(.panel) }
        }

        private func fallbackView(_ configuration: LayoutWheelConfiguration, _ appearance: OverlayAppearance,
                                  _ state: LayoutWheelLiquidState, _ mode: LayoutMode?) -> LayoutWheelView {
            LayoutWheelView(configuration: configuration, overlayAppearance: appearance,
                            selection: state.selection, fan: currentFan, currentMode: mode)
        }

        func stop() {
            restoreTask?.cancel(); restoreTask = nil
            host = nil
            renderer.onClosed = nil
            renderer.onOpenWheelLost = nil
            renderer.close()
            renderer.previewView.removeFromSuperview()
        }
    }

    #if BETTERTILE_TEST_HOOKS
    /// Lets a test reach the coordinator that SwiftUI creates when it hosts the preview.
    @MainActor static var coordinatorCreatedForTesting: ((Coordinator) -> Void)?
    #endif
    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        #if BETTERTILE_TEST_HOOKS
        Self.coordinatorCreatedForTesting?(coordinator)
        #endif
        return coordinator
    }
    public func makeNSView(context: Context) -> NSView { let view = NSView(); view.wantsLayer = true; return view }
    public func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(view, configuration: configuration, appearance: overlayAppearance,
            state: LayoutWheelLiquidScene.state(selection: selection, fan: fan, pointer: pointer),
            fan: fan, currentMode: currentMode,
            playback: playback, modeChanged: modeChanged)
    }
    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }
}
