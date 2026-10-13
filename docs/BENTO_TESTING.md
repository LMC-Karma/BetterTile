# Bento validation

Run this checklist for changes to Bento event handling, placement transactions,
session reconciliation, or recovery.

## Automated checks

```sh
swift test
swift build
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Manual checks

Choose the checks that match the changed behavior. This list is guidance, not a
requirement to repeat the full matrix for every pull request or release.

Keep Console filtered to the `bento` category while testing. One user action
should produce one settlement path. Repeating `settlement branch:` messages for
one action indicate an event-ownership or fixed-point failure even when the
windows look correct.

- Exercise tile, resize, Repair, and window removal in representative native and
  Electron applications.
- Check one and multiple displays when display ownership or work-area behavior
  changed.
- Check Space switching, fullscreen, sticky windows, or Stage Manager when the
  change touches those integrations.
- Check drag snapping and linked resizing on both the shared gesture source and
  its fallback when gesture routing changed.
- Exercise the public fallback when private observation behavior changed. Use
  the documented `disablePrivateAPIs` default for that comparison.
- Confirm each action settles once without twitching, drifting, duplicate
  placement, or a failure on one display stopping another.
- For new-window placement, rearrange the layout by hand, focus a wide pane,
  and open a window of another application in the background. The focused pane splits side by side. Repeat
  with a tall pane; it splits top and bottom. Repeat after a half-screen snap;
  the new window fills the empty slot instead of splitting a pane.
- For **Balance on new window**, turn the setting on and open a window. Each
  partition gives its panes equal shares. Repeat with an application that has
  a large minimum size, such as Calendar. That window keeps its minimum, its
  neighbours share the rest, and no failure pill or overlap remains.
- For minimum-size measuring, run `log stream --level debug --predicate
  'subsystem == "com.lmckarma.BetterTile" AND category == "Accessibility"'`.
  Open two windows of one application, one after the other. Each logs
  `probe measured a … window`, and each window shows a brief resize as it
  appears. After placement, no panes overlap. Quit the application; the log
  reports that its seed was dropped.
- For a hung application, put a window of a test application, such as
  TextEdit, in a Bento layout. Stop it with `kill -STOP <pid>`. Drag dividers
  next to its pane, snap other windows, and drag windows by their title bars.
  BetterTile stays responsive after at most one short stall, and the stopped
  window keeps its pane. Resume it with `kill -CONT <pid>`; a divider drag
  next to it then works at once. Never stop a system process.

## Performance checks

Measure performance when a change touches a hot path or investigates a reported
regression. Compare before and after builds on the same Mac with the same
workload. The `GestureEvents` and `Accessibility` signposts provide delivery and
observation timings. Record the method and result when performance affects the
decision to merge or release; do not impose a universal sample count or
threshold on unrelated changes.
