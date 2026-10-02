import AppKit
import BetterTileCore
import SwiftUI

/// A local illustration: uses the Bento engine and native grip renderer, with
/// sample windows only. It never acquires or mutates an application window.
public struct DividerResizePreview: View {
    public var thickness: Double
    public var feedback: ResizeFeedbackMode
    public var paneGap: Double
    public var overlayAppearance: OverlayAppearance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shape = DividerPreviewShape.plus
    @State private var position = CGPoint(x: 0.5, y: 0.5)
    @State private var committed = CGPoint(x: 0.5, y: 0.5)
    @State private var dragStart: CGPoint?
    @FocusState private var gripFocused: Bool

    public init(thickness: Double, feedback: ResizeFeedbackMode, paneGap: Double, overlayAppearance: OverlayAppearance = .init()) {
        self.thickness = thickness
        self.feedback = feedback
        self.paneGap = paneGap
        self.overlayAppearance = overlayAppearance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Try a divider").fontWeight(.medium)
                Spacer()
                Picker("Divider shape", selection: $shape) {
                    ForEach(DividerPreviewShape.allCases, id: \.self) { shape in
                        Text(shape.rawValue).tag(shape)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Reset", action: reset)
            }
            GeometryReader { proxy in
                let bounds = BTRect(x: 0, y: 0, width: proxy.size.width, height: proxy.size.height)
                let sample = shape.sample(in: bounds, position: position, paneGap: paneGap)
                let resting = shape.sample(in: bounds, position: committed, paneGap: paneGap)
                let ghosting = dragStart != nil && feedback == .ghost
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                    ForEach((ghosting ? resting : sample).placements, id: \.windowID) { placement in
                        sampleWindow(placement, ghost: false)
                            .opacity(ghosting ? 0.45 : 1)
                    }
                    if ghosting {
                        ForEach(sample.placements, id: \.windowID) { placement in
                            sampleWindow(placement, ghost: true)
                        }
                    }
                    PreviewGrip(
                        mode: sample.mode(thickness: thickness), thickness: thickness,
                        active: dragStart != nil, reduceMotion: reduceMotion, overlayAppearance: overlayAppearance
                    )
                    .frame(width: 180, height: 180)
                    .position(x: sample.center.x, y: sample.center.y)
                    .allowsHitTesting(false)

                    Color.clear
                        .frame(width: shape == .horizontal ? 56 : 32,
                               height: shape == .vertical ? 56 : 32)
                        .contentShape(Rectangle())
                        .position(x: sample.center.x, y: sample.center.y)
                        .focusable()
                        .focused($gripFocused)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("divider-preview"))
                            .onChanged { value in
                                gripFocused = true
                                if dragStart == nil { dragStart = committed }
                                guard let start = dragStart else { return }
                                position = CGPoint(
                                    x: shape == .horizontal ? 0.5 : min(0.75, max(0.25, start.x + value.translation.width / proxy.size.width)),
                                    y: shape == .vertical ? 0.5 : min(0.75, max(0.25, start.y + value.translation.height / proxy.size.height))
                                )
                            }
                            .onEnded { _ in committed = position; dragStart = nil })
                        .accessibilityLabel("\(shape.rawValue) divider preview")
                        .accessibilityValue("\(Int(position.x * 100)) percent across, \(Int(position.y * 100)) percent down")
                        .accessibilityAdjustableAction { direction in
                            let delta = direction == .increment ? 0.05 : -0.05
                            if shape != .horizontal { position.x = min(0.75, max(0.25, position.x + delta)) }
                            if shape != .vertical { position.y = min(0.75, max(0.25, position.y + delta)) }
                            committed = position
                        }
                }
                .coordinateSpace(name: "divider-preview")
                .clipped()
            }
            .frame(height: 250)
            HStack {
                Text(dragStart == nil ? "Grab the divider to stretch and resize." : "Release to keep the layout. Escape cancels.")
                Spacer()
                Text(feedback == .ghost ? "Ghost Preview" : "Live Resize")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Text("Sample windows only. Plus and T dividers resize Bento intersections.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .onChange(of: shape) { reset() }
        .onChange(of: feedback) { reset() }
        .onChange(of: paneGap) { reset() }
        .onExitCommand { position = committed; dragStart = nil }
    }

    private func reset() {
        position = CGPoint(x: 0.5, y: 0.5)
        committed = position
        dragStart = nil
    }

    private func sampleWindow(_ placement: Placement, ghost: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                ForEach(0..<3) { _ in Circle().fill(.secondary.opacity(0.4)).frame(width: 5, height: 5) }
                Spacer()
            }
            Divider()
            if ghost {
                Text("\(Int(placement.frame.size.width)) × \(Int(placement.frame.size.height))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tint)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.12)).frame(height: 5)
                RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.12)).frame(width: 55, height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: placement.frame.size.width, height: placement.frame.size.height)
        .background(ghost ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ghost ? Color.accentColor : Color(nsColor: .separatorColor)))
        .position(x: placement.frame.midX, y: placement.frame.midY)
        .accessibilityHidden(true)
    }
}

enum DividerPreviewShape: String, CaseIterable {
    case vertical = "Vertical", horizontal = "Horizontal", plus = "Plus"
    case up = "T · up", down = "T · down", left = "T · left", right = "T · right"

    func sample(in bounds: BTRect, position: CGPoint, paneGap: Double) -> DividerPreviewSample {
        let leaves = ["A", "B", "C", "D"].map { BentoNode.leaf(WindowID(rawValue: $0)) }
        func split(_ axis: SplitAxis, _ first: BentoNode, _ second: BentoNode) -> BentoNode {
            .partition(BentoPartition(axis: axis, first: first, second: second))
        }
        let root: BentoNode = switch self {
        case .vertical: split(.vertical, leaves[0], leaves[1])
        case .horizontal: split(.horizontal, leaves[0], leaves[1])
        case .plus: split(.vertical, split(.horizontal, leaves[0], leaves[1]), split(.horizontal, leaves[2], leaves[3]))
        case .left: split(.vertical, split(.horizontal, leaves[0], leaves[1]), leaves[2])
        case .right: split(.vertical, leaves[0], split(.horizontal, leaves[1], leaves[2]))
        case .up: split(.horizontal, split(.vertical, leaves[0], leaves[1]), leaves[2])
        case .down: split(.horizontal, leaves[0], split(.vertical, leaves[1], leaves[2]))
        }
        let baseline = BentoLayoutState(root: root, metrics: BentoLayoutMetrics(paneGap: paneGap))
        let display = DisplayID(rawValue: "preview")
        let center = BTPoint(x: bounds.minX + bounds.size.width * position.x, y: bounds.minY + bounds.size.height * position.y)
        let coordinates = Dictionary(uniqueKeysWithValues: baseline.boundaries(in: bounds, displayID: display).compactMap { boundary in
            boundary.branchID.map { ($0, boundary.axis == .vertical ? center.x : center.y) }
        })
        let constraints = Dictionary(uniqueKeysWithValues: root.windowIDs.map {
            ($0, WindowConstraints(minimumSize: BTSize(width: 60, height: 40)))
        })
        let state = BentoResizeEngine().resize(
            state: baseline, branchCoordinates: coordinates, in: bounds, constraints: constraints
        )?.state ?? baseline
        let boundaries = state.boundaries(in: bounds, displayID: display)
        let acceptedCenter = BTPoint(
            x: boundaries.first(where: { $0.axis == .vertical })?.coordinate ?? bounds.midX,
            y: boundaries.first(where: { $0.axis == .horizontal })?.coordinate ?? bounds.midY
        )
        return DividerPreviewSample(
            shape: self, center: acceptedCenter,
            placements: state.placements(in: bounds, constraints: constraints), boundaries: boundaries
        )
    }
}

struct DividerPreviewSample {
    var shape: DividerPreviewShape
    var center: BTPoint
    var placements: [Placement]
    var boundaries: [BoundaryDescriptor]

    func mode(thickness: Double) -> DividerHandleMode {
        if shape == .vertical || shape == .horizontal, let boundary = boundaries.first {
            let span = (boundary.spanStart + 8)...(boundary.spanEnd - 8)
            let resting = DividerHandleGeometry.straightLength(span: span, active: false)
            let active = DividerHandleGeometry.straightLength(span: span, active: true)
            return shape == .vertical ? .vertical(restingLength: resting, activeLength: active)
                : .horizontal(restingLength: resting, activeLength: active)
        }
        return .junction(
            center: CGPoint(x: 90, y: 90),
            resting: DividerHandleGeometry.junctionArmLengths(center: center, boundaries: boundaries, active: false, thickness: thickness),
            active: DividerHandleGeometry.junctionArmLengths(center: center, boundaries: boundaries, active: true, thickness: thickness)
        )
    }
}

private struct PreviewGrip: NSViewRepresentable {
    let mode: DividerHandleMode
    let thickness: Double
    let active: Bool
    let reduceMotion: Bool
    let overlayAppearance: OverlayAppearance

    func makeNSView(context: Context) -> DividerHandleView {
        DividerHandleView(frame: CGRect(x: 0, y: 0, width: 180, height: 180), mode: mode, thickness: thickness)
    }

    func updateNSView(_ view: DividerHandleView, context: Context) {
        view.overlayAppearance = overlayAppearance
        view.configure(mode: mode, thickness: thickness)
        view.setActive(active, animated: !reduceMotion)
    }
}
