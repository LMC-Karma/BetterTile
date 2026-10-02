# Tabbed testing findings

Last updated: 2026-10-02.

This is the status record for the experimental Tabbed implementation. Update
the relevant row after each test or fix. An attempted action is not a passed
test. Use [TABBED_TESTING.md](TABBED_TESTING.md) for the manual procedure.

## Current assessment

Real-window behavior is only partly verified. The approved design uses one
Tabbed curtain behind all selected tabs on each display. Inactive windows stay
open behind it; nothing is parked or minimized. Automated checks validate the
policy and owned AppKit panels. The real-application matrix below remains open.

Tabbed now runs on the Bento engine (see "Tabbed on Bento" in
[ARCHITECTURE.md](ARCHITECTURE.md)). Pane geometry, divider drags, window drags,
and minimum sizes come from Bento; the earlier Tabbed divider, resize, and
fitting code is gone. A fixture-window pass repeated some workflows on this
engine: activation, selection, tab moves, splitting, resizing, closure, and
Native exit. Earlier live results remain historical unless a current retest
is named below. The real-application and multi-display matrix is still open.

## Intended behavior

- Each desktop independently uses Native, Bento, or Tabbed.
- Tabbed panes remain visible when empty. Each pane has ordered tabs and one
  selected window.
- Initial activation uses the chosen default layout. Existing windows join the
  first pane, with the previously focused eligible window selected.
- New windows join the last-used pane and become selected.
- Dragging a window by its title bar uses Bento drops. A center drop adds it to
  that pane as a tab; an edge drop splits; a tab torn from a group and dropped
  nowhere returns to its group.
- Adding panes preserves groups and adds empty panes. Removing panes merges
  removed groups into the nearest remaining pane. One pane collects all tabs.
- Layout changes support Undo. Returning to Tabbed restores surviving runtime
  assignments and selections after a Native visit. Native restores pre-entry
  frames when they remain reachable and compatible with current minimums.
  Leaving for Bento gives every hidden tab its own pane.

### Minimum-size policy

- Only a pane's selected tab counts. A hidden tab never makes a layout too
  small; it is stacked behind the selected tab at best effort and may stay
  larger if its application refuses the size. Empty panes keep a
  120-point-wide minimum.
- Bento's constraint solver fits minimums, including the tab strip height.
- Divider drags stop at a minimum and turn orange, as in Bento.
- Selection, resizing, and Repair check both minimum dimensions. Selecting a
  tab keeps boundaries stable when it fits; otherwise the solver adjusts them.
  An impossible selection retains the previous tab.
- A stable refusal in width or height can cause one retry after complete
  rollback. A position-only move or unchanged size is not evidence of a
  minimum. Stale sessions, cancellation, and degraded restoration do not retry.
- Gesture starts preserve learned limits while any display or stored desktop
  retains Tabbed groups, including during a Native visit. A gesture on another
  display must not erase an inactive tab's limits. Two consecutive stable
  smaller size readings lower the learned bound.
  A content change alone does not prove that a smaller size will be accepted.
- Repair rereads window constraints and fits the current pane groups.

## Findings

"Automated" means Core, fake-window, or off-screen AppKit tests. "Live" means
real windows on a real desktop. The 2026-10-02 checks used disposable fixture
applications; they do not establish the Safari, Finder, Terminal, and VS Code
matrix below.

| ID | Finding | Automated | Live |
| --- | --- | --- | --- |
| T-01 | Width conflicts rejected layouts that could fit | Fixed | Pending |
| T-02 | Tab controls reported themselves as disabled | Fixed | Passed |
| T-03 | A failed Undo discarded its history entry | Fixed | Not needed |
| T-04 | Early live pane interactions were inconclusive | n/a | Open; retest by hand |
| T-05 | Crowded strips exposed hidden tabs; close fired on mouse-down | Fixed | Pending |
| T-06 | Main Repair controls ran Bento repair in Tabbed | Fixed | Pending |
| T-07 | Initial smoke test and Bento-engine fixture retest | n/a | Partial: see current live checks below |
| T-08 | Accessibility presses returned before their tab action | Fixed | Passed |
| T-09 | Raw resize events did excessive synchronous work | Fixed | Pending (sustained drag) |
| T-10 | Divider grab jumped; release used a stale position | Fixed | Pending |
| T-11 | Failed resize restoration left automatic placement on | Fixed | Not needed |
| T-12 | Focus changes within 300 ms of placement were discarded | Fixed | Pending |
| T-13 | A tab click depended on unrelated panes' windows | Fixed | Pending |
| T-14 | Multi-window writes repeated per-app Accessibility setup | Fixed | Pending (timing) |
| T-15 | Pane chrome used HUD styling and a heavy fill | Revised | Pending (appearance) |
| T-16 | Escape could not cancel while a managed app had focus | Fixed | Pending |
| T-17 | Closed floating windows stayed in session and Undo state | Fixed | Not needed |
| T-18 | Tab selection accepted a release outside the tab | Fixed | Pending |
| T-19 | Dragging offered splits at the 12-pane limit | Fixed | Pending |
| T-20 | A Space change kept an unfinished divider resize | Fixed | Pending |
| T-21 | A window slow to take focus rolled back a correct layout | Fixed | Pending |
| T-22 | Tabbed failures showed a generic "Couldn't apply layout" | Fixed | Pending |
| T-23 | A failed focus read left a focus refresh pending | Fixed | Not needed |
| T-24 | Selecting a visible tab shifted a crowded strip under the pointer | Fixed | Pending |
| T-25 | Row divider overshoot froze the layout instead of clamping | Fixed | Pending |
| T-26 | Narrow tabs showed only an ellipsis; divider states were hard to distinguish | Revised; light and dark renders checked | Pending |
| T-27 | Settings did not show preset geometry or explain how defaults apply | Revised; light and dark renders checked | Pending |
| T-28 | A window-edge resize was ignored: hidden tabs showed and strips misaligned until Repair | Fixed | Pending |
| T-29 | Tab strips followed a divider only at release | Fixed | Pending |
| T-30 | Inactive tabs showed while a selected window was smaller than its pane | Curtain experiment; geometry, ordering requests, fallback, and cleanup covered | Pending |
| T-31 | App activation could expose inactive tabs in another pane, including with floating focus | Reworked as an order-checked repair (see T-33); fake-window regressions on one and two displays | Pending |
| T-32 | Tabbed on two displays repeated placement for unrelated removal IDs | Fixed; unchanged displays settle once in model regression | Pending |
| T-33 | Opening BetterTile Settings handed focus back to the last Tabbed window | Fixed; model regression reproduced the activation before the fix | Pending |
| T-34 | Tab strips covered BetterTile Settings and floating windows | Fixed when exact identities are available | Pending |
| T-35 | A click on a curtain selected the hidden tab behind it | Fixed | Pending |
| T-36 | Displaced selected windows removed pane dividers; inactive tabs and own panels could suppress handles | Fixed; Core and fake-window regressions pass | Pending |
| T-37 | Selection skipped the size solver; recovery excluded height refusals | Fixed; Core and fake-window regressions pass | Pending |
| T-38 | Pane curtains could not cover oversized inactive tabs across boundaries or gaps | Shared display curtain; order, identity, coverage geometry, and readback checks pass | Pending |
| T-39 | Empty recovery and newly synchronized panes could lose membership or crash | Fixed; Core regressions cover empty recovery and vacancy membership | Related fixture checks passed: last-tab close leaves an empty pane; a new window joins |
| T-40 | Bento Restore exceeded the pane cap; adopted layouts omitted overflow | Fixed; cap, reinsertion anchor, overflow, and subsequent rejoin covered | Pending |
| T-41 | Equally strong contradictory resize samples chose an arbitrary boundary | Fixed; contradictory samples refuse fitting, agreeing samples retain expected geometry | Pending |
| T-42 | Restore preview consumed history; failed writes or retries could hide incomplete rollback | Fixed; nonmutating previews, both direct mutation APIs, stale plans, and full-participant retry covered | Failure paths tested with fake windows |
| T-43 | Retired input callbacks could start or cancel replacement gestures; linked rollback failure lacked recovery | Fixed; stop/restart, configuration retirement, source handoff, and degraded cleanup regressions | Pending for held native drags |
| T-44 | Closed retained tabs and terminated applications left unavailable entries | Fixed; authoritative closure, read failures, offscreen windows, launch reuse, and raw WindowServer query IDs covered | Passed with fixtures: selected close chooses survivor; last close leaves empty pane; new-window join and quit cleanup |
| T-45 | Increased minimums prevented Native exit | Fixed; Native exit and shutdown regressions cover grown minimums and exact reachable baselines; failed Native exit rolls back | Passed with fixtures: Native exit and idle shutdown restore frames with grown width and height minimums; unchanged baseline restored exactly |
| T-46 | Shutdown cancelled an active divider after restoration and overwrote restored frames | Fixed; fake-window regression reproduced the overwrite; divider cancellation now precedes final restoration | Pending for a held native gesture |

The polish pass also fixes Bento clamping beside locked boundaries, divider
Escape handling with either app focused, ignored linked-resize neighbors,
rollback after a partial frame write, and stale result-pill dismissal. Core
and fake-window regressions reproduce these failures before their fixes.

Tabbed pane dividers are now Bento's dividers, with the same hover handle,
minimum-size stop, and orange limit. Crowded strips retain their visible range
until selection moves outside it. Drag insertion uses that same range. Compact
tabs keep their application icon, full-title tooltip, and close control.

### T-21: Slow focus rolled back a correct layout

A Tabbed placement required the target window to take focus within about
150 ms. A slower application saw its accepted frames undone with an error.
Accepted frames now wait up to about 550 ms for focus. If focus never arrives,
the layout stays and the focus observer reconciles selection later. Frame
refusal still rolls back. Regressions cover a delayed focus and a focus that
never arrives. This may explain the unexplained error in T-07; that is not
confirmed.

### T-22: Tabbed failures named no reason

The result pill mapped every Tabbed reason to "Couldn't apply layout". It now
shows "Window refused this size", "Use Repair Tabbed", "Desktop changed", or
"Window changed". The full reason stays in the status message.

### T-23: A failed focus read kept a refresh pending

If reading the focused window failed or returned no window, the pending focus
refresh stayed set, and every later Tabbed placement read focus again. The
flag now clears unless placement or a resize is still in progress.

### T-28: Window-edge resizes were ignored

BetterTile adopted a user's window-edge resize only in Bento. In Tabbed, a
smaller selected window exposed the hidden tabs behind it, and a window
dragged into a neighbor overlapped it without any minimum-size check. The tab
strips stayed on the old pane geometry until Repair. Tabbed now waits for the
mouse button to be released, then follows Bento: a shared pane edge moves that
divider and stops at each pane's minimum; any other change snaps back. Bento's
edge reader also ignored the tab strip above a lower pane's window, so stacked
panes always snapped back; it now subtracts the content reserve. Core,
fake-window, and model regressions reproduce each failure before the fix.

### T-33: Settings lost focus to a Tabbed window

Every application activation re-selected the focused Tabbed window and
activated its application. `focusedWindow()` skips BetterTile and
applications it cannot read, and reports the last managed application's window
instead. Opening BetterTile Settings, Spotlight, or a menu-bar window therefore
handed focus straight back to the last Tabbed window. Activation also raised
other panes' selected tabs without checking the window order, so a floating or
ignored window could end up behind them.

A focus change now selects a tab only when that window's application is
frontmost. Activation, focus changes, and selection repair the WindowServer
order so every selected tab stays above every inactive tab. Floating windows
already in front stay above the shared curtain, including in pane gaps.
Divider occlusion uses verified order across applications when available.
The repair never activates an application or changes focus. A
fake-window model test reproduced the activating raise before the fix. Core
and model tests cover a correct order, an exposed pane, a floating window kept
in front, an unreadable window left alone, a second display, and selection
with and without a readable order.

### T-34: Tab strips covered Settings and floating windows

Tab strips and empty panes floated above every normal window. BetterTile's
Settings window floats at the same level, so each refresh put the strips above
Settings. The strips hid only under the focused window, which BetterTile's own
windows never are. With an exact identity, the strips and empty panes now sit
in the normal window stack directly above their pane's selected window. A
window in front of the selected tab covers its strip as well. Without the
identity, they float as before.

### T-35: A curtain click reached a hidden tab

The curtain ignored the mouse, so a click on its frosted area reached the
hidden tab behind it and selected that tab. The curtain now takes the click
without coming forward and selects the pane's selected window.

### Shared curtain and sizing follow-up

A disposable AppKit experiment confirmed cross-process panel ordering in an
isolated fixture: a floating fixture window stayed above both selected windows,
which stayed above the shared curtain and an oversized inactive fixture.
The curtain was visible and non-key. All fixture windows were closed. This
checks public panel ordering and coverage geometry. It does not establish
visual frost coverage, real-app Accessibility raising, or live Tabbed resizing.

Fake-window regressions cover both minimum dimensions on selection and Repair,
ignored writes, stable hidden-size readbacks, pane boundaries despite displaced
selected windows, floating windows in gaps, and ignored raise actions. A
missing inactive-tab identity now prevents a curtain as well. These checks do
not close the real-application findings below.

## Shared Liquid Glass controls

The appearance preference covers tab strips, every mode's divider, empty panes,
the shared curtain, drop and resize previews, the Layout Wheel, and result
feedback. Configuration tests cover migration, round trips, invalid strength,
and the appearance-only runtime change. Overlay tests cover the solid fallback,
curtain frost floor, clear empty panes, and divider hit ownership. A fake-window
model test checks that changing appearance does not move or raise tabs. A wheel
controller test checks that it updates an open gesture without cancelling it.

Light/dark rendering checks inspect BetterTile's own views only. They do not
establish native glass blur over foreign windows. Divider tests now cover
Glass capsule containment at narrow thicknesses, Reduce Motion completion,
and appearance changes during a gesture without moving windows or replacing
its baseline. AX strength announcements round the endpoint to 100 percent.
Fixture checks reached that endpoint and returned to 50 percent. Light/dark
Settings divider samples rendered normally; strength endpoints and Glass
on/off preserved fixture window dimensions. Cross-process blur and curtain
coverage remain pending.

## Current live checks

The fixture pass verified Native → Tabbed with One Pane and Two Columns, and
Native → Bento → Tabbed. Selecting an inactive same-app tab sent typed input
to its window. Tab reorder changed order and selection; dragging a tab to an
edge created a split. An adopted Tabbed divider moved from 50 to 55 percent.
Accessibility resizing stopped at a 640-point application minimum, and further
decrements left the pane unchanged. A native shared-edge drag moved the
boundary, but its exact release distance was not established.

With eighteen fixture tabs, the selected tab stayed visible, the menu listed
every tab and identified two hidden tabs, and choosing a hidden entry focused
it and revealed it in the strip. Dragging a close press outside its button did
not close the window. After closure fixes, closing the selected tab selected a
survivor; closing the last tab retained an empty pane; a new window joined it.
Application quit removed retained tabs. Native exit and idle shutdown
succeeded after the fixture's width and height minimums grew; the restored
window measured 640 by 512 points including its title bar. With unchanged
minimums, shutdown restored the exact pre-entry frame. These checks read
settled frames.

The automated hardening pass also covered membership, overflow, history,
rollback, callback retirement, and native identity evidence. AX/display
callback lifetime safety was reviewed in source; no native timing crash was
reproduced. WindowServer batch queries now encode raw window IDs, with a
query-array regression. Test cleanup preserves distinct policy, integration,
and failure cases; opt-in preview helpers report explicit skips without an
output directory. Fake App models no longer read physical mouse-button state.
An active-divider shutdown regression also reproduced cancellation overwriting
restored frames. Shutdown now cancels the divider before final restoration;
that held-gesture path remains unverified live.

The automation could not verify a numbered Desktop or target a hidden divider
panel for a pointer drag. App-only images cannot establish full cross-process
curtain composition. Held-drag Escape, Mission Control/App Exposé, Space
transitions, multiple displays/Sidecar, sustained high-rate drags, and live
system accessibility-display changes remain unchecked.

## Remaining live checks

Start with two panes and two tabs per pane. Put windows from the same app in
different panes, and include another app in at least one pane.

1. **Shared curtain.** Test Safari, Finder, Terminal, and VS Code with
   repeated tab selections, Cmd-Tab, Dock clicks, native edge resizes, and
   divider drags. Confirm inactive-window detail stays hidden, the selected
   window stays above the curtain, and other panes do not change. Confirm
   curtains are absent from Cmd-Tab, Mission Control, and App Exposé. Repeat
   across a Space change and two displays, and compare the public fallback
   with private APIs disabled. Click the frosted area and confirm the selected
   window comes forward. Record coverage across pane boundaries and gaps,
   including oversized inactive tabs.
2. **Windows in front of panes.** Open BetterTile Settings over a pane and
   click between Settings, other apps, and tabs. Confirm Settings keeps focus
   and stays above the tab strips. Put a window from an Ignore Everywhere app
   over a pane, then Cmd-Tab to an app with a hidden tab in that pane. Confirm
   the hidden tab goes back behind the selected tab and the ignored window
   stays in front. Repeat with Spotlight and a menu-bar app's window.
3. Type after selecting a tab. Confirm input reaches the selected window.
4. Try the 50/50 case where a right-hand tab needs about 60% width, including
   selecting an inactive tab that needs more width. Confirm inactive windows
   stay covered.
5. Resize toward a width limit. Check clamping, release, Escape, and Undo.
   Try an impossible width and a minimum-height conflict.
6. Use Mission Control and App Exposé to select an inactive window. Confirm its
   tab becomes selected without another pane changing.
7. Switch among Tabbed, Native, and Bento desktops, including a Space change
   during a pending write.
8. Test tab moves, edge splits, presets, group merging, Undo, float, and
   reattachment. Revisit T-04 by hand.
9. Repeat selected/last-tab closure and application quit/relaunch with real
   applications. Cancel a save prompt and confirm the tab stays until the
   window closes.
10. Verify restoration on Native exit and Debug quit, including windows opened
    during Tabbed and changed or previously unknown minimums. Preserve exact
    reachable baselines when their current minimums still allow them. Read
    settled frames, and repeat quit while holding a divider gesture.
11. Check multiple displays, fullscreen transitions, and sustained drag
    performance separately.
12. Crowd a strip with nine tabs. Check the hidden-tab menu, tooltips, close
    press, drag-away, release, and menu placement.
13. Use both main Repair controls while Tabbed is active, in light and dark
    mode.

Manual VoiceOver testing is not required. Accessibility labels and actions are
covered by automated tests.

## Current implementation limits

Tabbed is available only in Debug builds. Inactive tabs stay on-screen behind
the selected window; nothing is parked off-screen, minimized, or moved between
Spaces. Stage Manager must be off.

Pane assignments and the last 20 layout changes are runtime-only. Edge splits
stop at 12 panes. Cross-display tab dragging is not implemented. Hidden tabs
follow a divider at release, not during the drag. The shared curtain covers
the work area throughout the drag; its real-application ordering and visual
coverage remain unverified.
Without a validated exact identity, no curtain appears and hidden tabs can
still show while a selected window is smaller than its pane. Curtains have no
parking fallback.
