import release from './release.json' with { type: 'json' };
export { release };
// Product facts and public copy. Build again after editing.
export const brand = {
  name: 'BetterTile', headline: ['Your windows.', 'Working together.'],
  get tagline() { return this.headline.join(' '); },
  description: 'A free, native macOS window manager. Snap windows into place, resize neighbours together, let Adaptive tiling make room as your work grows, and bring a desktop back with Saved Layouts.',
  requirement: 'Apple silicon Mac, macOS 26 or later', version: release.latest.version, checked: '3 October 2026',
  site: 'https://lmc-karma.github.io/BetterTile/',
  links: {
    download: release.latest.dmg,
    latest: 'https://github.com/LMC-Karma/BetterTile/releases/latest',
    github: 'https://github.com/LMC-Karma/BetterTile',
    docs: 'https://github.com/LMC-Karma/BetterTile/blob/main/README.md',
    install: 'https://github.com/LMC-Karma/BetterTile#install',
    security: 'https://github.com/LMC-Karma/BetterTile/blob/main/SECURITY.md',
    releases: 'https://github.com/LMC-Karma/BetterTile/releases',
    issues: 'https://github.com/LMC-Karma/BetterTile/issues',
    limitations: 'https://github.com/LMC-Karma/BetterTile/blob/main/docs/releases/0.6.0-beta.md',
    license: 'https://github.com/LMC-Karma/BetterTile/blob/main/LICENSE',
  },
  assets: { symbol: 'assets/identity/symbol-reversed.svg', icon: 'assets/identity/app-icon-native-dark-128.png', iconLight: 'assets/identity/app-icon-native-light-128.png', iconLarge: 'assets/identity/app-icon-native-dark-256.png', iconLightLarge: 'assets/identity/app-icon-native-light-256.png', video: 'assets/media/overview.mp4', poster: 'assets/media/overview.jpg' },
};

// Section copy. Product statements come from the release notes, CONTEXT.md or the app README.
export const copy = {
  hero: { title: brand.headline, body: 'A native Mac window manager that keeps your workspace in step.', note: 'Free forever · Open source' },
  bento: { title: ['Adaptive tiling.', 'Grows as you work.'], body: 'Open a new window. Adaptive tiling makes room in the layout, choosing a split that keeps movement and resizing to a minimum.', detail: 'When an app stops responding and comes back, its windows rejoin the layout.' },
  linked: { title: ['Resize together.', 'Stay aligned.'], body: 'Give one window more room without leaving the other behind. Drag their shared boundary and both sides stay aligned.', detail: 'Choose Live Resize to see each change as you move. Or choose Resize Preview: the new frames show during the drag and apply when you release.' },
  snapping: { title: ['See the fit.', 'Then let go.'], body: 'Drag a title bar toward an edge or corner. Preview the placement, then release to snap into place.', detail: 'Adjust the Snap Zones in Settings.' },
  saved: { title: ['Your desktop.', 'Back in one click.'], body: ['Save a desktop’s arrangement as a Saved Layout. Apply it from the menu bar panel, the Layout Wheel or its own shortcut.', 'Each pane can prefer apps or an App Group. While a layout is followed, a new window of a preferred app goes into its pane. Bind a layout to a set of displays, and BetterTile applies it when those displays connect.'], detail: 'Apply never opens an app or takes a window from another desktop. Undo Apply puts the windows back. Saved Layouts are local files with app bundle IDs and layout shapes, not window titles or documents.' },
  tabbed: { title: ['More within reach.', 'Less on the surface.'], body: 'Tabbed groups windows in resizable panes. Select a tab to bring its window forward. Drag tabs between panes, or drag a floating window into a pane as a tab.', detail: 'Turn off Stage Manager for Tabbed. Pane assignments last for the current app session.', extra: { title: 'Layout Gallery', body: 'Open the Layout Gallery from a tab bar’s … menu. It shows a picture of each layout. The + button in a pane opens an app straight into it, and tab bars can hide until you point at them.' } },
  wheel: { title: ['Your next move.', 'Within reach.'], detail: 'In a One Level wheel, the bottom sector is Repair Layout. Escape or the center cancels. Optional middle click reserves that button system-wide while enabled.', extra: { title: 'Grouped style', body: 'Choose Grouped for groups such as Size, Thirds, Displays, Mode and Choose Layout, each with its own fan of commands. Or keep Custom, with one or two levels. The wheel can change a desktop’s mode, choose a Tabbed layout and apply Saved Layouts.' } },
  keyboard: { title: ['Keep your hands', 'on the keys.'], body: 'Place windows with global shortcuts. Undo a placement when you want to try another arrangement.', detail: 'Give each command its keys on the Shortcuts page in Settings, with duplicate checks.' },
  more: { title: ['Also new', 'in 0.6.'], body: 'Two more changes in this beta. The release notes list the rest.', items: [
    { media: 'repair-layout', title: 'Repair Layout', body: 'Rebuild a desktop’s layout from its visible windows. Adaptive panes return to equal shares.' },
    { media: 'multi-display', title: 'Multiple displays', body: 'Next Display and Previous Display make room on the destination and close the gap on the source.' },
  ] },
  ownership: { eyebrow: 'A small app. Clear intentions.', title: 'No paid tier. No tracking.', body: 'Free forever, with the source open to everyone. No paid tier, subscription, advertising, behavioral tracking, or sale of user data.' },
};

export const faq = [
  ['Which Macs can run it?', 'BetterTile 0.6 requires an Apple silicon Mac with macOS 26 or later. Intel Macs stay on 0.5.2 and are not offered this update. Accessibility is the only macOS permission BetterTile requests. Check the latest release notes before installing a new version.'],
  ['Why does it need Accessibility?', 'Accessibility lets BetterTile read window frames, then move and resize eligible windows. The app explains the permission before requesting it.'],
  ['Is it really free?', 'Yes. BetterTile is free forever and open source under GPL v3 or later. There is no paid tier, trial expiry, subscription, advertising, behavioral tracking, or sale of user data.'],
  ['Does the app use the internet?', 'Window and configuration data stay on your Mac. Update checks and downloads contact GitHub, which receives ordinary connection metadata. Automatic update checks run every four hours by default and can be disabled. Send Feedback opens a GitHub form with the app version and build in its suggested title; it submits no issue automatically.'],
  ['How do updates work?', 'BetterTile shows release notes and asks before downloading or installing. Sparkle verifies an EdDSA signature on each update. This is separate from the beta’s self-signed macOS code signature. You can also use Check for Updates from the app.'],
  ['What are the current limits?', 'Turn off Stage Manager before using Tabbed. Pane assignments, followed Saved Layouts and Undo history last only for the current app session. Cross-display tab dragging remains unavailable. BetterTile does not move windows between macOS desktops. Some apps refuse requested window sizes.'],
  ['Can I keep using macOS tiling?', 'BetterTile can work with windows arranged by macOS tiling. For dragging to screen edges, use either BetterTile Drag Snapping or macOS edge tiling to avoid competing previews.'],
];

export const comparison = [
  { name: brand.name, icon: 'assets/identity/app-icon-native-dark-128.png', price: 'Free · Public beta', fit: 'Direct shared-boundary control, Adaptive tiling, Tabbed panes and Saved Layouts.', resize: 'Drag the seam. Choose Resize Preview or Live Resize.', ownership: 'Free · GPL v3+ · macOS 26+ beta on Apple silicon', source: brand.links.docs, extra: brand.links.security, extraLabel: 'Beta & privacy details' },
  { name: 'Rectangle Pro', icon: 'assets/competitors/rectangle-pro-128.png', iconFill: true, price: 'US$9.99 · 10-day trial', fit: 'Custom placement commands and saved workspaces, including automatic layout triggers.', resize: 'Adjacent windows adjust on release after an edge drag.', ownership: 'US$9.99 displayed · 10-day trial', source: 'https://rectangleapp.com/pro/docs/general/', extra: 'https://rectangleapp.com/pro/docs/layouts/', extraLabel: 'Saved layouts' },
  { name: 'Moom', icon: 'assets/competitors/moom-128.png', price: '$15 · Perpetual license', fit: 'Reusable arrangements and a configurable window-control palette.', resize: 'Saved multi-window arrangements. A shared seam was not verified.', ownership: '$15 displayed · perpetual license, ≥1 year updates', source: 'https://manytricks.com/moom/help/customactions.html', extra: 'https://manytricks.com/moom/', extraLabel: 'Product & price' },
  { name: 'AeroSpace', icon: 'assets/competitors/aerospace-128.png', price: 'Free', fit: 'Keyboard and CLI tiling with plain-text configuration and virtual workspaces.', resize: 'Tree resize and balance commands. Pointer seam behavior was not tested.', ownership: 'Free · MIT · configuration-oriented', source: 'https://nikitabobko.github.io/AeroSpace/commands#resize', extra: 'https://github.com/nikitabobko/AeroSpace', extraLabel: 'Source & workflow' },
];

// Checklist rows, one value per product in comparison order. true = documented by the developer.
// A string adds how it works. null = not verified in the developer's sources. 'no' = BetterTile does not offer it yet.
// Sources: research/category.md, checked 3 October 2026. BetterTile rows follow the 0.6.0 release notes.
// Do not turn a missing feature page into a cross.
export const checklist = [
  ['Resize neighbours together', 'Move one edge and the next window follows.', ['Drag the shared edge', 'After release', null, 'Resize commands']],
  ['Tile new windows automatically', 'Room is made as windows open.', ['Adaptive tiling', 'Layout triggers', null, 'Tree tiling']],
  ['Drag to snap', 'Edges, corners and custom zones.', [true, true, 'Drag zones', null]],
  ['Keyboard shortcuts', 'Place windows without the pointer.', [true, true, true, 'Keyboard and CLI']],
  ['Pointer menu', 'Choose a placement where the pointer is.', ['Layout Wheel', null, 'Pop-up palette', null]],
  ['Tabbed panes', 'Several windows share one pane.', [true, null, null, null]],
  ['Saved layouts', 'Store an arrangement and apply it later.', ['Saved Layouts', true, 'Saved arrangements', null]],
  ['Open source', 'Read and build the code yourself.', ['GPL v3 or later', null, null, 'MIT']],
  ['Requires', '', ['macOS 26 · Apple silicon', 'macOS 13.5', 'macOS 10.13', null]],
];

// 1080p60 rendered product demos. The MP4s contain no audio track. The seven original file names stay stable
// (bento.mp4 holds the Adaptive loop); new clips use the video project's file stems.
const video = (name, alt, caption) => ({ kind: 'video', src: `assets/media/${name}.mp4`, poster: `assets/media/${name}.jpg`, alt, caption, width: 1920, height: 1080 });
export const media = {
  overview: video('overview', 'Overview of drag snapping, linked resizing, Adaptive tiling, Tabbed with the Layout Gallery, the Layout Wheel, Saved Layouts and multiple displays.', 'A 38-second tour of BetterTile'),
  linked: video('resize', 'A shared boundary moves with Live Resize, and the neighbouring windows resize together.', 'Linked resizing'),
  bento: video('bento', 'New windows open and Adaptive tiling gives each one a pane.', 'Adaptive tiling'),
  snapping: video('snap', 'Windows move to an edge, show a placement preview, then snap into place.', 'Drag snapping'),
  'saved-layouts': video('saved-layouts', 'A Saved Layout named Writing is applied from the menu bar panel. The windows arrange, and Undo puts them back.', 'Saved Layouts'),
  tabbed: video('tabbed', 'Tabs switch the visible window, a tab moves between two panes, and a floating window joins a pane as a tab.', 'Tabbed'),
  'layout-gallery': video('layout-gallery', 'The Layout Gallery opens from the tab bar menu, previews the 2×2 Grid, and applies it while each pane keeps its tabs.', 'Layout Gallery'),
  wheel: video('wheel', 'The Layout Wheel opens at the pointer and places a window on the right half. Then Repair Layout arranges the desktop.', 'Layout Wheel'),
  'wheel-grouped': video('wheel-grouped', 'In the Grouped Layout Wheel, a rest on Thirds opens its fan and Left Two Thirds places the window. A quick flick on Size maximizes it.', 'Layout Wheel, Grouped style'),
  keyboard: video('keyboard', 'Keyboard shortcuts place a window on the left half and maximize it. Restore then steps back one placement at a time.', 'Keyboard shortcuts and undo'),
  'repair-layout': video('repair-layout', 'Repair Layout runs from the menu bar panel, and three Adaptive panes return to equal shares.', 'Repair Layout'),
  'multi-display': video('multi-display', 'Previous Display sends a window to the other display. The destination makes room and the source closes the gap.', 'Multiple displays'),
};

// 800 × 450, 20 fps GIF exports for the app README. Published at assets/media/gifs/bettertile-<stem>.gif.
export const gifs = ['snap', 'resize', 'adaptive', 'tabbed', 'layout-gallery', 'wheel', 'wheel-grouped', 'saved-layouts', 'repair-layout', 'multi-display', 'keyboard'];
