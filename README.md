# BetterTile website

A static product website with an overview and six feature videos. Dark is the default; one header button switches to light. Current native Dark and Ice Blue icon exports are used throughout. Live site: https://lmc-karma.github.io/BetterTile/.

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
| Feature text, FAQ, comparison | `content.mjs` and supporting markup in `render.mjs` |
| Videos, posters, dimensions and captions | `content.mjs` → `media` |
| Colors, type, spacing and responsive layout | `redesign.css` |
| In-view playback, pause and direct theme toggle | `redesign.js` |
| Current native icon paths | `content.mjs` → `brand.assets` |
| Social image / earlier vector studies | `identity.mjs` and `export.html` |
| Separate historical brand board | `brand-base.css` and `brand.css` |

Rebuild after content changes. Do not hand-edit generated HTML. Theme selection stays in localStorage. Generated HTML and identity SVGs are committed because Pages serves the branch root.

## Videos

`assets/media/` contains silent H.264 MP4s at 1920×1080, 60 fps, with matching JPEG posters. `manifest.json` records source, processing and measured metadata.

- Overview: the complete 25-second opening video, including its BetterTile logo/name closing card. Its original video stream is preserved and audio track removed.
- Resize, Bento, snap, Tabbed, wheel, keyboard: dedicated website loops from `bettertile-videos/out/loops/`, copied without video re-encoding and with fast-start metadata. These already have no closing cards or audio.
- These supplied exports are rendered product demonstrations, not live screen recordings. The separate recorded-video output folder was empty when inspected.

Videos load and loop when visible, pause offscreen/in hidden tabs, and preserve a visitor's explicit pause. Reduced motion uses posters until Play. Each video has one small Play/Pause control, with no Replay button or native playback toolbar. Source aspect ratios are preserved at all widths. The older `assets/demo.mp4` and its poster were removed.

To replace a clip, update its `src`, `poster`, `alt`, `caption`, `width` and `height` in `media`. Keep high-resolution originals elsewhere, remove audio and (for feature loops) any closing title card, and check the loop seam. Do not upscale the smaller GIFs in place of the MP4s.

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

The site has no analytics or third-party scripts. Appearance is saved in this
browser's local storage. Playback choices stay in memory. GitHub receives
ordinary request metadata while hosting the page and media. Download and source
links lead to the BetterTile GitHub repository.

Relative links support `/BetterTile/`. `brand.site` controls canonical/social URLs. Research, brand guide, outline and full copy are included beside this file.
