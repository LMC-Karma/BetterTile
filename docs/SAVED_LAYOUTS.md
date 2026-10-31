# Saved Layouts

A Saved Layout holds a shape and ordered pane preferences. A preference can be
an app or an App Group. Apply arranges eligible windows that are already open;
it never launches an app or requests a window. A preference is a choice, not a
requirement: another window can fill the pane when the preferred app is absent.

## Create and edit a layout

In Settings → Saved Layouts, choose a screen in **On:** and select a layout.
Use the canvas to edit its shape and pane preferences. Select a pane to add,
remove, or reorder its preferences. An empty preference list means any window.
The preview's **Now on** lines explain the current plan; windows can change
before Apply. **Choose Window** lists eligible windows of an app for a pane.
Its selection applies to the next Apply only. BetterTile checks that the window
is still eligible before applying.

**Save Current Layout** captures eligible windows on the selected screen's
current desktop as a new layout. It records the mode, shape, relative positions,
tab order and floating windows. It does not save window titles, documents,
display or desktop identities, or window identities. **Update from Current
Desktop** updates the selected layout's shape and sizes. It matches new panes
to the nearest old panes, using each old pane once, and keeps their preferences.
An unmatched pane gets its current app as its preference. The name stays with the layout. If Update changes an Adaptive layout to another
mode, **Add extra windows as panes** is turned off.

Use **Edit in Text Editor**, **Reveal in Finder**, or **Reload** to work with
files outside Settings. An external change blocks a conflicting save; Reload
reads the file again. Invalid files are reported and preserved. They do not
block saving a new capture.
If capture or saving an Update fails, the open draft and its edit history stay
unchanged.

## Files and migration

The library is `~/Library/Application Support/BetterTile/Saved Layouts/`;
Debug builds use `BetterTile Debug` instead. Each layout is a JSON file. Version
2 stores the mode and shape, plus an ordered `prefer` list for each slot:

```
"slots": [
  { "id": "left", "prefer": [
    { "app": "com.apple.Preview" }, { "group": "Browser" }
  ] },
  { "id": "right", "prefer": [] }
],
"extraWindows": "float",
"keepForNewWindows": false
```

Each app entry uses a bundle ID; a group entry refers to a group by name.
Adaptive layouts use `extraWindows`: `float` is the default, and `addAsPanes`
adds extra windows as panes. Tabbed and Manual layouts do not write this field.
`keepForNewWindows` defaults to false. BetterTile writes its own header comments
on save. It reads `//` comments anywhere in the file. On save, only its own
header comments remain; removing the header is safe.

Version 2 is the only supported layout format. Unsupported files remain in the
library as unreadable entries with a reason. Reading, Import and Apply never
rewrite, rename or delete those files.

Three complete version 2 files. The tests decode every `json` example in this
guide, so these stay valid.

An Adaptive layout: the left pane prefers Xcode, then any app of the Coding
group; the right pane prefers Safari; Notes floats at a set place.

```json
{
  "version": 2,
  "name": "Writing",
  "mode": "bento",
  "paneGap": 6,
  "layout": {
    "split": "vertical",
    "ratios": [0.65, 0.35],
    "children": [{ "slot": "editor" }, { "slot": "browser" }]
  },
  "slots": [
    { "id": "editor", "prefer": [{ "app": "com.apple.dt.Xcode" }, { "group": "Coding" }] },
    { "id": "browser", "prefer": [{ "app": "com.apple.Safari" }] },
    { "id": "notes", "prefer": [{ "app": "com.apple.Notes" }] }
  ],
  "floats": [
    { "slot": "notes", "rect": { "x": 0.6, "y": 0.1, "width": 0.3, "height": 0.5 } }
  ],
  "extraWindows": "float",
  "keepForNewWindows": false
}
```

A Manual layout with one rectangle that prefers any app of the Browser group:

```json
{
  "version": 2,
  "name": "Reference",
  "mode": "manual",
  "slots": [{ "id": "browser", "prefer": [{ "group": "Browser" }] }],
  "windows": [
    { "slot": "browser", "rect": { "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8 } }
  ]
}
```

A Tabbed layout with one pane that holds Safari and Notes as tabs:

```json
{
  "version": 2,
  "name": "Reading",
  "mode": "tabbed-v1",
  "paneGap": 6,
  "layout": { "group": "main" },
  "slots": [
    { "id": "browser", "prefer": [{ "app": "com.apple.Safari" }] },
    { "id": "notes", "prefer": [{ "app": "com.apple.Notes" }] }
  ],
  "groups": [{ "id": "main", "slots": ["browser", "notes"], "selected": "browser" }],
  "keepForNewWindows": true
}
```

## App Groups

An App Group is a named, ordered list of apps shared by layouts. Groups are
flat: a group cannot contain another group. BetterTile stores them in
`App Groups.json` beside the Saved Layouts folder. Entries can contain an app
display name, bundle ID, or both. Editing a group affects the next Apply of
every layout that refers to it.

A name-only entry resolves against installed apps: exact name first, then a
single substring match, then the text as a bundle ID. An ambiguous name needs a
choice; an unresolved or uninstalled app is shown in Settings and does not
supply a preferred match. Resolution is held in memory on load and Reload;
**Save Resolved Apps** or a user save writes it. An unknown group also produces
a warning. Apply and Details report unknown groups and unresolved group members
while allowing eligible fallback windows to fill panes. Invalid group files
leave the last valid groups in use.

When the file is missing, BetterTile suggests Browser and Coding groups using
installed apps. The suggestions are active immediately; **Keep** retains one
and **Remove** removes it without bringing the suggestion back. Rename a group
in Settings to update layout references. A rename made directly in the file
does not update those references.

Export can embed copies of the App Groups a layout uses in an export-only
`appGroups` member. Import can add a missing
group or map it to an existing group; adding is selected by default when the
export contains the group. The library layout itself keeps references rather than group copies.

## Apply

Apply is available in Settings, the menu bar panel, the Layout Wheel, and a
per-layout shortcut. It works on one display's current desktop. Ignore rules,
minimized or fullscreen windows and other ineligible windows remain excluded.
It never touches windows on another desktop. Escape cancels through the final
input checkpoint before session commit, including input queued while frames
are being written. Once final validation and session commit begin, a later
Escape does not cancel that Apply. BetterTile restores the pre-Apply frames
while the same desktop still owns the transaction. Restoration stops if
ownership or a window changes, so it does not overwrite the newer state.

The plan uses these steps:

1. **Preferred windows.** Expand each group in member order, keeping the first
   occurrence of each app. Assign windows across all panes together to maximize
   preferred matches, then first choices, second choices, and so on. A previous
   assignment can break a tie only when it preserves those match and rank counts
   and fills the same panes as the fresh plan. Otherwise, distance and a stable
   window identity break remaining ties.
2. **Choose free panes.** Choose up to as many free panes as there are remaining
   windows, largest first. At an equal-area boundary, choose panes nearest the
   remaining windows, then left to right and top to bottom. Deliberately empty
   areas are not fill targets.
3. **Assign remaining windows.** The frontmost remaining window takes the
   largest chosen pane, or the nearest of equally large panes. Match the other
   windows to the remaining chosen panes by nearest position.
4. **Place extras.** In Tabbed, extras become tabs in a pane with the same app,
   then a preference for that app, then its current tab-mates, or the nearest
   pane. Tabs follow front-to-back order; the frontmost extra is selected in its
   pane. In Adaptive, extras float at their current frames by default. **Add
   extra windows as panes** inserts them up to the six-pane limit, then floats
   the rest. In Manual, extras stay untouched.
5. **Leave empty panes.** Unfilled Adaptive slots remain vacant and unfilled
   Tabbed panes stay empty.

A user-started Apply first uses windows on the target display. A window on
another visible display can be reused only when it matches a preference, is
unreserved, belongs to that display's current desktop, and is not in an
Adaptive or Tabbed pane there. The source and destination are revalidated.
The result pill offers **Details**
and, when there is a change to undo, **Undo**. Undo restores the previous session
and frames while the touched desktops remain visible and their sessions have
not changed. A mode or preset change, Repair Layout, or a change to pane
membership expires Undo. A later Apply that writes frames or changes a session
replaces its previous checkpoint. A repeat that reports “already arranged” and
changes nothing keeps the original Undo. A transferred window can return only
while its original desktop is visible; a session change there also expires Undo.

The local position hints cache helps match windows on later applies. It contains
normalized frames, not window IDs, titles, or app data, and is not exported.

Apply uses the layout’s pane gap on that desktop until Repair Layout or an
explicit relayout, including a gap change in Settings. Other desktops keep their
own gap.

## Keep this layout for new windows

Turn on **Keep this layout for new windows** before Apply to follow the layout.
An unsaved layout can arrange windows but cannot follow them; the result’s Details
then say “Save this layout to keep following new windows.”
When a followed pane becomes empty, a new window whose app is preferred can fill
it. The best preference wins, with pane order breaking ties. Each matching empty
pane can receive a later window, including another window of the same app.
Other arrivals follow the mode's normal rules. Following does not move an
existing window to make room.

Closing a window, quitting its app, rule exclusion, automatic float, or moving it
to another desktop can leave its followed pane empty. Divider resize and swaps
keep following. A mode or shape change, Repair Layout, applying another layout
or preset, splitting or merging, dragging a window out to float, Undo, edge
transfer, or minimizing a window ends it. The menu bar panel shows **Following
<layout>** and **Stop**. Following is held in memory and does not persist across
relaunch.
