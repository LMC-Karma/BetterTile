# Architecture

BetterTile separates deterministic placement policy from macOS side effects.

## Layers

1. **BetterTileCore** owns geometry, actions, Bento placement, linked resizing, frame history, shortcut/configuration models, and migrations. It has no AppKit or Accessibility dependency.
2. **BetterTileMacOS** adapts public macOS APIs. `AccessibilityWindowSystem` rejects scaled Stage Manager thumbnails and publishes AX window events, `WindowCoordinator` owns rollback-capable frame transactions and self-event suppression, and AppKit panels provide hover-only dividers and reusable ghost previews.
3. **BetterTileApp** provides the SwiftUI menu-bar and searchable sidebar Settings scenes, permission guidance, immediate visible-window reconciliation, shortcut registration, and drag-snap lifecycle.

## Coordinate model

Core geometry uses logical points with a top-left origin. Display visible frames and Accessibility window frames are converted at the macOS boundary. Core code never sees AppKit's bottom-left global screen coordinate system.

## Space boundary

BetterTile operates on eligible on-screen windows exposed by public APIs. It refreshes the current window set immediately when apps, Spaces, or displays change and keeps one runtime layout session per display. It does not infer or wait for Stage Manager groups and never attempts to move windows across Spaces.

## Event ordering

All window mutations pass through the main-actor coordinator. Multi-window operations preflight every participant, apply in deterministic order, and roll back already-applied frames when a later Accessibility write fails. Ghost resize transactions do not mutate real windows before commit; live transactions can restore their original baseline on cancellation. AX move/resize events are debounced, while events matching a recent coordinator generation and expected frame are suppressed to prevent feedback loops.

## Bento

Bento uses a binary split tree held by each display's runtime `LayoutSession`. Leaves reference currently visible windows and branches carry an axis, normalized weight, and lock state. New windows are inserted by evaluating every unlocked leaf and choosing the split with the lowest movement/area-change score; closed or hidden windows are removed from the current tree. `BentoResizeEngine` changes branch weights and recursively derives all affected frames, `BentoLayoutFitter` adopts native edge changes, and `BentoBoundaryResolver` exposes only shared segments verified against current window frames.

## Linked resizing

The linked-resize engine detects and merges shared boundary segments within a configurable tolerance. Linked and Bento boundaries share the same overlay interaction model, but Bento resizing stays tree-aware instead of applying flat per-window deltas. The requested operation clamps against recursive subtree minimum sizes and visible bounds.

## Configuration

Settings use a versioned Codable envelope. Version-1 display-keyed Bento states are discarded during migration because their Accessibility IDs cannot survive relaunch; all other supported preferences migrate. Runtime display sessions are not persisted. Writes use Foundation's atomic file replacement.

## Security

Only Accessibility permission is required. BetterTile uses public frameworks, does not inject code, does not disable SIP, and does not call private SkyLight symbols.
