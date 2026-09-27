# Tabbed testing findings

Last updated: 2026-09-10 (America/Phoenix).

This is the running record for the experimental Tabbed implementation. Update
the relevant entry after each test or fix. Record the build, steps, expected
result, actual result, and evidence. An attempted action is not a passed test.
Use [TABBED_TESTING.md](TABBED_TESTING.md) for the full manual procedure.

## Current assessment

The implementation passes automated tests and builds. Divider, linked, and
Tabbed resize paths now coalesce input at display cadence and move the actual
windows during the gesture. Live smoothness is still unproven for the required
two-pane, four-window scenario and on a high-refresh display. No decision has
been made to accept stacking as reliable or replace it with another strategy.

Work is on `feat/tabbed-test-layout`, based on commit `873e004`.

The user authorized computer use again on September 9. The signed GUI build
passed limited live activation, cross-pane dragging, divider resizing, and
frame-restoration checks. Other tab actions produced rejection feedback or no
confirmed change. T-07 records the results and limits. The two-tabs-per-pane
scenario and reliable keyboard focus remain unverified.

## Intended behavior

- Each desktop independently uses Native, Bento, or Tabbed.
- Tabbed panes remain visible when empty. Each pane has ordered tabs and one
  selected window.
- Initial activation uses the chosen default layout. Existing windows join the
  first pane, with the previously focused eligible window selected.
- New windows join the last-used pane and become selected.
- Adding panes preserves groups and adds empty panes. Removing panes merges
  removed groups into the nearest remaining pane. One pane collects all tabs.
- Layout changes support Undo. Returning to Tabbed restores surviving runtime
  assignments and selections. Native restores pre-entry frames; Bento arranges
  windows with its own layout.

## Findings and fixes

### T-01: Width conflicts rejected layouts that could fit

Status: implemented; automated tests pass; live retest pending.

Before: a requested 50/50 split was rejected if a window needed more than its
half, even when its neighbor could give up enough width.

After: Tabbed adjusts side-by-side divider ratios to satisfy pane minimum
widths. For example, a 1,006-point area has 1,000 usable points after its
6-point gap. A right pane requiring 600 points gets 600; the left gets 400.
The window height still leaves room for the 34-point tab strip.

The following policy implements the user's width-adaptation request:

- Use the greatest minimum width among the pane's observed tabs, including
  inactive tabs. Empty panes retain a 120-point minimum width.
- Adjust relevant ancestor dividers in nested layouts. Preserve ratios that
  already fit. Preserve pane identities, tab order, selection, and gaps.
- Apply fitting through the shared Tabbed placement path: activation, new
  windows, presets, tab moves, edge splits, divider resizing, Repair, and Undo.
- Commit the fitted layout so divider chrome and subsequent operations use
  the widths actually requested from the windows.
- Keep row ratios unchanged. Reject an operation if a window's minimum height
  cannot fit below the tab strip, or combined minimum widths exceed the area.
- Keep the existing unsupported-window checks. This change does not make
  non-resizable windows resizable.

For an unreported width minimum, the coordinator checks stable frame samples
before rollback. If heights and focus were accepted, the existing minimum-size
learner can record a refused shrink. After a complete rollback, Tabbed fits
the layout again and retries once. An unchanged frame is not enough evidence
to learn a minimum. Height refusals, stale sessions, cancellation, and degraded
restoration do not trigger that retry.

Implementation: `TabbedLayoutState.fittingMinimumWidths`, the app model's
`applyTabbedState`, and `WindowCoordinator.applyTabbed`.

Tests cover inactive tabs, 40/60 allocation, nested ancestors, unchanged row
heights, divider clamping, fractional widths, empty panes, impossible widths,
height refusals, learned widths, rollback failure, and Undo of fitted layouts.

### T-02: Tab controls reported themselves as disabled

Status: fixed; automated and limited live verification passed.

The tab strip exposed Accessibility press actions but reported its controls as
disabled. The overlay now explicitly marks those controls enabled. The
off-screen overlay test checks that state. A rebuilt live app exposed enabled
tab controls, and its pane menu opened through Accessibility.

This does not establish keyboard-navigation coverage. Manual VoiceOver testing
is not required.

### T-03: Failed Undo discarded its history entry

Status: fixed; automated regression passed.

Before: Undo removed its history entry before window placement succeeded.
After a rejected placement, retrying Undo did nothing.

After: the app removes the entry only after the fitted layout is applied and
the session commit succeeds. `tabbedFailedUndoCanBeRetried` reproduced the
failure before the fix and passes afterward.

### T-04: Live pane interaction results were inconclusive

Status: open; manual retest required.

The computer-use session repeatedly returned to Settings during pane
interactions. Some calls timed out or reported a changed target. A move command
was attempted, but the following captured state still showed an empty second
pane. A minimum-size message also appeared during the sequence. The evidence
does not distinguish an app defect from interference by the automation.

Correction to the earlier chat summary: that session did not confirm moving a
tab into an empty pane. The later T-07 session did confirm one such drag. It
does not resolve the remaining interaction failures.

### T-05: Crowded strips and close-button interaction

Status: fixed; automated regressions and synthetic visual checks passed.

Before: drawing omitted tabs that did not fit, but accessibility still exposed
their buttons outside the pane or over the menu. The selected tab could be
hidden. A close request fired on mouse-down, so releasing elsewhere could not
cancel it. Pointer and accessibility pane menus offered different actions.

After: one strip geometry controls drawing, hit testing, accessibility, and
drag insertion. It keeps the selected tab visible and shows a hidden-tab count.
Both pane-menu entry points list all tabs with the current selection checked.
Close requests require release on the same close button. Tests reproduced the
old failures and passed after the changes.

The strip also has full-title tooltips, hover feedback, an active-pane badge,
and a selected-tab underline. Empty panes use shorter guidance. Divider grips
are visible, and accessibility increment/decrement actions use the existing
resize transaction in five-percent steps. Undo reflects history availability,
including after a divider resize. Presets are grouped under Change Layout.
Menus omit empty move destinations and disable splits at the 12-pane limit.
Release settings no longer expose the experimental Tabbed preset picker.

Tests cover 120-, 240-, 330-, and 1024-point strip widths, overflow selection,
accessibility bounds, close cancellation, menu actions, and divider intents.
Light and dark previews cover regular, crowded, minimum-width, and empty panes.
At 120 points the title truncates heavily; its full text remains available in
the tooltip and pane menu. Native hover timing, real dragging, and menu
placement still need live checks.

### T-06: Main Repair controls invoked Bento in Tabbed mode

Status: fixed; fake-window regression passed.

The status-bar Repair control and main panel button now dispatch through
`BetterTileModel.repairCurrentLayout`. In Tabbed mode they repair Tabbed; other
modes retain the existing Bento behavior. Labels reflect that behavior. The
regression changes a fake member's frame, invokes Repair, and confirms frame
restoration without changing mode or pane groups.

### T-07: Authorized live GUI smoke test

Status: partial passes; one accessibility dispatch defect fixed; broader live
coverage remains incomplete.

Tested September 9, approximately 22:13–22:29, America/Phoenix, with the signed
Debug 0.4.6 (12) product from the previous GUI validation. No production code
or tests changed in this session. The public app was running initially. Debug
used its normal sibling prompt to quit the public app before managing windows.
Accessibility was granted, and Stage Manager was off.

The fixture contained three disposable TextEdit documents (A, B, and C) and
one disposable Preview image. The existing editor window also joined Tabbed.
The initial Debug mode was Bento; its default Tabbed preset was One Pane.
The test changed the preset to Two Columns before entering Tabbed.

Confirmed results:

- Activation placed all five windows in pane one and left pane two empty.
- A direct tab click selected TextEdit B and brought it forward. A subsequent
  tab-strip drag moved B into pane two. The immediate capture showed C selected
  and visible in pane one, with B selected and visible in pane two.
- Selecting Preview brought it forward in pane one while B remained visible
  in pane two. This is one observed mixed-app state, not repeated validation.
- A divider drag changed the left pane width from 840 to 960 points. Frame
  reads confirmed A, C, and Preview all used the new left content frame
  `(0, 64, 960, 949)`. B used `(966, 64, 954, 949)` on the right. This checks
  that inactive members followed that resize; it does not establish minimum
  width adaptation, Escape, Undo, or performance under sustained dragging.
- Switching to Native restored all four disposable windows to their exact
  recorded pre-entry frames, shown below. These were measured after Bento had
  arranged the fixtures and before Tabbed activation.

| Fixture | Pre-entry and restored frame `(x, y, width, height)` |
| --- | --- |
| TextEdit A | `(841, 30, 128, 983)` |
| TextEdit B | `(970, 30, 120, 983)` |
| TextEdit C | `(1091, 30, 120, 983)` |
| Preview | `(1212, 30, 708, 983)` |

Unresolved observations:

- Early pointer attempts used fixed coordinates while the tab order changed.
  Some labels in the test notes therefore named a different tab than the
  coordinate actually moved. Those attempts do not establish product failures.
- One attempt displayed "Couldn't apply layout". The popup repeated the generic
  failure message; the underlying coordinator reason was not captured. The
  invalid fixed-coordinate assumptions and concurrent desktop interaction mean
  the result is not reproducible evidence of a placement defect.
- An attempted typing check did not establish focus in B or a typed marker
  there. Treat keyboard input routing as unverified.
- Some later observations showed the editor foreground again. Automation or
  concurrent desktop activity may have affected the sequence; neither has
  been isolated from application behavior. No root cause or code fix is claimed.
- Two tabs in each pane were not established. Mission Control, App Exposé,
  multiple displays, Space changes, fullscreen, close cancellation, overflow,
  both Repair controls, and live light-mode behavior remain pending.

Cleanup completed: all four documents created by this session were closed.
Debug's One Pane preset and Bento mode were restored. Debug quit normally,
and the public app relaunched. Earlier disposable documents were left alone.
The user then requested a handoff. Local captures remain private; the handoff
points to them. Automated tests and builds were not rerun because no code
changed. `git diff --check` passed.

### T-08: Accessibility presses returned before their tab action

Status: fixed; focused regression, full suite, signed build, and live AXPress
check passed.

The custom accessibility buttons returned success and scheduled their action
in an unstructured main-actor task. A native `AXPress` could therefore finish
without changing selection. The live follow-up reproduced this independently
of pointer coordinates: `AXPress` returned success for a named tab while its
accessibility label and focused window remained unchanged.

`TabbedAccessibilityButton.accessibilityPerformPress()` now invokes its
main-actor action synchronously. The regression asserts that an empty-pane
activation intent exists when `accessibilityPerformPress()` returns, without a
task yield. It failed with the deferred implementation and passed with the
synchronous call.

The signed Debug follow-up entered Tabbed with four named windows in pane one.
Direct accessibility hit testing found `BetterTile Test A.txt, selected` and
`BetterTile Test B.txt`. Calling native `AXPress` on B changed the labels to A
unselected and `BetterTile Test B.txt, selected`; TextEdit became frontmost.
The app remained running. The follow-up then restored Bento mode and the One
Pane default, closed the disposable TextEdit and Preview windows, quit Debug,
and relaunched the public app.

### T-09: Raw resize events performed excessive synchronous work

Status: fixed in code; automated regressions pass; sustained live retest
pending.

Before: each divider drag event could immediately run a multi-window
Accessibility transaction. Linked resizing also repeated full observation and
transaction setup, and Tabbed resizing ran the normal placement path, including
window ordering and settlement work, for every raw event. A pointer can produce
events faster than applications accept Accessibility frame writes. That lets
obsolete work occupy the main actor and makes real windows lag or stutter.

After: each gesture stores only its newest sample. An AppKit display link drains
that sample at most once per frame. Live Accessibility mutation is capped at 60
Hz because a 120 Hz display does not make synchronous cross-process AX writes
complete at 120 Hz. The transaction persists across ticks, unchanged targets
are skipped, and intermediate ticks avoid extra participant snapshots. Mouse-up
bypasses the scheduler and validates and applies the exact final geometry.

Linked resize no longer rewrites the source window that the user is already
resizing. Tabbed resize changes real frames during the drag without repeatedly
raising or restacking tabs. Release performs the slower authoritative read-back.
If an app refuses the final size, BetterTile restores both the original frames
and the original Tabbed state. Escape uses the same baseline restoration path.

Automated tests inject bursts of 120 raw drag samples and confirm that only the
latest sample is applied on a manual display tick. They also cover exact release,
source-window write avoidance, Tabbed ordering avoidance, cancellation,
settlement rejection, and participant invalidation at release. These tests
prove bounded work and transaction behavior with the fake window system. They
do not measure live AX latency or frame pacing in third-party applications.

### T-10: Pointer release and divider grab errors

Status: fixed; off-screen AppKit pointer regressions pass; live retest pending.

The old tests sent intents directly to the resize controller. Tests through
the actual pane and divider views reproduced three defects: a stationary
divider grab changed the split ratio, divider release used the last drag
sample, and tab release could commit the preceding pane destination.

Divider views now retain their original split and pointer offset. Both resize
and tab dragging consume the release position before committing. Horizontal
and vertical tests cover the stationary grab and exact release; the tab test
covers a final cross-pane movement and cancellation. Both controls accept the
first click while another application is active. Drop previews name the action
and pane, and tabs show pressed feedback.

Tabbed resize ticks also update chrome geometry without reading focus,
replacing content views, or raising panels. Previously hidden panels stay
hidden. Accessibility frames and overflow geometry continue to track resizing.
One off-screen sample of 120 updates with two panes and four tabs took 11.5 ms
before this change and 8.4 ms after. This measures only overlay work. It does
not measure live Accessibility latency or establish native frame pacing.

### T-11: Failed resize restoration left automatic placement enabled

Status: fixed; fake-window regressions pass.

A failed Escape restoration left automatic placement active. A subsequent
window-created event could move another window despite the unknown desktop
arrangement. An incomplete intermediate resize rollback also discarded its
transaction without restoring the original Tabbed state or suspending writes.

Both failure paths now use the cancellation recovery path. Successful recovery
restores the gesture's original state and frames. Failed recovery suspends
automatic placement and shows Repair Tabbed or Native as recovery actions.
Tests reproduce both outcomes and confirm that Repair permits placement again.

### T-12: Recent external focus changes were discarded

Status: fixed; fake-window regressions pass; live focus retest pending.

Focus notifications received within 300 ms of placement were discarded to
avoid responding to BetterTile's own ordering requests. An external window
selection in that interval could therefore leave the wrong tab selected.
The regression reproduced a selection that stayed stale for ten seconds.

Focus handling now waits until the suppression interval ends and reads the
current focused window. Activating an empty pane cancels an older pending
notification. Focus events cannot resume a session suspended after failed
restoration or interrupt an active resize. Tests cover these cases.

### T-13: Selection depended on unrelated windows

Status: fixed locally; fake-window regressions pass; live retest pending.

A tab click ran the full minimum-size fitter and placement transaction. An
unrelated pane's window becoming non-resizable or changing its minimum size
could reject the click. The four-window/two-pane regression reproduced that
failure without a change to the requested tab.

Selection now uses the existing pane frame and validates placement of only the
selected window. It preserves the other panes' geometry and restores their
ordering only if activating the target application could expose one of that
application's inactive tabs there. Tests cover both shared and separate apps.

### T-14: Repeated application setup during multi-window writes

Status: implemented locally; batch and rollback regressions pass; live timing
comparison pending.

Each frame write independently disabled and restored enhanced accessibility.
Resizing several windows from one application therefore repeated setup and
restoration within one tick. Multi-window transactions now share one
synchronous setup scope. The Accessibility adapter caches that scope per PID
and restores each saved value on exit, including errors and rollback. Existing
single-window and Leave Disabled behavior are retained. No suspension crosses
an asynchronous wait or event-loop turn.

This reduces repeated Accessibility setup. It is not a measured native
frame-pacing result. Tests exercise the coordinator's real placement and
rollback paths with the fake window system.

### T-15: Pane interface revision

Status: implemented locally; light and dark synthetic visual checks pass.

Pane chrome uses native semantic surfaces instead of HUD styling and a heavy
grey fill. Selected tabs use a distinct surface and accent underline. Tabs
include application icons where space allows. Close and menu controls use
system symbols. Empty panes show a drop symbol, a clear destination label,
and guidance for choosing where new windows open. The existing close-release,
overflow, tooltip, drag, and keyboard behavior is retained.

### T-16: Escape could not cancel while a managed app had focus

Status: fixed locally; focused overlay regressions pass; live retest pending.

Tabbed panels do not activate BetterTile. The previous Escape handler monitored
only events sent to BetterTile, so it missed Escape sent to the managed app.
Tab drags and divider resizes now install both local and global AppKit monitors
for the gesture. Cancellation runs synchronously on the main actor. Both
monitors are removed when the interaction ends. Global events remain
observation-only; other local keys pass through. The existing Accessibility
grant covers global key observation; no new permission or private API was added.

Injected-monitor tests cover both Escape sources for resize, global Escape for
tab drag, non-Escape local pass-through, cleanup, and release after cancellation.
They do not establish native keyboard delivery or real-window rollback.

### T-17: Closed floating windows remained in session and Undo state

Status: fixed locally; pure and fake-window regressions pass.

Closing a floated window previously retained its floating exclusion and
pre-entry frame. Undo snapshots also retained that ID. Confirmed destruction now
removes both pane membership and floating state, and clears retained restoration
frames even when the window has already left the pane. Undo uses the same
closure-specific removal. Ordinary reconciliation keeps floating exclusions
when a window is temporarily absent, minimized, or ineligible.

Regressions cover floated-window closure, restoration-only entries, temporary
removal, and closure followed by completed Undo. The initial checks failed on
the previous cleanup path; all 53 focused lifecycle/Tabbed checks then passed.

### T-18: Tab selection accepted a cancelled release

Status: fixed locally; AppKit event regression passes; native retest pending.

A press on a tab body previously selected it even when mouse-up landed outside
that tab. Selection now requires release inside the same tab body, excluding
its close button. The drag path still uses the final release destination.

### T-19: Dragging offered unavailable pane splits

Status: fixed locally; AppKit event regression and light/dark preview checks pass.

At the 12-pane limit, edge dragging previously showed a split preview and
emitted an action that Core rejected without changing the layout. Edge drops
now offer no split at that limit. Center moves remain available. The Float
window target uses a native window symbol and a separate text label.

### T-20: A Space change kept an unfinished divider resize

Status: fixed locally; focused fake-window regressions pass; native retest pending.

Space stabilization previously discarded the active resize transaction while
keeping its intermediate pane ratio. It now restores stored geometry only for
the gesture's source session. Closed windows remain removed. No frame writes
occur on departure; returning to the source Space reconciles the saved layout.
The interrupted gesture adds no Undo entry. Tests reproduce the previous ratio
on return and cover both surviving and destroyed windows during the gesture.

## Validation record

Environment for the initial live smoke test: macOS 26.6.2 (25G83), BetterTile
Debug 0.4.6 (12). Accessibility was granted. Stage Manager was off. App
inventory confirmed only the Debug BetterTile variant was running at that
point. The working-tree content, not the unchanged version number, identifies
each test build.

| Check | Result | Evidence and limits |
| --- | --- | --- |
| Tabbed UI interaction follow-up | Passed: 631 tests | Full suite includes cancelled tab presses, pane-limit drops, and Space-interrupted resize with closure and Undo. Fake-window and own-view tests do not establish native stacking or performance. |
| UI follow-up Debug build and previews | Passed | Unsigned BetterTile Debug build; fresh light/dark tab strips and Float window renders inspected. A test-only compositing correction passed its focused render check afterward. App not launched. |
| Escape and closed-window cleanup continuation | Passed: 627 tests | Full Swift package suite with the native build system. New checks cover cancellation handlers, closure cleanup, temporary floating-window absence, and Undo. |
| Continuation unsigned Debug build | Passed | BetterTile scheme, Debug, `CODE_SIGNING_ALLOWED=NO`. Existing Layout Wheel capture and Sparkle stripping warnings. App not launched; native checks remain open. |
| Selection and batching investigation | Passed: 621 tests | Full Swift package suite, including the four-window/two-pane selection regression and shared placement/rollback batch regression. |
| Revised pane UI | Passed | Inspected light and dark synthetic renders; corrected symbol proportions and template-icon contrast. Full live desktop appearance is not established. |
| Local solution build | Passed, unsigned and personally signed Debug | BetterTile scheme; strict deep signature verification. The running public app was not replaced or controlled during this investigation. |
| Pointer, recovery, and focus follow-up | Passed: 619 tests | Full Swift package suite; includes regressions for actual view event delivery, chrome geometry, failed resize restoration, and delayed focus. |
| Follow-up Debug builds | Passed, unsigned and personally signed | BetterTile scheme, Debug. Signature verification passed. Existing Sparkle stripping warnings remain. App not launched; no live window or native smoothness result is claimed. |
| Follow-up UI previews | Passed | Off-screen light and dark strips, crowded tabs, narrow panes, and empty panes. |
| Initial full Swift package suite | Passed: 588 tests | Before the Undo regression was added. |
| Suite after accessibility and Undo fixes | Passed: 589 tests | No live width-adaptation code was present yet. |
| Full suite after width adaptation | Passed: 598 tests | Includes Core, fake-window coordinator, and app-model tests. |
| Full suite after GUI fixes | Passed: 605 tests | Includes crowded strips, close cancellation, menu state, divider accessibility, and mode-aware Repair. |
| Full suite after synchronous accessibility dispatch | Passed: 605 tests | Includes the regression that requires the pane action before `accessibilityPerformPress()` returns. |
| Full suite after display-synchronized live resize | Passed: 612 tests | Includes divider, linked, and Tabbed coalescing; exact release; cancellation; final settlement rollback; and participant invalidation. |
| Signed Debug launch after live-resize changes | Passed; no resize exercised | The current product launched with Accessibility granted, then quit normally. The public app was restored. A sustained drag was skipped to avoid rearranging the user's active workspace. |
| GUI previews | Passed | Light and dark images rendered from test views only. A later preview-only transparency-compositing change passed its focused test. No production code changed after the full suite. |
| Debug builds after GUI fixes | Passed, unsigned and signed; not launched | Latest product is in `/private/tmp/BetterTile-Tabbed-Validation`. Signature verification passed with normal trust settings. Existing Sparkle stripping warnings remain. |
| Unsigned Debug Xcode build | Passed | `BetterTile.xcodeproj`, scheme `BetterTile`, Debug, `CODE_SIGNING_ALLOWED=NO`. Sparkle emitted existing signed-binary stripping warnings. |
| Signed Debug build and launch before width adaptation | Passed | Accessibility remained granted. This was an earlier build. |
| Signed Debug build after width adaptation | Passed; not launched | Built separately in `/private/tmp/BetterTile-Tabbed-Validation`. No computer use or live testing was resumed. |
| Signed Debug build and named-tab AXPress after T-08 | Passed and launched | Native AXPress selected TextEdit B immediately, updated the selected accessibility label, focused TextEdit, and did not terminate the app. |
| Unsigned Debug Xcode build after T-08 | Passed | `CODE_SIGNING_ALLOWED=NO`; only the existing Sparkle stripping warning was reported. |
| Updated app signature | Passed | `codesign --verify --deep --strict` passed using the Mac's normal trust settings. The sandboxed check could not establish certificate trust. |
| Tabbed strip and menu | Observed | TextEdit and T3 Code appeared as tabs during the initial one-pane smoke test. |
| Two-column and empty-pane UI | Observed | A half-width strip and an empty second pane were captured. |
| Original minimum-size rejection | Observed | The old implementation displayed its size error. This was the behavior T-01 changes. |
| Float a window | Partially observed | T3 Code disappeared from the strip after the float action. Exact restoration and reattachment were not verified. |
| Return to Native | Mode selection observed | Native was selected at the end. Exact restoration of every frame was not measured. |
| Live width adaptation | Not established | The T-07 resize passed; the requested minimum-width scenarios remain pending. |
| Live GUI continuation | Partial passes | T-07 records activation, one cross-pane drag, selected-window captures, resize frames, and exact Native restoration. T-08 records the diagnosed and fixed AXPress defect. |
| Diff whitespace check | Passed | `git diff --check`. |

Two disposable TextEdit documents were created for the initial smoke test.
They may remain open or autosaved; cleanup was not verified. No documents or
windows should be assumed closed from that session.

## Remaining live checks

Start with two panes and two tabs per pane. Put windows from the same app in
different panes, and include another app in at least one pane.

1. Select tabs repeatedly. Type into the selected window. Confirm the other
   pane keeps its selection and visible window.
2. Try the 50/50 case where a right-hand tab needs about 60% width. Confirm the
   divider adapts, the tab strip fits above the content, and inactive windows
   remain covered. Repeat with an inactive tab imposing the width limit.
3. Resize toward a width limit. Check clamping, release, Escape, and Undo.
   Repeat with Focus or another nested layout.
4. Try an impossible combined width and a minimum-height conflict. Confirm
   rejection preserves the previous arrangement and membership.
5. Use Mission Control and App Exposé to select an inactive window. Confirm its
   tab becomes selected without another pane changing.
6. Switch among Tabbed, Native, and Bento desktops. Check assignments and
   selections after returning. Include a Space change during a pending write.
7. Test tab moves, edge splits, presets, group merging, Undo, float, and
   reattachment. Revisit T-04 with direct manual interaction.
8. Close selected and last tabs. Cancel a save prompt and confirm the tab stays
   until the application actually closes its window.
9. Verify exact frame restoration on Native exit and Debug quit. Include new
   windows that did not exist at entry.
10. Check multiple displays, fullscreen transitions, and live performance
    separately.
11. Crowd a strip with nine tabs. Select a hidden tab from the count menu and
    confirm it appears. Check full-title tooltips, close press/drag-away/release,
    menu placement, and Undo enablement.
12. Use both main Repair controls while Tabbed is active. Confirm neither
    changes the mode or pane groups. Check the controls in light and dark mode.

## Current implementation limits

Tabbed is exposed as an experimental Debug mode. Windows use normal on-screen
stacking. The implementation does not park windows off-screen, minimize
inactive tabs, or move windows between native Spaces.

Pane assignments and the last 20 layout changes are runtime-only. Edge splits
are limited to 12 panes. Title-bar drag integration and cross-display tab
dragging are not implemented. Ordinary BetterTile snap actions are disabled
for Tabbed members until they are floated.

The width learner uses bounded observations and one automatic retry. Live
testing must establish how delayed or unusual application responses behave.
Automated results do not establish real window ordering, focus, or visibility.

Unrelated README edits were already in the workspace and were preserved.
PR #65 was opened prematurely and then closed after the maintainer objected.
Its branch had already been pushed; nothing was merged. Further investigation
and changes remain local until the maintainer explicitly requests publication.
