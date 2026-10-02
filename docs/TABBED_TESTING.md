# Tabbed test build

Tabbed is an experimental mode available in Debug builds. It uses normal
on-screen window stacking. Inactive tabs remain open behind their pane's selected
window. Nothing is parked off-screen, minimized, or moved between native Spaces.
Turn off Stage Manager before testing this mode.

This build tests one Tabbed curtain across each display's work area, behind
all selected tabs. Its frosted surface covers inactive tabs across pane
boundaries and gaps. A click selects that pane's selected window or activates
an empty pane. The curtain needs validated exact identities for every tab
and a verified safe window order. Missing identities or unsafe ordering
hide it. This experiment still needs live checks with real applications.

Tab strips sit directly above their selected windows. Settings and floating
windows in front retain their order. After an app switch, BetterTile repairs
inactive tabs above any selected tab without activating an application.

Record results and unresolved observations in
[TABBED_TEST_FINDINGS.md](TABBED_TEST_FINDINGS.md).

## Start

1. Build and run the BetterTile scheme with the Debug configuration. Use the
   existing local signing setup in [DEVELOPMENT.md](DEVELOPMENT.md).
2. Grant Accessibility to BetterTile Debug if needed. The public app and Debug
   app must not manage windows at the same time; the normal sibling-app prompt
   handles that transition.
3. In Settings, choose the default Tabbed layout under Window Mode.
4. On the desktop you want to test, choose **Tabbed (Test)** in the mode picker.

Existing eligible windows become tabs in the first pane. Other panes start
empty. Click an empty pane to send newly opened windows there.

## Controls

- Click a tab to select and focus its window. Pane sizes stay stable when it
  fits. A larger minimum can move dividers. An impossible arrangement keeps
  the previous selection and explains the conflict.
  Releasing outside the original tab body cancels selection, including release
  over its close button or another tab.
- Drag within a strip to reorder. Drag into a pane's center to join its tabs.
- Drag to a pane edge to create a split. A preview shows the proposed destination.
  Center and edge previews name the destination pane and action. The release
  position determines the destination, including after a fast drag.
  At the 12-pane limit, edge drops are unavailable; center moves still work.
- Drop on **Float window** to detach. Escape or an invalid drop cancels.
- Drag a divider to resize. Tab strips follow the divider during the drag.
  The shared curtain keeps covering the work area. At release, inactive tabs
  follow the requested frame at best effort. Apps can refuse that size.
  Side-by-side splits adjust
  to each pane's selected tab's minimum width. A requested 50/50 split
  can become 40/60 when the right pane needs more width. Row splits also
  adjust to minimum heights, including the tab strip. Impossible layouts
  are rejected. The real windows update from the latest pointer sample on each
  display tick, up to 60 times per second. Release applies the exact final
  position, then checks the frames accepted by each app. A rejected final frame
  restores the windows and the Tabbed state. A stable refusal in either
  dimension can cause one retry after complete
  rollback. Ignored size writes do not become minimum sizes. Gestures on any
  display retain observed limits while Tabbed groups remain stored. A later accepted smaller size
  lowers that learned limit.
  Grabbing either side of a divider preserves the pointer's offset. A stationary
  grab does not move the divider. If cancellation cannot restore the previous
  arrangement, automatic placement stops until Repair or an explicit layout action.
  Changing Spaces during an active divider drag cancels its stored geometry.
  Frames are restored when returning to that Space, without restoration writes
  on departure. The cancelled drag does not add an Undo entry.
- Resize a selected window by its edge. BetterTile waits until you release the
  mouse button. An edge shared with another pane moves that pane divider and
  stops at each pane's minimum size. Any other change snaps back, including
  every resize in One Pane. Hidden tabs and strips then follow, and Undo
  restores the previous divider.
- Use the pane's **…** menu for Change Layout, Undo, Repair Tabbed, and empty-pane
  removal. Right-click a tab for close, move, split, and float commands.
- Use **Add Floating Window Here** in a pane menu to reattach a detached window.
- When tabs do not fit, the menu shows a hidden-tab count. It lists every tab
  and checks the selected one. Selecting a hidden tab brings it into the strip.
  Hover over a truncated title to read it in full.
- Pane destinations, visible tabs, close buttons, pane menus, and dividers keep
  accessibility labels and actions. Dividers adjust in five-percent steps.
  Automated tests cover these; manual VoiceOver testing is not required.
- A close-button press can be cancelled by releasing outside that button.
  The main Repair controls repair Tabbed while Tabbed is active.
- Closing a tab requests normal application closure. The tab remains until the
  window closes, including while a save confirmation is open.
- Switching to Native restores pre-entry frames for surviving windows. Windows
  opened during Tabbed keep their current frame. Switching to Bento tiles the
  windows. Returning to Tabbed restores the runtime pane assignments.

Pane assignments and Undo history are runtime-only. Relaunch starts from the
chosen default. The history holds the last 20 layout changes. Edge splits are
limited to 12 panes in this test build. Title-bar drag integration and
cross-display tab dragging are not implemented; use the tab strip on one display.
Ordinary BetterTile snap actions are disabled for Tabbed members. Float the
window first to use those actions.

## Manual checks to record

Use disposable windows for the first pass. Automated tests use a fake window
system; the checks below validate real application and macOS behavior.

- Put two windows from the same app in different panes, with another app selected
  in one pane. Select tabs repeatedly and confirm the other pane stays correct.
- Test curtains with Safari, Finder, Terminal, and VS Code. Shrink a selected
  window by its native edge and drag a divider. Confirm the frosted surface
  hides inactive-tab detail, the selected window stays above it, and the
  curtain covers the work area, including gaps and oversized inactive tabs.
  Repeat with light and dark appearance, Reduce
  Transparency, and Increase Contrast.
- Switch apps with Cmd-Tab and Dock clicks, including an already selected tab.
  Confirm other panes keep their selected windows above the shared curtain.
  Repeat with windows from the same app on two displays.
- Confirm curtains do not appear as windows in Cmd-Tab, Mission Control, or
  App Exposé and do not take keyboard focus or block a floating window. Click
  the frosted area around a smaller selected window. Confirm that window comes
  forward and no hidden tab is selected.
- Open BetterTile Settings over a pane. Click between Settings, other apps, and
  tabs. Confirm Settings keeps focus and stays above the tab strips.
- Put a window from an Ignore Everywhere app over a pane. Cmd-Tab to an app
  with a hidden tab in that pane. Confirm the hidden tab goes back behind the
  selected tab and the ignored window stays in front. Repeat with Spotlight and
  a menu-bar app's window in front.
- Change Spaces, enter fullscreen, disconnect a display, leave Tabbed, and quit
  Debug. Confirm no curtain remains on an unrelated desktop or display.
- Relaunch Debug with `disablePrivateAPIs` enabled as described in
  [SECURITY.md](../SECURITY.md). Confirm Tabbed still works with ordinary
  stacking and no curtains. Restore the default after this comparison.
- Type after selecting a tab. Confirm input reaches the selected window.
- Open Mission Control and App Exposé. Select an inactive window and confirm its
  tab becomes selected without another pane changing.
- Switch between a Tabbed desktop, a Native desktop, and a Bento desktop. Confirm
  their modes and assignments remain independent.
- Resize toward each app's minimum size. Look for exposed inactive windows,
  flicker, delayed frame changes, or a divider continuing to move after release.
- Resize a selected window by each edge in One Pane and Two Columns, including
  into a neighbor at its minimum width. Confirm nothing moves before release,
  then the window snaps back or the divider moves and stops at the minimum,
  with hidden tabs and strips aligned and no Repair needed.
- Sustain a fast divider drag for at least five seconds on both a 60 Hz and a
  high-refresh display when available. Confirm pointer input remains responsive,
  windows do not fall progressively behind, and release lands at the pointer's
  exact final position. Test Finder, TextEdit, Preview, and a browser separately;
  applications can accept Accessibility writes at different speeds.
- Close the selected tab, cancel an application's save prompt, and close a pane's
  last tab. Confirm selection and empty-pane behavior.
- Try each preset, move groups between panes, reduce the pane count, and Undo.
- Crowd a strip with nine tabs. Select hidden tabs through its menu, inspect
  tooltips, and cancel a close click by dragging away before release.
- Resize a divider and check Undo. Test both main Repair controls while
  Tabbed is active. Inspect light and dark mode.
- Float a window, use it, and reattach it. Check that pane UI does not cover it.
- Switch to Native, switch back, and quit Debug. Confirm windows remain reachable.
- Exercise multiple displays, fullscreen transitions, and a Space change during
  a pending operation. Do not infer those results from the single-display checks.

On a rejected operation, the previous state is retained and restoration is
attempted. An incomplete restore suspends automatic writes for that session.
Use **Repair Tabbed**, a new explicit layout action, or switch to Native.

## Validation status

Core, fake-window coordinator, and app-model tests cover activation, membership,
geometry, layout changes, focus requests, restoration, and session isolation.
They also verify display-tick coalescing, exact release geometry, cancellation,
final-frame rejection, and the absence of repeated tab ordering during a live
resize. Curtain tests cover work-area geometry, selected-window
ordering requests, pane clicks, missing identities, cleanup, and solid accessibility
fallbacks. Stacking tests cover the order repair, windows kept in front,
unreadable windows, other displays, strip ordering, and focus while BetterTile
is in front. Off-screen AppKit tests use BetterTile's own windows and cannot prove
real-application ordering. An off-screen pane rendering test checks
accessibility actions without
capturing foreign windows. Real-app stacking, Mission Control/App Exposé, live
performance, and display/Space transition behavior require the manual checks
above. This test build is not evidence that those platform checks have passed.
