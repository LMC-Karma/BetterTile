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

Keep Console filtered to the `bento` category while testing. One user action
should produce one settlement path. Repeating `settlement branch:` messages for
one action indicate an event-ownership or fixed-point failure even when the
windows look correct.

- Tile, resize, Repair, and remove windows from Finder, Safari, Terminal, Xcode,
  and a Chromium or Electron application.
- Repeat on one display and two displays. A failure on one display must not stop
  Bento on the other.
- Change Dock position and visibility, then confirm every pane remains inside
  the new work area.
- Enter and leave focus mode, including with a minimum-size window.
- Switch Spaces and sleep/wake the Mac, then confirm the first stable observation
  produces at most one reflow.
- Repeat Space switching with “Displays have separate Spaces” enabled and
  disabled. Confirm each display and Space restores its own Bento tree.
- Keep one window on multiple Spaces and confirm Bento leaves it floating.
- Enter a native fullscreen Space and confirm BetterTile shows no divider and
  performs no ambient placement.
- With Stage Manager enabled, drag single-window and multi-window thumbnails.
  Confirm BetterTile selects only the frontmost real member, never adds a
  thumbnail artifact as a pane, and leaves every other group member untouched.
- Repeat the Stage Manager checks with its Accessibility hierarchy unavailable
  or `disablePrivateAPIs` enabled. Confirm ordinary hit-testing still works.
- Exercise drag snapping and linked resizing with the shared gesture event tap
  active. Confirm down/drag/up ordering matches the `NSEvent` fallback, Escape
  still cancels drag snapping, and one gesture produces one settlement path.
- Disable the event tap during an active gesture and confirm it recovers or both
  consumers switch to `NSEvent` without a duplicate drag or resize. Confirm no
  Input Monitoring prompt appears.
- Compare shared-event and `NSEvent` gesture traces in Instruments. Confirm p95
  down/drag/up delivery latency does not regress by more than 10%.
- Repeat the Space, fullscreen, and display checks after running
  `defaults write com.lmckarma.BetterTile disablePrivateAPIs -bool true` and
  reopening BetterTile. Restore normal behavior with
  `defaults delete com.lmckarma.BetterTile disablePrivateAPIs`.
- During and immediately after each operation, confirm windows do not twitch,
  drift, or restore twice.
