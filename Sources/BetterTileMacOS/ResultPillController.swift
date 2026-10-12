import AppKit
import BetterTileCore
import os

public struct ResultPillFeedback: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case success
        case failure
    }

    public let kind: Kind
    public let message: String
    /// The specific reason under a short failure title, so a generic title
    /// such as "Couldn't apply layout" always says why.
    public let detail: String?
    public let symbolName: String
    public let dismissDelay: TimeInterval

    init(kind: Kind, message: String, detail: String? = nil, symbolName: String, dismissDelay: TimeInterval) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.symbolName = symbolName
        self.dismissDelay = dismissDelay
    }

    public static func success(_ message: String = "Layout applied") -> Self {
        Self(kind: .success, message: message, symbolName: "checkmark", dismissDelay: 0.9)
    }

    public static func failure(_ error: String?) -> Self {
        let value = (error ?? "").lowercased()
        let message: String
        if value.contains("accessibility") || value.contains("permission") {
            message = "Accessibility required"
        } else if value.contains("ignore this app") {
            message = "App is ignored"
        } else if value.contains("repair bento") {
            message = "Bento not active"
        } else if value.contains("eligible") || value.contains("focused window") {
            message = "No eligible window"
        } else if value.contains("up to six") {
            message = "Bento is full"
        } else if value.contains("cannot fit") || value.contains("can't fit") || value.contains("minimum size") {
            message = "Can’t fit this layout"
        } else if value.contains("tabbed size") {
            message = "Window refused this size"
        } else if value.contains("change layout → one pane") {
            message = "Choose One Pane"
        } else if value.contains("use tabbed undo") {
            message = "Use Tabbed Undo"
        } else if value.contains("float the window to use this action") {
            message = "Float this window first"
        } else if value.contains("repair tabbed") || (value.contains("tabbed") && value.contains("restore")) {
            message = "Use Repair Tabbed"
        } else if value.contains("desktop changed") {
            message = "Desktop changed"
        } else if value.contains("no longer matches")
            || value.contains("window changed")
            || value.contains("captured window")
            || value.contains("no longer available") {
            message = "Window changed"
        } else {
            message = "Couldn’t apply layout"
        }
        // Titles that do not say why carry the reason as a second line.
        let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explains = ["Couldn’t apply layout", "Can’t fit this layout", "Window refused this size", "Bento is full"].contains(message)
        let detail = explains && !reason.isEmpty ? reason : nil
        return Self(kind: .failure, message: message, detail: detail, symbolName: "xmark",
                    dismissDelay: detail == nil ? 1.6 : 3)
    }
}

public enum ResultPillLayout {
    static let maximumDetailWidth: Double = 520
    static let minimumDetailWidth: Double = 240
    /// Horizontal space beside the detail label: insets, icon, and spacing.
    static let detailChrome: Double = 55
    /// The label draws its text 2 pt inside each side.
    static let labelTextInset: Double = 4
    /// Spare width, so a small difference between this measurement and the
    /// label's own layout cannot push text onto a third line.
    static let measurementMargin: Double = 6
    /// The detail label shows at most this many lines.
    public static let detailLineLimit = 2
    /// The width the detail text can use on the widest pill.
    public static let maximumDetailTextWidth = maximumDetailWidth - detailChrome - labelTextInset - measurementMargin
    static var detailFont: NSFont { .systemFont(ofSize: 11) }

    /// The number of lines `text` takes in the detail font, wrapped by word
    /// at `width`. It measures rendered glyphs, so wide characters such as
    /// CJK text and emoji count at their real width.
    public static func detailLineCount(_ text: String, width: Double) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: detailFont])
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var lines = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, _, _ in
            lines += 1
        }
        return lines
    }

    /// True when all of `text` shows within the detail's lines on the widest pill.
    public static func detailFits(_ text: String) -> Bool {
        detailLineCount(text, width: maximumDetailTextWidth) <= detailLineLimit
    }

    /// Builds a detail that names windows. When the full detail does not fit,
    /// it shortens the titles, not the sentence around them, so the
    /// instruction always stays visible.
    public static func detail(naming titles: [String], _ compose: ([String]) -> String) -> String {
        let full = compose(titles)
        guard !detailFits(full) else { return full }
        func shortened(to length: Int) -> String {
            compose(titles.map { title in
                guard title.count > length else { return title }
                return title.prefix(length).trimmingCharacters(in: .whitespaces) + "…"
            })
        }
        // Find the longest title length that fits. `fitting` always fits,
        // or is the shortest form when even that does not fit.
        var fitting = 0
        var tooLong = titles.map(\.count).max() ?? 0
        while tooLong - fitting > 1 {
            let middle = (fitting + tooLong) / 2
            if detailFits(shortened(to: middle)) { fitting = middle } else { tooLong = middle }
        }
        return shortened(to: fitting)
    }

    public static func frame(for feedback: ResultPillFeedback, on display: DisplaySnapshot) -> BTRect {
        let width: Double
        let height: Double
        if let detail = feedback.detail {
            let spare = detailChrome + labelTextInset + measurementMargin
            let textWidth = NSAttributedString(string: detail, attributes: [.font: detailFont]).size().width
            width = min(maximumDetailWidth, max(minimumDetailWidth, (textWidth + spare).rounded(.up)))
            // A detail wider than the widest pill wraps to a second line.
            height = detailLineCount(detail, width: width - spare) > 1 ? 72 : 58
        } else {
            let estimatedWidth = 72 + Double(feedback.message.count) * 7
            width = min(240, max(172, estimatedWidth))
            height = 40
        }
        return BTRect(
            x: display.visibleFrame.midX - width / 2,
            y: display.visibleFrame.minY + 24,
            width: width,
            height: height
        ).clamped(to: display.visibleFrame)
    }
}

@MainActor
public final class ResultPillController {
    private static let signposter = OSSignposter(
        subsystem: "com.lmckarma.BetterTile",
        category: "Overlay"
    )

    public var overlayAppearance = OverlayAppearance() {
        didSet { (panel.contentView as? OverlayGlassView)?.overlayAppearance = overlayAppearance }
    }
    private let panel: NSPanel
    private let stack = NSStackView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var dismissalTask: Task<Void, Never>?
    private var presentationID = UUID()

    public convenience init() {
        self.init(panel: NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        ))
    }

    init(panel: NSPanel) {
        self.panel = panel
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = makeContentView()
    }

    public func show(_ feedback: ResultPillFeedback, on display: DisplaySnapshot) {
        let interval = Self.signposter.beginInterval("showResultPill")
        defer { Self.signposter.endInterval("showResultPill", interval) }
        guard let mainFrame = NSScreen.screens.first?.frame else { return }
        dismissalTask?.cancel()
        presentationID = UUID()

        label.stringValue = feedback.message
        detailLabel.stringValue = feedback.detail ?? ""
        detailLabel.isHidden = feedback.detail == nil
        icon.image = NSImage(
            systemSymbolName: "\(feedback.symbolName).circle.fill",
            accessibilityDescription: feedback.message
        )
        icon.contentTintColor = feedback.kind == .success ? .systemGreen : .systemRed

        let frame = ResultPillLayout.frame(for: feedback, on: display)
        detailLabel.preferredMaxLayoutWidth = max(0, frame.size.width - ResultPillLayout.detailChrome)
        let target = CoordinateConverter.toAppKit(frame, mainScreenFrame: mainFrame)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: 10), display: true)
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }

        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(feedback.dismissDelay))
            guard let self, !Task.isCancelled else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.panel.orderOut(nil)
                return
            }
            let completion = self.dismissalCompletion()
            let exit = self.panel.frame.offsetBy(dx: 0, dy: 8)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel.animator().alphaValue = 0
                self.panel.animator().setFrame(exit, display: true)
            } completionHandler: {
                Task { @MainActor in completion() }
            }
        }
    }

    func dismissalCompletion() -> @MainActor @Sendable () -> Void {
        let presentationID = presentationID
        return { [weak self] in
            guard let self, self.presentationID == presentationID else { return }
            self.panel.orderOut(nil)
        }
    }

    public func hide() {
        let interval = Self.signposter.beginInterval("hideResultPill")
        defer { Self.signposter.endInterval("hideResultPill", interval) }
        dismissalTask?.cancel()
        presentationID = UUID()
        panel.orderOut(nil)
    }

    /// The detail's wrapping must match what `ResultPillLayout` measures.
    static func configureDetailLabel(_ label: NSTextField) {
        label.font = ResultPillLayout.detailFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = ResultPillLayout.detailLineLimit
    }

    private func makeContentView() -> NSView {
        let effect = OverlayGlassView()
        effect.cornerRadius = 20
        effect.overlayAppearance = overlayAppearance

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 13, bottom: 8, right: 15)
        Self.configureDetailLabel(detailLabel)
        detailLabel.isHidden = true
        let text = NSStackView(views: [label, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 19),
            icon.heightAnchor.constraint(equalToConstant: 19),
        ])
        return effect
    }
}
