// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import BetterTileCore

/// An independent, nonactivating chooser above Tabbed curtains and pane panels.
/// The owner forwards shared left clicks; temporary AppKit monitors cover own-window
/// clicks and global right clicks, which the shared left-button stream does not see.
@MainActor public final class TabbedChooserPresenter {
    public let panel: NSPanel
    public var onDismiss: (() -> Void)?
    public private(set) var isPresented = false
    private var dismissed = false
    private var presentedAt: TimeInterval = 0
    private let now: () -> TimeInterval
    private let contentSize: NSSize
    private var localMouseDownMonitor: Any?
    private var globalRightMouseDownMonitor: Any?
    var addGlobalRightMouseMonitor: (@escaping @MainActor (NSPoint, TimeInterval) -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { event in
            // Global AppKit events have screen coordinates and no owning window.
            let point = event.locationInWindow
            let timestamp = event.timestamp
            MainActor.assumeIsolated { handler(point, timestamp) }
        }
    }
    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    public convenience init(content: NSView, size: NSSize, appearance: OverlayAppearance = OverlayAppearance()) {
        self.init(content: content, size: size, appearance: appearance, panel: TabbedChooserPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false))
    }

    init(content: NSView, size: NSSize, appearance: OverlayAppearance = OverlayAppearance(), panel: NSPanel, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.panel = panel
        self.now = now
        contentSize = size
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        // isFloatingPanel resets the level, so apply the chooser level afterward.
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        let container = TabbedChooserContainer(frame: NSRect(origin: .zero, size: size))
        let radius = PopupGlass.panelRadius
        let backing = OverlayGlassView(frame: container.bounds)
        backing.cornerRadius = radius
        backing.isPopup = true
        backing.overlayAppearance = appearance
        backing.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = radius
        container.layer?.masksToBounds = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(backing)
        backing.setPopupContent(content)
        panel.setContentSize(size)
        panel.contentView = container
        (panel as? TabbedChooserPanel)?.onCancel = { [weak self] in self?.dismiss() }
    }

    isolated deinit {
        if let localMouseDownMonitor { removeMonitor(localMouseDownMonitor) }
        if let globalRightMouseDownMonitor { removeMonitor(globalRightMouseDownMonitor) }
    }

    public func show(relativeTo rect: NSRect, of view: NSView, paneFrame: NSRect?) {
        guard let window = view.window, window.isVisible, let screen = window.screen else { dismiss(); return }
        present(anchorFrame: window.convertToScreen(view.convert(rect, to: nil)),
                paneFrame: paneFrame, screenFrame: screen.visibleFrame)
    }

    /// AppKit screen coordinates, independent of the strip panel's height or view flipping.
    func present(anchorFrame: NSRect, paneFrame: NSRect?, screenFrame: NSRect) {
        guard !dismissed else { return }
        let proposed = NSRect(x: anchorFrame.midX - contentSize.width / 2,
                              y: anchorFrame.minY - contentSize.height - 6,
                              width: contentSize.width, height: contentSize.height)
        panel.setFrame(Self.clampedFrame(proposed, paneFrame: paneFrame, screenFrame: screenFrame), display: false)
        presentedAt = now()
        isPresented = true
        if localMouseDownMonitor == nil {
            localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // AppKit calls local monitors before dispatching to the clicked control.
                // Handle synchronously so an opener cannot close the chooser it creates.
                MainActor.assumeIsolated { self?.handleAppKitMouseDown(event) }
                return event
            }
        }
        if globalRightMouseDownMonitor == nil {
            globalRightMouseDownMonitor = addGlobalRightMouseMonitor { [weak self] point, timestamp in
                self?.handleMouseDown(at: point, timestamp: timestamp)
            }
        }
        // Showing preserves focus; an inside click takes key status without app activation.
        panel.orderFrontRegardless()
    }

    public func handleMouseEvent(_ event: GlobalGestureEvent) {
        guard isPresented, event.kind == .leftMouseDown, event.button == 0 else { return }
        let mainFrame = NSScreen.screens.first?.frame ?? .zero
        let point = NSPoint(x: event.position.x, y: mainFrame.maxY - event.position.y)
        handleMouseDown(at: point, timestamp: Double(event.timestamp) / 1_000_000_000)
    }

    private func handleAppKitMouseDown(_ event: NSEvent) {
        guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return }
        handleMouseDown(at: GlobalGestureEvent.screenLocation(of: event), timestamp: event.timestamp)
    }

    private func handleMouseDown(at point: NSPoint, timestamp: TimeInterval) {
        guard isPresented else { return }
        // A delayed sample from the opening click must not dismiss a newly opened chooser.
        if timestamp > 0, timestamp < presentedAt { return }
        if !panel.frame.contains(point) { dismiss() }
    }

    public func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        isPresented = false
        if let localMouseDownMonitor { removeMonitor(localMouseDownMonitor) }
        if let globalRightMouseDownMonitor { removeMonitor(globalRightMouseDownMonitor) }
        localMouseDownMonitor = nil
        globalRightMouseDownMonitor = nil
        panel.orderOut(nil)
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    /// Prefer the full pane on each axis where the chooser fits; otherwise use the display.
    static func clampedFrame(_ frame: NSRect, paneFrame: NSRect?, screenFrame: NSRect) -> NSRect {
        guard !screenFrame.isEmpty else { return frame }
        let pane = paneFrame?.intersection(screenFrame) ?? .zero
        var result = frame
        result.size.width = min(frame.width, screenFrame.width)
        result.size.height = min(frame.height, screenFrame.height)
        let horizontal = !pane.isEmpty && result.width <= pane.width ? pane : screenFrame
        let vertical = !pane.isEmpty && result.height <= pane.height ? pane : screenFrame
        result.origin.x = min(max(result.minX, horizontal.minX), horizontal.maxX - result.width)
        result.origin.y = min(max(result.minY, vertical.minY), vertical.maxY - result.height)
        return result
    }
}


@MainActor class TabbedChooserPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            // Shapes and buttons need Escape even when no text field takes focus.
            // Keep .nonactivatingPanel so the other application stays active.
            makeKey()
        }
        // Let text editing cancel composition or clear search before the panel closes.
        if event.type == .keyDown, event.keyCode == 53, !(firstResponder is NSTextView) {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor private final class TabbedChooserContainer: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
