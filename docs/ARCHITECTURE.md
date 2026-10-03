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
After a successful application Accessibility inventory omits a window, cleanup
requires either its exact identity to be absent from the full public WindowServer
list or its cached Accessibility element to report `invalidUIElement`. The latter
confirms closure without an exact WindowServer identity. Other Accessibility read
failures do not confirm closure. Destruction events and application termination
also remove window identities.
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

Tabbed selection preserves pane geometry when the selected window fits. It swaps
which window the pane's Bento leaf holds and checks both minimum dimensions.
If it needs more space, Bento's constraint solver adjusts the pane boundaries.
An impossible arrangement retains the previous selection. A focus change
selects a tab only when that
window's application is frontmost. While BetterTile or an application it cannot
read is in front, `focusedWindow()` reports the last managed application's
window, and selecting it would take focus away.

After a focus change, application activation, or tab selection,
`TabbedLayoutState.sharedCurtainStackingRepair` compares the WindowServer
front-to-back order with every tab on the display. It puts all selected tabs
above all inactive tabs. Windows already in front, including floating windows
in pane gaps, are raised again when needed to keep them above the shared
curtain. If a tab's identity is missing or a protected window cannot be raised,
no repair runs and the curtain hides. The repair never activates an
application, changes keyboard focus or selection, or moves a window. Without
a readable order, selection still raises the selected tabs of panes that
share the selected window's application, and activation changes nothing.

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
  carries the whole group. Selecting a tab replaces the leaf's window.
  Boundaries move only when the selected window needs more space.
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
- In the Debug experiment, one Tabbed curtain covers the display's work area.
  It sits below every selected tab and above inactive tabs, including portions
  that extend outside their panes. `TabbedOverlayController` orders this
  normal-level, nonactivating panel below the backmost selected window with
  public `NSWindow.order(_:relativeTo:)`. The model verifies the WindowServer
  order and every tab identity before supplying that anchor. Missing
  identities or unsafe ordering hide the curtain. It never guesses from a
  frame or parks a window. An opaque, bright neutral gradient conceals inactive
  windows. Rounded cutouts exclude occupied tab strips, including during
  resizing. The curtain keeps its rectangular input surface; the strips above
  it own tab interaction. Reduce Transparency and Increase Contrast use a
  uniform opaque surface.
  A click selects the selected tab in that pane, or activates an empty pane;
  it does not reach an inactive tab. Curtains have no accessibility navigation.
  They hide with the overlay on mode exit, Space changes, fullscreen, display
  removal, and shutdown.
- With the same identity, tab strips and empty panes are normal-level panels
  ordered directly above the selected window, or above the active pane's
  selected window for an empty pane. Any window in front of the selected tab,
  including BetterTile's floating Settings window, therefore covers them.
  Without the identity, they float above normal windows and hide only under
  the focused window, as before. `AccessibilityWindowSystem.stackingOrder`
  reads on-screen normal-level windows with `CGWindowListCopyWindowInfo` and
  skips BetterTile's Tabbed panels. Cross-application ordering still needs
  live validation.
- Bento owns every layout interaction in Tabbed: divider drags (including the
  minimum-size state), window drags, and minimum-size solving. After a Bento
  commit, Tabbed re-applies its state so hidden tabs follow their pane and the
  strips move. During a divider drag, the strips and curtains follow each
  accepted sample without repeating tab ordering; hidden tabs follow at
  release. A window drag first tears the tab out of its
  group when the group has other tabs; a center drop adds the window to that
  pane as a tab, and a torn tab dropped nowhere returns to its group.
- Fixed partition snaps use `TabbedSnapPlanner` through one model route for
  keyboard/menu actions, captured Layout Wheel commands, and native snap zones.
  Only the source window moves between groups. An exact logical destination
  pane receives it; otherwise a new pane reserves the requested region and
  every retained pane is assigned to a deterministic subdivision of the
  remainder. Assignment memoizes pane subsets, bounded by the 12-pane cap.
  A conservative subdivision may refuse an otherwise possible packing.
  Pane matching and the fixed-target invariant use gapless logical geometry;
  normal gaps and the tab-strip reserve apply once to window placements.
- Snap membership remains provisional until all selected frames settle.
  Learned-minimum retries replan from the original state and must preserve
  the exact requested region. Hidden tabs remain best effort on success;
  rollback verifies the prior selections too. Native snaps keep the original
  group state and verified frame checkpoint, including the mouse-down frame
  of a user-floated source. Undo records one successful change and retains
  that float frame without changing the Native-exit baseline. Queued snaps
  keep the captured window/action and replan against the current session.
  Work-area, Space, session, mode, and rule checks protect asynchronous work.
- A user's edge resize of a selected window follows Bento's rule
  (`TabbedLayoutState.adoptingResize`), read only after the mouse button is
  released. A shared pane edge moves that divider, stopping at each pane's
  minimum. Any other change, including One Pane, an outer edge, a move, or a
  macOS destination, puts the windows back. Hidden tabs and strips then follow.
- Divider and native-edge resize proposals remain provisional until every
  selected window accepts its frame. Recovery uses the session's last verified
  frames, even when a divider gesture begins with a displaced window. Current
  observed frames remain separate inputs to the Accessibility write planner.
  Minima learned on live release allow at most two corrective solves before
  completion. Width and height retain independent refusal evidence. Failed or
  unsettled corrections restore the gesture checkpoint.
  Rejected proposals restore the checkpoint only while its desktop, display,
  and participants remain valid. Bounded readback lets accepted restoration
  settle before classifying an incomplete restore as degraded.
- Tabbed's pointer dividers use pane boundaries even when an application has
  displaced its selected window. Inactive tabs and BetterTile panels do not
  suppress the handle. Verified window order determines which floating
  windows are in front and can suppress it; without that order, the
  frontmost application's floating windows provide the fallback. Bento's divider
  handle appears only on hover, so the Tabbed overlay adds a
  VoiceOver slider over each divider. The slider ignores the mouse; increment
  and decrement move the Bento divider by five percent of the area it splits.
- New windows join the active pane as its selected tab. Entering Tabbed from
  Bento adopts the tree, so every pane stays where it was. Leaving for Bento
  gives every hidden tab its own pane (`unstacked(in:)`) and removes the
  reserve. Leaving for Native restores the pre-Tabbed frames and keeps the tab
  groups for the next Tabbed visit.

## Overlay appearance

`OverlayAppearance` stores the shared Liquid Glass preference and frosting
strength. Settings presents its inverse as **Glass transparency**, from
Frosted to Clear. The persisted value keeps its existing meaning; no migration
is needed. Invalid strength values fail configuration validation. Appearance
changes update visible views without placing windows or cancelling a gesture.

`OverlayGlassView` uses native AppKit glass with a light semantic-color plate.
The slider changes only that plate, continuously from 22 percent to zero.
Text-bearing surfaces retain regular glass. Empty panes use clear glass with
half that added frosting. Disabling glass, Reduce
Transparency, or Increase Contrast selects an opaque surface. Display-option
changes apply while views are visible. Decorative glass never owns pointer
events. The Tabbed curtain conceals inactive windows independently of this
preference.

The menu bar popover uses the system's native glass. `GlassBacking` adds only
the shared frosting or accessibility fallback over it; Clear removes this
additional layer. The Layout Wheel uses the same backing over one native glass
surface. Its hub does not add a second glass material.

Divider handles draw their lens with public Core Animation layers. Native
glass blurs at this size without providing the required lens optics. The lens
draws a magnified accent track, reflections, and one rounded junction outline.
A separate click-through panel below the handle supplies the fading track and
outer shadow. Resize ghosts sit below both panels. The track stops within the
usable divider span. Glass transparency controls the lens body's frosting.
Straight hit areas, cursors, and minimum-size feedback keep their existing
behavior. Junction hit frames grow to contain the wider lens: at the default
thickness, the resting four-way frame is 44 points square instead of 34.
Glass off, Reduce Transparency, and Increase Contrast select the solid capsule.
The settings preview uses the same handle and decoration views.
The preference also covers tab strips, Tabbed drop targets, resize ghosts,
the Layout Wheel, the menu bar popover, and result feedback. Snap and Bento
placement/swap previews retain their light outlines, tint, and pulse.

Tab dragging changes a provisional display order, without mutating the layout.
The lifted tab follows the pointer and native layer springs move its neighbors.
Insertion uses stable target geometry, not animated positions. Held edge
positions scroll crowded strips. Mouse-up recomputes the destination and emits
one intent. The released tab stays at its destination until that placement
completes; failure restores the committed order. New tab drags wait for any
pending placement to finish. Escape, hiding, or a layout change clears the
provisional order, springs, and scrolling. Reduce Motion disables the springs.

## Linked resizing

The linked-resize engine detects and merges shared boundary segments within a configurable tolerance. Linked and Bento boundaries share the same overlay interaction model, but Bento resizing stays tree-aware instead of applying flat per-window deltas. The requested operation clamps against recursive subtree minimum sizes and visible bounds.

## Configuration

Settings use a versioned Codable envelope. Version-1 display-keyed Bento states are discarded during migration because their Accessibility IDs cannot survive relaunch; all other supported preferences migrate. Runtime display sessions are not persisted. Writes use Foundation's atomic file replacement.

## Security

Only Accessibility permission is required. BetterTile does not inject code or disable SIP. Public Apple APIs are preferred; any private API integration requires the design review, approval, fallback, testing, and disclosure defined in [SECURITY.md](../SECURITY.md).
