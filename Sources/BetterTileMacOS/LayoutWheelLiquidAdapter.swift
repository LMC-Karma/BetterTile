import AppKit
import BetterTileCore
import os

/// The single mapping from persisted liquid settings to presentation values.
public enum LayoutWheelLiquidDefaults {
    public static let overflowPadding = 14.0
    @MainActor public static let iceBlue = NSColor(srgbRed: 0.12, green: 0.52, blue: 1, alpha: 1)
    public static var systemDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    public static func lockBeyondRim(configuration: LayoutWheelConfiguration) -> LayoutWheelSubmenuLockBeyondRim {
        switch configuration.appearance.liquid.submenus.keepOpen {
        case .always: .keep
        case .withinGroupAngle: .withinGroupAngle
        }
    }

    /// How the pointer opens and aims a group's submenu. The overlay gesture and the Settings
    /// preview both call this, so the two cannot aim differently.
    public static func updateFan(_ fan: inout LayoutWheelFanState, vector: BTPoint, at now: TimeInterval,
                                 content: LayoutWheelLiquidContent, configuration: LayoutWheelConfiguration,
                                 layoutAvailable: Bool = true) {
        guard let layout = content.submenuLayout else { return }
        fan.update(vector: vector, at: now, geometry: content.wheelGeometry, layout: layout,
                   layoutAvailable: layoutAvailable, lockBeyondRim: lockBeyondRim(configuration: configuration),
                   configuration: configuration)
    }

    public static func tuning(configuration: LayoutWheelConfiguration) -> LayoutWheelLiquidTuning {
        let settings = configuration.appearance.liquid
        var value = LayoutWheelLiquidTuning.standard
        value.tension = settings.feel.tension
        value.ringing = settings.feel.ringing
        value.bulge = settings.feel.bulge
        value.stretch = settings.feel.stretch
        value.splash = settings.feel.splash
        value.magnetDamping = settings.feel.magnetDamping
        value.dropletResponse = settings.feel.dropletResponse
        value.opening = opening(settings.motion.opening)
        value.closing = closing(settings.motion.closing)
        value.drift = settings.motion.pointerLean ? settings.motion.leanAmount : 0
        return value
    }

    public static func content(configuration: LayoutWheelConfiguration,
                               unavailableCommands: Set<LayoutWheelCommand> = [],
                               layoutAvailable: Bool = true, currentMode: LayoutMode? = nil) -> LayoutWheelLiquidContent {
        .init(configuration: configuration, levelCount: configuration.effectiveLevelCount,
              submenuStyle: arrangement(configuration.appearance.liquid.submenus.arrangement),
              unavailableCommands: unavailableCommands, layoutAvailable: layoutAvailable, currentMode: currentMode)
    }

    static func opening(_ value: LayoutWheelLiquidSettings.Opening) -> LayoutWheelLiquidOpening {
        switch value { case .calm: .calm; case .rise: .rise; case .bloom: .bloom; case .quick: .quick }
    }
    static func closing(_ value: LayoutWheelLiquidSettings.Closing) -> LayoutWheelLiquidClosing {
        switch value { case .calm: .calm; case .quick: .quick; case .sink: .sink }
    }
    static func arrangement(_ value: LayoutWheelLiquidSettings.Arrangement) -> LayoutWheelSubmenuStyle {
        switch value { case .fan: .fan; case .cluster: .cluster; case .clusterAboveThree: .clusterAboveThree }
    }
    static func names(_ value: LayoutWheelLiquidSettings.Names) -> LayoutWheelLiquidPresenter.Names {
        switch value { case .centre: .centre; case .underIcons: .underIcons; case .hidden: .hidden }
    }

    @MainActor public static func accent(_ colour: LayoutWheelLiquidSettings.HighlightColour) -> NSColor? {
        switch colour {
        case .iceBlue: iceBlue
        case .champagne: NSColor(srgbRed: 0.93, green: 0.77, blue: 0.53, alpha: 1)
        case .violet: NSColor(srgbRed: 0.64, green: 0.49, blue: 0.96, alpha: 1)
        case .smokeGrey: .white
        case .noHighlight: .white
        case .systemAccent: nil
        }
    }

    @MainActor static func apply(to renderer: LayoutWheelLiquidPresenter, configuration: LayoutWheelConfiguration,
                                 appearance: OverlayAppearance, systemDark: Bool = Self.systemDark) {
        let settings = configuration.appearance.liquid
        renderer.tuning = tuning(configuration: configuration)
        // Material remains encoded for downgrade compatibility; blur now follows Appearance.
        renderer.material = .automatic
        renderer.accent = accent(settings.look.highlightColour)
        renderer.brightenHighlight = settings.look.highlightColour == .noHighlight
        renderer.neutralUnderglow = settings.look.highlightColour == .smokeGrey
        renderer.names = names(settings.look.names)
        renderer.actionTint = settings.look.actionTint
        switch settings.appearance {
        case .system: renderer.dark = nil
        case .light: renderer.dark = false
        case .dark: renderer.dark = true
        }
        renderer.translucency = (renderer.dark ?? systemDark) ? settings.translucency.dark : settings.translucency.light
        // System display options still take precedence; no saved value is rewritten.
        renderer.opaque = appearance.useLiquidGlass ? nil : true
    }

    @MainActor static func snapshotStyle(configuration: LayoutWheelConfiguration, dark: Bool, opaque: Bool = false) -> LayoutWheelLiquidStyle {
        let settings = configuration.appearance.liquid
        return .make(dark: dark, opaque: opaque,
            accent: accent(settings.look.highlightColour) ?? .controlAccentColor,
            translucency: dark ? settings.translucency.dark : settings.translucency.light,
            brightenHighlight: settings.look.highlightColour == .noHighlight,
            neutralUnderglow: settings.look.highlightColour == .smokeGrey)
    }

    /// Ignore appearance-only changes when deciding whether icon content needs rebuilding.
    static func sameDrawingContent(_ lhs: LayoutWheelLiquidContent, _ rhs: LayoutWheelLiquidContent) -> Bool {
        var a = lhs.configuration
        var b = rhs.configuration
        a.appearance = .init(size: lhs.configuration.appearance.size)
        b.appearance = .init(size: rhs.configuration.appearance.size)
        return a == b && lhs.submenuLayout == rhs.submenuLayout
            && lhs.unavailableCommands == rhs.unavailableCommands && lhs.layoutAvailable == rhs.layoutAvailable
            && lhs.currentMode == rhs.currentMode
    }
}

/// What the liquid renderer is asked to draw. The overlay gesture and the Settings preview both build
/// it here. Content is costly and changes rarely, so callers cache it; state is cheap and is built for
/// every pointer sample. The same inputs always become the same content and state.
enum LayoutWheelLiquidScene {
    static func content(configuration: LayoutWheelConfiguration, unavailableCommands: Set<LayoutWheelCommand> = [],
                        layoutAvailable: Bool = true, currentMode: LayoutMode?) -> LayoutWheelLiquidContent {
        LayoutWheelLiquidDefaults.content(configuration: configuration, unavailableCommands: unavailableCommands,
                                          layoutAvailable: layoutAvailable, currentMode: currentMode)
    }

    static func state(selection: LayoutWheelSelection?, fan: LayoutWheelFanState, pointer: BTPoint?) -> LayoutWheelLiquidState {
        .init(selection: selection, fan: fan, pointer: pointer)
    }

    static func content(_ presentation: LayoutWheelPresentation) -> LayoutWheelLiquidContent {
        content(configuration: presentation.configuration, unavailableCommands: presentation.unavailableCommands,
                layoutAvailable: presentation.layoutAvailable, currentMode: presentation.currentMode)
    }

    static func state(_ presentation: LayoutWheelPresentation) -> LayoutWheelLiquidState {
        state(selection: presentation.selection, fan: presentation.fan, pointer: presentation.pointer)
    }
}

/// Adapts the gesture's presentation to the renderer. Placements retain the
/// shared drop-cue path; the liquid renderer has no window-mutation callback.
@MainActor final class LayoutWheelLiquidAdapter: NSObject, LayoutWheelPresenting {
    let renderer: LayoutWheelLiquidPresenter
    private let placements: PlacementWireframeController
    var prewarmHandler: ((LayoutWheelLiquidContent) -> Void)?
    var pipelinePrepareHandler: @MainActor () -> Bool = LayoutWheelLiquidPresenter.prepare
    var isOpenHandler: (() -> Bool)?
    var refreshAppearanceHandler: (() -> Void)?
    var systemDarkProvider: () -> Bool = { LayoutWheelLiquidDefaults.systemDark }
    private var prewarmedDark: Bool?
    private var prewarmedNames: LayoutWheelLiquidPresenter.Names?
    var prepareHandler: ((LayoutWheelLiquidContent) -> Bool)?
    var openHandler: ((LayoutWheelLiquidContent, BTPoint, LayoutWheelLiquidState) -> Bool)?
    private var appearanceTask: Task<Void, Never>?
    private var currentContent: LayoutWheelLiquidContent?
    /// The last opened target. A hold starts before its target is captured,
    /// and the next target is usually the same desktop.
    private var lastTarget: (unavailableCommands: Set<LayoutWheelCommand>, layoutAvailable: Bool,
                             currentMode: LayoutMode?)?
    private var fallback: LayoutWheelPanelPresenter?
    /// Whether the fallback has already opened a wheel. It serves one gesture, so after that opening
    /// the next gesture starts on the liquid renderer again.
    private var fallbackHasOpened = false
    private var configuration: LayoutWheelConfiguration?
    private var appearance = OverlayAppearance()
    var usesLiquidGeometry: Bool { fallback == nil }
    var presentationFailureHandler: (@MainActor () -> Void)?
    private static let log = Logger(subsystem: "com.lmckarma.BetterTile", category: "LayoutWheel")

    static func make(prepare: @MainActor () -> Bool = LayoutWheelLiquidPresenter.prepare) -> any LayoutWheelPresenting {
        guard prepare() else {
            log.error("Liquid Layout Wheel unavailable; using the panel fallback.")
            // Starts hidden from capture. LayoutWheelController applies the
            // configured value right after it receives this presenter.
            return LayoutWheelPanelPresenter(capturePolicy: OverlayCapturePolicy())
        }
        return LayoutWheelLiquidAdapter()
    }

    init(renderer: LayoutWheelLiquidPresenter = LayoutWheelLiquidPresenter()) {
        self.renderer = renderer
        placements = PlacementWireframeController(capturePolicy: renderer.capturePolicy)
        super.init()
        renderer.onOpenWheelLost = { [weak self] in self?.presentationFailureHandler?() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appearanceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        appearanceTask?.cancel()
        renderer.close()
        placements.hide()
    }

    func setCaptureVisibility(showsInRecordings: Bool) {
        renderer.capturePolicy.showsInRecordings = showsInRecordings
    }

    func prewarm(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {
        let overlayChanged = self.appearance != appearance
        self.configuration = configuration
        self.appearance = appearance
        guard configuration.isEnabled, configuration.triggers.keyboardEnabled || configuration.triggers.mouse != .off else {
            renderer.releaseResources()
            currentContent = nil
            prewarmedDark = nil; prewarmedNames = nil
            return
        }
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: configuration, appearance: appearance, systemDark: systemDarkProvider())
        guard isOpenHandler?() ?? renderer.isOpen else {
            // Closed wheels prepare content and the atlas only when the trigger hold starts.
            currentContent = nil
            prewarmedDark = nil; prewarmedNames = nil
            _ = pipelinePrepareHandler()
            return
        }
        let next = LayoutWheelLiquidDefaults.content(configuration: configuration)
        let effectiveDark = renderer.dark ?? systemDarkProvider()
        let drawingChanged = prewarmedDark != effectiveDark || prewarmedNames != renderer.names
            || (currentContent.map({ !LayoutWheelLiquidDefaults.sameDrawingContent($0, next) }) ?? true)
        let needsRefresh = drawingChanged || overlayChanged || currentContent?.configuration.appearance != configuration.appearance
        if drawingChanged {
            if let prewarmHandler { prewarmHandler(next) } else { renderer.prewarm(next) }
            prewarmedDark = effectiveDark
            prewarmedNames = renderer.names
        }
        currentContent = next
        if needsRefresh {
            if let refreshAppearanceHandler { refreshAppearanceHandler() } else { renderer.refreshAppearance() }
        }
    }

    func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {
        LayoutWheelLiquidDefaults.apply(to: renderer, configuration: configuration, appearance: appearance, systemDark: systemDarkProvider())
        // The panel fallback serves one gesture. The next one tries the liquid renderer again,
        // so a single failure never leaves the overlay looking unlike the Settings preview.
        dropFallback()
        let content = LayoutWheelLiquidDefaults.content(configuration: configuration,
            unavailableCommands: lastTarget?.unavailableCommands ?? [],
            layoutAvailable: lastTarget?.layoutAvailable ?? true, currentMode: lastTarget?.currentMode)
        if !(prepareHandler?(content) ?? renderer.prepareToOpen(content)) {
            Self.log.error("Liquid Layout Wheel preparation failed; using the panel fallback.")
            fallback = LayoutWheelPanelPresenter(capturePolicy: renderer.capturePolicy)
            fallbackHasOpened = false
        }
    }

    /// Any gesture starts on the liquid renderer. A hold that already failed to prepare keeps its
    /// own fallback until that gesture opens.
    func beginGesture() {
        if fallbackHasOpened { dropFallback() }
    }

    private func dropFallback() {
        fallback?.close()
        fallback = nil
        fallbackHasOpened = false
    }

    func discardPreparation() {
        renderer.close()
        // A hold that ended before the wheel opened takes its fallback with it.
        if !fallbackHasOpened { dropFallback() }
    }

    func open(_ presentation: LayoutWheelPresentation) {
        if let fallback { fallbackHasOpened = true; fallback.open(presentation); return }
        lastTarget = (presentation.unavailableCommands, presentation.layoutAvailable, presentation.currentMode)
        let content = content(presentation)
        if !(openHandler?(content, presentation.placement.center, state(presentation))
             ?? renderer.open(content, center: presentation.placement.center, state: state(presentation))) {
            // Metal can fail after startup as well. Leave a usable wheel.
            Self.log.error("Liquid Layout Wheel open failed; using the panel fallback.")
            fallback = LayoutWheelPanelPresenter(capturePolicy: renderer.capturePolicy)
            fallbackHasOpened = true
            fallback?.open(presentation)
        }
    }

    func update(_ presentation: LayoutWheelPresentation) {
        if let fallback { fallback.update(presentation); return }
        renderer.update(content(presentation), state: state(presentation))
    }

    private func content(_ presentation: LayoutWheelPresentation) -> LayoutWheelLiquidContent {
        if let currentContent, currentContent.configuration == presentation.configuration,
           currentContent.unavailableCommands == presentation.unavailableCommands,
           currentContent.layoutAvailable == presentation.layoutAvailable,
           currentContent.currentMode == presentation.currentMode { return currentContent }
        let content = LayoutWheelLiquidScene.content(presentation)
        currentContent = content
        return content
    }

    private func state(_ presentation: LayoutWheelPresentation) -> LayoutWheelLiquidState {
        LayoutWheelLiquidScene.state(presentation)
    }

    func showPlacements(_ placements: [Placement]) { self.placements.show(placements) }
    func hidePlacements() { placements.hide() }
    func close() {
        renderer.close(); fallback?.close()
    }
    func end(_ acknowledgment: LayoutWheelAcknowledgment) {
        if let fallback { fallback.end(acknowledgment); return }
        renderer.end(acknowledgment == .commit ? .commit : .cancel)
    }

    @objc private func appearanceChanged() {
        appearanceTask?.cancel()
        appearanceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, let configuration = self.configuration else { return }
            self.prewarm(configuration: configuration, appearance: self.appearance)
            self.appearanceTask = nil
        }
    }
}
