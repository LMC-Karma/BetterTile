# Layout Wheel research for BetterTile

Date: 2026-08-28

> This report records the initial research recommendation. The maintainer later
> approved a simultaneous two-ring design. Follow
> [LAYOUT_WHEEL_PLAN.md](LAYOUT_WHEEL_PLAN.md) for the settled product contract
> and implementation steps.

## Decision

Build a single eight-sector window wheel anchored at the pointer. Use a held
keyboard shortcut: press to open, move past a center dead zone to preview, and
release to apply exactly one action. Releasing in the center or pressing Escape
cancels.

Do not start with a second ring, submenus, profiles, mouse side-button triggers,
or all 34 `WindowAction` values. Those features add configuration and input
state before the core gesture has been validated. BetterTile already exposes
the less frequent actions through keyboard shortcuts and menus.

The default sectors should keep a stable spatial meaning:

| Direction | Action |
| --- | --- |
| Top | Top Half |
| Top-right | Top Right Quarter |
| Right | Right Half |
| Bottom-right | Bottom Right Quarter |
| Bottom | Bottom Half |
| Bottom-left | Bottom Left Quarter |
| Left | Left Half |
| Top-left | Top Left Quarter |
| Center | Cancel |

Show the highlighted action name near the hub and show BetterTile's placement
preview on the display. Keep each sector fixed: unlike repeated keyboard
shortcuts, selecting Left must not cycle through left half, left third, and left
two-thirds.

## What the existing apps demonstrate

### Loop: the best base interaction

[Loop](https://github.com/mrkai77/Loop) is the closest direct precedent. Its
documented interaction is to hold a trigger key, move the pointer toward a
radial action, and release. It also provides an optional window preview,
keyboard equivalents, repeated-action cycles, and independent switches for the
radial interface and cursor interaction.
[Loop feature documentation](https://github.com/mrkai77/Loop#features)

Its default radial menu uses eight spatial directions rather than displaying
every available command. Cardinal directions can represent action cycles, the
corners remain direct quarter actions, and the center is separate. The source
also separates radial layout, view state, panel control, and action data:

- [RadialLayout.swift](https://github.com/mrkai77/Loop/blob/develop/Loop/Window%20Action%20Indicators/Radial%20Menu/RadialLayout.swift)
- [RadialMenuController.swift](https://github.com/mrkai77/Loop/blob/develop/Loop/Window%20Action%20Indicators/Radial%20Menu/RadialMenuController.swift)
- [RadialMenuAction.swift](https://github.com/mrkai77/Loop/blob/develop/Loop/Window%20Management/Window%20Action/RadialMenuAction.swift)

The lesson for BetterTile is the gesture and sparse directional layout, not
Loop's cycling behavior. A radial direction should have one predictable result.

### Vorssaint: useful robustness, too much scope

[Vorssaint](https://github.com/vorssaintapp/vorssaint-utils) is a real
open-source project, not only a beta concept. Its wheel is a general launcher
for apps, files, links, key combinations, media controls, toggles, tools, and
nested menus. Window layout is one profile among those uses.
[Vorssaint feature documentation](https://github.com/vorssaintapp/vorssaint-utils#everything-it-does)

The implementation contains several behaviors worth adopting:

- Clamp the wheel to the active display's visible frame.
- Ignore small pointer movement before pointer selection takes ownership. This
  protects trackpad users from accidental selection.
- Let the center hub cancel or step back, not execute a surprising command.
- Support Escape, Return, and arrow-key navigation.
- Reset pointer activation after entering a submenu so the same motion cannot
  immediately execute a child.
- Respect Reduce Motion and Reduce Transparency, and give every icon an
  accessibility label.

These behaviors are visible in the project's
[radial service](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Services/RadialMenu/RadialMenuService.swift),
[support model](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Services/RadialMenu/RadialMenuSupport.swift),
and [SwiftUI wheel](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/UI/RadialMenu/RadialMenuView.swift).
Its default window-layout profile is notably sparse even though the general
wheel can hold many items: maximize and the four directional halves.

Vorssaint's profiles, nested menus, custom placement, mouse triggers, and
app-specific menus are reasonable later options. They are not required to
prove BetterTile's window gesture.

### BetterStage: visual reference only

The first two supplied images appear to show BetterStage's Snap Wheel. Its
public documentation describes configurable snap zones, window modes, Retile,
and multiple keyboard, mouse, modifier, and trackpad triggers.
[BetterStage public repository](https://github.com/terrytz/betterstage)

The compact two-ring hierarchy is attractive, but the outer symbols are hard to
understand without labels. More importantly, BetterStage states that its source
is private and its license is proprietary. BetterTile can study the observable
interaction, but must not adapt its private implementation, artwork, or visual
identity.

## Reading the supplied images

The first two images show a compact two-ring wheel. The inner ring gives spatial
window directions while the outer ring holds utility commands. It keeps the
most frequent placements close to the pointer, but most outer icons are opaque
without text.

The third image appears consistent with Vorssaint's general command wheel. Its
live highlight, clear center hub, and visible sector boundaries are useful. Its
large number of slices and repeated window glyphs make targets harder to scan
and distinguish.

The best combination for BetterTile is therefore:

- Loop's sparse, spatial, hold-move-release gesture.
- Vorssaint's center cancellation, live action label, keyboard behavior, screen
  clamping, input threshold, and accessibility treatment.
- BetterStage's subtle hierarchy only if usage later proves that a second level
  is necessary.

## BetterTile implementation design

### One deep controller, one existing action path

Keep angular selection deterministic in `BetterTileCore`. A small
`LayoutWheelGeometry` type should map a center point and pointer point to either
the dead zone or one of eight sector indexes. It must not import AppKit or know
about event monitoring.

Put a `LayoutWheelController` in `BetterTileMacOS`. It should own the transient
borderless, nonactivating panel; SwiftUI-hosted wheel; keyboard press/release
state; pointer monitoring while visible; display clamping; and placement
preview. This is one coherent input-and-presentation module. Do not spread its
state across `GlobalShortcutMonitor`, the app delegate, and the SwiftUI view.

`BetterTileApp` should own lifecycle and settings. When the controller commits
a selection, the app must invoke a model operation that preserves the existing
permission checks, application rules, Bento policy, settlement verification,
and result feedback. The radial controller must never write an Accessibility
window frame or call `WindowCoordinator.perform` directly.

This preserves the required dependency direction:

```text
BetterTileApp  ->  BetterTileMacOS  ->  BetterTileCore
 lifecycle          panel/input         sector geometry
 model routing      preview view        action data
```

### Preview must be exact and non-mutating

`WindowCoordinator.plan(_:)` is currently unsuitable for pointer hover. It
calls `cycledAction`, which updates two-second left/right shortcut cycle state.
Calling it while the pointer crosses sectors could change state even if the
user cancels, and Left could preview or commit a third instead of a half.

Add a non-mutating exact-action preview path. It should calculate the focused
window's target without advancing shortcut cycles or recording history. On
release, the model should revalidate the focused window and current display,
then commit that exact radial action through its normal manual-or-Bento route.
Tests must prove that hover and cancel do not change cycle state, history,
configuration, Bento state, or any window frame.

The preview renderer can reuse the visual language of the existing drag-snap
and ghost-frame overlays. Extract a shared placement-preview controller only
when the radial menu becomes its second real caller. It must support one frame
in Manual mode and multiple affected frames in Bento mode.

### Trigger and configuration

Use a configurable Carbon hot-key chord for version one. The existing shortcut
monitor already uses the public `RegisterEventHotKey` API, but only listens for
press events. The radial controller needs paired press and release events. Keep
that registration inside the controller unless a second hold gesture creates a
real reason to generalize it.

Ship the radial trigger disabled or unassigned by default to avoid stealing a
system or application shortcut. Add the binding to `BetterTileConfiguration`;
its current schema is version 9, so the change needs a migration and round-trip
tests.

Do not add side-mouse-button, modifier-only, or trackpad triggers in version
one. BetterTile's current shared event tap is intentionally limited to the left
mouse button. Broadening event monitoring changes the documented security and
permission behavior and needs a separate design and security review.

### Visual and accessibility specification

- Prototype a roughly 200–220 point wheel, then tune it with real pointer and
  trackpad use instead of treating that size as final.
- Use eight equal wedges, a generous center dead zone, and an outer selection
  band that remains active if the pointer overshoots the visible wheel.
- Use native materials and semantic colors. Highlight with shape and contrast,
  not color alone.
- Display the selected action name in or below the hub. Icons supplement the
  label; they do not replace it.
- Open immediately on press. Use only short opacity and scale transitions. With
  Reduce Motion enabled, remove scale and use a simple fade.
- With Reduce Transparency enabled, replace glass with an opaque high-contrast
  surface.
- Provide visible keyboard focus. Arrow keys change the selected sector,
  Return commits, and Escape cancels.
- Expose accessibility labels for every sector and announce the current
  selection. Preserve all existing shortcut and menu paths.

### Version-one state machine

```text
idle
  | trigger pressed
  v
open in dead zone -- Escape / trigger released --> cancel
  | pointer crosses activation radius
  v
highlighting -- pointer moves --> preview exact sector
  | trigger released
  v
revalidate --> apply once through BetterTileModel --> dismiss
```

If the focused window disappears, the active display changes incompatibly, or
preflight fails, dismiss without mutation and use BetterTile's existing result
feedback. Never apply the last highlighted action after losing the target.

## Scope after version one

Only after the base gesture tests well, make the eight slots configurable as an
exact `WindowAction` or a `CustomZone`. If users need more than eight, allow one
slot to open a replacement submenu with a center Back action. Do not add a
permanent outer ring until usability testing shows it is faster than a submenu.

Bento is not a separate radial command. The same selected placement should use
BetterTile's active Manual or Bento policy. Linked resize is a gesture mode, not
a placement, so it does not belong in the first wheel. Maximize, Restore,
display movement, thirds, sixths, and repair utilities can remain in existing
menus and shortcuts until configurable slots exist.

## Verification

Add focused tests before connecting live window mutation:

- Core: every angle, wraparound, exact boundaries, center dead zone, outer
  overshoot, and all eight default mappings.
- macOS controller: press/move/release, release in the dead zone, Escape,
  pointer jitter, display clamping, lost focus, and exactly-once commit.
- model/coordinator: preview has no side effects; cancel changes nothing;
  radial Left never advances the shortcut cycle; permission and application
  rules still block; Manual and Bento commits use their existing transaction
  paths.
- configuration: version-9 migration, missing binding, invalid binding, and
  encode/decode round trips.
- manual: multiple displays and Spaces, menu-bar/notch edges, mouse and
  trackpad, VoiceOver, keyboard-only use, Reduce Motion, Reduce Transparency,
  ignored applications, and an Accessibility write refusal.

## Licensing and security

Loop is GPL-3.0 and Vorssaint is GPL-3.0-or-later; BetterTile is also GPL-3.0,
so GPL compatibility is not by itself a reason that adaptation is impossible.
The simplest implementation is still to use BetterTile's existing native
components and implement the documented behavior independently. If actual code
is adapted, record the exact source, commit, license, and attribution required
by `SECURITY.md`. Do not reuse product names, icons, or distinctive artwork.

Version one needs no new dependency, private API, privileged component, or new
permission. Sparkle remains the only runtime dependency. Mouse-button and
broader event-tap support should remain a separate, explicitly reviewed change.
