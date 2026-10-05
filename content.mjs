// Product facts and public copy. Build again after editing.
export const brand = {
  name: 'BetterTile', headline: ['Your windows.', 'Working together.'],
  get tagline() { return this.headline.join(' '); },
  description: 'A free, native macOS window manager. Snap windows into place, resize neighbours together, and let Bento adapt as your work grows.',
  requirement: 'macOS 26 or later', version: '0.5.1 beta', checked: '3 October 2026',
  site: 'https://lmc-karma.github.io/BetterTile/',
  links: {
    download: 'https://github.com/LMC-Karma/BetterTile/releases/latest',
    github: 'https://github.com/LMC-Karma/BetterTile',
    docs: 'https://github.com/LMC-Karma/BetterTile/blob/main/README.md',
    install: 'https://github.com/LMC-Karma/BetterTile#install',
    security: 'https://github.com/LMC-Karma/BetterTile/blob/main/SECURITY.md',
    releases: 'https://github.com/LMC-Karma/BetterTile/releases',
    limitations: 'https://github.com/LMC-Karma/BetterTile/blob/main/docs/releases/0.5.0-beta.md',
    license: 'https://github.com/LMC-Karma/BetterTile/blob/main/LICENSE',
  },
  assets: { symbol: 'assets/identity/symbol-reversed.svg', icon: 'assets/identity/app-icon-native-dark-128.png', iconLight: 'assets/identity/app-icon-native-light-128.png', iconLarge: 'assets/identity/app-icon-native-dark-256.png', iconLightLarge: 'assets/identity/app-icon-native-light-256.png', video: 'assets/media/overview.mp4', poster: 'assets/media/overview.jpg' },
};

export const copy = {
  hero: { title: brand.headline, body: 'A native Mac window manager that keeps your workspace in step.', note: 'Free forever · Open source' },
  linked: { eyebrow: '01 / Linked resizing', title: ['One boundary.', 'Both windows.'], body: 'Give one window more room without leaving the other behind. Drag their shared boundary and both sides stay aligned.', detail: 'Use live resizing to see each change as you move. Or choose a ghost preview and commit the new arrangement when you release.' },
  bento: { title: ['Bento grows', 'with your work.'], body: 'Open a new window. Bento makes room in the layout, choosing a split that keeps movement and resizing to a minimum.' },
  placement: { eyebrow: '03 / Everyday placement', title: ['Find your place.', 'Keep your flow.'], body: 'Drag a title bar toward an edge or corner. See the placement preview, then release to snap into place.' },
  tabbed: { eyebrow: '04 / Tabbed', title: ['More within reach.', 'Less on the surface.'], body: 'Group windows into resizable panes. Select a tab to bring its window forward. Everything else stays open behind it.', note: 'Turn off Stage Manager for Tabbed. Pane assignments last for the current app session.' },
  ownership: { eyebrow: 'A small app. Clear intentions.', title: 'Your windows. Your workspace.', body: 'Free forever, with the source open to everyone. No paid tier, subscription, advertising, behavioral tracking, or sale of user data.' },
};

export const faq = [
  ['Which Macs can run it?', 'The current beta requires macOS 26 or later. Accessibility is the only macOS permission BetterTile requests. Check the latest release notes before installing a new version.'],
  ['Why does it need Accessibility?', 'Accessibility lets BetterTile read window frames, then move and resize eligible windows. The app explains the permission before requesting it.'],
  ['Is it really free?', 'Yes. BetterTile is free forever and open source under GPL v3 or later. There is no paid tier, trial expiry, subscription, advertising, behavioral tracking, or sale of user data.'],
  ['Does the app use the internet?', 'Window and configuration data stay on your Mac. Update checks and downloads contact GitHub, which receives ordinary connection metadata. Automatic update checks run every four hours by default and can be disabled. Send Feedback opens a GitHub form with the app version and build in its suggested title; it submits no issue automatically.'],
  ['How do updates work?', 'BetterTile shows release notes and asks before downloading or installing. Sparkle verifies an EdDSA signature on each update. This is separate from the beta’s self-signed macOS code signature. You can also use Check for Updates from the app.'],
  ['What are the current limits?', 'Turn off Stage Manager for Tabbed. Pane assignments and Undo history last for the current app session. Tabbed edge splits stop at 12 panes; cross-display tab dragging is unavailable. Some apps refuse requested window sizes. Broader multi-display and fullscreen behavior is still under validation.'],
  ['Can I keep using macOS tiling?', 'BetterTile can work with windows arranged by macOS tiling. For dragging to screen edges, use either BetterTile Drag Snapping or macOS edge tiling to avoid competing previews.'],
];

export const comparison = [
  { name: brand.name, fit: 'Direct shared-boundary control, adaptive Bento, and Tabbed panes.', resize: 'Drag the seam. Choose a ghost preview or live resizing.', ownership: 'Free · GPL v3+ · macOS 26+ beta', source: brand.links.docs, extra: brand.links.security, extraLabel: 'Beta & privacy details' },
  { name: 'Rectangle Pro', fit: 'Custom placement commands and saved workspaces, including automatic layout triggers.', resize: 'Adjacent windows adjust on release after an edge drag.', ownership: 'US$9.99 displayed · 10-day trial', source: 'https://rectangleapp.com/pro/docs/general/', extra: 'https://rectangleapp.com/pro/docs/layouts/', extraLabel: 'Saved layouts' },
  { name: 'Moom', fit: 'Reusable arrangements and a configurable window-control palette.', resize: 'Saved multi-window arrangements. A shared seam was not verified.', ownership: '$15 displayed · perpetual license, ≥1 year updates', source: 'https://manytricks.com/moom/help/customactions.html', extra: 'https://manytricks.com/moom/', extraLabel: 'Product & price' },
  { name: 'AeroSpace', fit: 'Keyboard and CLI tiling with plain-text configuration and virtual workspaces.', resize: 'Tree resize and balance commands. Pointer seam behavior was not tested.', ownership: 'Free · MIT · configuration-oriented', source: 'https://nikitabobko.github.io/AeroSpace/commands#resize', extra: 'https://github.com/nikitabobko/AeroSpace', extraLabel: 'Source & workflow' },
];

// 1080p60 rendered product demos. The MP4s contain no audio track.
export const media = {
  overview: { kind: 'video', src: 'assets/media/overview.mp4', poster: 'assets/media/overview.jpg', alt: 'Overview of drag snapping, linked resizing, Bento, Tabbed and the Layout Wheel.', caption: 'A quick tour of BetterTile', width: 1920, height: 1080 },
  linked: { kind: 'video', src: 'assets/media/resize.mp4', poster: 'assets/media/resize.jpg', alt: 'A shared boundary moves and all neighbouring windows resize together.', caption: 'Linked resizing', width: 1920, height: 1080 },
  bento: { kind: 'video', src: 'assets/media/bento.mp4', poster: 'assets/media/bento.jpg', alt: 'New windows open and Bento adapts the layout to make room.', caption: 'Adaptive Bento', width: 1920, height: 1080 },
  snapping: { kind: 'video', src: 'assets/media/snap.mp4', poster: 'assets/media/snap.jpg', alt: 'Windows move to an edge, show a placement preview, then snap into place.', caption: 'Drag snapping', width: 1920, height: 1080 },
  tabbed: { kind: 'video', src: 'assets/media/tabbed.mp4', poster: 'assets/media/tabbed.jpg', alt: 'Tabs switch the visible window and move between two panes.', caption: 'Tabbed', width: 1920, height: 1080 },
  wheel: { kind: 'video', src: 'assets/media/wheel.mp4', poster: 'assets/media/wheel.jpg', alt: 'The Layout Wheel opens at the pointer and places a window in the chosen area.', caption: 'Layout Wheel', width: 1920, height: 1080 },
  keyboard: { kind: 'video', src: 'assets/media/keyboard.mp4', poster: 'assets/media/keyboard.jpg', alt: 'Keyboard shortcuts place a window, then restore its earlier position.', caption: 'Keyboard shortcuts and undo', width: 1920, height: 1080 },
};
