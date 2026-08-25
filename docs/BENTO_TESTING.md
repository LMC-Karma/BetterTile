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

## Performance checks

Measure performance when a change touches a hot path or investigates a reported
regression. Compare before and after builds on the same Mac with the same
workload. The `GestureEvents` and `Accessibility` signposts provide delivery and
observation timings. Record the method and result when performance affects the
decision to merge or release; do not impose a universal sample count or
threshold on unrelated changes.
