import AppKit
import BetterTileCore

/// A display-wide chooser. Preview callbacks draw chrome only; Apply is the
/// only callback that can request a layout mutation.
@MainActor
final class TabbedLayoutGallery: NSObject {
    let content: TabbedLayoutGalleryView
    let presenter: TabbedChooserPresenter
    var onDismiss: (() -> Void)?
    private var dismissed = false

    init(state: TabbedLayoutState, onPreview: @escaping (TabbedPreset?, TabbedPresetGrouping) -> Void,
         onApply: @escaping (TabbedPreset, TabbedPresetGrouping) -> Void,
         appearance: OverlayAppearance = OverlayAppearance(),
         presenterFactory: ((NSView, NSSize) -> TabbedChooserPresenter)? = nil) {
        content = TabbedLayoutGalleryView(current: Self.currentPreset(for: state))
        presenter = presenterFactory?(content, content.frame.size)
            ?? TabbedChooserPresenter(content: content, size: content.frame.size, appearance: appearance)
        super.init()
        content.onPreview = onPreview
        content.onApply = { [weak self] preset, grouping in
            self?.cancel()
            onApply(preset, grouping)
        }
        content.onCancel = { [weak self] in self?.cancel() }
        presenter.onDismiss = { [weak self] in self?.finish() }
    }

    func show(relativeTo rect: NSRect, of view: NSView, paneFrame: NSRect? = nil) {
        presenter.show(relativeTo: rect, of: view, paneFrame: paneFrame)
    }

    func cancel() { presenter.dismiss() }

    private func finish() {
        guard !dismissed else { return }
        dismissed = true
        content.onPreview?(nil, content.grouping)
        content.onPreview = nil
        content.onApply = nil
        onDismiss?()
        onDismiss = nil
    }

    static func currentPreset(for state: TabbedLayoutState) -> TabbedPreset? {
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 1000)
        let frames = state.frames(in: bounds)
        return TabbedPreset.allCases.first { preset in
            guard preset.paneCount == state.panes.count else { return false }
            var template = TabbedLayoutState(preset: preset).layout
            template.metrics = state.layout.metrics
            guard let sample = TabbedLayoutState(adopting: template) else { return false }
            let expected = sample.frames(in: bounds)
            return zip(state.panes, sample.panes).allSatisfy { actual, pane in
                guard let a = frames[actual.id], let b = expected[pane.id] else { return false }
                return abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
                    && abs(a.size.width - b.size.width) < 0.01 && abs(a.size.height - b.size.height) < 0.01
            }
        }
    }
}

@MainActor
final class TabbedLayoutGalleryView: NSView {
    let current: TabbedPreset?
    private(set) var selected: TabbedPreset?
    private(set) var grouping = TabbedPresetGrouping.keepTabGroups
    private(set) var choices: [TabbedLayoutChoiceButton] = []
    // Overlay buttons: the chooser is rarely key, so stock buttons would draw grey.
    let applyButton: NSButton = OverlayButton(title: "Apply", kind: .primary)
    let cancelButton: NSButton = OverlayButton(title: "Cancel", kind: .secondary)
    private let groupingControl = NSSegmentedControl(labels: ["Keep tab groups", "Distribute windows"], trackingMode: .selectOne, target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    var onPreview: ((TabbedPreset?, TabbedPresetGrouping) -> Void)?
    var onApply: ((TabbedPreset, TabbedPresetGrouping) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(current: TabbedPreset?) {
        self.current = current
        selected = current
        super.init(frame: NSRect(x: 0, y: 0, width: 364, height: 364))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Layout Gallery for the whole display")
        func label(_ text: String, y: CGFloat, bold: Bool = false) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: bold ? 13 : 11, weight: bold ? .semibold : .regular)
            label.textColor = bold ? .labelColor : PopupGlass.secondaryLabelColor
            label.frame = NSRect(x: 12, y: y, width: 340, height: 20)
            addSubview(label)
        }
        label("Layout Gallery", y: 12, bold: true)
        let scope = NSTextField(labelWithString: "Applies to the whole display")
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = PopupGlass.secondaryLabelColor
        scope.frame = NSRect(x: 32, y: 36, width: 320, height: 16)
        addSubview(scope)
        let display = NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: nil)!)
        display.frame = NSRect(x: 12, y: 36, width: 16, height: 16)
        addSubview(display)
        for (index, preset) in TabbedPreset.allCases.enumerated() {
            let button = TabbedLayoutChoiceButton(preset: preset, current: preset == current)
            button.frame = NSRect(x: 12 + (index % 3) * 116, y: 64 + (index / 3) * 96, width: 108, height: 88)
            button.target = self
            button.action = #selector(choose(_:))
            button.onPreview = { [weak self] hovering in
                guard let self else { return }
                self.onPreview?(hovering ? preset : self.selected, self.grouping)
            }
            button.onArrow = { [weak self] delta in
                guard let self else { return }
                let next = (index + delta + self.choices.count) % self.choices.count
                self.window?.makeFirstResponder(self.choices[next])
            }
            addSubview(button)
            choices.append(button)
        }
        groupingControl.frame = NSRect(x: 12, y: 260, width: 340, height: 24)
        groupingControl.target = self
        groupingControl.action = #selector(changeGrouping(_:))
        groupingControl.setAccessibilityLabel("Tab groups")
        addSubview(groupingControl)
        note.frame = NSRect(x: 12, y: 292, width: 340, height: 28)
        note.font = .systemFont(ofSize: 11)
        note.textColor = PopupGlass.secondaryLabelColor
        addSubview(note)
        let currentLabel = NSTextField(labelWithString: "✓ Current layout")
        currentLabel.font = .systemFont(ofSize: 11)
        currentLabel.textColor = PopupGlass.secondaryLabelColor
        currentLabel.frame = NSRect(x: 12, y: 336, width: 144, height: 16)
        addSubview(currentLabel)
        let height = OverlayButtonMetrics.height, gap = OverlayButtonMetrics.spacing
        let applyWidth = applyButton.intrinsicContentSize.width, cancelWidth = cancelButton.intrinsicContentSize.width
        let applyX = bounds.width - 12 - applyWidth
        applyButton.frame = NSRect(x: applyX, y: 330, width: applyWidth, height: height)
        cancelButton.frame = NSRect(x: applyX - gap - cancelWidth, y: 330, width: cancelWidth, height: height)
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(apply)
        addSubview(cancelButton)
        addSubview(applyButton)
        let controls: [NSView] = choices + [groupingControl, cancelButton, applyButton]
        for (index, control) in controls.enumerated() { control.nextKeyView = controls[(index + 1) % controls.count] }
        updateSelection()
    }

    required init?(coder: NSCoder) { nil }

    // No fill: the chooser's popup glass shows through, or its opaque fallback.

    @objc private func choose(_ sender: TabbedLayoutChoiceButton) { select(sender.preset) }
    func select(_ preset: TabbedPreset) {
        selected = preset
        updateSelection()
        onPreview?(preset, grouping)
    }

    @objc private func changeGrouping(_ sender: NSSegmentedControl) {
        setGrouping(sender.selectedSegment == 0 ? .keepTabGroups : .distributeWindows)
    }
    func setGrouping(_ policy: TabbedPresetGrouping) {
        grouping = policy
        updateSelection()
        onPreview?(selected, grouping)
    }

    private func updateSelection() {
        for button in choices {
            button.state = button.preset == selected ? .on : .off
            button.needsDisplay = true
        }
        groupingControl.selectedSegment = grouping == .keepTabGroups ? 0 : 1
        note.stringValue = grouping == .keepTabGroups
            ? "Each pane keeps its tabs. New panes start empty."
            : "Windows spread over the panes, one pane each first."
        // Distributing windows is useful on the current shape too.
        applyButton.isEnabled = selected != nil && (selected != current || grouping == .distributeWindows)
    }

    @objc func apply() {
        guard applyButton.isEnabled, let selected else { return }
        onApply?(selected, grouping)
    }
    @objc private func cancelAction() { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class TabbedLayoutChoiceButton: NSButton {
    let preset: TabbedPreset
    let current: Bool
    static var currentBadgeColor: NSColor { PopupGlass.accentShade(for: .systemGreen) }
    private(set) var hovering = false
    var onPreview: ((Bool) -> Void)?
    var onArrow: ((Int) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(preset: TabbedPreset, current: Bool) {
        self.preset = preset
        self.current = current
        super.init(frame: .zero)
        title = preset.title
        setButtonType(.toggle)
        isBordered = false
        setAccessibilityLabel(preset.title + (current ? ", current layout" : ""))
        toolTip = title
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    func setHovering(_ value: Bool) { hovering = value; needsDisplay = true; onPreview?(value) }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onPreview?(true); needsDisplay = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onPreview?(false); needsDisplay = true }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onArrow?(-1)
        case 124: onArrow?(1)
        case 125: onArrow?(3)
        case 126: onArrow?(-3)
        default: super.keyDown(with: event)
        }
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func draw(_ dirtyRect: NSRect) {
        let thumbnailRadius = PopupGlass.innerRadius
        let selected = state == .on
        let focused = window?.firstResponder === self
        let thumb = NSRect(x: 1, y: 1, width: 106, height: 66)
        let outline = NSBezierPath(roundedRect: thumb, xRadius: thumbnailRadius, yRadius: thumbnailRadius)
        NSColor.labelColor.withAlphaComponent(hovering || focused ? 0.12 : 0.06).setFill()
        outline.fill()
        if selected || focused {
            (selected ? NSColor.controlAccentColor : NSColor.keyboardFocusIndicatorColor).setStroke()
            outline.lineWidth = 2
            outline.stroke()
        }
        // The layout icon, 66 points, Regular, centred in the thumbnail. Its ink is centred
        // on the canvas, so the canvas is centred and not shifted by ink mass.
        let ink = (selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).withAlphaComponent(0.65)
        if let context = NSGraphicsContext.current?.cgContext {
            LayoutGlyph.layout(preset).stroke(
                in: context, origin: CGPoint(x: thumb.midX - 33, y: thumb.midY - 33), canvasSize: 66,
                color: ink.cgColor, flipped: isFlipped)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (preset.title as NSString).draw(in: NSRect(x: 0, y: 72, width: 108, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        if current {
            Self.currentBadgeColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 88, y: 6, width: 14, height: 14)).fill()
            NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white]))?
                .draw(in: NSRect(x: 90, y: 8, width: 10, height: 10), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
