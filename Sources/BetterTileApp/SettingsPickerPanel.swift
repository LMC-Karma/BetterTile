// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore
import BetterTileMacOS
import SwiftUI

/// Window-modal picker presentation without macOS's opaque system-sheet backing.
@MainActor final class SettingsPickerController {
    let panel: SettingsPickerPanel
    let glass: PopupGlassHost
    private(set) weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private let blocker = SettingsPickerBlocker()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var inputMonitor: Any?
    private var onDismiss: (() -> Void)?
    private let size: NSSize

    init(content: NSView, size: NSSize, appearance: OverlayAppearance,
         panel: SettingsPickerPanel = SettingsPickerPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false),
         onDismiss: @escaping () -> Void) {
        self.panel = panel
        self.size = size
        self.onDismiss = onDismiss
        glass = PopupGlassHost(content: content, appearance: appearance)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = glass
        panel.setContentSize(size)
        panel.onCancel = { [weak self] in self?.dismiss() }
    }

    func present(over parent: NSWindow) {
        guard self.parent == nil else { return }
        // One window-modal picker per Settings window, including across Settings pages.
        for child in parent.childWindows ?? [] {
            (child as? SettingsPickerPanel)?.onCancel?()
        }
        self.parent = parent
        previousResponder = parent.firstResponder
        panel.appearance = parent.appearance
        if let content = parent.contentView {
            blocker.frame = content.bounds
            blocker.autoresizingMask = [.width, .height]
            content.addSubview(blocker)
        }
        parent.addChildWindow(panel, ordered: .above)
        position()
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.parent?.isVisible == true, self.parent?.isOnActiveSpace == false { self.dismiss(restoringFocus: false) }
            }
        })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoringFocus: false) }
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]) { [weak self] event in
            let blocked = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.route(event) == nil
            }
            return blocked ? nil : event
        }
        // Start a fresh editing session when a retained panel is presented again.
        panel.makeFirstResponder(panel.initialFirstResponder)
        // Offscreen parents stay offscreen. Tests use this exact presentation path.
        if parent.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    /// Child sheets (Browse) keep their native input loop. Only the owning Settings window is blocked.
    func route(_ event: NSEvent) -> NSEvent? {
        guard let parent, event.window === parent else { return event }
        if parent.isVisible { panel.makeKey() }
        return nil
    }

    private func position() {
        guard let parent else { return }
        let area = parent.convertToScreen(parent.contentLayoutRect)
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
    }

    func dismiss(restoringFocus: Bool = true) {
        guard let parent else { return }
        self.parent = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        if let sheet = panel.attachedSheet {
            sheet.cancelOperation(nil)
            if panel.attachedSheet === sheet { panel.endSheet(sheet, returnCode: .cancel) }
            sheet.orderOut(nil)
        }
        // Ordering out alone leaves the field editor as first responder, with stale input state.
        panel.endEditing(for: nil)
        panel.makeFirstResponder(nil)
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        blocker.removeFromSuperview()
        if restoringFocus {
            parent.makeFirstResponder(previousResponder)
            if parent.isVisible, parent.isOnActiveSpace { parent.makeKey() }
        }
        previousResponder = nil
        let completion = onDismiss
        onDismiss = nil
        completion?()
    }

    isolated deinit {
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        blocker.removeFromSuperview()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}

@MainActor class SettingsPickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Let the field editor cancel composition or clear search before an unhandled cancel reaches us.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func close() { onCancel?(); super.close() }
}

@MainActor private final class SettingsPickerBlocker: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {}
}

extension View {
    func settingsPickerPanel<Content: View>(isPresented: Binding<Bool>, size: NSSize,
                                           appearance: OverlayAppearance,
                                           @ViewBuilder content: @escaping (@escaping () -> Void) -> Content) -> some View {
        background(SettingsPickerAnchor(isPresented: isPresented.wrappedValue, onDismiss: { isPresented.wrappedValue = false },
                                        size: size, appearance: appearance, content: { dismiss in AnyView(content(dismiss)) }))
    }
}

private struct SettingsPickerAnchor: NSViewRepresentable {
    let isPresented: Bool
    let onDismiss: () -> Void
    let size: NSSize
    let appearance: OverlayAppearance
    let content: (@escaping () -> Void) -> AnyView

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.update = { [weak view] in
            guard let view else { return }
            guard isPresented else {
                view.awaitsBindingReset = false
                view.dismiss()
                return
            }
            // The panel closed itself (Escape, parent close, Space change) and the binding is
            // still true until the deferred reset below. Updates in that gap, such as Settings
            // regaining focus, must not present the picker again.
            if view.awaitsBindingReset { return }
            guard let window = view.window else { return }
            if let controller = view.controller {
                controller.panel.appearance = window.appearance
                controller.glass.overlayAppearance = appearance
                return
            }
            let dismiss = onDismiss
            let host = NSHostingView(rootView: content(dismiss))
            let controller = SettingsPickerController(content: host, size: size, appearance: appearance) { [weak view] in
                // Clear the content to cancel pending Browse and release picker state on every exit.
                host.rootView = AnyView(EmptyView())
                view?.controller = nil
                // The binding already reads false when SwiftUI asked for this dismissal.
                if view?.isDismissingForBinding != true { view?.awaitsBindingReset = true }
                Task { @MainActor [weak view] in
                    guard let view, view.controller == nil else { return }
                    dismiss()
                    // The binding now reads false. Clearing here, not on the next update, means a
                    // presentation requested before that update is not swallowed.
                    view.awaitsBindingReset = false
                }
            }
            view.controller = controller
            controller.present(over: window)
        }
        view.update?()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.dismiss() }

    final class Anchor: NSView {
        var update: (() -> Void)?
        var controller: SettingsPickerController?
        /// True from a self-initiated dismissal until SwiftUI's binding reads false.
        var awaitsBindingReset = false
        var isDismissingForBinding = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { dismiss() } else { update?() }
        }
        func dismiss() {
            isDismissingForBinding = true
            controller?.dismiss()
            isDismissingForBinding = false
            controller = nil
        }
    }
}

/// A drawn popup cancel button with the same Escape equivalent as the stock control.
struct SettingsPickerCancelButton: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> OverlayButton {
        let button = OverlayButton(title: "Cancel", kind: .secondary,
                                   target: context.coordinator, action: #selector(Coordinator.cancel))
        button.keyEquivalent = "\u{1b}"
        button.keyEquivalentModifierMask = []
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // Keep the native control at its natural width and the shared action height,
    // even when a future parent proposes the whole sheet's remaining height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OverlayButton, context: Context) -> CGSize? {
        CGSize(width: nsView.intrinsicContentSize.width, height: OverlayButtonMetrics.height)
    }

    func updateNSView(_ button: OverlayButton, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func cancel() { action() }
    }
}

/// Register an actual AppKit default button. A SwiftUI key equivalent alone does not
/// provide the borderless panel's native Return action after the search editor leaves.
struct SettingsPickerConfirmButton: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> DefaultButton {
        let button = DefaultButton(title: title, target: context.coordinator, action: #selector(Coordinator.confirm))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DefaultButton, context: Context) -> CGSize? {
        CGSize(width: nsView.intrinsicContentSize.width, height: OverlayButtonMetrics.height)
    }

    func updateNSView(_ button: DefaultButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func confirm() { action() }
    }

    final class DefaultButton: NSButton {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow, window?.defaultButtonCell === cell { window?.defaultButtonCell = nil }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.defaultButtonCell = cell as? NSButtonCell
        }
    }
}
