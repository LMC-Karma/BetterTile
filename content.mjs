// Product facts used by the build: the download link, the brand page, the identity SVGs, the structured data and
// the sitemap. The home page copy lives in index.html. Build again after editing.
// The one place that decides what every Download button opens. It is the latest-release page, so the site never
// shows an old disk image or version. After a release uploads the fixed-name asset BetterTile.dmg, change it to
// 'https://github.com/LMC-Karma/BetterTile/releases/latest/download/BetterTile.dmg' for a direct download.
export const DOWNLOAD_URL = 'https://github.com/LMC-Karma/BetterTile/releases/latest';
export const brand = {
  name: 'BetterTile', headline: ['Your windows.', 'Working together.'],
  get tagline() { return this.headline.join(' '); },
  description: 'A free, native macOS window manager. Snap windows into place, resize neighbours together, let Adaptive tiling make room as your work grows, and bring a desktop back with Saved Layouts.',
  requirement: 'Apple silicon Mac, macOS 26 or later', checked: '22 November 2026',
  site: 'https://lmc-karma.github.io/BetterTile/',
  links: {
    download: DOWNLOAD_URL,
    latest: 'https://github.com/LMC-Karma/BetterTile/releases/latest',
    github: 'https://github.com/LMC-Karma/BetterTile',
    docs: 'https://github.com/LMC-Karma/BetterTile/blob/main/README.md',
    install: 'https://github.com/LMC-Karma/BetterTile#install',
    security: 'https://github.com/LMC-Karma/BetterTile/blob/main/SECURITY.md',
    releases: 'https://github.com/LMC-Karma/BetterTile/releases',
    issues: 'https://github.com/LMC-Karma/BetterTile/issues',
    limitations: 'https://github.com/LMC-Karma/BetterTile/releases/latest',
    license: 'https://github.com/LMC-Karma/BetterTile/blob/main/LICENSE',
  },
  assets: { symbol: 'assets/identity/symbol-reversed.svg', icon: 'assets/identity/app-icon-native-dark-128.png', iconLight: 'assets/identity/app-icon-native-light-128.png', iconLarge: 'assets/identity/app-icon-native-dark-256.png', iconLightLarge: 'assets/identity/app-icon-native-light-256.png', video: 'assets/media/overview.mp4', poster: 'assets/media/overview.jpg' },
};

// 800 × 450, 20 fps GIF exports. The app README on main links these six at assets/media/gifs/bettertile-<stem>.gif,
// so they stay published. The website page itself does not use them.
export const gifs = ['resize', 'adaptive', 'tabbed', 'layout-gallery', 'saved-layouts', 'wheel'];
