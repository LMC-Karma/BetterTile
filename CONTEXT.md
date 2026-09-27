# Domain glossary

Shared vocabulary for BetterTile's domain. Terms here name concepts, not Swift
types; code and documentation should use them consistently.

## Layout Wheel

BetterTile's pointer-centered chooser for window actions and Repair Bento. It
presents one or two concentric levels around a cancel hub.

_Avoid_: Snap Wheel, radial menu, Layout Dial

## Window mutation

An operation that changes what the user sees on screen: moving or resizing one
or more windows, or minimizing and restoring them. Multi-window mutations are
all-or-nothing in intent — if part of one fails, the rest is undone.

## Mutation outcome

The terminal meaning of one window mutation. Exactly one outcome describes
exactly one mutation, and nothing about it carries over to the next. A mutation
either **applied**, **failed** (nothing visible changed — every window that had
already moved was returned to where it started), or ended **degraded**.

## Degraded

A mutation failed *and* the attempt to undo it was itself incomplete, so at
least one window was left away from where it started. A degraded desktop is in
an unknown arrangement: automatic corrections stop until the user starts a new
transaction or asks for a repair.

## Ambient layout transition

The complete result of reconciling one display's observed windows with its
active layout session during a background desktop sweep. It either updates
bookkeeping without moving windows, places the lone window when its latch
fires, or proposes a Bento layout for the mutation path to apply atomically.

## Native Space

One macOS desktop reported by the validated native observation capability.
BetterTile pairs its process-local identity with a display to select a runtime
layout session. It never persists the identity or uses it to move a window.

## Stage group

The real windows represented by one Stage Manager thumbnail. BetterTile may
select one validated frontmost member for a drag. It does not create a layout
session for the group or synchronize the other members.

## Tabbed

An experimental per-desktop layout mode, available only in Debug builds. It
divides the work area into panes and shows each pane's windows as tabs. It is
not native macOS window tabbing: BetterTile draws the tab strip and brings the
selected window forward.

_Avoid_: Tabs mode, stacking mode

## Pane

One rectangular region of a Tabbed layout. A pane has ordered tabs, at most
one selected tab, and stays visible when empty. The active pane receives newly
opened windows.

## Tab

A window that belongs to a pane. Every tab in a pane shares the pane's content
frame. The selected tab's window is in front; the others stay open behind it.

_Avoid_: native tab (the tabs inside one application's window)

## Floating window

A window on a managed desktop that the active layout leaves in place. The user
can float a window out of Bento or out of a Tabbed pane, and BetterTile floats
windows that appear on several Spaces. A floating window keeps its own frame
until the user returns it to the layout.

## Tabbed preset

A starting pane arrangement for Tabbed: One Pane, Two Columns, Two Rows,
Bento — Focus, or Four Panes. The user picks the default in Settings.
