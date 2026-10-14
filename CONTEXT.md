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

## Bento

A per-desktop layout mode that divides the work area among up to six visible
windows. Its layout is a tree of splits: a new window takes room from existing
panes, and a closed window gives its room back. A region of the tree without a
window, such as the rest of the screen after a half-screen snap, is an empty
slot.

## Repair Bento

A command that rebuilds the Bento layout of one display from its visible
windows. It picks the arrangement closest to the current window frames, with
equal shares and no empty slots. It ends Focus mode and resumes automatic
placement after a degraded mutation. With one window, it restores that
window's configured placement instead.

## Balance on new window

A Bento setting, off by default. After a new window joins, each partition
gives its children equal shares. A window that cannot shrink that far keeps
its minimum size. Tabbed is not affected.

## Tabbed

A per-desktop layout mode that divides the work area into panes and shows each
pane's windows as tabs. It is not native macOS window tabbing: BetterTile draws the tab strip and brings the
selected window forward.

_Avoid_: Tabs mode, stacking mode

## Pane

One rectangular region of a Tabbed layout. A pane has ordered tabs, at most
one selected tab, and stays visible when empty. The active pane receives newly
opened windows.

## Tab

A window that belongs to a pane. The pane's content region is shared by its
tabs. The selected tab's window is in front; the others stay open behind it.

_Avoid_: native tab (the tabs inside one application's window)

## Hidden tab

A tab that is not its pane's selected tab. It stays open behind the selected
tab, at its pane's window frame. Only the selected tab counts toward the pane's
minimum size, so selecting a larger hidden tab can grow its pane.

## Tabbed curtain

A single frosted surface behind all selected tabs on a Tabbed display. It
covers hidden tabs, including portions that extend beyond their panes.

## Floating window

A window on a managed desktop that the active layout leaves in place. The user
can float a window out of Bento or out of a Tabbed pane. BetterTile floats
popup windows, such as file pickers and dialogs, and windows that appear on
several Spaces. On a Bento desktop it also floats windows that cannot be
resized or moved, and a seventh window. On a Tabbed desktop it floats a new
window that fits no pane. A floating window keeps its own frame until the user
returns it to the layout, for example by dragging it into a Tabbed pane as a
tab.

## Focus mode

A temporary Bento arrangement that expands one tiled window to the work area
and minimizes its covered peers. Maximize enters Focus mode. Restore, Maximize
again, or restoring a peer from the Dock ends it and returns the previous Bento
layout after the peers return. Repair Bento also brings the peers back. A
partition shortcut ends Focus mode before applying the requested partition.

## Tabbed preset

A starting pane arrangement for Tabbed: One Pane, Two Columns, Two Rows,
Bento — Focus, or Four Panes. The user picks the default in Settings.

## Minimum size

The smallest size a window accepts. Applications rarely report it, so
BetterTile measures each new window with a brief size probe and learns from
sizes a window refuses. Each application keeps a seed: the latest measurement
from any of its windows. A new window plans with the seed until it is measured,
and the seed is dropped when the application quits.

## Ghost Preview

A resize feedback mode for shared dividers. During the drag, BetterTile draws
the new frames and moves no window. Release applies the previewed layout, and
Escape cancels it.

## Live Resize

A resize feedback mode for shared dividers. Windows follow the divider during
the drag. Escape returns them to their frames from before the drag.

## Result pill

A short message capsule that reports the outcome of a user action on its
display, such as "Pane added" or "Couldn’t apply layout". A failure pill can
add a second line that gives the reason. The pill dismisses itself after a
moment.
