# BetterTile website

A static product website for BetterTile 0.6 with an overview video and eleven feature videos. The site is Midnight only, with no appearance toggle. Current native Dark and Ice Blue icon exports are used throughout. Live site: https://lmc-karma.github.io/BetterTile/.

## Preview and build

Node.js 22+ and Python 3. No npm install or runtime packages.

```sh
npm run build
npm run dev
```

Open http://127.0.0.1:4188/ and `brand.html#icon-colorways`. The build generates HTML, copy and identity studies, validates local paths and media, then copies the static output into `dist/`.

## Editing

| Change | Source |
| --- | --- |
| Product name, headline, description, links | `content.mjs` → `brand` |
| Version, release date, disk image link, recent releases | Run `npm run release` after each app release. It rewrites `release.json` from GitHub's public releases API. The build reads only that file. |
| Comparison checklist | `content.mjs` → `checklist`; sources in `research/category.md` |
| Link-preview image | Edit `social-preview.html`, render it at 1200 × 630, and save it as `assets/identity/social-preview.png`. The template is not deployed. |
| Feature text, FAQ, comparison | `content.mjs` and supporting markup in `render.mjs` |
| Videos, posters, dimensions and captions | `content.mjs` → `media` |
| Colors, type, spacing and responsive layout | `redesign.css` |
| In-view playback, pause, shared divider and scroll reveals | `redesign.js` |
| Current native icon paths | `content.mjs` → `brand.assets` |
| Social image / earlier vector studies | `identity.mjs` and `export.html` |
| Separate historical brand board | `brand-base.css` and `brand.css` |

Rebuild after content changes. Do not hand-edit generated HTML. Generated HTML and identity SVGs are committed because Pages serves the branch root.

## Videos

`assets/media/` contains silent H.264 MP4s at 1920×1080, 60 fps, with matching JPEG posters. `manifest.json` records the source, processing, poster frame and measured metadata of each file.

- Overview: the complete 38.6-second 0.6.0 overview from `bettertile-videos/out/v2/bettertile-overview.mp4`, including its BetterTile closing card. Its video stream is copied and its music track removed.
- Feature loops: `bettertile-videos/out/v2/loops/bettertile-<stem>.mp4`, remuxed with `-c:v copy -an -movflags +faststart`. They have no closing cards or audio. The seven earlier file names stay stable: `snap`, `resize`, `bento` (the Adaptive loop), `tabbed`, `wheel`, `keyboard` and `overview`. New clips use the video project's stems: `saved-layouts`, `layout-gallery`, `wheel-grouped`, `repair-layout` and `multi-display`.
- Posters: one representative frame per video, extracted at full size with `ffmpeg -ss <seconds> -frames:v 1 -q:v 3`. The frame times are in `manifest.json`.
- GIFs: `assets/media/gifs/bettertile-<stem>.gif` are byte-for-byte copies of the 800 × 450, 20 fps exports. The page does not use them; the app README links them at `https://lmc-karma.github.io/BetterTile/assets/media/gifs/bettertile-<stem>.gif`.
- These are code-built replicas of 0.6.0, not live screen recordings. The video project's README lists what each scene shows and its accuracy notes.

Page placement: Adaptive, linked resizing, snapping, Saved Layouts and keyboard each have a full section. Tabbed shows the Layout Gallery as a second video, and the Layout Wheel shows the Grouped style. "Also new in 0.6" holds Repair Layout and Multiple displays. `#bento` is an alias for `#adaptive`, because the app README links it.

Videos load and loop when visible, pause offscreen/in hidden tabs, and preserve a visitor's explicit pause. Reduced motion uses posters until Play. Each video has one small Play/Pause control, with no Replay button or native playback toolbar. Source aspect ratios are preserved at all widths.

To replace a clip, update the file and its entry in `content.mjs` → `media` (alt and caption), then refresh `manifest.json`. Keep high-resolution originals elsewhere, remove audio and (for feature loops) any closing title card, and check the loop seam. Do not upscale the GIFs in place of the MP4s.

## Icons

`app-icon-native-dark-*` comes from `docs/icon-composer/previews/ice-dark.png`; `app-icon-native-light-*` comes from `ice-default.png`. Website sizes are 32–1024 px. The editable sources remain in Resources/AppIconDark.icon and Resources/AppIconIce.icon. Native app files were not changed. Earlier vector assets remain historical studies on the separate, unindexed brand board.

After changing the social image, build, open `export.html`, export `social-preview.png` at 1200×630 and replace it. The social SVG is regenerated from current content and icon references.

## Checks and deployment

In the local browser: `await (await import('./browser-checks.js')).runChecks()`. See `VALIDATION.md` for results and limits.

The website is served from the independent **gh-pages** branch of
[LMC-Karma/BetterTile](https://github.com/LMC-Karma/BetterTile/tree/gh-pages).
The app stays on `main`. These branches have separate histories; do not merge
`gh-pages` into `main`.

For a website change:

1. Branch from the latest `origin/gh-pages`.
2. Edit the sources, run `npm run build`, and inspect the local browser preview.
3. Commit the sources, generated root HTML/SVGs, and media. Do not commit `dist/`.
4. Open a pull request targeting `gh-pages`. The Website checks workflow runs the build.
5. Merge the reviewed change after checks pass and the maintainer approves it.

Repository **Settings → Pages** uses **Deploy from a branch**, **gh-pages**,
**/ (root)**. Merging into `gh-pages` publishes the committed root files;
`dist/` is only a local static export. Keep `.nojekyll`. No native app build or
release is involved.

## Website data

The site has no analytics or third-party scripts. Playback choices stay in
memory. The site stores nothing in the browser. GitHub receives
ordinary request metadata while hosting the page and media. Download and source
links lead to the BetterTile GitHub repository.

Relative links support `/BetterTile/`. `brand.site` controls canonical/social URLs. Research, brand guide, outline and full copy are included beside this file.
