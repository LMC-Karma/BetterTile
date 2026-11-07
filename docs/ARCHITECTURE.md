# Architecture

Product text uses **Adaptive** instead of Bento, **Manual** instead of Native, **Resize Preview** instead of Ghost Preview, and **Repair Layout** instead of Repair Bento or Repair Tabbed.

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

`ConfigurationStore.load` returns defaults only for a confirmed missing file.
Lookup, read, decode, schema, and validation failures propagate to the app model.
The model retains the load error for its lifetime and blocks delayed saves,
explicit flushes, and shutdown saves. Settings shows a persistent explanation
independent of action status. Runtime configuration changes remain usable for
the session. Restoring a valid file and relaunching resumes normal saving.

## Time source

`BetterTileClock` in Core wraps Swift's `Clock` protocol with `Duration` and
monotonic `ContinuousClock.Instant` values. Its live default uses
`ContinuousClock`. `BetterTileModel` passes its injected clock to
`WindowCoordinator` and display-refresh debouncing. It drives recovery,
window-event scheduling, Space stabilization, settlement, arrival confirmation,
configuration-save delays, and coordinator retry waits. Arrival dates project
elapsed monotonic time from one initial wall-clock date.
`ResultPillController` also accepts an injected clock for dismissal.

Application responsiveness holds and pane-application deadlines use separate
uptime callbacks, defaulting to process system uptime. Tests replace these
callbacks together with the clock so hold expiry and recovery deadlines agree.
The 10-second watchdog remains a native run-loop timer. DragSnap pointer and
chooser delays and the pane-application picker retain separate UI timing seams.
Clock injection does not change the layer dependencies.

Saved Layout preview throttling and display-trigger settling and lock waits
also accept this clock.

Display-trigger elapsed time uses the same continuous clock as its waits and
includes system sleep. A settle wait that spans sleep can reach its limit when
execution resumes. The trigger reducer cancels and restarts waits on sleep and
wake events. Sleep during a settle wait remains a native manual check; fake-clock
tests cover cancellation and the settle limit.

## Coordinate model

Core geometry uses logical points with a top-left origin. Display visible frames and Accessibility window frames are converted at the macOS boundary. Core code never sees AppKit's bottom-left global screen coordinate system. With Leave space for Dock on, or with a Dock that never hides, the macOS boundary also removes the Dock's strip from its display's visible frame. macOS already reserves that strip for a Dock that never hides, but AppKit can report a secondary display's visible frame late after the Dock moves there or changes edge. The strip is the Dock's Accessibility list thickness plus 6 points, which matches what macOS reserves for a Dock that never hides, within a point. The list keeps its size while the Dock is hidden, so the work area stays the same as the Dock slides in and out. A Dock not shown since it started, as after login, reports no size; until it is shown, the thickness last measured on its edge stands in on the main display.

Pane ratios and logical pane geometry retain their precision. Adaptive window placements
snap pane edges to whole logical points before the content reserve and work-area
clamping. Half points round toward positive infinity on both sides of zero, so
whole-point gaps remain exact on negative-origin displays too. Origin and size
are not rounded separately.

Tabbed snaps the content edges after the tab-strip reserve to whole points.
Requests, stepped-size correction, resize classification, and overflow checks
use the same `windowFrame(forPane:)` projection, exposed by `contentFrames(in:)`.
Tabbed passes these expected frames to the shared divider fitter. The fitter
matches projected window edges to projected boundaries; its tolerance stays
unchanged. Logical pane frames and ratios remain precise.

## Snap Zones

Snap Zones settings keeps zone selection directly below the diagram, followed
by Activation area. Activation area offers picture choices: Narrow (3-point
edge, 48-point corner reach), Standard (5 and 69, the default), Wide (12 and
120), and Custom. Custom shows two steppers: Edge, from 1 to 40 points, and
Reach, the total corner reach on each axis from the display edge. Reach stays
between edge + 16 and edge + 160 points. When an edge change pushes reach out
of that range, reach moves with it and the caption says so. Values apply live
across displays. Reset to Default restores Standard; assignment defaults have
their own Reset to Default.

Configuration stores `snapEdgeActivationDistance` and
`snapCornerActivationSize` (the corner extension, so reach = edge + extension)
independently. The presets are derived values in `SnapZonePreset`; nothing new
is stored. Stored values that match no preset exactly show as Custom. Missing
values decode to the original 5-point edge width and 64-point corner
extension, for a 69-point corner reach. The diagram draws the bands at display
scale, clipped by its stage, and highlights the selected zone. An edge band is
at least 4 points thick so that it stays visible, and a corner is never thinner
than its edge band. At this minimum, Narrow, Standard, and Wide edges can look
the same; their corners still differ. The picture-choice thumbnails exaggerate
the bands, for comparison. The diagram does not draw an overlay on a real
display.

`SnapZoneDetector` tests corners before edges against full display bounds.
Placement uses the work area, which excludes the menu bar and reserved Dock
space. The same configured edge width determines where snapping wins over a
Tabbed tab strip. Outside that band, the strip wins over a corner area.
Pointer display ownership at shared edges stays unchanged. These settings do
not change macOS desktop-switch dwell handling.

## Window drag drops

A window drag has one decision: the drop that its overlay shows.
`DragSnapController` records that drop as a `WindowDropTarget` when it shows a
snap preview or an armed Bento cue. An ordinary snap records its action and
frame. A Bento or Tabbed drop records the `PreparedLayoutDrop` that the model
planned for the overlay: the outcome, the frames shown, and the Bento plan or
Tabbed arrangement. A Bento snap preview shows the planned frame of the dragged
window, with its gaps, and the frames of the windows that move. The value
clears when the overlay hides, for example when the pointer leaves the snap
area, a suppression modifier is held, or Escape cancels the drag.

A drop that cannot apply shows invalid feedback: a red snap frame or a red
pane cue. It is recorded as a non-committable target with a reason. Release
over it applies nothing and shows the reason in the result pill. A window
tiled in Bento or Tabbed returns to its slot. Any other window, such as a
Native window or a floating window, stays where the user dropped it, as after
any drag without a snap. A Bento snap whose remaining windows cannot fit, a
Tabbed snap that cannot keep its target, a Tabbed tab drop whose pane cannot
show the window as its selected tab, and a snap whose window minimum is larger
than the snap frame all show invalid feedback.

Release commits the recorded drop. It does not evaluate the release point
again, run the Bento hover delay again, or plan or fit the drop again. Before
any write, release checks that the desktop is the one the plan was made for:
the same layout session and revision, mode, Space, and work area. A plan from
another drag, or for a desktop that changed during the drag, writes none of
its frames, and the pill reports that the layout changed. After such a change,
every release, including one over nothing or over invalid feedback, puts the
dragged window in its slot of the current layout, for example after a shortcut
moved it during the drag. Settlement retries that write if the application
ignores it. A torn-off Tabbed tab returns to its pane if the pane remains;
otherwise the pill asks for Repair Tabbed. Nothing is written on another Space
or after a mode change. A Bento or Tabbed window released or cancelled without a drop
returns to its slot; a floating one stays where it is. Only a drop that the
overlay showed adds a window to the layout. Only a drag
that showed nothing, such as a fast flick to a screen edge, evaluates the
release point once. A suppression modifier held at release cancels the drop. A
Bento cue arms only after its hover delay, because the armed cue is the drop.
At a screen edge, a snap area wins over the edge of the pane under it, so the
overlay shows the snap and not a pane cue.

On a Tabbed desktop, a dragged window joins a pane as a tab in three places:
the center of a pane's selected tab, a pane's tab strip, and an empty pane.
This holds for a floating window and for a tab from another pane.
`BentoDragOutcome.tab` carries the pane and, for a strip, the tab index.
`TabbedOverlayController.tabDropZone(at:dragging:)` finds the strip or empty
pane under the pointer, with the strip insertion geometry of tab drags; the
model passes it to `DragSnapController` as a provider, so the macOS layer does
not read application state. The dragged window covers the strip, so the
insertion line is a floating-level panel, like the Bento drop cue. The
overlay plans the drop when it shows it: the window joins as the pane's
selected tab, and pane boundaries may adapt to show it. The cue says **Add as
tab**. A window that the pane cannot show does not join it as a hidden tab,
because its application could bring it in front of the other panes. The cue is
invalid and names the window and the axis, for example "Safari is too wide for
this pane"; `TabbedLayoutState.fitFailure(showing:in:windows:)` gives the
axis. A strip and an empty pane arm at once; a pane center waits for its
hover delay. A tab strip under the pointer wins over a snap area, except at
the screen edge itself, within the snap edge band: without a permanent menu
bar the top strips reach the top edge, and a pointer at that edge still snaps.
Farther inside the strip, the strip also wins over a corner area.
An empty pane does not win over a snap area. A pane's only tab dragged over
its own strip shows no drop, because the drop would change nothing. If the
placement of a floating window's tab drop fails, the window stays where it was
dropped and the pill reports the failure. Undo returns a floating window to its
frame from before the drag. The drop cue panels are excluded from screen
capture (`sharingType = .none`), so screenshots do not show them.

`PointerDisplay` maps the pointer to exactly one display. Display frames are
half-open, as in CoreGraphics: a point on an edge that two displays share
belongs to the right display of a side-by-side pair and to the lower display
of a stack.

The dragged window's own display does not take part in the drop. At a shared
edge, its center is often on the neighbouring display. Drag commits pass a
`DropDestination` to `WindowCoordinator`, which checks the dragged window's
reachability on the drop's display. Every other window keeps its own display,
so a window that an application moved to another display during the drag
makes the drop fail. Tabbed participant, restore, and rollback checks accept
the dragged window on either display. A frame that is mostly off the drop's
display is still rejected.

A snap preview shows the frame that the window will take. If the window's
known minimum size is larger than the snap area, the frame grows from the
snapped edges and stays inside the drop display's visible frame. Every drop,
including Bento, Focus mode, and Tabbed drops, carries the minimum sizes that
its overlay planned with. Release checks each frame against them, so a minimum
read again at release does not reject or change a drop that the overlay showed
as valid. A write that an application refuses still follows the usual readback
and rollback rules. Like any Tabbed placement, a Tabbed tab drop then retries
once with the size the application revealed, such as Terminal settling a row taller
than its pane: the tabs stay as the overlay showed, and only the panes adapt.
A Tabbed snap drag does not retry; it commits the snap the overlay showed or
fails.
A Bento or Tabbed drag stays on the display where
it started. If a Bento drop is not committed and the dragged window cannot
return to its frame from before the drag, BetterTile reports the failure and
stops automatic writes until Repair, as for a degraded mutation.

## Space boundary

BetterTile operates on eligible on-screen windows exposed by its macOS integration layer. It refreshes the current window set immediately when apps, Spaces, or displays change. A validated native desktop observation selects one process-local runtime layout session for each display and Space pair. Missing or malformed native observations retain the public-API window-overlap matcher. Empty window membership remains unknown, windows reported on several Spaces float, and native fullscreen Spaces expose neither automatic layout writes nor dividers. With separate Spaces per display, a window's center can lie on a display whose current Space does not hold it, for example while the window is dragged across a shared edge. A window whose one Space is current on another display stays visible and is reported on that Space's display; only a window whose Space is current on no display is left out. BetterTile never assigns a window to a hidden Space. An explicit display transfer
uses the destination display's current desktop.

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

Only an answer makes a window fixed-size. A busy or unresponsive application
can fail the question with `cannotComplete`. The snapshot then keeps the
window's previous answer, or counts the window as movable and resizable when
it never answered, and the next snapshot asks again.
`WindowConstraints.settabilitySource` records which case applies. Before,
an unanswered question made the window unmovable for that snapshot: Tabbed
dropped it from its pane as ineligible and adopted it again later as a
fixed-size window, which could float.

## Event ordering

Window identities survive off-screen and incomplete Accessibility sweeps.
After a successful application Accessibility inventory omits a window, cleanup
requires either its exact identity to be absent from the full public WindowServer
list or its cached Accessibility element to report `invalidUIElement`. The latter
confirms closure without an exact WindowServer identity. Other Accessibility read
failures do not confirm closure. Destruction events and application termination
also remove window identities. Confirmed destruction retires that window's
Restore history, write ownership, and placement baseline before gesture or Space
buffering. Cancellation restores only participants that still hold write
ownership. Temporary unreadability, minimization, and off-screen membership do
not retire it.

AX callbacks capture the known window identity and application observer's launch
and installation token on the main run loop. Deferred delivery rejects a closed
identity or replaced observer. Unknown callbacks never create identities; created
and destroyed callbacks can still request a topology refresh. Policy removal and
permission reset clear adapter caches without declaring surviving windows closed.
Those resets already discard identity mappings, so a later snapshot can assign a
new process-local ID; Restore across such a reset is not guaranteed.

Native membership includes retained, nonhidden, nonminimized window identities.
It keeps a temporarily missing pane in its desktop's tree. Confirmed destruction
and minimization still remove the pane, and a window observed on another display
is no longer protected on the old display.

Creation events on managed desktops queue the next main-actor pass without the
120 ms frame-event debounce. A creation callback also hands over its window's
Accessibility element. The adapter keeps it under an opaque token
(`WindowSystemEvent.creationToken`), and the pass reads that one window through
`CreatedWindowReading`: its attributes, its WindowServer record, and its Space
membership from the existing read-only native observation. No new private call
or permission is involved. A floating verdict this early can be wrong, because
a standard window may still be building its subrole and buttons. The adapter
keeps the element and judges again on the next read, and the model reads it
again every 120 ms until the readiness deadline. A utility panel or dialog
therefore costs a few single reads and at most one complete inventory, and never
a write. A window on the current Space joins the last complete inventory, which
any other window event invalidates. One WindowServer on-screen check covers
every window in that list. If a cached window failed it (hidden with Cmd-H,
moved to another Space, or closed without an event), the model takes a complete
inventory instead. The model then places the window from the list and the
stored layout state. With private APIs disabled, the window has no exact ID, the
targeted read answers "unavailable", and the complete inventory path runs. Placement keeps
every existing check: the minimum-size probe, rules, the Space and session
checks of the coordinator, and rollback. Tabbed starts its placement in the same
turn and reuses the focus that the pass read. One complete inventory then
validates the result after the ordinary delay; if it disagrees, the usual
reconciliation corrects the layout.

An element that is valid but not readable yet is read again after 8 ms, within
the original 500 ms readiness deadline, and never through a complete inventory.
An invalid element, a window not on the current Space, a callback without an
element, repeated callbacks for several windows, pending frame events or
recovery, a missing inventory, and the deadline all hand the arrival to the
complete inventory. A repeated callback for one element keeps its token and
adopts the window once. Failed inventories retain the normal exponential
backoff; held applications use recovery instead. Gestures and Space
stabilization still defer discovery. Frame classification reuses its inventory
for arrival reconciliation only when it attempted no mutation. A mutation
attempt requires a new inventory before reconciliation.

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
owner. Those monitors read each event's own location, so a stalled
main actor cannot move a release point.

A press on a BetterTile AppKit window stays with that window through release.
Before either native-window gesture consumer receives the press, the app checks
public AppKit window hit testing at its recorded position. Click-through drawing
is skipped. This prevents a revealed Auto-hide strip from starting a native
window drag or linked resize on the selected window underneath it. Chooser and
application-request observations still receive the shared events.

Layout Wheel keyboard activation uses paired local and global AppKit monitors,
so it works whether BetterTile or another app receives the event. Modifier
monitors follow feature enablement. Key and pointer monitors exist only during
a pending or open gesture. Global monitors remain observation-only. While the
wheel is open, its local monitor consumes recognized wheel-navigation keys so
they do not also activate BetterTile's focused Settings controls; other local
keys pass through. The optional Middle Click trigger has a separate suppressing
session event tap. It exists only while that preference is enabled, receives
only other-button down, drag, and up events, and consumes physical button 2
only with the chosen down-time predicate: unmodified or Option alone. Its
reservation lasts through button-up even when modifiers change. Keyboard holds
block new mouse reservations, and a reserved mouse button blocks keyboard holds
even after its wheel is cancelled. Only mouse-up commits a mouse gesture.
Tap failure disables that runtime path without disabling
keyboard activation. Both tap implementations copy scalar position, button,
modifier, timestamp, and event-kind values only.
Divider-local events, hover, Escape, and title-bar double-click handling keep
their AppKit paths.

Layout Wheel stores a `LayoutWheelStyle` beside its existing Custom assignments.
A missing style decodes as Custom; encoding Custom omits that key. Grouped
keeps eight fixed names and positions, with editable quick-flick commands and
zero through six ordered children per group. Grouped One Level puts the groups
in its only ring. Files from before the editor migrate Grouped to Two Levels,
because their stored level count controlled Custom only. Unknown commands in
Grouped inner slots become Empty without shifting the remaining assignments.
Two Levels adds independent Grouped inner assignments.
Neither style overwrites the other style's assignments. `LayoutWheelFanState` accepts monotonic time
and top-left pointer vectors. It owns rest deadlines, fan attachment, and
selection hysteresis independently of SwiftUI motion. A fan revealed under a
resting pointer keeps the sector's main action until movement exceeds 5 pt from
the reveal point. Directional fans use compass positions and stay
attached through gaps between their options. The controller schedules
one cancellable task for a pending 200 ms rest; it runs no display link.
Grouped resamples the pointer when keyboard modifiers are released, so queued
movement cannot leave a completed flick in the hub. Deliberate keyboard
selection stays selected until pointer movement resumes.
Fan space is reserved when opening, so expansion does not move the wheel.
Reduce Motion removes presentation animation without changing hit geometry.

A Grouped wheel can capture a display without a focused eligible window. Such
a target permits desktop Mode and Choose Layout commands only. Both window and
display targets retain display geometry, desktop session, native Space, and mode
for revalidation before commit. Mode uses the menu bar's model function with the
captured display and optional window. Adaptive entry and Tabbed exit repair that
display without looking up focus again; an empty display needs no window writes.
Choose Layout uses the Layout Gallery's preset intent with tab groups retained.
Neither adds a window-mutation path. Window actions keep their existing
coordinator plans and require the captured eligible window.

Divider and Tabbed tab-drag gestures install local and global AppKit key monitors
until release, cancellation, or overlay hiding. Both forward only the key code.
Escape cancels synchronously on the main actor, including when a managed app
retains keyboard focus. The global monitor only observes the event; the local
monitor consumes Escape and passes other keys through.

Auto-hide bars also observe Escape while revealed. Their local monitors yield
when a Tabbed chooser is key. The chooser's responder chain cancels composition,
clears a focused search, then closes on an empty search. Escape outside text
editing closes the chooser immediately.

All window mutations pass through the main-actor coordinator. Multi-window operations preflight every participant, apply in deterministic order, and roll back already-applied frames when a later Accessibility write fails. A committed layout writes each application on its own thread: shrinking windows first, in every application at once, then growing windows. Within one application the writes keep the coordinator's order. Saved Layout Apply (including Automatic Apply), display transfers and application
recovery explicitly request serial per-write validation when their desktop owner
can change during a batch. They still preflight all participants before the first
write. Ordinary Adaptive and Tabbed commits keep per-application concurrent
batches. Rollback revalidates its desktop owner before each restoration write.
Rollback reads every attempted window before it restores one. Ghost resize transactions do not mutate real windows before commit; live transactions can restore their original baseline on cancellation. A Ghost release whose post-commit correction fails or is cancelled also restores the baseline. AX move/resize events are debounced, while events matching a recent coordinator generation and expected frame are suppressed to prevent feedback loops.

Next Display and Previous Display plan the affected Adaptive layouts before any
window moves. The destination neighbours receive their frames first. The moved
window receives its frame next. Once its origin reaches the requested position,
the source windows close the gap. These passes share one rollback transaction.
A size readback can lag or settle in cell steps, so authoritative settlement
handles size and overlap differences. Both desktop sessions commit together. Settlement retains both owners. Only a
successful commit from those settlement tasks advances an expected revision;
a user action, desktop change or unrelated revision still invalidates the transfer.
If rollback is incomplete, automatic Adaptive writes stop on both desktops.
A Manual source can insert into an Adaptive destination. An Adaptive source also closes
its gap when the destination is Manual. Tabbed transfers keep their existing
path. The Layout Wheel previews the destination placement from the same plan.

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
held then, in the frame read back at release, is a refusal: the release is
solved again once with it, if the result stays inside the display without overlaps and above
every minimum. Otherwise the windows return to their frames from before the
gesture, and the release's Restore step is removed. The correction adds no
Restore step. A new gesture, another write to the windows, or a window whose
frame matches neither its release readback nor its placement, for example
after the user moved or resized it, ends the check. Undo history records the
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
window, and selecting it would take focus away. When `focusedWindow()` cannot
read an application's focused window, such as a small popup, it reports the
application's main window. A focus change therefore selects a tab or corrects
focus only when `TabbedWindowSystem.applicationFocus(of:)` confirms that the
application reports that window as focused. A missing focused window or a
failed read confirms nothing.

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
application, changes keyboard focus or selection, or moves a window. A raise
of a window makes it its application's main window, so the key window can
lose focus. When the key window is a tab, a standard window including one the
user floated, a dialog, or a floating panel such as the Font panel, the repair
raises it again last. Floating windows, such as a dialog BetterTile floated,
keep their place in the order: the repair does not raise them above every pane
just because they are behind a selected tab. The curtain goes directly behind
the backmost selected tab or floating window, and hidden tabs go behind that
window. The repair still raises a floating window of the front application
when a hidden tab is in front of it, when a raised window would cover it, or
when it has focus and is raised again last. A raise of such a window would
take focus, and raising the key window again last would put it back behind
the selected tab. A background application's window often ignores the raise,
so the order would never verify and every focus event would repeat it. Such a
window behind a hidden tab stays under the curtain until its application is
activated. A floating window that is not eligible, such as one that cannot be
moved, has no validated window number; it is raised above the panes as before.
When the anchor window has no validated number, the curtain goes behind the
backmost selected tab. The front application's floating windows also keep the
older raise rule when its key window is transient, so those raises wait as
described below, and when no window has focus, such as on Finder's desktop, so
they run at once. A transient key window cannot get focus back by a raise:
a popup whose subrole is not standard, dialog, or floating, such as a browser
toolbar bubble, closes when it loses focus. A focused window that cannot be
read counts as transient too. The repair then leaves out every window of that
application and every other raise that would cover one of them. The rest of
the repair runs. The curtain is handled as for an unverified order, and the
left-out raises wait for the next focus change. The watchdog retries them, for
each display, in case the popup closed without a notification. When the
application's focus is on no window, such as Finder's desktop, there is no
focus to protect, and the repair raises normally. A Tabbed placement does not activate or order a
window in any pane of an application whose popup has focus. When the selection does not
change, it only orders a selected tab that already has focus. Without
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
  nudge. An axis kept larger than its display's work area is no pending
  clamp: AppKit keeps a window that is larger than its screen rather than
  apply another size that is still too large.
- An axis that took the requested size lowers an older, larger minimum.

Tabbed placement writes accept stepped sizes (`WindowSystem.withSteppedSizes`).
Inside them, an axis that settles up to one step
(`SteppedSizeAcceptance.maximumShortfall`, 24 points) larger than requested
is the application's step, such as Terminal's next row, and proves nothing:
it is neither a minimum nor a pending clamp. A Tabbed size mismatch within one
step teaches nothing either. Other writes, such as Bento's and divider
drags', learn as before.

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
a seed. So far only `remove(_:)`, for a closed window, calls
`forget(windowID:)`. `WindowConstraints.minimumSizeSource` names where a
minimum came from: the default floor, an application hint, a seed, a learned
clamp, or a probe. A hint, a learned clamp, and a probe count as proven.
A seed keeps the window's own minimum and its source in
`unseededMinimumSize` and `unseededMinimumSizeSource`. The write veto and
every place that ignores a seed use that minimum, so a seed that raises one
axis never drops a hint on the other.

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

After reconciliation omits a held application, the app model schedules a fresh
sweep 0.1 s after its hold deadline. One main-actor task covers all held
applications. Each application gets at most three automatic recovery attempts,
with at least 1 s and then 2 s between attempts, and always after the latest
hold expires. Recovery sweeps admit only due applications whose retry budget
remains. Each actual inventory probe consumes one attempt, including probes in
follow-up sweeps during the same recovery pass. A completed sweep that reads
the application clears its retry budget. After exhaustion, the ordinary watchdog remains the fallback. A process
that quits needs no recovery sweep.

Recovery retains no layout proposal. A Space switch cancels the pending wake-up,
and its generation is checked again before recovery. The new desktop's sweep
can schedule its own check. Recovery observes current windows and session state,
so a newer mode change or manual action keeps its result. The normal session
revision check still precedes placement. Recovery also refreshes the native
Space observation and checks its generation immediately before committing a
Adaptive proposal, after minimum-size reads. Recovery minimum-size probes, Adaptive
placements, Focus drops, and measured-clamp corrections validate the Space
generation and session identity/revision after coordinator preflight snapshots,
before mutation dispatch. A delayed recovery settlement keeps that generation
for its correction and any authoritative placement retries. Topology, watchdog,
and direct refresh passes capture recovery's generation before observations
whenever an application hold or unreconciled returning window is pending,
including recovery without a frame callback. A visible-window read that releases
a hold records the returning window identities in the model. An activation read
queues the existing debounced topology pass, even though the hold's timer has
ended. A failed or stale sweep keeps those identities. A successful current
reconciliation retires only the windows it observed on that desktop; a Space
transition alone does not retire them. Tabbed retires them after its placement
commits. Destruction, including process termination, and shutdown discard them.
This evidence contains no frames or placement plan.
Tabbed rechecks its desktop after hidden-tab preflight reads
too. Stale work requests reconciliation.
An incomplete placement rollback or probe restoration remains degraded after a
generation change or cancellation. It reports Repair Layout and suspends automatic
writes on the session that owned the transaction. The store marks that session's
current value suspended without selecting it, replacing its layout or observed
frames, or mutating any window. Feedback identifies Repair Layout on another desktop
when that session is inactive. Only a failed transaction with a complete rollback
can become stale.
Active gestures defer reconciliation through the existing topology-event
buffer. Recovery uses that same buffer, so pending native snaps are handled
before arrivals are reconciled. A recognised snap supersedes an older
settlement only when that display has an observed retained or pending recovery
window. Absent evidence still guards stale dispatch without changing ordinary
settlement ownership. A returning snapped window joins the session before its partition
is applied, so the next sweep preserves that partition. Frame events from held
applications survive normal event acknowledgment until a sweep can read them.
The first sweep that reads them classifies their current frames before arrival
reconciliation, including ordinary topology sweeps and the watchdog. That pass
keeps recovery's Space checks even when the recovery timer did not start it.
Direct application launch, termination, and wake refreshes use that classifier
before probing or placing arrivals. The event pass supplies its results to its
trailing reconciliation, which does not classify the same batch again.
Retaining them schedules no extra sweeps during the hold. Window destruction or
process exit retires their retained evidence. Space stabilization can clear the
ordinary event buffer; the first readable sweep still includes retained recovery
frame identities in snap classification. Hold release alone does not retire an
absent window's event. Known native membership, unknown membership, and the
public fallback use the adapter's existing identity lifetime: confirmed closure,
process exit, or an identity-cache reset ends it. Recovery adds no identity
expiry or size cap. A current event pass consumes observed frame identities only
after successful classification; an attempted mutation is not success. Rejected,
stale, degraded, and deferred results keep each observed identity. An unresolved
Adaptive display defers arrival reconciliation while other displays continue.
Its destruction and minimization evidence also waits for reconciliation.
Confirmed peer removals reduce into a provisional recovery transaction after
settlement ownership is checked. Snaps, divider fitting, and layout restoration
share that reduced tree, which commits only with the frame transaction.
Recovery selects current session bookkeeping before classification can defer a
display. Native observation selects the exact session. If no exact session exists,
a visible overlap anchor can bind the current inferred session to that native
identity, preserving its mode, layout, and suspension. Space stabilization defers
new exact-session creation while an inferred owner has a pending application hold,
reconciliation, or retained frame event. Stable membership then binds an eligible
visible overlap even while the recovery window remains held or off-screen, or
selects a distinct unmatched desktop. Established exact sessions still select
immediately. Retained frame evidence also captures the recovery generation when
a completed adapter read has already released the hold. Public fallback uses the
existing overlap matcher without reusing an unmatched active session. A display
without an overlap anchor keeps its evidence and waits. The operation records only
whether that session matched the public observation. Its preflight and delayed
settlement checks require the same observation capability; a capability change
rejects dispatch. Such a stale result waits for a later existing reconciliation,
while session revision conflicts keep their usual reconciliation request. Consuming
the first-observation marker before classification keeps initialization from
replacing an adopted native snap. No frame or retry plan is retained.
Degraded sessions retain their suspension and Repair Layout feedback. A later existing
reconciliation reads the current frame and tries again; recovery adds no retry
task or retained plan. Only readable retained identities enter targeted event
reads. Absent identities remain retained without adding sweeps to unrelated
callbacks. A stale desktop or generation also keeps them. Transition-only
membership and observed frames do not count as Adaptive tree or floating adoption.
Stabilization queues returning evidence before ordinary arrival reconciliation.
Held frame callbacks retain their exact identity before gesture buffering.
Exact destruction clears both recovery maps before either buffering guard;
identity-cache reset and shutdown clear both maps too.

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

Authoritative settlement for Repair Layout and display reflows accepts up to
2 logical points of difference in each frame component (x, y, width, height).
A direct AX-write reproduction requested a 665.5-point height at the work-area
bottom edge and read back 664 points, a stable 1.5-point shortfall. AppKit screen
constraints or origin rounding may explain this shortfall; neither cause is
established. The tolerance matches minimum-size learning and ordinary Tabbed
frame acceptance.

Before accepting the layout, both the model's scheduling gate and authoritative
settlement check the actual frames with `BentoLayoutVerifier`. Its existing
2-point overlap allowance still applies. Combined component differences that
exceed that allowance report settlement failure. Accepted differences need no
extra settlement pass. Larger component differences retry only the mismatching
windows, at most twice, before reporting failure. The tolerance does not change
planner geometry, stepped-size acceptance, rollback verification, or display
ownership and reachability checks.

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

Hidden applications leave the Accessibility inventory. The macOS adapter
reports `hiddenApplicationWindowIDs` from public application state, matched
to the current application launch. Adaptive removes panes of hidden applications
with the same reinsertion anchors used for minimized panes. Their return restores
the prior positions and ratios even when focus or the new-window side preference
changed.
Floating windows of hidden applications retain their user or overflow disposition.
Focus-covered peers keep Focus's existing exclusion and minimize policy when
their application is hidden in the same pass. Confirmed closure still removes
a pane permanently. Unknown absence keeps its existing corroboration policy.
This adds no AX reads, permissions, or persisted data.

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
- **Tab bar presentation** lives in Settings → Window Layout → Tabbed.
  `TabbedStripPresentation` persists Always visible (the default), Compact,
  or Auto-hide. Missing configuration fields retain Always visible. Their
  reserves are 34, 24, and 6 points. `TabbedLayoutState` carries the reserve in
  its Bento metrics, including empty-pane minimums. Fitting, snap plans,
  previews, stepped-size correction, and settlement use those metrics. A
  setting change re-fits the layout; an unchanged setting writes no frames.
  Compact draws every app icon and only the selected title. Tooltips,
  accessibility labels, and the pane menu retain full titles.
- Auto-hide reserves its 6-point band once. Revealing a 34-point strip changes
  only the panel frame and overlays the selected window. It does not mutate
  an application window. Both states span the pane's full width. The collapsed
  band draws a three-point line with the strip's regular glass at reduced
  opacity. Dark appearance adds a 15-percent neutral tint beneath the glass line.
  The active pane's line is slightly brighter, without accent color.
  Revealed tabs use the Always visible height, titles, and controls. A 160 ms
  clipping animation expands the strip without scaling its content; Reduce
  Motion disables it. Content fades in over the final 60 percent. Lower-pane
  bands start inside their pane, after the gap.
  Local and global pointer-only monitors receive every mouse move and drag
  while Auto-hide is active, not only near a strip. Each sample reads the
  pointer location and acts only inside the six-point hidden band, the full
  revealed strip, or a pane that shows a request status. The controller caches
  pane frames and these areas until the layout state, the bounds, or the request
  pane changes. A sample outside every area returns before per-pane work unless
  a hover must end, and `ignoresMouseEvents` is written only when it changes.
  Passing through the band cancels dwell before the pointer reaches the
  traffic-light controls or menu bar. The monitors stop on hide, Space
  suspension, mode change, and teardown. The seven-point side lanes give
  divider handles and resize corners input priority without insetting the glass.
  Divider gestures suppress pending reveal. `TabbedBarVisibility` receives
  monotonic time and owns the 80 ms dwell, 300 ms leave delay, and drag, menu,
  selection, keyboard, gallery, and application-picker holds. Pointer samples
  are coalesced once per display refresh, so the dwell starts at the first
  display refresh after the pointer enters the band. The controller schedules
  its next deadline and cancels it on hide.
  While a selection hold exists, a 50 ms button-state check releases a lost mouse-up
  before the normal leave delay. Dismissal and teardown clear that tracking.
  Floating fallback panels recheck the latest obscuring frames when their
  chrome changes, including reveal and collapse.
  Escape dismisses revealed bars. Auto-hide removes no curtain cutouts in
  either state, so hidden tabs cannot show through a collapsed band.
- **Show Tab Bar** is an unassigned global action in the Tabs shortcut group
  and an application menu command. It reveals the active pane and makes its
  existing nonactivating panel key, without activating BetterTile. Only this
  command enables that panel's `canBecomeKey`; pointer clicks retain the
  existing focus model. Arrows move a separate focus marker and scroll it
  into view. Return selects that tab; Escape returns to the selected app.
  Both use the existing selection intent and WindowCoordinator focus path.
  Losing key focus releases the keyboard hold. Ending keyboard navigation
  orders a key panel out so AppKit releases focus, then restores its validated
  stacking anchor or floating occlusion policy. It never calls `resignKey()`
  directly. Reveal must pass the occlusion check before the panel becomes key.
  No event tap or alternate Accessibility mutation path is added.
- Only selected tabs count toward minimum sizes. Hidden tabs are placed at
  their pane's window frame, stacked behind the selected tab, as best effort
  (`WindowCoordinator.applyTabbed(required:)`): a hidden tab that refuses the
  size never fails the layout. Only hidden tabs whose frame changes are
  written, in the same frame-write batch, and they return if the layout fails.
- Some applications resize in steps, such as Terminal on whole character
  cells. Such a window settles at its pane's origin up to one step
  (`SteppedSizeAcceptance.maximumShortfall`, 24 points) larger or smaller
  than its pane. The placement accepts that frame once it is stable. A larger
  frame must also hold for the 0.25 s refusal delay, because it can be a size
  applied late.
  - The model remembers each window that settles more than half a point off
    its request, until it closes or its desktop leaves Tabbed, with each
    length it settled at off its request. A length that takes its request,
    or that the window's known minimum explains, is not recorded. The
    lengths give a grid
    (`SteppedGrid`): the step is their greatest common difference when it is
    2 to 24 points. Terminal's heights on one display, for example, are
    4 + 15·k. A larger common difference leaves the step unknown, because
    lengths 60 points apart can be steps of 15, 20, or 30; the known lengths
    are used until another length shows the step. One length can be a
    minimum the window never reported, so it only grows a pane too small for
    it, and the window is asked for it only in an area within 2 points of it;
    a larger area, such as after a small divider drag, is given whole.
    Lengths that share no step
    of 2 points, such as rounded fractional cells, give no grid. A window that
    settles off a length on its own grid, for example after a font change,
    starts its lengths again from the new one and snaps in the same
    placement.
  - Before it writes, a placement moves each divider beside a remembered
    window by at most 24 points, to the closest position where the most such
    windows fill their window areas exactly on their grids
    (`TabbedLayoutState.fittingSteppedGrids`). Hidden tabs count too, so a
    pane keeps its edge whichever tab is selected. Ties go to the smaller
    move, then toward the top or left. Each remembered window is then asked
    for the largest length on its grid that fits its area
    (`requestingSteppedGrids`), so it settles exactly there, and switching
    tabs writes nothing. Without a known step, it is asked for the largest
    known length within one step of its area. With more room than that, it is
    asked for the midpoint of the known lengths around the area; a step is at
    most 24 points, so it settles between them and shows a new length. Example: two Terminals in 2 Rows on a 968-point
    work area have 894 points of window area. 439 + 454 fits with one point
    to spare, so the divider moves 7 points: one Terminal fills its pane and
    the other leaves a one-point gap.
  - A window without a grid snaps instead. One more write fits the panes
    to it (`TabbedLayoutState.snappingToSteppedSizes`). On each axis, one pane
    edge moves so the window area equals the settled size. The neighbour gives
    or takes the points, above its own minimum and across an unlocked divider.
    The far edge moves first; a pane at the display edge moves its near edge.
    The edges of panes that hold a remembered window, or another window that
    settled off its pane in this write, stay in place. When no edge can follow,
    a smaller window keeps its gap, and a larger window is asked for its
    settled size less 25 points, one whole step and a point, but never less
    than a minimum that is not a seed. A window whose area is smaller than
    every length it took is asked for the smallest less 25 points, which
    teaches its step.
  - A window that rounds up toward its area is accepted. A window that still
    keeps its whole size refuses the request: the minimum is learned, and the
    retry fits or floats it as usual. After either write, a selected window
    larger than its window area would overlap its neighbour, so every window
    returns to its frame from before the first write. When that window grew
    within one step and that changed its grid, the retry plans with the new
    grid. A rollback accepts a remembered window that lands within one step
    of its old frame; any other window must land within 2 points.
  - Like a fit, none of this records pane sizes. Each snap writes a debug
    line in the `Tabbed` log category with the window, the axis, the points,
    and the neighbours.
- One Tabbed curtain covers the display's work area.
  It sits below every selected tab and above inactive tabs, including portions
  that extend outside their panes. `TabbedOverlayController` orders this
  normal-level, nonactivating panel below the backmost selected window with
  public `NSWindow.order(_:relativeTo:)`. The model verifies the WindowServer
  order and every tab identity before supplying that anchor. Missing
  identities hide the curtain. Unverified ordering keeps a curtain already
  shown for up to four refreshes, then hides it. It never guesses from a
  frame or parks a window. Native frosted glass conceals inactive window
  detail. Rounded cutouts exclude Always visible and Compact occupied strips,
  including during resizing. The curtain keeps its rectangular input surface; the strips above
  it own tab interaction. Disabling glass, Reduce Transparency, and Increase
  Contrast use an opaque surface.
  A click selects the selected tab in that pane, or activates an empty pane;
  it does not reach an inactive tab. Curtains have no accessibility navigation.
  They hide with the overlay on mode exit, fullscreen, display removal, and
  shutdown. Exact native Space sessions retain their curtains on Space changes;
  display-scoped fallback curtains hide until the new desktop settles.
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
  group when the group has other tabs. A press and release without any drag
  sample is a click and starts no drag. A sample suppressed by the snap
  modifiers still counts. A drop on a pane's center, its tab strip, or an
  empty pane adds the window to that pane as its selected tab, or shows
  invalid feedback when the pane cannot show it (see Window drag drops). A
  torn tab dropped nowhere returns to its group.
  When no selected tab moved, it returns without a placement.
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
  the exact requested region. Stepped-size corrections keep that region too,
  asking for a smaller cell inside it when an edge cannot move. Snap rollback
  verifies the actual checkpoint within the normal frame tolerance on both
  axes; a held size alone does not prove a resize step. Hidden tabs remain best
  effort on success; rollback verifies the prior selections too. Native snaps keep the original
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
  fits there, and the result pill says it does not fit in any pane. It does
  not join as a hidden tab: a hidden tab larger than its pane extends past the
  pane, and while its application is frontmost it can cover other panes. The
  decision log says whether the window fits no pane of this layout, or is a
  fixed-size window or a window with a proven minimum (see
  [Minimum sizes](#minimum-sizes)) larger than the work area below the strip.
- Result pills name a window by its title, so two windows of one application
  are told apart. A window without a title is named by its application. A
  long title is shortened, not the words around it, so the one-line pill
  title still says what happened.
- `TabbedLayoutState.automaticallyFloatingWindowIDs` tells these automatic
  floats from the user's floats. Moving, splitting, adding, floating by hand,
  or closing the window ends an automatic float. The set is part of the
  state, so Undo and rollback keep it. Each new automatic float is checked
  again once, 1 s after its placement settles or fails, with fresh
  snapshots; an Undo that brings floats back does not start that check.
  When a committed placement changes the pane frames or the set of selected
  tabs, for example after applying a preset, a removed or added pane, a divider or
  pane-size change, a new work area, or a smaller tab selected or a large one
  closed, every automatic float that was already floating is checked again.
  The comparison is per session and starts again on each entry to Tabbed. A
  window that a pane can show joins that pane as its selected tab, and the
  boundaries adapt as for an arrival. If that pane shows the focused window,
  the returned window joins it as a hidden tab instead, so a check the user
  did not ask for never hides or unfocuses the focused window; the 1 s check
  and the return on entry to Tabbed follow the same rule. Any other window stays an automatic float. This
  check is silent: a failure is logged and shows no pill. A
  window moved to another display leaves this layout and joins the other
  display's layout as an arrival. Repair Tabbed adopts each automatic float again: it keeps a proven
  minimum, ignores the application's seed for that decision, and probes only
  a window that was never probed. A returned window becomes its pane's
  selected tab, or a hidden tab beside the focused window, as in the checks above. The pill counts the windows returned. User
  floats stay floating. Every Tabbed sweep and placement ignores a seed
  larger than the work area below the strip, so the write shows the
  window's real minimum. A
  hidden tab larger than its pane, for example after its pane shrank, is
  moved back inside the work area, where the curtain covers it. Entry captures
  its frame baseline before placement, but shows strips and the curtain only
  after placement succeeds. A rejected entry restores the previous mode and
  layout, or Native for a desktop that started in Tabbed, and reports failure.
  A degraded outcome still suspends automatic writes. Later sweeps
  do not retry a rejected mode switch. Each adoption, return, and float writes a debug line
  in the `Tabbed` log category with the window's frame, its resizability and
  minimum with their sources, and the result for each pane it tried.
  Entering Tabbed from Bento adopts the tree, so every pane stays where it was.
  Windows that Bento floated on its own, such as a seventh window, become
  automatic floats, and every entry to Tabbed, from Bento or Native, adopts
  the automatic floats again. Leaving for Bento gives Tabbed's automatic floats
  back to Bento as its own.
  Leaving for Bento gives every hidden tab its own pane (`unstacked(in:)`) and
  removes the reserve. Hidden tabs fill empty panes first, largest empty pane
  first, each taking the next hidden tab from the nearest pane. The other
  hidden tabs split their own pane along its longer side. An empty pane left
  over is removed, so Bento shows no empty slot. Leaving for Native restores
  the pre-Tabbed frames and keeps the tab groups for the next Tabbed visit.

## Tabbed panels on native Spaces

An exact native Space session owns its `TabbedOverlayController` and panels.
`BetterTileModel.spacePanelOverlays` retains those controllers. The display map
selects only the current session's controller for input. A background sweep can
observe a new Space before its notification arrives; it detaches and suspends
the outgoing controller without hiding that desktop's retained surfaces. Panels omit
`.moveToActiveSpace` before their first ordering on the owning desktop. AppKit
keeps them on that desktop, so a warmed strip can appear during the Space slide.
No API assigns an application window or panel to another Space. Sessions without
exact native identity keep the display-scoped hide-and-refresh behavior.
Ownership is checked again after focus, stacking, and window-number reads,
immediately before ordering. A changed Space or observation capability defers
presentation until a current refresh.

A Space change cancels interactions, the pane application picker, Layout Gallery,
keyboard holds, and visibility timers. Retained surfaces stay ordered on their
own desktops. Auto-hide bars collapse without ordering a panel. Pointer clicks
never request key focus; the explicit Show Tab Bar command keeps its existing
keyboard behavior. Intents and pane application requests validate their session
and current native Space. Picker dismissal also checks the display and session,
so an inactive overlay cannot cancel another desktop's request.

Confirmed destruction and minimization update retained session membership before
Space stabilization or gesture buffering. Application termination already emits
confirmed destruction for each known window through the Accessibility adapter.
Every retained controller that contains the identity updates its cached tab
content and empty-pane frame without ordering panels, reading foreign windows,
or writing application frames.
A removed selected tab hides the curtain until stacking can be verified on
return. Minimization preserves the entry restoration frame. Destruction removes
it. The normal post-arrival membership stabilization and placement remain the
safety net for unobserved changes and replacement selected tabs. Reconciliation
compares selections with the last successful placement, so immediate lifecycle
bookkeeping cannot bypass replacement fitting.

Ended sessions, removed Spaces, disconnected displays, and leaving Tabbed release
their controllers. Observation loss discards exact panel ownership and rebuilds
display-scoped chrome for the current overlap-matched session. Its historical
Space ID does not confer native presentation ownership. Native observation
recovery replaces fallback panels with an exact controller; panels from the old
ownership are never reused. Callbacks require the current controller as well as
the current session and observation capability. Placement and pane application
requests capture current capability and reject a change during preflight or
completion. Permission loss hides every retained surface; shutdown hides and
releases all controllers.
Stacking and divider coverage exclude panels of inactive sessions too.

Panels use `.transient`, which AppKit documents as hiding in Mission Control.
Exact Space strips, empty panes, and divider controls use AppKit's default
animation behavior; curtains and fallback panels use `.none`.
`.stationary` would keep them visible; `.managed` would include them in the
overview. `.auxiliary` governs Stage Manager and fullscreen, rather than Mission
Control entry, and is not added. The relevant public API contracts are
[transient](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/transient),
[stationary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/stationary),
[managed](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/managed),
[auxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/auxiliary),
and [animation behavior](https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property).
Mission Control entry fades retained strips over about 100 ms, starting as
windows shrink. macOS gives no earlier public signal, so this is a known
limitation. Native fullscreen creates no Tabbed chrome. No new private API, permission, configuration field,
dependency, persistence, or diagnostic log is introduced.

## Overlay appearance

### Pane application picker

Empty panes and populated tab bars expose **Add App**. The overlay emits an
owner-bound callback to the app model. `PaneApplicationPicker` wraps the shared
`ApplicationPicker`; it adds no catalog or persisted setting. The shared
picker lists Recent, Running, and All Apps, and records each choice in the
local Recent list described in [SECURITY.md](../SECURITY.md). A nonactivating
bar's **Show Tab Bar** keyboard path also accepts `+`. Native buttons and
existing-window choices have accessibility labels. One presentation holds
Auto-hide open through application selection, creation, fallback and placement.
The picker closes after an app is chosen. The request then appears in its
pane and keeps Auto-hide open until it ends. Dismissing the picker cancels
only application selection. No synthetic tab enters the layout. The shared
picker's optional window provider expands current-desktop window rows inline;
callers without the provider keep the application-only picker. The pane request
builds its window map once on opening and updates it from normal window and
application events. Row rendering only looks up that map. It reads no model,
Accessibility, running-instance, or Space state.

The app model captures the pane, display, session, Space, work area and Space
generation. A stopped app launches through `NSWorkspace`; a running app asks
`WindowCoordinator.requestNewApplicationWindow` to invoke an actually exposed
public menu operation. Exact **New Window** and recognized complete localized
window titles take priority. Bare ⌘N qualifies only from the File menu (by
position) and only with an allow-listed complete window or generic document
title; otherwise reopen, then **Use a window from this desktop**. The small
localized title table is disclosed in SECURITY.md. Unknown titles use reopen. There is no consent UI, answer store,
or unanswered-question reservation.
The obsolete defaults key is ignored. Several instances use the active or
frontmost instance automatically. Missing menu commands use
`NSWorkspace.openApplication` at the running process's validated bundle URL
to reopen the existing app. Reopen always requests background operation and
makes no preliminary process-activation call. An app can still activate itself
or create no window; the arrival timeout and explicit window fallback remain.
Menu discovery reads only menu attributes on a detached background task. Its
read budget checks the deadline before every AX call and sets that element's
messaging timeout to the lesser of 50 ms and the remaining 500 ms budget.
Traversal reads at most 32 top-level entries and 128 direct items per menu;
child-array IPC payloads add only one overflow sentinel to those limits. No
per-item destination or window inventory validation runs. An already found command survives deadline expiry.
The coordinator's main-actor request path revalidates the destination and process
after discovery and before the bounded AXPress. Re-reading command metadata also
runs in the background, with a fresh budget. Pane destination validation
refreshes native desktop observation with cached windows, without an AX window
inventory. Placement still validates a full snapshot. Tests use fake AX trees
and delayed readers. Unsupported menu operations try reopening automatically. If no window arrives
within the request timeout, the pane offers current-desktop window choices. Launch and menu requests can create no window. They
cannot be undone by frame rollback. See [SECURITY.md](../SECURITY.md) for the
exact operation and retained-data scope.

Before ordinary Tabbed arrival routing, the model reserves new windows of the
chosen app as deliberate floats. They receive no measurement or frame writes.
The request waits up to 10 seconds for a running app, or 30 seconds for a cold
launch, for a new eligible window ID of the requested process on the current
display and desktop. Cold launches show **Still opening…** after 10 seconds.
Request-local creation order (including unresolved creation tokens), then
first-observed order, selects the earliest eligible arrival independently of
window ID spelling or inventory order. A running process also needs exact
creation evidence received after the request: the callback's window ID or a
creation token resolved by the existing targeted read. Request-owned tokens
are also resolved when a full inventory bypasses the optimized event path.
The request keeps creation evidence separate from explicit-choice arrivals and
re-evaluates eligibility until its deadline, including after an early
unconfirmed observation. The automatic-arrival helper itself checks creation
evidence, order membership, PID, bundle ID, baseline, display, desktop,
eligibility and resizability. Restoration and baseline IDs cannot qualify. A new process's first eligible window can qualify without
a callback. Dialogs, sheets, fixed-size and multi-Space windows cannot auto-place.
The request places a qualifying window in the same event pass that first reads
it, before ordinary Tabbed reconciliation can place the previous selections.
It uses the final fitted pane frame and the existing transaction and readback;
it does not run a minimum-size probe or wait for the request's 200 ms poll.
Fake-system coverage verifies one frame write for a window that accepts that
frame. No click-wait state is shown for it. The coordinator brings it forward only while the request's focus intent is
current. Workspace activation observations and a final frontmost-app check
suppress raising after the user changes apps. The coordinator checks the dynamic
predicate after writing frames. Reopen disables workspace activation and makes
no preliminary activation call. One MainActor-owned `ApplicationRequestIntent`
records focus intent across all in-flight pane requests.
Each request registers its targets and expected launch, menu and reopen
activations. A failure clears that operation's expectation. Cancellation
unregisters the request. Successful placement transfers a qualifying focus
helper to the bounded observation window below. An opening timeout also
unregisters it.
An unconfirmed arrival keeps its helper only until the automatic-placement
deadline, even if **Use here** remains available until the separate click
deadline. An expected activation from any live
request does not become another request's user choice.

The main-queue workspace observer delivers each activation to this record once,
before a queued placement continuation. A genuine app activation, a fresh
hit-tested click on any window (including a target), or an activation after newer
keyboard input records the latest user choice. Clicks must fall within the
request lifetime and be no more than one second old. Both the shared event tap
and the AppKit mouse-down fallback forward these choices. Without the tap, the
fallback also forwards left-mouse drag and mouse-up events to a pending request
through monitors of its own, with snapping on or off, so a click on an
unconfirmed arrival can complete. Chooser dismissal still receives only
mouse-down. `WindowHitTesting`,
`ApplicationActivating`, and `ApplicationWindowRequesting` are required by the
app's window-system interface. The coordinator also requires activation and
new-window requests and calls them directly. A missing capability fails to
compile instead of silently disabling click observation, restoration, or the
New Window command. Observation stays
active while any request is pending, including with snapping and linked resizing
off. Cancellation
cannot record a late choice.

Automatic pane placement checks focus when membership commits. If a genuine newer choice still
qualifies, a completed request observes target activation for two seconds after
placement or the request's terminal state, whichever is later. One expiry task
releases that helper; shutdown releases it early. Each target
activation rechecks the latest shared choice and can restore it once. Restoration
requires a requested app in front, a different latest user choice, and an
unchanged public keyboard-event count. That counter reads no keys or text.
Newer input conservatively suppresses restoration, including typing in Source.
The record consumes the choice's one restoration attempt before activation.
A choice keeps the process that made it: the hit-tested window's process or the
activated process. Restoration goes through the coordinator, which sets the
public Accessibility frontmost attribute on that process, as `raiseWindow` does.
BetterTile is not the active app then, so a public `NSRunningApplication`
activation request is only the fallback; macOS can decline it. Without a known
process, only a single running copy qualifies. Its resulting activation is
expected, not another user choice. No other request can restore again for that
choice. There is no activation loop or retry. The `request-focus` unified-log
category records request, phase, choice, activation, placement, restore
decisions and the activation result without titles or app content.

One coordinator frame write is a transaction, not an atomic WindowServer frame
change. The public AX adapter writes size, position, then a final size to correct
application clamping. Its settlement loop reads frames without rewriting them.
An application may animate or change its frame independently. A WindowServer
geometry sample alone cannot identify which AX calls occurred. Opening feedback is published synchronously before the task
performs any AX inventory. A waiting/placing request rejects duplicate choices;
a successfully dispatched command is never followed by reopen. A retry
publishes Opening synchronously even if reconciliation is busy, then dispatches
once after the placement releases the display. A second retry during Opening
cannot queue another dispatch. Add App and Open App queue one picker behind a
busy placement; tab-drag enablement does not disable application selection.
The queued picker revalidates its display, desktop and pane owner. A focus
observation in another pane changes selection without cancelling the captured
request destination.
An unconfirmed arrival or eligible existing window keeps the explicit **Use here**
path. The previous hit-tested click fallback remains for unconfirmed arrivals.
Fallbacks and late arrivals keep their original frames until explicitly chosen.
**Use here** in BetterTile's pane UI chooses placement, not an app switch. Its
transaction raises the chosen window only if the target app is frontmost when
the coordinator finishes its frame writes. A later app choice prevents that
raise. Explicit placement uses the same shared, one-shot focus restoration
boundary at successful completion.

The selected candidate moves through the ordinary fitted `applyTabbedState`
transaction. It fills an empty pane or joins an occupied one as selected.
Membership and one Undo step commit only with successful placement. Failed
placements retain the prior membership. Incomplete rollback suspends the owning
session through the existing degraded path. Preflight and delayed writes retain
the captured request check, including current display and native membership of
the chosen window. A separate floating Undo source retains its original frame
without granting the cross-display exemptions used only for window drags.

Cancellation, a newer manual destination or gesture, pane removal, mode/Space/
work-area changes, permission loss, owner teardown and shutdown discard the
request. Cancelled or expired creation keeps a 30-second guard without a
destination. On Tabbed desktops its late arrivals stay floating; another
creation for that app waits for the guard to expire or the user chooses an
existing window. The pane's explicit **Try Again** action can repeat the request;
The earlier guard remains; only eligible creations of the new request may auto-place. Offering
choices also retains this guard, even after an explicit selection, because the request may still produce another window.
After the guard expires, new unseen arrivals follow ordinary policy.
The 200 ms timer runs only while waiting, placing, or offering the bounded
arrived-window click fallback. Choosing and other fallbacks retain no polling
task. Window and application events update their choices. Pane, session, mode,
Space, work-area, permission and shutdown events invalidate their owner.
A placement completion also resumes an explicit choice queued behind it.
Full inventories run during the bounded arrival wait. Fallback lists use current
window observations and stay live when the user brings the app forward with **Show App**. New windows
of that app stay outside the layout while the request offers choices. No new
background restoration trigger is added.

Tabbed's empty pane card and pane menu open the same native Layout Gallery
panel. Its scope is the whole display. Miniatures use the preset geometry;
hover and keyboard focus draw the candidate panes with the existing placement
wireframes. Previewing and cancelling do not change the session or write window
frames. Apply emits one preset intent through the model and WindowCoordinator.
The Core preset policy keeps tab groups by default. Distribute windows flattens
the panes' tabs in pane order, fills each new pane once, then appends remaining
tabs round-robin. Windows the user floated stay outside the panes; automatic
floats can return through the usual recovery. A successful change
uses the existing Undo Layout Change history. Local split and remove actions
remain separate. A state or work-area change dismisses the gallery.

The pane picker and Layout Gallery share `TabbedChooserPresenter`. It owns an
independent borderless `.nonactivatingPanel` at `.modalPanel`, above normal
curtains and floating pane panels. It has a rounded 12-point overlay container.
It never attaches as a pane's child, so pane refreshes cannot reset its level.
It uses `.transient` and `.ignoresCycle` collection behavior and does not hide
on deactivation. Showing and closing do not activate BetterTile or hand focus
back to an earlier app explicitly. Any inside click makes the panel key without
activating BetterTile, so Escape works after a shape or button click as well as
search-field interaction. Ordering out the nonactivating panel lets AppKit
return keyboard focus to the previous key window.
Its frame is calculated from the anchor control in AppKit screen coordinates,
then clamped to the full pane on each axis where it fits. A smaller pane falls
back to the owning display's visible frame on that axis. AppKit has no popover
placement step that can reposition this final frame.

The app forwards the existing shared left-mouse event stream to both chooser
owners before processing arrival clicks or gestures. Outside mouse-down closes
the panel; inside mouse-down, drag and mouse-up do not. A queued event older
than the presentation is ignored. The existing DragSnap NSEvent left-mouse-down
global fallback supplies other-app left clicks when the shared tap is unavailable.
Global AppKit monitors exclude BetterTile's own events, so the presenter also
installs a temporary local left/right mouse-down monitor while shown. It checks
the event's own screen position synchronously before control dispatch, returns
the event unchanged, and therefore cannot dismiss a chooser opened by that
dispatch. A temporary global right-mouse-down monitor supplies other-app right
clicks. Both use the same frame and opening-time checks and are removed on
dismissal or presenter destruction. Opening a chooser keeps the existing left
observation paths enabled even with snapping off.
Escape is handled by the key panel, including when its search editor has focus.
Choosing an item, owner removal, work-area or display change, Space change and
Tabbed exit close the panel through the owner's existing cancellation paths.
Gallery cancellation clears its wireframe preview without a layout mutation.

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

Popups use regular glass with the Glass transparency setting's 0-to-22-percent
plate, a lit rim, and the 12/8/6-point radius family in `PopupGlass`. The plate
is `max(floor, sliderPlate)`. The shared Light floor is
`PopupGlass.minimumPlateOpacity`; Dark uses `PopupGlass.minimumDarkPlateOpacity`.
Light compiles at 0.20. Dark popups use a 0.35 minimum plate so text stays readable over bright windows.
The popup's effective app appearance selects the floor,
including when BetterTile and macOS use opposite appearances. These floors do
not apply to Tabbed bars or panes outside a request panel. The Appearance caption
explains that popups and the menu bar panel keep a light frost for readable text.
This covers the Tabbed "+" chooser, the Layout Gallery, and a pane while it
shows a request panel. Popup controls live inside the native
`NSGlassEffectView.contentView`, so AppKit can adapt their foreground to the
backdrop. The frost plate and rim stay behind the controls and pass through
input. Popup content has no full-surface background. Text uses semantic label
colours; size and weight carry hierarchy. Opaque search fields resolve the normal
label colour in the popup window's app appearance, rather than its glass's vibrant
appearance. Their placeholders use 0.64 of that label's opacity in Light and 0.54
in Dark: the lowest passing one-percent steps on the semantic field surface.
The opaque fallback moves the same content host above its plate, so controls
remain visible and reachable without replacing their state.

The menu panel's custom mode buttons decline automatic `NSButton` vibrancy,
so their opaque shaded-accent fill stays equal to a primary `OverlayButton`.
Unselected ink keeps the semantic primary label colour. The shared application
picker draws an opaque semantic text-field background inside its search capsule,
so entered text and placeholders remain readable independently of the glass backdrop.
The field, editor and caret use the full normal label colour, resolved to RGB in
the popup window's app appearance so glass does not dim the typed text.
The field declines vibrancy to keep that surface and ink together. Its magnifier
uses primary ink within the native search cell's hit rectangle. Native selection,
clear-button drawing and editing actions are retained. Add Rule uses a secondary
`OverlayButton` for Cancel, retaining
its native Escape equivalent and the panel's search-first Escape routing. The pane
chooser also sends Escape through its text editor first: cancel composition,
clear a non-empty query, then dismiss an empty search. Escape on non-text controls
still dismisses the chooser directly.
The Cancel and native confirm wrappers return their natural widths and a fixed
24-point height from `sizeThatFits`, independently of parent proposals. Call sites
retain `fixedSize()` in `OverlayButtonRow` to measure their full one-line widths.
The row uses `ViewThatFits` to stack actions when horizontal space is limited.
The participation editor's Suggested tag uses an opaque `accentShadeColor`
capsule with white text, following the same contrast palette as primary overlay
buttons. It has no separate hover or press colour variant.

Settings presents Add Rule and Add Floating Window in a transparent,
key-capable child `NSPanel` using `PopupGlassHost`. This replaces only their
opaque system-sheet presentation. A dimmed input blocker and a temporary local
event monitor block the owning Settings window while the picker is open. Other
windows and Browse sheets keep their normal input. The panel follows the parent
frame. Completion, Cancel, Escape, parent closure and Space changes detach it
and remove the blocker and monitor. Ordinary dismissal restores the parent's
previous responder without bringing a hidden parent onscreen. No configuration
migration, placement policy or new permission is involved.

The menu bar panel is a transparent, key-capable, borderless `NSPanel` with
`PopupGlassHost` as its only material. Its glass, plate and hosted text use
BetterTile's app appearance. The panel keeps its 332-point width, uses a
12-point corner radius and the window shadow, and has no popover arrow. A
status-item click toggles it. The status button uses the public push-on/push-off
type, with `state = .on` while the panel is open and `.off` on every dismissal.
A guarded callback reapplies that state after mouse-up tracking. Programmatic
close and context-menu completion also restore the current panel state.
Visible highlighting depends on the native status bar; no custom pill or
pressed image is drawn. Both outside-click monitors exclude the status
button's screen bounds. Global mouse-down routing runs synchronously before
the status button's mouse-up toggle, so a non-key panel closes only once.
The existing outside-click monitors and Escape close it. Escape
passes through while Settings or Setup is the key window. Opening scales the
SwiftUI content from the status item's position on its top edge over 260 ms.
The glass host stays stationary while the window fades, so the material keeps
its appearance. Closing reverses toward that anchor over 180 ms. Reduce Motion
uses only a 120 ms window fade. The window frame and hit regions stay fixed.
Closing disables mouse and keyboard input. It clears the first responder and
the status highlight immediately. Reopening restores the saved responder. A generation
check keeps an interrupted close from hiding a reopened panel. Commands and Settings use
the same close path. A mode change keeps the menu open and key: Tabbed
placement still orders its windows, but defers application focus while the menu
is shown. Successful placements retain their latest focus target, including
window arrivals. When the panel is dismissed, before its fade, the model
focuses that target if it remains a selected tab on the same desktop. macOS
reports a Space switch only when its animation ends, about half a second after
the switch key, so a focus at the end of the fade could activate a window on the
desktop the user is leaving. When native observation is available, BetterTile
drops deferred focus if macOS reports no Space for the window or cannot confirm
its exclusive membership of the captured desktop.
Only status-item toggles and Escape can replay deferred focus while BetterTile
remains active. Commands, Settings, outside clicks, programmatic closes and app
deactivation discard deferred focus. A placement decides the deferral once per
request, and a size retry keeps it. A placement that commits after the dismissal
waits 0.7 seconds for the Space to settle, then checks the desktop, the
dismissal and BetterTile's activity again before it focuses. One dismissal
focuses at most once. A Space change, reopening the panel, another app's
activation and any later user command discard a pending replay or wait. User
commands include shortcuts, menu commands, tab-strip and pane-button choices,
Saved Layouts, opening or committing the Layout Wheel, window and tab drags, and
divider or linked-resize gestures. The panel sits 4 points
below the menu bar, with an 8-point side and bottom inset. It resizes with its
content while keeping its top edge fixed.
Outside the selected mode, menu-panel text uses semantic primary label ink, including captions,
shortcuts and the enabled Settings and Quit buttons. Size and weight carry the
hierarchy. Feedback and permission messages use primary text with a coloured
symbol. Dark cards use the semantic quaternary fill; Light keeps its existing
card fill. Repair Layout retains its stock accent appearance.

The menu mode picker alone uses a drawn 284-by-24-point track with three equal
segments, a semantic fill one step above the card, and radius 6. Native buttons
own focus, mouse and keyboard activation. The glyph canvas is unchanged and
the title gap is 4 points. Unselected ink is the primary label colour. The
selected fill is inset 2 points inside the track with radius 4. It uses
`PopupGlass.accentShadeColor` with white ink; pointer feedback uses the overlay
buttons' black 8-percent hover and 16-percent press. Arrows move focus without
changing the mode; Space or Return selects. The picker is one Tab stop under
Full Keyboard Access. Each segment has a label and selected value. Saved
Layouts retains its native `LayoutModePicker`.

The menu panel uses the same shared floor as every other popup. Debug builds
accept `-BetterTilePopupDarkPlateFloor <value>` from process launch arguments
only, clamped to 0.20 through 0.60. Missing, invalid or non-finite values keep
the compiled Dark floor. Saved defaults are never read, Light is unaffected,
and Release ignores the argument. For example, `-BetterTilePopupDarkPlateFloor
0.40` tests a 40-percent minimum plate on all Dark popups. There is no separate
panel floor or panel-only override. All opaque fallbacks still use alpha one.

The Settings menu editor retains its frosting preview through `GlassBacking`.

The non-Metal Layout Wheel fallback hosts `LayoutWheelGlassView` in its
nonactivating AppKit panel. One native SwiftUI regular-glass annulus covers both rings. The well
is a separate fixed-centre circle. A long centre label extends that same glass
shape with a capsule; both share the well plate and stay fixed at the centre. The raised inner step, edge light, recess
shade and faint separators are drawn decoration. They add depth without
sampling the screen or changing input regions. Native glass never flips its
foreground, and measuring the backdrop would need Screen Recording. So the
wheel follows the popup recipe: untinted regular glass under a
`windowBackgroundColor` plate of 0.20 + 0.20 x strength (0.26 at the 30 percent
default). The ring floor is capped at 0.20. The well has its own plate floor of
0.47, above the cap. The centre well uses a darker plate so Cancel and the
hovered names stay readable over bright windows. Ink is white at 94
percent in Dark and black at 86 percent in Light, with no halo or shadow. The
panel takes the system appearance from the global `AppleInterfaceStyle`
preference, not BetterTile's Settings override. Strength stays at 30 percent
until the wheel surface settings arrive. The global glass switch, Reduce
Transparency and Increase Contrast select opaque shapes. The renderer reads
those options through an injectable provider so tests can drive them.

`LayoutWheelDrawnMetrics` supplies scaled icon frames, optical arrow shifts,
separator segments and lens bounds. Only the hub radius changes, to 32 points
at Medium for both styles. All other hit radii, Core selection, fan dwell,
hysteresis and dispatch stay unchanged. The Settings fan editor keeps these metrics and its stable sector controls.
Its rehearsal preview embeds the liquid renderer described below.

`LayoutWheelCentreLabel` measures the real system fonts before drawing. It
tries the full name in the well on one, two, then three balanced lines at
base size. It next tries one or two compact lines, then the tag, then a
permitted Custom short name. Three compact lines are not used. Every fit
reserves the fixed unavailable mark, regardless of availability. Tag text
also keeps clear of the drawn lens outlines, while its plate clears the icon
boxes. Grouped parents show their name and main action; children show
only their own name. The view draws those exact measured lines. Unavailable
commands keep the same layout with dimmed text and a slash mark. Their full
reason stays in the existing release handler. The centre content reads only
the Core selection and fan state; it owns no dwell or redraw timer. The centre
ink is content of the view carrying the native glass effect, so the container
captures it above the glass. `LayoutWheelLabelPresentation` caches first-ring
ink boxes and the joined outline when semantic input changes. Display-link
frames reuse that immutable preparation. When a
name uses the tag, the existing cosmetic spring eases ring lean to zero so
icons keep clear of the fixed tag. Other names restore the shared lean amount
in `LayoutWheelDrawnMetrics.leanDistance`.

`LayoutWheelGlassRenderer` drives the existing cosmetic springs with a public
AppKit display link only while they move. It stops at rest and removes the
hosting tree when closed. Terminal presentation freezes semantic input.
Commit applies one parent opacity after glass, ink and decoration compose.
Cancel replaces native glass with opaque shapes before shrinking the whole
presentation. Reduce Motion snaps presentation channels and exits immediately.
The renderer owns no command callback, window observation or mutation path.

`LayoutWheelController` selects the liquid presenter at launch through
`LayoutWheelPresenting`. Only the Metal pipeline prepares at launch and on
configuration changes while closed. Icons, names, the atlas and hidden panel
prepare when the trigger hold starts, within the existing 220 ms hold. An open
wheel refreshes changed drawing content and appearance in place. Every cancelled hold releases its drawables. Opening uses the
captured pointer and the content's full fan extent when clamping to the display.
Missing Metal or shaders, allocation failure during preparation, and open failure
log a fallback to `LayoutWheelPanelPresenter`. A late fallback resets placement
to the panel's geometry before input resumes. Placement previews still use
`PlacementWireframeController`; neither renderer mutates windows.

`LayoutWheelFanState` owns one configured selection state, command resolution,
rest deadline, keyboard navigation and terminal reset. Liquid pointer geometry
uses a locked sub-menu: after a 200 ms rest, a group opens as a tight fan or as a
cluster grown from its chevron (`LayoutWheelSubmenuLayout`). The group stays open
inside its sector plus 10 degrees. An aimed child changes only when another is
within reach and 6 points nearer. The default keeps the aim beyond the rim; the
bounded policy includes every edited child's angular extent and rearms only on
return to the ring. One Level uses the configured inner group ring. Two Levels
uses independent grouped inner slots. The fallback retains its original fan
attachment geometry in the same state type; it shares rest/open, sector
stickiness, command, keyboard and reset logic. `LayoutWheelSubmenuState` is only
an SPI compatibility alias for the prototype harness.

`LayoutWheelLiquid` in Core is deterministic presentation, driven by supplied
time: closed-form springs, an outline stored as 32 Fourier harmonics with a
capillary-wave spectrum, area-preserving bulge and pointer-stretch targets, fan
droplets with attach/detach hysteresis, and separate open, commit and cancel
motions. Reduce Motion keeps the outline circular and uses short fades.
Reduce Transparency, Increase Contrast and the global glass switch's off state
use opaque body/well fills without blur, including changes during a gesture.
`isAtRest` is a fixed point, so the clock can stop. The model never selects.
Fan necks, attachment impulses and the shader's smooth union use
`LayoutWheelLiquidDroplet.openingConnectionWindow`: full for 220 ms, easing to
zero by 500 ms. Settled bubbles add no rim
pull or bridge. The aimed slice keeps its independent bulge. These presentation
channels never change hit geometry.
`LayoutWheelLiquidContent` reads the panel's semantic slot resolver for command,
icon and availability parity, including edited groups and current desktop mode.
The controller and adapter cache content independently of pointer samples.

`LayoutWheelLiquidDefaults` maps the saved liquid appearance, tuning and
sub-menu settings into the presenter and content. Prewarm keeps effective dark
appearance and Names in its cache key. Tuning-only changes can reuse the atlas;
a Light/Dark or system-theme change prepares matching ink before the next open.
The global glass switch still selects the opaque fallback.
`LayoutWheelLiquidPreview` embeds the same renderer in Settings without showing
a panel or accepting a window-mutation callback.
The overlay gesture and the Settings preview are one path. Both write the saved
configuration into the renderer with `LayoutWheelLiquidDefaults.apply`, build
content and state with `LayoutWheelLiquidScene`, and aim submenus with
`LayoutWheelLiquidDefaults.updateFan`. Content is built once and cached; state is
built for every pointer sample, so a sample stays cheap. Offscreen parity tests
drive both paths as the app drives them (the real controller and adapter against the
preview hosted by SwiftUI), draw them in the same states and compare the pixels,
the content and the state.

When the liquid renderer fails, the panel fallback serves that gesture only. A
failed preparation or open does not stay with the session: the start of every
later gesture, whether a keyboard hold or a mouse button, tries the liquid
renderer again, and a hold that ends before the wheel opens takes its fallback
with it. One failure is different. When the Metal device or the shader library is
missing at launch, the pipeline marks itself failed for the process, and the panel
wheel serves the whole session. Neither the device nor the library can change
while the app runs, and a retry would cost a failed pipeline build on every hold.

What still differs is real:

- The window and its backdrop. The overlay blurs the live desktop in a click-through panel,
  and its blur takes the wheel's Appearance. The preview sits in the Settings window over an
  illustrated desktop, and its blur material takes the Settings window's appearance.
- The target's availability. The overlay dims commands that cannot run, such as every window
  action when no eligible window is focused. The preview draws every command available.
- Choose Layout on a desktop that is not Tabbed. The overlay keeps that group's submenu closed,
  because it passes the target's availability to `updateFan`; the preview always opens it.
- The real pointer and placement, and the preview's scaling to fit its area.

A group without a quick flick takes the Action tint colour of the first command assigned to it, so
reordering an edited group's children can change its highlight.
The liquid Grouped wheel uses
the Custom radii plus 10 pt of chevron room. `LayoutWheelLiquidPresenter` draws it in a
click-through panel. At the back, one system blur view is masked by the drawn
outline and droplets; the 128-point mask sits 1 pt inside the edge, is
rebuilt only when a point moves by more than 0.4 pt, and shrinks instead of
turning translucent while the wheel fades. Where the shape passes the mask,
the shader adds the blur material's tone. One Metal pass draws the body and,
from a packed icon texture, every icon, so icons and liquid move on the same
frame; only the centre name is a layer. A sprite mask tints aimed main icons,
chevrons and bubble icons in the shader, with a 120 ms model-time cross-fade.
Aim changes never rebuild or upload the atlas. Other main icons dim to 50%
while a sub-menu is open. Mist and Clear keep black ink in Light; Ice and Ember
still tint. All styles tint in Dark (white over white is visually unchanged
for Mist and Clear). `CAMetalDisplayLink` supplies ready
drawables on the main run loop. It replaces drawable acquisition in the
main-thread frame path. Model advance, encoding, the blur mask and the centre
label use the same callback. The Metal layer presents with that Core Animation
transaction after its command buffer is scheduled. Opening requests the first
callback; it does not draw synchronously. The blur and centre label stay hidden
until a body frame is accepted. Time inside `open` therefore does not measure
open-to-first-visible-frame latency. Measure that interval from the open request
to visible content in a timestamped compositor frame, separately from the time
waiting for command-buffer scheduling. The encoder skips a frame
instead of waiting if all three data buffers are in flight. SwiftUI icon
renders are copied into owned bitmap pixels before caching, so cached images
do not retain the render backend. One icon renderer is reused within each
atlas preparation and released when preparation finishes. The icon and text
caches each retain at most 512 KiB of bitmap pixels and 128 images. They evict
the least recently used image. One packed atlas is retained. The shader is precompiled into the
package's `default.metallib`, the pipeline is built once, and
`prepareToOpen` does the remaining setup during the trigger's hold. Its first
GPU submission warms both pipelines into a one-pixel target without acquiring
a drawable. The display link runs only while the model moves. Stopping invalidates it, clears
its callback and rejects callbacks from an earlier run. Closing releases the
link and shrinks the drawables to one pixel. Each frame and each mask rebuild
is an `os_signpost` interval (category `LiquidWheel`). Tuning, time scale and
frame observers
are `@_spi(LiquidWheelPrototype)` for the local prototype harness only.

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
the Layout Wheel, the menu bar panel, and result feedback. Snap and Bento
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

Pane gap changes publish to Settings immediately. Window placement consumes the
latest value once per 75 ms interval, with one final pass when the slider is
released. Pending changes share one task and retain the previous runtime gap
until that pass. Window drags, divider drags, linked resizing, Space
stabilization, and pending layout placements defer the pass. It reflows only
active Adaptive displays through their normal constraint, coordinator,
and rollback paths. Reconciliation changes the session metrics; changing them
before reconciliation would hide the geometry change from Adaptive. A failed
inventory or placement retains the request until the active Adaptive sessions
commit the new gap. Later refreshes, including watchdog inventories, retry it
without starting a 75 ms inventory polling loop. Tabbed keeps its own preset
spacing and strip reserve. Shutdown cancels the timer and clears the pending
request.

Settings use a versioned Codable envelope. Version-1 display-keyed Bento states are discarded during migration because their Accessibility IDs cannot survive relaunch; all other supported preferences migrate. Runtime display sessions are not persisted. Writes use Foundation's atomic file replacement.

Schema 12 configurations gain a nested `layoutWheel.appearance` value with
`surfacePreset`, `surfaceStrengths`, and `size`. This additive change needs no
schema bump: missing fields migrate by presence. Reset Layout Wheel restores the complete wheel configuration. Appearance-only
reset is described below; it preserves the legacy compatibility snapshot.
`groupOverrides` and `groupedInnerSlots` sit beside appearance. Missing group
overrides use the fixed Core definitions. Explicit Empty children stay in order;
an unknown child command is dropped individually on decode. Normalization caps
each group at six children and removes legacy Custom Zone commands. Fan geometry,
selection, rendering, and Settings all read the same resolved group contents.

`appearance.liquid` adds Style (Ice, Ember, Mist, Clear), independent
System/Light/Dark appearance, Look, Motion, Feel and Sub-menus without changing
schema 12. The stable style IDs are `ice`, `warm`, `frosted` (Mist) and `mono` (Clear).
Styles are defined by their highlights: blue, warm gold, soft white, and colorless
glass brightening. Mist supplies white to the shared tinted Gaussian cloud;
pale clouds use extra coverage and a neutral Light shade to stay visible on
white. Clear adds a faint neutral contour only when the shader's effective dark
flag is false; Dark retains its screen brighten. The contour also stays in the
opaque Light fallback. Ice, Mist and Clear share the standard non-highlight baseline;
Ember retains its bouncier feel.

The additive `liquid.styleRevision` is 2; the configuration schema remains 12.
A missing marker, an integer below 2, or a wrong marker type resets the selected
style's tuning once. Revisions **2 and higher** retain edits, including files
from a future build. This applies to all four presets, including Ice and Ember.
The reset restores these fields to the selected preset's defaults:

- Look: `highlightColour`, `names`, `actionTint`, and the retired `material`
  compatibility field (automatic). Glow policy is derived from the highlight;
  there is no separate saved glow field.
- Translucency: `light` and `dark`.
- Motion: `opening`, `closing`, `pointerLean`, and `leanAmount`.
- Feel: `tension`, `ringing`, `bulge`, `stretch`, `splash`, `magnetDamping`, and
  `dropletResponse`.
- Sub-menus: `arrangement` and `keepOpen`.

The selected preset, Appearance, Size, assignments, triggers, legacy
`surfacePreset`, and all three `surfaceStrengths` remain unchanged. Current
saves write revision 2, so later edits survive reload. A pre-marker build saving
again can cause one more reset; the next current save is stable.

A style-revision bump is an explicit tuning-reset migration, not a configuration
schema bump. The next preset-baseline change must deliberately advance both the
written marker and the reset threshold together (for example, to 3), state which
older tuning resets, and test the reset and subsequent edit/save cycle. Do not
reset merely because a file has a higher revision than this build understands.

The retired Material field remains decodable and encoded, is excluded from
Modified, and is ignored by presentation. A reset writes its automatic default.
Blur follows Appearance. Its approved opacity curve is unchanged through
translucency 0.85, then ramps to no blur at 1.0.
Missing liquid settings start fresh on the complete Ice baseline. Legacy Liquid
Glass maps to System, Light to Light and Dark to Dark. Old strengths do not seed
translucency or physics. Missing nested objects and fields use the selected
style's baseline. Unknown enum strings use their documented default. A malformed
liquid object falls back to Ice while preserving the legacy appearance snapshot.
The legacy appearance fields keep their strict type checks.

Core stores physical Feel values. Values clamp to their physical ranges on
mutation and decode; NaN uses the selected style's baseline and infinities clamp
to the range ends. Numeric normalization rounds to nine decimal places so a
slider round trip cannot mark an untouched preset Modified. Modified compares
all active extra settings with the complete selected preset; it excludes
Appearance, Size and the retired Material field. Selecting a Style or Reset to style defaults replaces every extra
setting while preserving Appearance, Size, assignments and triggers. Reset
appearance restores Ice, System and Medium only.

An explicit Appearance choice also writes the legacy `surfacePreset`: System
maps to Liquid Glass, Light to Light and Dark to Dark. Reset appearance selects
System for both renderers. All three `surfaceStrengths` remain unchanged. This
keeps the panel fallback aligned with the chosen Appearance.
Size edits still use `appearance.size`. A file without `liquid`, such as one
saved by an older build, starts on Ice and maps Appearance from the retained
legacy preset. Tests decode the legacy projection with frozen pre-change
decoders; they check the projection, not that an older build loads the file.

The App presents Fine-Tuning as a native sheet with Look, Motion, Feel and
Sub-menus tabs. Only the App maps the inverse Wobble length, Snap bounce and
Sub-menu speed sliders. `LayoutWheelLiquidDefaults` maps every saved setting to
the product renderer and embedded preview. System translucency follows the
same system-dark preference as the presenter. Ice blue is a shared fixed color;
only System accent uses the system accent. Highlight raw value `none` uses
an achromatic screen blend that preserves glass alpha. The approved selection cloud has a flat angular plateau with soft edges across
the slice dividers and a long inward fade whose peak is at the outer rim. It
slightly lights the glass beneath the accent. Travel still widens and reduces
its intensity. Clear retains its neutral contour in Light.

The preview replays on style changes and Play. Ordinary edits update the look
and semantic content in place. Feel changes apply on Play or the next open;
the sheet says "Play to feel the change." Size changes reopen with Reduce Motion
for a settled resize. Preparation and late-open failures both install the panel
fallback and switch pointer selection to its matching metrics. Neither preview
can dispatch a window action. Closing Settings stops the embedded renderer.

Style pictures use the existing Metal shader, icon images and sprite layout on
an owned offscreen texture. Settings caches at most eight images, keyed by style
and theme, and clears them on size changes or window close. No panel, display
link, retained drawable pool or DEBUG-only API is used. If rendering fails, the
approximation remains, with the same style description. Legacy Strength is encoded for compatibility but
is not read by either wheel; the panel fallback uses 0.30.

The surface is independent of the content style, Settings appearance, and shared
`OverlayAppearance`. Liquid Glass defaults to strength 0.30; Light and Dark each
default to 0.55. Switching presets retains all three strengths. Construction,
decoding, and writes clamp finite strengths to 0...1 and round to 5-percent
steps, with midpoint ties rounding up. Nonfinite values and missing strengths
use the preset's default. Unknown surface names select Liquid Glass; unknown
size names select Medium. Unknown names and strength keys are dropped on the
next save. Older builds are not guaranteed to load a file saved by this
build. For example, older decoders reject a Custom slot assigned a Mode or
Choose Layout command. The legacy fields that remain encoded serve the panel
fallback; they are not a downgrade guarantee. Invalid JSON types still fail
loading, so the existing save protection applies.

`LayoutWheelSize` stores Small, Medium, or Large, with scales 0.8, 1.0, and 1.2.
A missing appearance uses default surfaces and strengths. A missing size
migrates from the nearest legacy scale, with midpoint ties going to the larger
size. The compatibility `scale` remains encoded at its original value so the
panel fallback and its Settings preview do not change on migration. The liquid
wheel draws, places and hit-tests at the selected size's exact scale. It backs
`appearance.size` in memory, keeping both values consistent without two stored
sizes. An explicit conflicting size wins on decode. A legacy scale that maps
to a known explicit size is retained, including on later saves. An unknown size
always selects Medium's exact scale.

New Settings UI must write `layoutWheel.appearance.size`, never a continuous
scale. A size write sets the compatibility scale to the preset's exact value.
When the panel fallback also reads the size, remove the compatibility property, its continuous
backing value, and its 0.8...1.3 normalization; store size directly and retain
legacy scale decoding for older files. If an old-renderer compatibility key is
still needed on save, encode `size.scale` for that key.

The liquid renderer reads `layoutWheel.appearance.size.scale` and
`layoutWheel.appearance.liquid`. The panel fallback reads the compatibility scale and the selected preset's
strength. Light and Dark select fixed ink and plate appearances; Liquid Glass
follows the system appearance in the runtime panel. Its injectable
system display options continue to select opaque fallbacks for Reduce
Transparency and Increase Contrast, as does the shared glass-off switch.
These overrides never rewrite the saved preset or strengths.

`layoutWheel.triggers` groups keyboard enablement, keyboard kind, ordinary
modifier chord, and the mutually exclusive mouse choice. Missing nested triggers
migrate the old fields. An unknown keyboard kind disables keyboard activation.
Ordinary chords still require at least two modifiers.
Right Control is a distinct kind, never a single-modifier chord. Encoding keeps
valid legacy fields: Right Control projects to keyboard disabled, and Option +
Middle click projects to mouse disabled. An older build that loads the file
therefore cannot reserve a broader gesture. Reset triggers assigns one default value. The macOS controller
retains a scalar input snapshot with virtual key code, aggregate modifiers and raw
side bits. Right Control has a distinct session trigger. It requires a fresh right
key-down, the right-side bit, no left Control or other ordinary modifier, and a
matching current snapshot at the hold deadline. Ambiguous identity or a missed
release cancels. It remains hidden in Settings until real keyboard and Jump
validation. All keyboard monitoring restarts require a neutral state before a
new hold when current state is available. A left or right mouse-down cancels a
pending or open Right Control hold through observation-only AppKit monitors. A disabled idle middle-click tap is re-enabled;
continuity loss during a reserved gesture ends its reservation and discards
callbacks from the retired generation.

Layout Wheel Settings uses expanded editing geometry with one fan by default,
an All fans switch, and a command inspector beside the wheel. The inspector can
assign Empty, reorder, add, remove, and reset children without dispatching a
command. A separate preview view uses the current renderer and Core fan policy.
It owns temporary selection and dwell state and has no window-mutation callback.
Appearance resets assign defaults directly, including a migrated legacy size;
they do not depend on equality with a legacy continuous scale.

## Saved Layouts

`SavedLayoutDocument` in Core describes one desktop on one display. Its
versioned JSON stores app bundle IDs, slot IDs, relative rectangles, split
ratios, Tabbed membership and selection, and deliberate floats. It stores no
window titles, document paths, runtime window IDs, or native desktop identity.
It is separate from application configuration and does not change its schema.

`SavedLayoutValidator` serves both canvas editor changes and file imports.
It reports plain-English errors with JSON paths. `SavedLayoutDraft` retains the
submitted bytes and replaces its last-known-good document only after successful
validation. Unsupported versions are rejected before the body is decoded.
These types perform no disk I/O and cannot overwrite an invalid source file.

`SavedLayoutCapture` converts runtime input into a document. The planner assigns
eligible open windows using ordered app and App Group preferences, then fills
free panes and handles extras according to the mode. It returns a plan without
mutating windows. The app layer owns the local files, editor and group store.
Only Apply and Undo mutate windows through the coordinator. Capture and Update
read the current desktop. See [SAVED_LAYOUTS.md](SAVED_LAYOUTS.md) for the
format and assignment policy.

### Display sets and display triggers

A display trigger binds a Saved Layout file to one display in an exact display
set.

- **Core.** `DisplayFingerprint` (UUID, vendor, model, serial, built-in flag,
  name, frame) and `DisplaySetMatcher` are pure. The matcher returns `.exact`,
  `.uncertain` (serial-less same-model displays paired by left-to-right order), or
  `.none`, plus the stored-to-live index pairs. `DisplayTriggerDocument`
  encodes and decodes `Display Triggers.json`, checks bounds, and keeps unknown
  keys. It does no disk I/O.
- **MacOS.** `DisplayFingerprintReader` reads identity from public CoreGraphics
  and AppKit calls (`CGDisplayCreateUUIDFromDisplayID`, vendor, model, serial,
  built-in, mirror state, bounds, `NSScreen.localizedName`). It skips a display
  that mirrors another. It never touches a window.
- **App.** `DisplayTriggerStore` owns the file next to the Saved Layouts folder:
  a bounded read, a coordinated atomic write, and a byte comparison against the
  last read before every write. An unreadable file is reported and kept, and
  saving stays blocked. `DisplayTriggerCard` in Saved Layouts settings binds the
  open layout, stores the two switches, and starts Apply on the target display
  through the page's `SavedLayoutApplySession`. It reuses the Saved Layouts Apply
  path unchanged.

The card refreshes on `NSApplication.didChangeScreenParametersNotification`.
`BetterTileModel.displayTriggerStore` is the one store that Settings and the
automatic Apply share. The Saved Layouts page reads the file again each time it
appears.

### Automatic Apply

- **Core.** `DisplayTriggerReducer` is pure: events (`displaysChanged`, `wake`,
  `locked`, `unlocked`, `lockExpired`, `settled`, `interactionEnded`, `userInput`,
  `applyFinished`) in, actions (`settle`, `apply`, `cancel`, `suspendApply`) out.
  A lock cancels a started Apply while keeping an unused pending attempt for
  fresh settling after unlock. It remembers the last known display set
  (the sorted UUIDs), so the same set again starts no wait, a repeated change
  restarts one wait, and an attempt is used up when it is handed out. Only
  exact matches of enabled bindings become fires; uncertain matches become
  offers. `DisplaySettleDetector` is the pure quiet-window check.
- **App.** `DisplayTriggerRuntime` owns the waiting. The model calls it after the
  existing `DisplayRefreshDebouncer` and from the wake notifications. There is
  no repeating timer or poll outside pending work. During settling it reads
  window frames every 150 ms; an interaction hold checks again every 250 ms.
  While a wait or an Apply is pending (and only then) it
  holds a temporary AppKit mouse-down and key-down monitor that reads the event
  kind and nothing else. It calls the applier, so every window write still goes through
  `WindowCoordinator` and the same transaction and Undo as a manual Apply. The
  applier keeps one Undo step for each display. The runtime tracks this user's
  session activity separately from the lock wait, so another session's app
  activation or an expired wait cannot release an inactive session. Session
  availability travels with an automatic transaction through forward-write and
  recovery validation. A hold cancels the owned Apply task and applier operation;
  the completed result remains available without a pill while the session is held.
  The applier retains at most one deferred changed result per display. Session
  return, lock release and Apply completion can drain it once the session is
  available, including when return precedes the runtime's completion callback.
  Repeated notifications do not replay it. No changed frames means no deferred
  pill; stopping clears deferred results. Incomplete recovery retains Repair
  Layout guidance, and Undo is offered only while that run's checkpoint is valid.
- **Pills.** An automatic Apply shows one `ResultPillController` for each display.
  The runtime keeps the newest result for each layout file for the Last run row.
  An automatic Apply with nothing to place shows no pill.


`SavedLayoutPositions` owns optional `Saved Layout Positions.cache` in the library
folder. Its non-JSON extension keeps the library listing from showing this cache.
It contains only normalized post-commit frames keyed by file name and slot ID;
The cache is separate from layout files and configuration schema 12. Reads are bounded to 256 KiB and validate
version, paths, slots and geometry. Missing or invalid hints fall back to saved
rectangles without blocking Apply. Coordinated writes prune missing files and
evict older library entries to remain within 256 layouts and the byte bound.
Delete removes an entry; Update retains only unchanged slot-ID/app pairs. Export does not copy the cache. File-owned candidate contexts prevent a delayed choice from writing
another file's hints. The run's Undo checkpoint retains previous hints in memory;
a successful Undo restores them only if its recorded hints are still current.
Neither rollback nor failed Undo records a frame as successfully placed.

Saved Layouts preview inventory revisions follow window creation, destruction,
minimization, restoration and focus, application topology changes, and completed
desktop stabilization and display reconfiguration. Reconciliation compares each
eligible window's display and cached Space membership. Move/resize bursts that
only change frames on the same display and desktop do not invalidate the preview.
A changed display or desktop does invalidate it. The page coalesces inventory
bursts; Apply always reads a fresh inventory.

### Saved Layouts Apply and Undo

Apply plans against eligible open windows on the target display's current
desktop. A user-started Apply may reuse an unreserved preference-matching window
from another visible display when it is outside that display's Adaptive and
Tabbed panes. Automatic Apply stays on the target display. Apply does not open
apps or request windows. The coordinator revalidates participants and owns window
mutations. Escape cancels through the final input checkpoint, including input
queued during frame writes. Once final validation and session commit begin,
a later Escape does not cancel that Apply. Synchronous AX batches can occupy
the main actor, so Apply waits for an AppKit input turn before final validation
and session commit. At the next before-waiting phase, a one-shot main-run-loop
observer dispatches pending application events in queue order through AppKit's
normal monitors and responders. The batch is capped at 256 events; a one-second
injected-clock deadline bounds the wait. Other queued commands can also run;
final validation checks coordinator mutation generations as well as the desktop
owner before committing the proposed session.
Cancellation or a failed input checkpoint restores the baseline through the
existing owner-guarded recovery path. Changed ownership still stops restoration.
The key monitors are installed before App Group loading and inventory, and stay
installed through this checkpoint. Undo restores the previous session and frames
when safe. A followed
layout keeps its pane preferences in the runtime session and gives matching new
windows priority for empty panes. Following is not persisted.

### Saved Layouts outside Settings

`SavedLayoutActionStore` owns optional, bounded `Layout Actions.json` beside the
display triggers, keyed by library filename. `SavedLayoutActions` uses public
Dispatch directory sources and one recursive FSEvents stream while its runtime
catalog is active, including with Settings closed. The watch set contains at most
two directory sources and one stream, independent of library size. Individual
layout files hold no watch descriptors. The stream covers in-place JSON edits,
including files whose modification dates are preserved; directory roots cover
renames, additions, removals and folder recreation. While the configured parent
is missing, only the surviving directory roots are watched. Creating an
intermediate parent reattaches observation closer to the library. The stream
starts at current events and filters unrelated sibling paths. Dropped events or
root changes force a coalesced rescan and stream reattachment.
File events reset a 150 ms trailing wait on the injected clock. Changed files
that do not decode are retried every 50 ms, up to 500 ms after the last event,
before publishing the catalog. A continuous event stream forces a check within
one second of its first event, including incomplete writes; the next event then
starts a new burst. Stop clears that burst deadline. An idle catalog has no
queued wait. Duplicate notifications with unchanged metadata do not decode the
library again. File identity and change timestamps detect replacements and
same-size in-place edits even when modification dates are kept. Attribute-only
changes can also trigger a decode. An ancestor event
only scans the library if the library, parent or actions-file identity changed.
A failed event stream leaves directory additions/removals observed and reports
partial coverage. Reload retries the stream or a failed directory watch. No
periodic timer or fallback poll runs. Stop, shutdown, destruction and root
replacement release the corresponding sources, descriptors and stream context.
A missing library folder keeps its local action settings until a readable
directory confirms removed files.

The model validates shortcut conflicts against all window actions, the wheel
trigger and other layouts before either Settings page can commit a conflicting
edit. The one Carbon monitor uses named IDs after the
fixed window-action IDs; retired named IDs are not reused. Failed registrations
are reported, and externally introduced conflicts disable both actions.

Panel, wheel and shortcut dispatch resolve the file again and call the existing
`SavedLayoutApplier.start` with an explicit display. The model's action resolver
can require session provenance: only managed focus observation and explicit
BetterTile actions record it through `rememberUserActionDisplay`. Reconciliation
and initialization never grant it; disconnect clears it. Settings uses its
existing picker rule. Its Apply session can adopt an outside run and retain Undo. All new target reads happen on events or clicks.

The wheel's catalog is transient `LayoutWheelConfiguration` state excluded from
encoding. It changes Choose Layout's child contents, retaining eight groups and
the existing geometry/renderer/shaders. Category hover changes navigation state;
category release commits nothing. More release opens a native chooser through a
separate navigation callback. Hover checks cached library data and captured target/session provenance, without
an Accessibility read; release resolves focus again and enters the existing applier.

## Security

Only Accessibility permission is required. BetterTile does not inject code or disable SIP. Public Apple APIs are preferred; any private API integration requires the design review, approval, fallback, testing, and disclosure defined in [SECURITY.md](../SECURITY.md).
