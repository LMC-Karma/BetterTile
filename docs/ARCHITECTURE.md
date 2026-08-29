# Architecture

BetterTile separates deterministic placement policy from macOS side effects.

## Layers

1. **BetterTileCore** owns geometry, actions, Bento placement, linked resizing, frame history, shortcut/configuration models, and migrations. It has no AppKit or Accessibility dependency. It contains no updater API and must not gain one: updating is a distribution concern, not placement policy.
2. **BetterTileMacOS** owns Accessibility, window-system integration, coordinate conversion, and window mutations. `AccessibilityWindowSystem` rejects scaled Stage Manager artifacts as windows and resolves a validated thumbnail group to one real member for the ordinary drag path. It also publishes AX window events. `WindowCoordinator` owns rollback-capable frame transactions and self-event suppression, and AppKit panels provide hover-only dividers and reusable ghost previews.
3. **BetterTileApp** owns the SwiftUI/AppKit application lifecycle and application-level UI integrations: the menu-bar and searchable sidebar Settings scenes, the main menu and status item, alerts, permission guidance, immediate visible-window reconciliation, shortcut registration, drag-snap lifecycle, Sparkle's `SPUStandardUpdaterController`, and user-requested `NSWorkspace` actions such as opening the Applications folder or the feedback form.

## Application-level integrations

The app delegate owns `SPUStandardUpdaterController` and implements
`SPUUpdaterDelegate` directly. This is an intentional clarification of the layer
boundary rather than an undocumented exception.

The shared Xcode target has two application identities. Debug actions build
**BetterTile Debug** with `com.lmckarma.BetterTile.debug`; Release and Archive
build the public **BetterTile** identity. Each identity has separate
configuration and `UserDefaults` storage. At launch, the app asks to quit a
running sibling variant before the model registers shortcuts or Accessibility
observers. This keeps one window manager active without adding another target
or scheme.

There is deliberately **no updater service type and no updater API in
BetterTileCore**. Sparkle is an application-lifecycle integration in the same
category as the status item and the main menu, and an indirection layer would
add a seam without adding a decision.

What is extracted is only the framework-independent *decisions* those
integrations make, in `BetterTileMacOS/ApplicationUpdatePresentation.swift`:
`UpdateIndicator` (how updater outcomes retain or clear the available version
shown by the app UI),
`FeedbackLink` (what the feedback URL may contain), and `ApplicationVolume`
(whether the app must ask to be moved out of the disk image). These are pure,
import neither Sparkle nor AppKit, and are unit tested. The app delegate remains
responsible for translating Sparkle's callbacks into those inputs, persisting
the small reminder state, and applying the results to real AppKit objects.

Sparkle's own update UI, download, installation, bundle replacement, and
relaunch are validated as manual release checks; see
[RELEASING.md](RELEASING.md).

Sparkle starts only in Release. Debug keeps the framework embedded through the
shared target, but it has no feed URL, updater controller, update settings, or
manual update command.

## Coordinate model

Core geometry uses logical points with a top-left origin. Display visible frames and Accessibility window frames are converted at the macOS boundary. Core code never sees AppKit's bottom-left global screen coordinate system.

## Space boundary

BetterTile operates on eligible on-screen windows exposed by its macOS integration layer. It refreshes the current window set immediately when apps, Spaces, or displays change. A validated native desktop observation selects one process-local runtime layout session for each display and Space pair. Missing or malformed native observations retain the public-API window-overlap matcher. Empty window membership remains unknown, windows reported on several Spaces float, and native fullscreen Spaces expose neither automatic layout writes nor dividers. BetterTile never attempts to move windows across Spaces.

## Event ordering

One listen-only session event tap forwards ordered scalar left-button values
from a dedicated run loop to the main actor. Drag snapping and linked resizing
share that stream. If tap creation or recovery fails, both consumers switch to
their existing `NSEvent` monitors as one unit so one physical event has one
owner.

Layout Wheel keyboard activation uses observation-only AppKit monitors. The
modifier monitor follows feature enablement. Key and pointer monitors exist
only during a pending or open gesture. The optional Middle Click trigger has a
separate suppressing session event tap. It exists only while that preference is
enabled, receives only other-button down, drag, and up events, and consumes only
unmodified physical button 2. Tap failure disables that runtime path without
disabling keyboard activation. Both tap implementations copy scalar position,
button, modifier, timestamp, and event-kind values only. Divider-local events,
hover, Escape, and title-bar double-click handling keep their AppKit paths.

All window mutations pass through the main-actor coordinator. Multi-window operations preflight every participant, apply in deterministic order, and roll back already-applied frames when a later Accessibility write fails. Ghost resize transactions do not mutate real windows before commit; live transactions can restore their original baseline on cancellation. AX move/resize events are debounced, while events matching a recent coordinator generation and expected frame are suppressed to prevent feedback loops.

## Bento

Bento uses a binary split tree held by each display's runtime `LayoutSession`. Leaves reference currently visible windows and branches carry an axis, normalized weight, and lock state. New windows are inserted by evaluating every unlocked leaf and choosing the split with the lowest movement/area-change score; closed or hidden windows are removed from the current tree. `BentoResizeEngine` changes branch weights and recursively derives all affected frames, `BentoLayoutFitter` adopts native edge changes, and `BentoBoundaryResolver` exposes only shared segments verified against current window frames.

## Linked resizing

The linked-resize engine detects and merges shared boundary segments within a configurable tolerance. Linked and Bento boundaries share the same overlay interaction model, but Bento resizing stays tree-aware instead of applying flat per-window deltas. The requested operation clamps against recursive subtree minimum sizes and visible bounds.

## Configuration

Settings use a versioned Codable envelope. Version-1 display-keyed Bento states are discarded during migration because their Accessibility IDs cannot survive relaunch; all other supported preferences migrate. Runtime display sessions are not persisted. Writes use Foundation's atomic file replacement.

## Security

Only Accessibility permission is required. BetterTile does not inject code or disable SIP. Public Apple APIs are preferred; any private API integration requires the design review, approval, fallback, testing, and disclosure defined in [SECURITY.md](../SECURITY.md).
