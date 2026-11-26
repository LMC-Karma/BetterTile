// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import AppKit
import AVFoundation
import SwiftUI

/// A short, silent recording of BetterTile that the Setup Assistant loops.
/// The files are in `Resources/SetupClips`: 960 px wide, 30 fps, HEVC.
enum SetupClip: String, CaseIterable {
    case hero, snap, adaptive, tabbed, resize, wheel, keys, saved, repair

    /// The clips show the whole 3024 × 1964 recording screen, menu bar included.
    static let aspectRatio: CGFloat = 3024 / 1964

    var url: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "mp4", subdirectory: "SetupClips")
    }
}

/// Loops one clip. With Reduce Motion on, it shows a still frame and a play
/// button instead of playing by itself.
struct SetupClipView: View {
    let clip: SetupClip
    var caption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playsWithReduceMotion = false

    private var isPlaying: Bool { !reduceMotion || playsWithReduceMotion }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if clip.url != nil {
                SetupClipPlayerView(clip: clip, isPlaying: isPlaying)
            }
            if let caption {
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(SettingsSpacing.s2)
            }
            if reduceMotion {
                Button {
                    playsWithReduceMotion.toggle()
                } label: {
                    Image(systemName: playsWithReduceMotion ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .help(playsWithReduceMotion ? "Pause" : "Play")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(SetupClip.aspectRatio, contentMode: .fit)
        .clipShape(.settings(SettingsRadius.inner))
        .overlay {
            RoundedRectangle.settings(SettingsRadius.inner)
                .strokeBorder(SettingsColor.groupBorder, lineWidth: 0.5)
        }
        .onChange(of: clip) { playsWithReduceMotion = false }
    }
}

private struct SetupClipPlayerView: NSViewRepresentable {
    let clip: SetupClip
    let isPlaying: Bool

    func makeNSView(context: Context) -> SetupClipPlayerNSView {
        let view = SetupClipPlayerNSView()
        view.show(clip, playing: isPlaying)
        return view
    }

    func updateNSView(_ view: SetupClipPlayerNSView, context: Context) {
        view.show(clip, playing: isPlaying)
    }

    static func dismantleNSView(_ view: SetupClipPlayerNSView, coordinator: ()) {
        view.stop()
    }
}

/// Plays through an `AVPlayerLayer`, without controls. It pauses while its
/// window is hidden, and releases the player when SwiftUI removes it.
final class SetupClipPlayerNSView: NSView {
    /// The still frame shown before playback and under Reduce Motion.
    private static let stillTime = CMTime(seconds: 3, preferredTimescale: 600)

    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var clip: SetupClip?
    private var wantsPlayback = false
    private var occlusionObserver: (any NSObjectProtocol)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not available") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func show(_ clip: SetupClip, playing: Bool) {
        if clip != self.clip, let url = clip.url {
            self.clip = clip
            looper?.disableLooping()
            player.removeAllItems()
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
            if !playing {
                player.seek(to: Self.stillTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        wantsPlayback = playing
        updatePlayback()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        clip = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            }
        }
        updatePlayback()
    }

    private func updatePlayback() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        if wantsPlayback, visible {
            player.play()
        } else {
            player.pause()
        }
    }
}
