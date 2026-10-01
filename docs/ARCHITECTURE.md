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

Window identities survive off-screen and incomplete Accessibility sweeps.
Cleanup requires closure evidence from the full public WindowServer list;
without an exact identity, destruction or application termination owns cleanup.
Native membership includes retained, nonhidden, nonminimized window identities.
It keeps a temporarily missing pane in its desktop's tree. Confirmed destruction
and minimization still remove the pane, and a window observed on another display
is no longer protected on the old display.

One listen-only session event tap forwards ordered scalar left-button values
from a dedicated run loop to the main actor. Drag snapping and linked resizing
share that stream. If tap creation or recovery fails, both consumers switch to
their existing `NSEvent` monitors as one unit so one physical event has one
owner.

Layout Wheel keyboard activation uses paired local and global AppKit monitors,
so it works whether BetterTile or another app receives the event. Modifier
monitors follow feature enablement. Key and pointer monitors exist only during
a pending or open gesture. Global monitors remain observation-only. While the
wheel is open, its local monitor consumes recognized wheel-navigation keys so
they do not also activate BetterTile's focused Settings controls; other local
keys pass through. The optional Middle Click trigger has a separate suppressing
session event tap. It exists only while that preference is enabled, receives
only other-button down, drag, and up events, and consumes only unmodified
physical button 2. Tap failure disables that runtime path without disabling
keyboard activation. Both tap implementations copy scalar position, button,
modifier, timestamp, and event-kind values only.
Divider-local events, hover, Escape, and title-bar double-click handling keep
their AppKit paths.

Divider and Tabbed tab-drag gestures install local and global AppKit key monitors
until release, cancellation, or overlay hiding. Both forward only the key code.
Escape cancels synchronously on the main actor, including when a managed app
retains keyboard focus. The global monitor only observes the event; the local
monitor consumes Escape and passes other keys through.

All window mutations pass through the main-actor coordinator. Multi-window operations preflight every participant, apply in deterministic order, and roll back already-applied frames when a later Accessibility write fails. Ghost resize transactions do not mutate real windows before commit; live transactions can restore their original baseline on cancellation. AX move/resize events are debounced, while events matching a recent coordinator generation and expected frame are suppressed to prevent feedback loops.

Continuous resize gestures keep only the newest pointer or observed-window
sample and consume it on an AppKit display-link tick. Live Accessibility batches
run at no more than 60 Hz; ghost-only feedback may follow the display's native
rate. Intermediate ticks reuse one frame transaction, skip unchanged targets,
and avoid repeated participant sweeps. They also skip the trailing
clamp-correcting size write; the next tick or the release corrects a clamp. Mouse-up bypasses coalescing, validates
the participants, and applies the exact final geometry. Linked resizing writes
only the neighboring windows; the application keeps control of the window the
user is resizing.

Frame batches share enhanced-accessibility setup per application. The
coordinator keeps placement and rollback in one synchronous batch. The macOS
adapter restores each application's original setting before the batch returns,
including error exits. This avoids toggling the same application's setting for
each of its windows. No suspension is held across an event-loop turn.

Tabbed selection preserves pane geometry and other windows' frames. It swaps
which window the pane's Bento leaf holds and fits only that window; it does not
rerun the minimum-size solver. Activation restores ordering in other panes only
when they contain a window from the activated application.

## Bento

Bento uses a binary split tree held by each display's runtime `LayoutSession`. Leaves reference currently visible windows and branches carry an axis, normalized weight, and lock state. New windows are inserted by evaluating every unlocked leaf and choosing the split with the lowest movement/area-change score; closed or hidden windows are removed from the current tree. `BentoResizeEngine` changes branch weights and recursively derives all affected frames, `BentoLayoutFitter` adopts native edge changes, and `BentoBoundaryResolver` exposes only shared segments verified against current window frames.

The **New window side** preference applies only to new Bento insertions.
Automatic retains the existing insertion policy. An explicit side favors a
constraint-valid insertion toward that edge within the existing partition tree.
Vacancies take priority, and an unavailable preferred split uses the normal
insertion policy. Minimized windows retain their reinsertion anchors, and
Space transitions retain their stored layouts. Changing the preference does
not rearrange existing windows.

### Tabbed on Bento

Tabbed is Bento with tab groups. A Tabbed desktop's `bentoState` is its layout;
`LayoutSession.tabbedState` adds only tab membership (`BentoTabbedLayoutState`)
and the pane that receives new windows. Reading `tabbedState` follows any
change a Bento operation made to the tree; writing it also writes the tree.

- Each pane is a Bento leaf holding its selected tab, or a vacancy with the
  pane's identity when empty. A pane follows its selected window, so a swap
  carries the whole group. Selecting a tab replaces the leaf's window without
  moving a boundary.
- The tab strip is a Bento content reserve,
  `BentoLayoutMetrics.contentTopInset`. Placements start each window below it,
  the constraint solver adds it to each pane's minimum height, and the
  boundary resolver expects it between stacked windows. Tabbed also sets
  `vacantMinimumSize` so empty panes stay large enough to receive a tab. With
  both at zero, Bento behaves as before.
- Only selected tabs count toward minimum sizes. Hidden tabs are placed at
  their pane's window frame, stacked behind the selected tab, as best effort
  (`WindowCoordinator.applyTabbed(required:)`): a hidden tab that refuses the
  size never fails the layout. Only hidden tabs whose frame changes are
  written, in the same frame-write batch, and they return if the layout fails.
- Bento owns every layout interaction in Tabbed: divider drags (including the
  minimum-size state), window drags, and minimum-size solving. After a Bento
  commit, Tabbed re-applies its state so hidden tabs follow their pane and the
  strips move. During a divider drag, the strips follow each accepted sample;
  hidden tabs follow at release. A window drag first tears the tab out of its
  group when the group has other tabs; a center drop adds the window to that
  pane as a tab, and a torn tab dropped nowhere returns to its group.
- A user's edge resize of a selected window follows Bento's rule
  (`TabbedLayoutState.adoptingResize`), read only after the mouse button is
  released. A shared pane edge moves that divider, stopping at each pane's
  minimum. Any other change, including One Pane, an outer edge, a move, or a
  macOS destination, puts the windows back. Hidden tabs and strips then follow.
- Bento's divider handle appears only on hover, so the Tabbed overlay adds a
  VoiceOver slider over each divider. The slider ignores the mouse; increment
  and decrement move the Bento divider by five percent of the area it splits.
- New windows join the active pane as its selected tab. Entering Tabbed from
  Bento adopts the tree, so every pane stays where it was. Leaving for Bento
  gives every hidden tab its own pane (`unstacked(in:)`) and removes the
  reserve. Leaving for Native restores the pre-Tabbed frames and keeps the tab
  groups for the next Tabbed visit.

## Linked resizing

The linked-resize engine detects and merges shared boundary segments within a configurable tolerance. Linked and Bento boundaries share the same overlay interaction model, but Bento resizing stays tree-aware instead of applying flat per-window deltas. The requested operation clamps against recursive subtree minimum sizes and visible bounds.

## Configuration

Settings use a versioned Codable envelope. Version-1 display-keyed Bento states are discarded during migration because their Accessibility IDs cannot survive relaunch; all other supported preferences migrate. Runtime display sessions are not persisted. Writes use Foundation's atomic file replacement.

## Security

Only Accessibility permission is required. BetterTile does not inject code or disable SIP. Public Apple APIs are preferred; any private API integration requires the design review, approval, fallback, testing, and disclosure defined in [SECURITY.md](../SECURITY.md).
