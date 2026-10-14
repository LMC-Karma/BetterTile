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

## Popup and fixed-size windows

A popup window floats at its own size and never joins a Bento or Tabbed
layout. Examples are file pickers, settings and progress dialogs, and About
windows. `PopupWindowClassifier` in Core makes the decision from attributes
that `AccessibilityWindowSystem` reads. The rules adapt AeroSpace's
`isDialogHeuristic`; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

- A modal window is a popup.
- A window whose subrole is not `AXStandardWindow` is a popup.
- A window without an enabled full-screen button is a popup. Listed terminals,
  editors, Chromium browsers, and a few other applications are exceptions,
  because their ordinary windows can lack that button. Firefox and Ghostty
  have their own rules.

Some windows cannot be judged yet. A minimized or fullscreen window, a window
whose attributes cannot be read, and a window with an attached sheet get no
verdict, and a later sweep judges them again. A sheet disables its window's
close button, so a document with an open Save sheet stays tiled. A verdict
lasts for the life of the window.

A fixed-size window is a window whose size or position attribute is not
settable. A Bento pane would ask it for a frame it refuses, so it floats on a
Bento desktop, including after the desktop leaves Tabbed for Bento. Tabbed keeps
it as a tab. A window that cannot be resized keeps its own size, centred in
its pane's window area, and the pane must be large enough to hold it.

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

Some applications close a document window without a destruction event; focus
only moves to another window. When focus lands in a Bento layout, the model
marks a check for the next event pass. It resolves the focused window when the
event arrives, so a later focus change elsewhere cannot clear the mark. The
event pass runs one check however many events marked it. The check reads the tiled panes of every
active Bento layout through the targeted cached refresh. A document closed on one
display can move focus to its application's window on another display, so the
check is not limited to the focused layout. If every pane is still visible and eligible,
no complete sweep runs. A missing, ineligible, or unreadable pane, or an
unavailable cache, requests the complete sweep above. The check only requests a
sweep; it never confirms closure by itself.

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

All window mutations pass through the main-actor coordinator. Multi-window operations preflight every participant, apply in deterministic order, and roll back already-applied frames when a later Accessibility write fails. A committed layout writes each application on its own thread: shrinking windows first, in every application at once, then growing windows. Within one application the writes keep the coordinator's order. Rollback reads every attempted window before it restores one. Ghost resize transactions do not mutate real windows before commit; live transactions can restore their original baseline on cancellation. A Ghost release whose post-commit correction fails or is cancelled also restores the baseline. AX move/resize events are debounced, while events matching a recent coordinator generation and expected frame are suppressed to prevent feedback loops.

Continuous resize gestures keep only the newest pointer or observed-window
sample and consume it on an AppKit display-link tick. Live Accessibility batches
run at no more than 60 Hz; ghost-only feedback may follow the display's native
rate. Intermediate ticks reuse one frame transaction, skip unchanged targets,
and avoid repeated participant sweeps. They also skip the trailing
clamp-correcting size write; the next tick or the release corrects a clamp.
Live ticks read each written window back but never send a position nudge;
only a final write does, for a kept size the learned minimum does not already
explain at a frame that does not prove the write was processed. A single-window
write and a batched committed write use the same rule. The nudge counts only
when the window follows it and then returns to its position. It proves that
the application handles writes, not that the size is final, so the kept size
becomes a pending clamp; see [Minimum sizes](#minimum-sizes).
Each tick writes every application at once, one thread per application, and
returns only after every write. A shrinking window takes the new sample at
once. A growing window, or the growing axis of a window at a junction, takes
the previous sample, so it only enters space its neighbour gave up a tick
earlier. A growing window that would overlap a neighbour that refused its
size waits for the next sample or the release; a still pointer does not keep
the display ticks running for it. A rejected tick shrinks windows back before
it regrows their neighbours. Mouse-up bypasses coalescing, validates
the participants, and applies the exact final geometry. Linked resizing writes
only the neighboring windows; the application keeps control of the window the
user is resizing.

During a Live Resize, a window that holds a size larger than requested gives
a minimum for that gesture only. Each readback is compared with the size
before its write. An axis that shrank and stopped short of its request is a
refusal once a later tick, at least 50 ms later, still holds it. At 120 Hz a
60 Hz application can report one lagging length on two ticks in a row; 50 ms
spans three of its frames. An axis that kept its size is a refusal only after
it held for 0.25 s, because the application can still be applying an earlier
size. The persistent learner reads live ticks the same way: their readbacks
often trail the requests by a few ticks, so a shrink is measured from the
smaller of the previous readback and the previous tick's request.

A Ghost Preview release commits the previewed layout and reads every window
back. A window that shrank toward its size and stopped short of it gives a
measured minimum, and the release solves the layout again with it, at most
twice. Each commit is compared with the frames before it. A window that kept
its size or grew gives no evidence at once. A Bento release leaves it to
settlement. A native linked release, Ghost Preview or Live Resize, has no
settlement, so BetterTile reads its windows again 0.25 s later. A size still
held then, at the same origin, is a refusal: the release is solved again once
with it, if the result stays inside the display without overlaps and above
every minimum. Otherwise the windows return to their frames from before the
gesture, and the release's Restore step is removed. The correction adds no
Restore step. A new gesture, another write to the windows, or a window that
moved, for example by the user, ends the check. Undo history records the
release once, after any correction. If a correction fails or is cancelled,
every window returns to its frame from before the gesture.

Frame batches share enhanced-accessibility setup per application. The
coordinator keeps placement and rollback in one synchronous batch. The macOS
adapter restores each application's original setting before the batch returns,
including error exits. This avoids toggling the same application's setting for
each of its windows. Outside a live divider drag, no suspension is held across
an event-loop turn. A live divider drag holds each application's suspension
from its first write until the gesture ends, cancels, or the overlay hides, so
an application such as a Chromium browser does not toggle the setting on every
tick.

Tabbed selection preserves pane geometry when the selected window fits. It swaps
which window the pane's Bento leaf holds and checks both minimum dimensions.
If it needs more space, Bento's constraint solver adjusts the pane boundaries.
`TabbedLayoutState.preferredPaneRatios` records the pane sizes from the user's
own layout edits: divider drags, edge resizes, presets, splits, and pane
removal. An edit records new sizes only for the partitions whose ratios it
changed. Other partitions keep the size the user set, even while a larger tab
has grown them. Fitting a tab does not change the recorded sizes. With
**Restore pane size when switching tabs** on, every Tabbed placement starts
from those sizes when they fit. A pane that grew for a larger tab therefore
returns to its size when a smaller tab is selected, and when the larger tab
moves, floats, or closes. A tab that needs more room grows its pane again from
those sizes. With the setting off, a grown pane stays grown. A hidden
tab is measured with `probeMinimumSizes` before it is raised, while it is still
behind its pane's selected tab. An impossible arrangement retains the previous
selection. `TabbedLayoutState.fitProblem` then names the cause for the result
pill: a window larger than the display, a locked divider, or the panes that
would have to shrink below their own minimum sizes. A focus change
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
no repair runs. A missing identity hides the curtain. An order that cannot be
verified keeps a curtain already shown, at the same bounds, for up to four
refreshes while the model checks again 80 ms later; then the curtain hides. A
window list that cannot be read hides it at once. The repair never activates an
application, changes keyboard focus or selection, or moves a window. Without
a readable order, selection still raises the selected tabs of panes that
share the selected window's application, and activation changes nothing.

## Minimum sizes

Applications rarely report a minimum size, so `WindowMinimumSizeLearner`
learns it from evidence. Some applications, such as Chromium browsers, apply a
new position at once and the new size later. A window that moves to a display
with another backing scale can also report its old size for a moment. A
readback straight after such a write shows a size larger than requested that
is not a minimum.

The adapter reads each written window back, axis by axis:

- An axis that shrank toward the request and stopped short of it is the
  minimum at once.
- An axis that kept its size, or grew, proves nothing yet. If the write was
  processed, it becomes a pending clamp. A write was processed when the window
  moved to the requested origin, its size changed, or it followed a position
  nudge.
- An axis that took the requested size lowers an older, larger minimum.

A pending clamp is confirmed axis by axis. An axis becomes the minimum only
when an observation at least 0.25 s after the write still shows the same
length. That observation can be a snapshot or the settled frame that Bento
settlement or the Tabbed placement loop reports. An earlier observation of the
same length leaves the axis pending. An observation with another length drops
that axis only, so a height applied late does not discard a width the window
kept. Any newer write to the window drops the whole clamp. The rule is
time-based: an application that applies a size more than 0.25 s after the
write still teaches the old size, until two smaller stable
snapshots lower it again. Chromium usually applies a size within a few display
frames, so 0.25 s leaves a wide margin while it still fits inside the
settlement and Tabbed sampling windows. The stable-mismatch path also learns a
shrink that settled short of its request. A minimum confirmed on any path
becomes the application's seed and invalidates cached snapshots.

Because of the delay, the sampling loops wait for it before they treat a kept
size as a refusal. Bento settlement keeps sampling, up to its usual limit,
while a changed window is larger than requested and larger than its known
minimum, until 0.25 s have passed. The Tabbed placement loop reports a stable
size mismatch, and gives up on a refused size, only after 0.25 s. The Tabbed
fit retry runs when the mismatch report learned a minimum or when the window's
refreshed constraints show a larger minimum, because a snapshot can confirm
the clamp first.

A new window on a managed desktop is measured before its first placement:
`probeMinimumSizes` writes a 1×1 size, reads the size back, and restores the
original frame within about 10 ms. Only an axis that shrank and stopped is a
measurement. A window that kept its size stays unmeasured, because the restore
leaves nothing to confirm later. Entering a mode or returning to a desktop
measures nothing, because those windows are already visible. A window is
probed at most once, even when the probe measures nothing, so an application
that applies its minimum late is not resized again on every selection.

Each application also keeps a seed: the latest measurement from any of its
windows. Only a proven measurement or a confirmed clamp becomes a seed, never
a pending clamp. A new window plans with its application's seed until the probe
measures it. Its own measurement then replaces the seed for that window and
becomes the application's new seed. BetterTile drops an application's seed
when a process of that application quits, so a relaunch starts without it.
Hiding an application keeps its seed. Measurements and seeds stay in process
memory and are never saved. `forget(windowID:)` drops one window's measurement
and pending clamp without probing it again, and `forgetApplication(_:)` drops
a seed. No feature calls `forget(windowID:)` yet.

## Unresponsive applications

An Accessibility call to a hung application blocks the main actor until its
messaging timeout. The timeout is 0.35 s for a read and 1.5 s for a frame
write. `UnresponsiveApplicationGate` in Core limits that cost to about one
timeout for each hang.

- A call that fails with `cannotComplete` after at least 0.3 s holds its
  application for 2 s.
- A quick `cannotComplete` is a busy application that answered. It neither
  starts nor ends a hold.
- Any completed call ends the hold.

`AccessibilityWindowSystem` routes reads, settable checks, frame writes, and
notification removals through `gatedCall`. `requireResponsive` stops a frame
write or minimum-size probe before its first call. While an application is
held, these calls fail at once, as a timed-out call would. A sweep already
treats a failed read as an unreadable application and keeps its windows, so
its panes stay in the layout. A frame-write sequence stops at the first
refused call.

Writes that put a user's window back stay ungated: the probe's size restore
and the position restore. The enhanced-accessibility restore is gated. If the
application is held or does not answer, the restore waits. BetterTile tries
it again at the start of the next frame batch and when it refreshes its
application observers. When BetterTile quits, after its last frame writes, it
makes one last ungated try; a restore that fails stays pending. An application that quit needs no restore. A notification removal
that does not complete stays recorded, because the notification may still be
registered.

While the front application is held, `focusedWindow()` reports it as not
responding. It does not fall back to a recently used application, so a
shortcut never acts on a window the user is not looking at.

## Bento

Bento uses a binary split tree held by each display's runtime `LayoutSession`. Leaves reference currently visible windows and branches carry an axis, normalized weight, and lock state. Closed or hidden windows are removed from the current tree. `BentoResizeEngine` changes branch weights and recursively derives all affected frames, `BentoLayoutFitter` adopts native edge changes, and `BentoBoundaryResolver` exposes only shared segments verified against current window frames.

`BentoPlanner` places a new window in this order. An explicit **New window
side**, described below, applies first. Bento holds at most six windows; a
seventh floats where it is.

1. While the tree still matches the automatic layout, the planner rebuilds the
   automatic layout with the new window.
2. Otherwise the largest empty slot takes the new window before any pane is
   split. An empty slot is a region of the tree without a window, such as the
   rest of the screen after a half-screen snap.
3. Otherwise the new window splits the focused pane along its longer side
   (`BentoLayoutState.split(_:inserting:in:)`). A wide pane gets the new pane
   beside it, a tall pane gets it below, and a square pane splits side by side.
4. If that split leaves a pane too small to use, the planner tries a split
   beside every pane on every edge. It keeps the layout whose smallest pane is
   largest, then the layout that moves existing windows least.

A window restored without a reinsertion anchor, and a window dropped onto
another window, also split their target along its longer side. Snaps can leave
an empty slot on purpose. Repair Bento removes empty slots, and the panes
beside a slot take its space.

After a placement writes the full Bento tree with multiple windows,
`commitBentoProposal` reads their measured sizes. If an application clamps a
window larger than requested, BetterTile solves the same tree with the learned
minimum sizes. A changed, valid solution gets at most one correction write
through `WindowCoordinator` within that commit, avoiding a later placement
jump. Only a shrink that stopped short of its request is learned in time for
this correction; a pending clamp is corrected by settlement once it is
confirmed. Settlement compares against the corrected frames. A failed correction
with a successful rollback keeps the first placement. If the correction and
its rollback both fail, the outcome is degraded and automatic writes stop
until a new transaction or Repair.

The **New window side** preference applies only to new Bento insertions.
Automatic retains the existing insertion policy. An explicit side favors a
constraint-valid insertion toward that edge within the existing partition tree.
Vacancies take priority, and an unavailable preferred split uses the normal
insertion policy. Minimized windows retain their reinsertion anchors, and
Space transitions retain their stored layouts. Changing the preference does
not rearrange existing windows.

The **Balance on new window** preference is off by default and applies only to
Bento. After a new window is inserted, `BentoBalancer` gives the children of
each partition equal shares. A child that cannot shrink to its share keeps its
minimum extent, and its siblings split the rest equally. A locked divider stays
in place, and each side of it is balanced separately. If the balanced tree
cannot meet the minimum sizes, the unbalanced insertion stands, so balancing
never turns a placement into a failure. A size an application refuses on write
goes through the same learned-minimum correction as any other Bento placement.

Each reinsertion anchor stores a neighbor, an edge, and the tree from just
before the minimize. Restoring several windows rebuilds the largest stored
tree. A drop, swap, partition, Layout Wheel command, or divider move clears
the stored trees, because restoring one would undo that change. The anchors
keep their neighbor and edge. A Focus mode drop, such as Maximize or macOS
Fill, keeps the stored trees, because Focus mode restores the tree from before
it began.

Maximize enters Focus mode on a tiled Bento window and retains the previous
tree for that desktop session. Restore, Maximize again, and a peer restored
from the Dock share one bounded wait for the covered peers to return before
restoring that tree. A peer still minimized when the wait ends, such as one
whose restore failed, leaves the tree like any minimized window: the available
windows fill the display, and the peer's reinsertion anchor keeps the previous
tree for its return. A rejected layout restore suspends
automatic placement until Repair. Background sweeps retain membership without
moving windows while the wait owns that session. A newer layout action cancels
the wait.

Keyboard and captured Layout Wheel partitions use the same peer-return wait.
When all peers are visible, the partition runs synchronously. Otherwise it
keeps the original target and replans after the peers return or the 1.5-second
deadline expires. It does not restore the previous tree before partitioning.
The resumed command validates the captured window, display, Space, session,
mode, and application rule again. Shortcut cycling still applies to keyboard
commands. A newer partition replaces the pending command and retains its
returning peers. Repair waits behind the command. Mode changes, a different
session, a newer gesture, and shutdown cancel the wait. Failed restore requests
and peer-return timeouts are logged. At the deadline, available peers join the
requested partition without waiting indefinitely for missing peers.

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
- One Tabbed curtain covers the display's work area.
  It sits below every selected tab and above inactive tabs, including portions
  that extend outside their panes. `TabbedOverlayController` orders this
  normal-level, nonactivating panel below the backmost selected window with
  public `NSWindow.order(_:relativeTo:)`. The model verifies the WindowServer
  order and every tab identity before supplying that anchor. Missing
  identities hide the curtain. Unverified ordering keeps a curtain already
  shown for up to four refreshes, then hides it. It never guesses from a
  frame or parks a window. Native frosted glass conceals inactive window
  detail. Rounded cutouts exclude occupied tab strips, including during
  resizing. The curtain keeps its rectangular input surface; the strips above
  it own tab interaction. Disabling glass, Reduce Transparency, and Increase
  Contrast use an opaque surface.
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
  Commands use the pane scope: the source's pane moves with all its tabs,
  swapping with a pane already at the exact logical region. Otherwise it
  reserves the requested region and the other panes are assigned to a
  deterministic subdivision of the remainder; extra regions become empty
  panes. Native snap zones use the window scope: only the source window moves
  between groups. An exact logical destination pane receives it; otherwise a
  new pane reserves the requested region and every retained pane is assigned
  to the remainder. A floating source always uses the window scope.
  Assignment memoizes pane subsets, bounded by the 12-pane cap.
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
  (`TabbedLayoutState.adoptingResize`), committed only after the mouse button
  is released. While the button is held, the same rule drives a preview of the
  tab strips and curtain; it moves no window. A shared pane edge moves that
  divider, stopping at each pane's minimum. Any other change, including One
  Pane, an outer edge, a move, or a macOS destination, puts the windows back.
  Hidden tabs and strips then follow. An edge released where it started
  changes nothing, and the strips return from the preview to the panes.
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
  suppress the handle. The on-screen window stack determines which foreign
  windows are in front of the seam's participants. Only windows at or below
  the handle's floating level count. Higher levels, such as the Dock's
  display-sized window on macOS 26, already draw above the handle. The handle
  and its track stop at the edges of exposed seam segments. Hover caches the stack for
  150 ms and invalidates it on boundary refresh or application activation.
  A gesture reads the stack once at its start and recomputes coverage from
  those frames as the seam moves. Missing stack data or an unresolved exact
  identity for any managed member retains the previous floating-window
  fallback, including when private APIs are disabled. Known inactive tabs
  absent from the on-screen stack do not disable coverage. A captured drag
  keeps its input window until release; when less than 24 points remain, its minimum knob can overlap a
  cover. A captured junction also retains its central target if a cover
  reaches it. The junction's rectangular input frame is bounded against
  diagonal covers as well as covers over its arms.
  Third-party transparent overlays at or below the floating level still cover
  the seam when their window alpha is above 0.01. Bento's divider
  handle appears only on hover, so the Tabbed overlay adds a
  VoiceOver slider over each divider. The slider ignores the mouse; increment
  and decrement move the Bento divider by five percent of the area it splits.
- New windows join the active pane as its selected tab. An arrival that cannot
  fit there joins, as a hidden tab, the other pane that can show it with the
  least change to the panes: as is, or after boundaries adapt. If no pane can
  show it, it floats at its own size, moved fully onto the work area when it
  fits there, and the result pill says it does not fit in any pane.
  Entering Tabbed from Bento adopts the tree, so every pane stays where it was.
  Leaving for Bento gives every hidden tab its own pane (`unstacked(in:)`) and
  removes the reserve. Hidden tabs fill empty panes first, largest empty pane
  first, each taking the next hidden tab from the nearest pane. The other
  hidden tabs split their own pane along its longer side. An empty pane left
  over is removed, so Bento shows no empty slot. Leaving for Native restores
  the pre-Tabbed frames and keeps the tab groups for the next Tabbed visit.

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
events. The Tabbed curtain follows the same preference, with regular glass
and an additional 14-percent frost floor even at Clear. Its plate ranges from
14 to 36 percent, without an outline around the work area. It uses the same
opaque fallback when glass is disabled or either display option is enabled.

The menu bar popover uses the system's native glass. `GlassBacking` adds only
the shared frosting or accessibility fallback over it; Clear removes this
additional layer. The Layout Wheel uses the same backing over one native glass
surface. Its hub does not add a second glass material.

Divider handles use public Core Animation layers and a retained Core Image
`CIGlassLozenge` filter on each colored track. The handle is clear at rest.
Grabbing fades in the track and stretches only the length over 0.18 seconds;
the glass width stays at the Divider width setting plus 4 points. The shadow
stays constant. Tracks stop at the supplied room on each arm. Glass transparency
controls the white body's opacity and adds up to 2.5 points of Gaussian blur
above the default frost level. Thin white edge rings and cap glints define the
lens; an orange track and hairline indicate a resize limit. All shadows have
explicit paths and the lens uses no masks. Geometry is cached per capsule set,
unchanged appearance updates return immediately, and pointer samples update
named filter parameters instead of replacing filters. Settings changes update
visible or grabbed handles without window placement. Glass off uses the
configured width and a frosted grey surface: a HUD material clipped to the
handle outline, under a translucent grip tint and a light rim. It turns blue
when grabbed and orange at a resize limit. Unavailable Core Image filters also
use the frosted surface. Reduce Transparency and Increase Contrast use a solid
fill. Hit testing and window resizing keep their existing
behavior; junction input frames keep their earlier width, which contains the
narrower lens.
At rest, a separate click-through panel below the handle supplies the track and
shadow. During a divider drag, one reusable click-through panel contains the
track, shadow, and knob, plus the preview views in Ghost Preview. Its frame stays
at the display's visible bounds and it is ordered below the input handle once.
Each display tick updates all drawing in one transaction with layer actions
disabled. The input handle stays visible and stationary, with its drawing hidden.
Live Resize needs this too: moving the panel that owns the drag on every tick
made Chromium browsers block their own window writes for 80–150 ms while they
were the active application. A drawing
sample forwards geometry, limit, stretch, and appearance changes to the overlay.
Ending the gesture restores the handle frame and drawing before hiding the
overlay and retracting. Settings uses the same lens views.
The preference also covers tab strips, Tabbed drop targets, resize ghosts,
the Layout Wheel, the menu bar popover, and result feedback. Snap and Bento
placement/swap previews retain their light outlines, tint, and pulse.

Tab dragging changes a provisional display order, without mutating the layout.
The lifted tab follows the latest pointer sample on each display tick, and
native layer springs move its neighbors. Insertion uses stable target geometry,
not animated positions. The same tick scrolls crowded strips at held edge
positions. Unchanged destinations retain their preview frame and window order.
Tooltips and accessibility children refresh when the drag presentation ends,
instead of on each provisional move. Mouse-up bypasses coalescing, recomputes
the exact release destination, and emits one intent. The released tab stays at
its destination until that placement completes; failure restores the committed
order. Clicks during a pending drop capture the displayed window identity and
queue selection behind placement. New tab drags wait for any pending placement
to finish. A blocked drag does not become a click on release. Escape, hiding,
or a layout change clears the provisional order, queued samples, springs, and
scrolling. Reduce Motion disables the springs.

Tabbed retains accepted commands in order while a placement is pending. On
completion, a consecutive run of selections keeps the last choice in each
pane, using the now-committed membership. Moves and other commands separate
these runs. Synchronous commands do not discard deferred reconciliation.
Native center drops use the original group and frame checkpoint for rollback;
membership and Undo commit only after placement succeeds. Returning a torn tab
to its origin restores its original order and selection without adding Undo.
A native drag supersedes the prior unfinished placement and commands queued
before capture. Commands accepted after capture wait for release; the cancelled
placement cannot discard them or unlock tab dragging during the native gesture.
Release drains those commands even when no new placement is needed.

## Linked resizing

The linked-resize engine detects and merges shared boundary segments within a configurable tolerance. Linked and Bento boundaries share the same overlay interaction model, but Bento resizing stays tree-aware instead of applying flat per-window deltas. The requested operation clamps against recursive subtree minimum sizes and visible bounds.

## Configuration

Settings use a versioned Codable envelope. Version-1 display-keyed Bento states are discarded during migration because their Accessibility IDs cannot survive relaunch; all other supported preferences migrate. Runtime display sessions are not persisted. Writes use Foundation's atomic file replacement.

## Security

Only Accessibility permission is required. BetterTile does not inject code or disable SIP. Public Apple APIs are preferred; any private API integration requires the design review, approval, fallback, testing, and disclosure defined in [SECURITY.md](../SECURITY.md).
