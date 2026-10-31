import AppKit
import BetterTileCore
import SwiftUI

/// A segmented control for the layout mode with the mode icon before each title.
///
/// SwiftUI's segmented `Picker` draws only the title of a `Label` on macOS, and splits a
/// stack of an image and a text into two segments. `NSSegmentedControl` draws both in
/// one segment, so this wrapper sets the image and the label of each segment.
public struct LayoutModePicker: NSViewRepresentable {
    /// The icon is 1.265 times the 13 point control font, with 4 points before the title.
    public static let glyphSize = CGFloat(LayoutGlyph.canvasSize(besideSymbolSize: 13))
    public static let glyphSpacing: CGFloat = 4
    /// The segmented cell rounds an image's width up to whole points and spaces the title from that width.
    /// Measured through this wrapper, an 18 pt image leaves a 3.3 pt average gap between icon and title
    /// origin, and a 19 pt image leaves 4.3 pt, in both width modes, Light and Dark. The gap also varies by
    /// about 1.5 pt between Manual, Adaptive and Tabbed. The image is padded to 19 pt, the nearer to 4 (within 0.6 on every combination).
    public static let imageTrailingPadding: CGFloat = 19 - glyphSize

    /// The padding a segment image carries. The title shifts a little with the width mode.
    public static func imageTrailingPadding(for width: Width) -> CGFloat { imageTrailingPadding }

    public enum Width: Sendable {
        /// Each segment is as wide as its icon and title need.
        case fitContent
        /// The control takes the width it is offered, split equally between segments.
        case fillAvailable
    }

    private let modes: [LayoutMode]
    private let selection: Binding<LayoutMode>
    private let width: Width
    private let accessibilityLabel: String

    public init(
        _ accessibilityLabel: String,
        modes: [LayoutMode] = LayoutMode.availableModes,
        selection: Binding<LayoutMode>,
        width: Width = .fitContent
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.modes = modes
        self.selection = selection
        self.width = width
    }

    public func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }

    public func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel(accessibilityLabel)
        // The image and title share a segment, so a wide control must not stretch its
        // content hugging. SwiftUI proposes the width.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(control)
        return control
    }

    public func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = selection
        context.coordinator.modes = modes
        configure(control)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = control.fittingSize
        switch width {
        case .fitContent: return natural
        case .fillAvailable: return CGSize(width: proposal.width ?? natural.width, height: natural.height)
        }
    }

    private func configure(_ control: NSSegmentedControl) {
        // Rebuild only when the modes change, so a selection never restarts tracking.
        if control.segmentCount != modes.count || (0 ..< modes.count).contains(where: { control.label(forSegment: $0) != modes[$0].title }) {
            control.segmentCount = modes.count
            for (index, mode) in modes.enumerated() {
                control.setLabel(mode.title, forSegment: index)
                control.setImage(LayoutGlyph.mode(mode).templateImage(canvasSize: Self.glyphSize, trailingPadding: Self.imageTrailingPadding(for: width)), forSegment: index)
                control.setImageScaling(.scaleNone, forSegment: index)
            }
        }
        control.segmentDistribution = width == .fillAvailable ? .fillEqually : .fit
        if let index = modes.firstIndex(of: selection.wrappedValue.availableMode), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    @MainActor
    public final class Coordinator: NSObject {
        var selection: Binding<LayoutMode>
        var modes: [LayoutMode] = LayoutMode.availableModes

        init(selection: Binding<LayoutMode>) { self.selection = selection }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard modes.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}
