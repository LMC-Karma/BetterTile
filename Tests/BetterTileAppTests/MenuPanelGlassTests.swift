import AppKit
import BetterTileCore
import SwiftUI
import Testing
@testable import BetterTileApp
@testable import BetterTileMacOS

@MainActor private func menuGlassDescendant<T: NSView>(_ root: NSView, of type: T.Type) -> T? {
    if let match = root as? T { return match }
    let content = (root as? NSGlassEffectView)?.contentView.map { [$0] } ?? []
    for child in root.subviews + content {
        if let match = menuGlassDescendant(child, of: type) { return match }
    }
    return nil
}

@MainActor private func menuGlassViews<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
    let content = (root as? NSGlassEffectView)?.contentView.map { [$0] } ?? []
    return ((root as? T).map { [$0] } ?? []) + (root.subviews + content).flatMap { menuGlassViews($0, of: type) }
}

@MainActor private func menuPanelSettle(_ window: NSWindow) {
    turnNativeRunLoop(layout: window.contentView)
}

@MainActor private func menuPanelNextTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@Suite(.appTestApplication, .serialized, .settingsUI) @MainActor struct MenuPanelGlassTests {
    @Test func panelTextNeverRequestsSecondaryOrColouredLabelInk() throws {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTileApp/BetterTileApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "private struct BetterTileMenuPanel:"))
        let end = try #require(source.range(of: "struct MenuPanelScrollView<"))
        let panel = String(source[start.lowerBound ..< end.lowerBound])
        #expect(!panel.contains(".foregroundStyle(.secondary)"))
        #expect(!panel.contains("UpdateVersionBadge(")) // Its fixed white/blue style belongs to Settings.
        #expect(!panel.contains(".foregroundStyle(.white)"))
        #expect(!panel.contains("Label(feedback.message, systemImage:"))
        #expect(!panel.contains("Label(\"Accessibility required\", systemImage:"))
        let rootIsPrimary = panel.contains(".foregroundStyle(PopupGlass.secondaryText)\n        .padding(MenuPanelMetrics.padding)")
        #expect(rootIsPrimary)
        // A root primary role covers title, pill, captions and action count. Standalone
        // controls, action tiles and footer must also establish that role for previews.
        for (name, next) in [("struct MenuPanelContent<", "enum MenuPanelStatusButton"),
                             ("struct MenuPanelControls:", "struct MenuPanelActionButton:"),
                             ("struct MenuActionButtonStyle:", "struct ShortcutLabel:"),
                             ("struct MenuPanelFooter:", "struct MenuPanelScrollView<")] {
            let begin = try #require(source.range(of: name))
            let finish = try #require(source.range(of: next))
            let establishesPrimary = source[begin.lowerBound ..< finish.lowerBound]
                .contains(".foregroundStyle(PopupGlass.secondaryText)")
            #expect(establishesPrimary, "\(name) must establish the popup's primary label role")
        }
    }

    @Test(arguments: [false, true])
    func panelShortcutInkResolvesToPrimaryInBothAppearances(dark: Bool) throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }
        // One render keeps both samples in the same drawing pass even if macOS changes.
        // Integral frames keep their glyph rasterization aligned to identical pixels.
        var capture: Result<NSBitmapImageRep, Error>!
        appearance.performAsCurrentDrawingAppearance {
            capture = Result {
                let surface = Color(nsColor: .windowBackgroundColor)
                let actual = ShortcutLabel(shortcut: nil, emptyLabel: "Window actions")
                    .frame(width: 160, height: 40).background(surface)
                let primary = HStack(spacing: 4) { Text("Window actions") }
                    .font(.system(size: 11, weight: .medium)).fixedSize()
                    .foregroundStyle(.primary).frame(width: 160, height: 40).background(surface)
                let renderer = ImageRenderer(content: HStack(spacing: 0) { actual; primary }
                    .environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                return NSBitmapImageRep(cgImage: image)
            }
        }
        let bitmap = try capture.get()
        #expect(bitmap.pixelsWide == 640 && bitmap.pixelsHigh == 80)
        var differences = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<320 {
            if bitmap.colorAt(x: x, y: y) != bitmap.colorAt(x: x + 320, y: y) { differences += 1 }
        } }
        #expect(differences == 0)
    }

    @Test(arguments: [false, true])
    func menuAndSettingsPopupsShareTheAppAppearanceFloor(dark: Bool) throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        // Simulate the opposite system appearance, then apply the app appearance to each window.
        NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        let menu = MenuPanelController(rootView: Color.clear.frame(width: 332, height: 100),
                                       appearance: .init(), presentWindow: { _ in })
        let settings = SettingsPickerController(content: NSView(), size: NSSize(width: 430, height: 520),
                                                appearance: .init(), onDismiss: {})
        defer {
            menu.dismiss(); menu.panel.close(); settings.panel.close()
            NSApp.appearance = previous
        }
        let appAppearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        for window in [menu.panel, settings.panel] {
            window.appearance = appAppearance
        }
        for host in [menu.glass, settings.glass] {
            let backing = host.backing
            backing.popupLaunchArguments = { ["BetterTile", "-BetterTilePopupDarkPlateFloor", "0.47"] }
            backing.displayOptions = { (false, false) }
            for (strength, slider) in [(0.0, 0.0), (0.5, 0.11), (1.0, 0.22)] {
                host.overlayAppearance = .init(strength: strength)
#if DEBUG
                let expected = max(dark ? 0.47 : 0.20, slider)
#else
                let expected = max(dark ? 0.35 : 0.20, slider)
#endif
                #expect(backing.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == (dark ? .darkAqua : .aqua))
                #expect(backing.plateOpacity == expected)
                #expect(abs(Double(try #require(backing.plate.layer?.backgroundColor?.alpha)) - expected) < 0.001)
            }
            for options in [(true, false), (false, true)] {
                backing.displayOptions = { options }
                backing.refreshAppearance()
                #expect(backing.plateOpacity == 1 && !backing.showsGlass)
            }
            backing.displayOptions = { (false, false) }
            host.overlayAppearance = .init(useLiquidGlass: false)
            #expect(backing.plateOpacity == 1)
        }
    }

    @Test(arguments: [false, true])
    func panelCardUsesSemanticDarkFillAndKeepsLightFill(dark: Bool) throws {
        func pixels(_ style: some ShapeStyle) throws -> Data {
            let renderer = ImageRenderer(content: Rectangle().fill(style).frame(width: 32, height: 32)
                .environment(\.colorScheme, dark ? .dark : .light))
            let image = try #require(renderer.cgImage)
            return try #require(NSBitmapImageRep(cgImage: image).tiffRepresentation)
        }
        let actual = try pixels(PanelSurface.card(for: dark ? .dark : .light))
        let expected = try dark ? pixels(.fill.quaternary) : pixels(Color.white.opacity(0.52))
        #expect(actual == expected)
    }

    @Test(arguments: [false, true])
    func panelHostsPopupGlassWithUnchangedWidthAndOpaqueFallbacks(dark: Bool) throws {
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let panel = MenuPanelContent(model: model, openSetup: {}, openSettings: {}, quit: {}) {
            LazyVGrid(columns: MenuPanelMetrics.columns, spacing: MenuPanelMetrics.gap) {
                ForEach(model.configuration.menuBarActions) { action in
                    MenuPanelActionButton(action: action, shortcut: nil) {}
                }
            }
        } notice: { EmptyView() }
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let controller = MenuPanelController(rootView: panel, appearance: .init(), presentWindow: { _ in })
        defer { controller.dismiss(); controller.panel.close(); NSApp.appearance = previousAppearance }
        controller.show(relativeTo: NSRect(x: 600, y: 800, width: 24, height: 24),
                        visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        menuPanelSettle(controller.panel)
        #expect(MenuPanelMetrics.width == 332)
        #expect(controller.panel.frame.width == 332)
        let glass = try #require(menuGlassDescendant(controller.panel.contentView!, of: PopupGlassHost.self))
        #expect(menuGlassViews(controller.panel.contentView!, of: NSGlassEffectView.self).count == 1)
        #expect(controller.panel.styleMask == [.borderless])
        #expect(!controller.panel.isOpaque && controller.panel.backgroundColor == .clear)
        #expect(controller.panel.hasShadow && controller.panel.canBecomeKey)
        let backing = glass.backing
        backing.displayOptions = { (false, false) }
        backing.refreshAppearance()
        #expect(glass.frame.width == 332)
        #expect(backing.isPopup && backing.glass.style == .regular)
        #expect(backing.cornerRadius == 12)
        let content = try #require(backing.popupContent)
        #expect(backing.glass.contentView.map { content.isDescendant(of: $0) } == true)
        #expect(menuGlassDescendant(content, of: NSSegmentedControl.self) == nil)
        let modePicker = try #require(menuGlassDescendant(content, of: MenuPanelModeControl.self))
        #expect(modePicker.frame.width == 284 && modePicker.frame.height == 24)
        for (strength, slider) in [(0.0, 0.0), (0.5, 0.11), (1.0, 0.22)] {
            let expected = max(dark ? 0.35 : 0.20, slider)
            glass.overlayAppearance = OverlayAppearance(strength: strength)
            #expect(backing.plateOpacity == expected)
            #expect(abs(Double(try #require(backing.plate.layer?.backgroundColor?.alpha)) - expected) < 0.001)
        }
        for options in [(true, false), (false, true)] {
            backing.displayOptions = { options }
            backing.refreshAppearance()
            #expect(!backing.showsGlass)
            #expect(backing.plateOpacity == 1)
            #expect(backing.plate.layer?.backgroundColor?.alpha == 1)
            #expect(backing.plate.layer?.borderWidth == 1)
            #expect(content.window === controller.panel && !content.isHiddenOrHasHiddenAncestor)
            #expect(glass.frame.width == 332)
        }
        if let directory = ProcessInfo.processInfo.environment["BT_PANEL_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = GlassPopupScene.capture(glass, includingGlass: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("panel-\(dark ? "dark" : "light")-opaque.png"))
        }
        backing.displayOptions = { (false, false) }
        glass.overlayAppearance = OverlayAppearance(useLiquidGlass: false)
        #expect(!backing.showsGlass && backing.plateOpacity == 1)
        #expect(backing.plate.layer?.backgroundColor?.alpha == 1)
        let oldFrame = controller.panel.frame
        model.configuration.menuBarActions = []
        menuPanelSettle(controller.panel)
        #expect(controller.panel.frame.height < oldFrame.height)
        #expect(controller.panel.frame.maxY == oldFrame.maxY)
        #expect(controller.panel.frame.width == 332)
    }

    @Test(arguments: [false, true])
    func appAppearanceOverridesTheOppositeSystemAppearance(appDark: Bool) throws {
        _ = NSApplication.shared
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        let app = try #require(NSAppearance(named: appDark ? .darkAqua : .aqua))
        let system = try #require(NSAppearance(named: appDark ? .aqua : .darkAqua))
        let model = makeModel(system: FakeAppWindowSystem())
        defer { model.shutdown() }
        let content = MenuPanelContent(model: model) { MenuAppearanceProbe() } notice: { EmptyView() }
        let controller = MenuPanelController(rootView: content, appearance: .init(), presentWindow: { _ in })
        defer { controller.dismiss(); controller.panel.close() }
        // Simulate a menu-bar window retaining the opposite macOS appearance.
        controller.panel.appearance = system
        NSApp.appearance = app
        controller.show(relativeTo: NSRect(x: 600, y: 800, width: 24, height: 24),
                        visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        menuPanelSettle(controller.panel)
        let backing = controller.glass.backing
        backing.displayOptions = { (false, false) }
        backing.refreshAppearance()
        let expected: NSAppearance.Name = appDark ? .darkAqua : .aqua
        #expect(controller.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        #expect(backing.glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        let controls = try #require(backing.popupContent)
        let segment = try #require(menuGlassDescendant(controls, of: MenuPanelModeControl.self))
        #expect(segment.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        let probe = try #require(menuGlassViews(controls, of: NSTextField.self).first { $0.identifier?.rawValue == "appearance-probe" })
        #expect(probe.stringValue == (appDark ? "dark" : "light"))
        #expect(probe.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        var expectedPlate: CGColor?
        app.performAsCurrentDrawingAppearance {
            expectedPlate = NSColor.windowBackgroundColor.withAlphaComponent(appDark ? 0.35 : 0.20).cgColor
        }
        #expect(backing.plate.layer?.backgroundColor == expectedPlate)
        #expect(!controller.panel.isVisible && !controller.panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(controller.panel)))
    }

    @Test func statusItemToggleOutsideClickAndEscapeCloseThePanelOffscreen() throws {
        _ = NSApplication.shared
        var presentations = 0, dismissals = 0
        let controller = MenuPanelController(rootView: Text("Menu").frame(width: 332, height: 300), appearance: .init(),
            presentWindow: { _ in presentations += 1 }, onDismiss: { dismissals += 1 })
        defer { controller.dismiss(); controller.panel.close() }
        let anchor = NSRect(x: 600, y: 800, width: 24, height: 24)
        let screen = NSRect(x: 0, y: 0, width: 1200, height: 800)
        controller.toggle(relativeTo: anchor, visibleFrame: screen)
        #expect(controller.isShown && presentations == 1)
        controller.toggle(relativeTo: anchor, visibleFrame: screen)
        #expect(!controller.isShown && dismissals == 1)
        controller.toggle(relativeTo: anchor, visibleFrame: screen)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        #expect(controller.route(escape) == nil)
        #expect(!controller.isShown && dismissals == 2)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        controller.panel.cancelOperation(nil)
        #expect(!controller.isShown && dismissals == 3)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(controller.route(click, isOverStatusItem: true) === click)
        #expect(controller.isShown)
        #expect(controller.route(click, isExcludedWindow: true) === click)
        #expect(controller.isShown)
        #expect(controller.route(click) === click)
        #expect(!controller.isShown && dismissals == 4)
        controller.dismiss()
        #expect(dismissals == 4)
        #expect(controller.panel.animationBehavior == .none)
        #expect(!controller.panel.isVisible && !controller.panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(controller.panel)))
    }

    enum HighlightExit: CaseIterable { case outsideClick, escape, toggle, programmatic, cancel }

    @Test(arguments: HighlightExit.allCases)
    func statusButtonStaysOnUntilEveryDismissalPath(exit: HighlightExit) async throws {
        _ = NSApplication.shared
        let statusItem = NSStatusBar.system.statusItem(withLength: 0)
        statusItem.autosaveName = nil
        statusItem.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try #require(statusItem.button)
        MenuPanelStatusButton.configure(button)
        var callbacks: [String] = []
        let controller = MenuPanelController(rootView: Text("Menu").frame(width: 332, height: 300), appearance: .init(),
            presentWindow: { _ in callbacks.append("present") },
            onShow: { MenuPanelStatusButton.setPanelShown(true, on: button); callbacks.append("show") },
            onDismiss: { MenuPanelStatusButton.setPanelShown(false, on: button); callbacks.append("dismiss") })
        defer { controller.dismiss(); controller.panel.close() }
        let anchor = NSRect(x: 600, y: 1056, width: 24, height: 24)
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        #expect(button.state == .on)
        #expect(callbacks.prefix(2) == ["present", "show"])
        button.state = .off // Simulate the status button's mouse-up tracking reset.
        await menuPanelNextTurn()
        #expect(button.state == .on)
        switch exit {
        case .outsideClick:
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            _ = controller.route(event)
        case .escape:
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: controller.panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
            #expect(controller.route(event) == nil)
        case .toggle: controller.toggle(relativeTo: anchor, visibleFrame: screen)
        case .programmatic: controller.dismiss()
        case .cancel: controller.panel.cancelOperation(nil)
        }
        #expect(!controller.isShown && button.state == .off)
        #expect(callbacks.last == "dismiss")
        await menuPanelNextTurn()
        #expect(button.state == .off)
    }

    @Test func statusButtonClearsWhenOpeningHasNoAnchor() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = nil
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        MenuPanelStatusButton.configure(button)
        let window = OffscreenTestWindow(contentRect: NSRect(x: 12000, y: 0, width: 24, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1055)
        for (visible, hasWindow, hasScreen) in [(true, false, true), (true, true, false), (false, true, true)] {
            button.state = .on // AppKit toggles before delivering the action.
            button.isHighlighted = true
            let geometry = MenuPanelStatusButton.presentationGeometry(for: button, isVisible: visible,
                window: hasWindow ? window : nil, visibleFrame: hasScreen ? frame : nil)
            #expect(geometry == nil)
            #expect(button.state == .off && !button.isHighlighted)
        }
        #expect(!window.isVisible)
    }

    @Test func nativeStatusButtonActionsToggleAndRestoreTheClosedState() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = nil
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        MenuPanelStatusButton.configure(button)
        let anchor = NSRect(x: 600, y: 1056, width: 24, height: 24)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        let controller = MenuPanelController(rootView: Text("Menu"), appearance: .init(), presentWindow: { _ in },
            onShow: { MenuPanelStatusButton.setPanelShown(true, on: button) },
            onDismiss: { MenuPanelStatusButton.setPanelShown(false, on: button) })
        defer { controller.dismiss(); controller.panel.close() }
        let target = MenuPanelStatusAction { controller.toggle(relativeTo: anchor, visibleFrame: visible) }
        button.target = target
        button.action = #selector(MenuPanelStatusAction.invoke)
        // Dispatch the real control's action without entering system menu-bar tracking.
        #expect(button.sendAction(button.action, to: target))
        await menuPanelNextTurn()
        #expect(controller.isShown && button.state == .on)
        // Dispatch the real control's action without entering system menu-bar tracking.
        #expect(button.sendAction(button.action, to: target))
        await menuPanelNextTurn()
        #expect(!controller.isShown && button.state == .off)
        // Also clear a native tracking state when a programmatic/context close finds no panel.
        button.state = .on
        MenuPanelStatusButton.setPanelShown(false, on: button)
        #expect(button.state == .off && !button.isHighlighted)
    }

    @Test func globalStatusMouseDownThenMouseUpClosesANonKeyPanelExactlyOnce() async throws {
        _ = NSApplication.shared
        var presentations = 0, dismissals = 0
        let controller = MenuPanelController(rootView: Text("Menu").frame(width: 332, height: 300), appearance: .init(),
            presentWindow: { _ in presentations += 1 }, onDismiss: { dismissals += 1 })
        defer { controller.dismiss(); controller.panel.close() }
        let anchor = NSRect(x: 600, y: 1056, width: 24, height: 24)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        controller.show(relativeTo: anchor, visibleFrame: visible)
        #expect(controller.isShown && !controller.panel.isKeyWindow, Comment(rawValue: keyWindowDiagnostics(controller.panel)))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        // A non-key status click can reach the global monitor before the button's mouse-up action.
        controller.routeGlobalMouseDown(down, isOverStatusItem: true)
        #expect(controller.isShown)
        controller.toggle(relativeTo: anchor, visibleFrame: visible) // Status button's mouse-up action.
        await menuPanelNextTurn()
        #expect(!controller.isShown && presentations == 1 && dismissals == 1)
        controller.show(relativeTo: anchor, visibleFrame: visible)
        controller.routeGlobalMouseDown(down, isOverStatusItem: false)
        #expect(!controller.isShown && dismissals == 2)
    }

    @Test func deferredShowCallbackCannotRehighlightAfterDismissalOrAReplacementShow() async {
        _ = NSApplication.shared
        var shows = 0, highlighted = false
        let controller = MenuPanelController(rootView: Text("Menu").frame(width: 332, height: 300), appearance: .init(),
            presentWindow: { _ in }, onShow: { shows += 1; highlighted = true }, onDismiss: { highlighted = false })
        defer { controller.dismiss(); controller.panel.close() }
        let anchor = NSRect(x: 600, y: 1056, width: 24, height: 24)
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        controller.dismiss()
        await menuPanelNextTurn()
        #expect(shows == 1 && !highlighted)
        controller.show(relativeTo: anchor, visibleFrame: screen)
        controller.dismiss()
        controller.show(relativeTo: anchor, visibleFrame: screen)
        await menuPanelNextTurn()
        #expect(shows == 4 && highlighted) // Three immediate calls, one current deferred call.
    }

    @Test func escapePassesThroughForSettingsOrSetupWithoutDismissingThePanel() throws {
        _ = NSApplication.shared
        let controller = MenuPanelController(rootView: Text("Menu").frame(width: 332, height: 300), appearance: .init(),
            presentWindow: { _ in })
        defer { controller.dismiss(); controller.panel.close() }
        controller.show(relativeTo: NSRect(x: 600, y: 1056, width: 24, height: 24),
                        visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(controller.route(event, isExcludedWindow: true) === event)
        #expect(controller.isShown)
        #expect(controller.route(event) == nil)
        #expect(!controller.isShown)
    }

    @Test(arguments: [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: 1920, y: 0, width: 2560, height: 1440)])
    func panelUsesFourPointTopGapOnRealisticMenuBarAnchors(screen: NSRect) {
        let visible = NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - 24)
        let anchor = NSRect(x: screen.midX, y: visible.maxY, width: 24, height: 24)
        let frame = MenuPanelController<Text>.frame(height: 600, anchor: anchor, visibleFrame: visible)
        #expect(visible.maxY - frame.maxY == 4)
        #expect(abs(frame.midX - anchor.midX) <= 1)
        let edge = NSRect(x: screen.maxX - 24, y: visible.maxY, width: 24, height: 24)
        let clamped = MenuPanelController<Text>.frame(height: 600, anchor: edge, visibleFrame: visible)
        #expect(screen.maxX - clamped.maxX == 8)
        #expect(visible.maxY - clamped.maxY == 4)
        let left = NSRect(x: screen.minX, y: visible.maxY, width: 24, height: 24)
        let leftClamped = MenuPanelController<Text>.frame(height: 600, anchor: left, visibleFrame: visible)
        #expect(leftClamped.minX - visible.minX == 8)
    }

    @Test func panelIsAnchoredAndClampedInsideTheVisibleFrame() {
        let screen = NSRect(x: -1440, y: 80, width: 1440, height: 900)
        for x in [-1430.0, -720.0, -20.0] {
            let anchor = NSRect(x: x, y: 1000, width: 24, height: 24)
            let frame = MenuPanelController<Text>.frame(height: 600, anchor: anchor, visibleFrame: screen)
            #expect(frame.width == 332 && frame.height == 600)
            #expect(frame.minX >= screen.minX + 8 && frame.maxX <= screen.maxX - 8)
            #expect(frame.minY >= screen.minY + 8 && frame.maxY <= screen.maxY - 4)
            #expect(frame.maxY <= anchor.minY - 4)
            if x == -720 { #expect(frame.midX == anchor.midX) }
        }
    }

}

private struct MenuAppearanceProbe: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.identifier = NSUserInterfaceItemIdentifier("appearance-probe")
        label.textColor = .labelColor
        return label
    }
    func updateNSView(_ view: NSTextField, context: Context) {
        view.stringValue = scheme == .dark ? "dark" : "light"
    }
}


@MainActor private final class MenuPanelStatusAction: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
