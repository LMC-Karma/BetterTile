# Tabbed test build

Tabbed is an experimental mode available in Debug builds. It uses normal
on-screen window stacking. Inactive tabs remain open behind their pane's selected
window. Nothing is parked off-screen, minimized, or moved between native Spaces.
Turn off Stage Manager before testing this mode.

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

- Click a tab to select and focus its window.
- Drag within a strip to reorder. Drag into a pane's center to join its tabs.
- Drag to a pane edge to create a split. A preview shows the proposed destination.
  Center and edge previews name the destination pane and action. The release
  position determines the destination, including after a fast drag.
- Drop on **Float window** to detach. Escape or an invalid drop cancels.
- Drag a divider to resize. All stacked members follow the pane so inactive
  windows do not retain a larger frame behind it. Side-by-side splits adjust
  to the greatest minimum width of each pane's tabs. A requested 50/50 split
  can become 40/60 when the right pane needs more width. Row ratios remain
  unchanged; minimum heights must fit below the tab strip. Impossible layouts
  are rejected. The real windows update from the latest pointer sample on each
  display tick, up to 60 times per second. Release applies the exact final
  position, then checks the frames accepted by each app. A rejected final frame
  restores the windows and the Tabbed state. An unreported width minimum can
  cause one retry after rollback.
  Grabbing either side of a divider preserves the pointer's offset. A stationary
  grab does not move the divider. If cancellation cannot restore the previous
  arrangement, automatic placement stops until Repair or an explicit layout action.
- Use the pane's **…** menu for Change Layout, Undo, Repair Tabbed, and empty-pane
  removal. Right-click a tab for close, move, split, and float commands.
- Use **Add Floating Window Here** in a pane menu to reattach a detached window.
- When tabs do not fit, the menu shows a hidden-tab count. It lists every tab
  and checks the selected one. Selecting a hidden tab brings it into the strip.
  Hover over a truncated title to read it in full.
- VoiceOver exposes pane destinations, visible tabs, close buttons, pane menus,
  and divider adjustment in five-percent steps.
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
- Type after selecting a tab. Confirm input reaches the selected window.
- Open Mission Control and App Exposé. Select an inactive window and confirm its
  tab becomes selected without another pane changing.
- Switch between a Tabbed desktop, a Native desktop, and a Bento desktop. Confirm
  their modes and assignments remain independent.
- Resize toward each app's minimum size. Look for exposed inactive windows,
  flicker, delayed frame changes, or a divider continuing to move after release.
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
- Adjust a divider through accessibility and check Undo after resizing. Test
  both main Repair controls while Tabbed is active. Inspect light and dark mode.
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
resize. An off-screen pane rendering test checks accessibility actions without
capturing foreign windows. Real-app stacking, Mission Control/App Exposé, live
performance, and display/Space transition behavior require the manual checks
above. This test build is not evidence that those platform checks have passed.
