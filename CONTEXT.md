# Domain glossary

Shared vocabulary for BetterTile's domain. Terms here name concepts, not Swift
types; code and documentation should use them consistently. Product text names
the modes Adaptive and Manual; code identifiers still use `bento`, `manual`,
and `ghost`.

## Layout Wheel

BetterTile's pointer-centered chooser for window actions, Repair Layout, desktop
Mode and Choose Layout. Window actions use a captured window; desktop commands
can target a display without a focused window. Custom style presents one or two
concentric levels around a cancel hub. Grouped style presents command groups
with child fans and supports a quick flick directly to a child.

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
bookkeeping without moving windows, places the lone window of an Adaptive
desktop when its latch fires, or proposes an Adaptive layout for the mutation
path to apply atomically. A Manual desktop never receives an automatic
single-window placement; Repair Layout places its lone window on request.

## Native Space

One macOS desktop reported by the validated native observation capability.
BetterTile pairs its process-local identity with a display to select a runtime
layout session. It never persists the identity or uses it to move a window.

## Stage group

The real windows represented by one Stage Manager thumbnail. BetterTile may
select one validated frontmost member for a drag. It does not create a layout
session for the group or synchronize the other members.

## Adaptive

A per-desktop layout mode that divides the work area among up to six visible
windows. Its layout is a tree of splits: a new window takes room from existing
panes, and a closed window gives its room back. A region of the tree without a
window, such as the rest of the screen after a half-screen snap, is an empty
slot.

_Avoid_: Bento (in product text)

## Repair Layout

A command that rebuilds the current desktop's layout from its visible windows.
On an Adaptive desktop, it picks the arrangement closest to the current
window frames, with equal shares and no empty slots. It ends Focus mode and resumes automatic
placement after a degraded mutation. With one window, it restores that
window's configured placement instead. On a Tabbed desktop, it rebuilds panes
and tabs from current windows and returns automatic floats that a pane can show.
In Manual, one window moves to its configured placement and the desktop stays
Manual; several windows are arranged and the desktop switches to Adaptive.

_Avoid_: Repair Bento, Repair Tabbed, Arrange with Bento

## Balance on new window

An Adaptive setting, off by default. After a new window joins, each partition
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
can float a window out of Adaptive or out of a Tabbed pane. BetterTile floats
popup windows, such as file pickers and dialogs, and windows that appear on
several Spaces. On an Adaptive desktop it also floats windows that cannot be
resized or moved, and a seventh window. On a Tabbed desktop it floats a window
that no pane can show, even after boundaries adapt. A floating window keeps
its own frame until the user returns it to the layout, for example by dragging
it into a Tabbed pane as a tab. A dragged window joins a Tabbed pane only as
its selected tab; a window that the pane cannot show stays floating.

## Automatic float

A floating window that Tabbed or Adaptive floated on its own, for example a
window that no pane can show, or a seventh Adaptive window. Tabbed returns it to
a pane when a pane can show it. It checks on each entry to Tabbed, once about
1 second after the window floats, again when the pane layout changes, and when
the user chooses Repair Layout. A window the user floated never returns on its
own.

## Focus mode

A temporary Adaptive arrangement that expands one tiled window to the work area
and minimizes its covered peers. Maximize enters Focus mode. Restore, Maximize
again, or restoring a peer from the Dock ends it and returns the previous Adaptive
layout after the peers return. Repair Layout also brings the peers back. A
partition shortcut ends Focus mode before applying the requested partition.

## Tabbed preset

A starting pane arrangement for Tabbed: Single Pane, 2 Columns, 2 Rows,
Main + 2, or 2×2 Grid. The user picks the default in Settings. It applies when
a desktop enters Tabbed from Adaptive or first enters from Manual. Keep
Adaptive panes preserves the Adaptive arrangement instead. Returning from
Manual restores the last tab groups.

## Minimum size

The smallest size a window accepts. Applications rarely report it, so
BetterTile measures each new window with a brief size probe and learns from
sizes a window refuses. Each application keeps a seed: the latest measurement
from any of its windows. A new window plans with the seed until it is measured,
and the seed is dropped when the application quits.

## Resize Preview

A resize feedback mode for shared dividers. During the drag, BetterTile draws
the new frames and moves no window. Release applies the previewed layout, and
Escape cancels it.

_Avoid_: Ghost Preview

## Manual

A per-desktop mode that leaves windows where they are, while BetterTile's
snapping and linked resizing remain available.

_Avoid_: Native (as a mode name)

## Live Resize

A resize feedback mode for shared dividers. Windows follow the divider during
the drag. Escape returns them to their frames from before the drag.

## Result pill

A short message capsule that reports the outcome of a user action on its
display, such as "Pane added" or "Couldn’t apply layout". A failure pill can
add a second line that gives the reason. The pill dismisses itself after a
moment. A Saved Layout result pill offers **Details** and, when available, **Undo**.
It stays while the pointer is over it.

## Saved Layout

A local file that describes a shape and ordered pane preferences for one
current desktop of one display. It stores app bundle IDs, App Group references,
relative geometry, mode and related layout settings, not window or desktop
identities, titles or documents.

## App Group

A named, ordered list of apps shared by Saved Layouts. An App Group is flat and
can be used as an item in a pane preference. Always include “App” in its name
to distinguish it from a Layout Wheel group or a Tabbed tab group.

## Pane preference

An ordered list of apps and App Groups that a Saved Layout prefers for a pane.
An empty list accepts any eligible window. Preferences do not require an app to
be open.

## Followed layout

An applied Saved Layout whose preferences guide new windows into matching empty
panes until following ends or the user selects **Stop**. It exists only in the
current session.

## Display set

The exact group of connected displays, identified by each display's identity
(UUID, or vendor, model, and serial number), not by resolution or position. A
display binding ties one Saved Layout to one display of one display set. A set
with an extra or a missing display is a different set.

## Automatic Apply

An Apply that BetterTile starts when a bound display set connects, or when the
Mac wakes for a binding with **Also after wake**. It runs only for an exact
match, waits for macOS and BetterTile to finish settling, and stops when the
user presses a mouse button or key. It uses eligible windows on the target display and never opens an app.

## Apply

The operation that arranges eligible open windows using a Saved Layout on one
display's current desktop. It never launches an app or requests a window.
User-started Apply can reuse a preference-matching window from another visible
display when it is unreserved and belongs to no pane there. Automatic Apply
uses only the target display. Neither takes a window from another desktop.
Escape cancels through the final input checkpoint before session commit,
including input queued during frame writes. Once final validation and session
commit begin, a later Escape does not cancel that Apply. Cancellation restores
the original frames while the desktop owner remains valid.
An automatic Apply shows no result while the screen is locked or this user's
session is inactive. If windows were left changed, it shows one result when
the user returns. Incomplete recovery explains that Undo or Repair Layout is needed.
Undo restores the previous session and frames while the touched desktops remain
visible and their session structures have not changed. Mode, preset, Repair
Layout, and pane membership changes expire Undo. A repeat that reports “already
arranged” and changes nothing keeps the original Undo checkpoint. A later Apply
that writes frames or changes a session replaces its previous checkpoint.

Saved Layouts can also Apply from the menu bar panel, grouped Layout Wheel or a
Mac-local per-layout shortcut. These use the focused managed window's screen,
else a display remembered from real focus or a user action in this app session.
They refuse when no such target exists. Settings keeps its independent On:
picker. The routes share Apply and Undo.
