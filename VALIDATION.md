# Validation — 0.6.0 update

Checked 4 November 2026. Scope: the 0.6.0 copy, release data, twelve videos, eleven README GIFs and the new page sections. Native app code and resources are unchanged.

## Completed

- `npm run build` passes: JavaScript syntax, generated HTML, local paths, one main heading per page, product constraints, 12 configured 1080p videos, the Apple silicon requirement, no visible "Bento" or "ghost preview", the README anchors (`#overview`, `#features`, `#bento`, `#adaptive`, `#linked`, `#snapping`, `#saved-layouts`, `#tabbed`, `#wheel`, `#keyboard`, `#more`), all 11 GIF paths, and the contrast pairs.
- `npm run release` refreshed `release.json` from GitHub's public releases API: 0.6.0 beta, 4 November 2026, `BetterTile-0.6.0-beta.dmg`, 12 MB. Download buttons and the version lines use it.
- All 40 browser checks passed at 1440 × 900 and at 390 × 844 (mobile emulation), served from a nested `/BetterTile/` URL: overview placement and playback, pause and its persistence, the overview loop boundary, load at 1920 × 1080 and loop wrap for each of the 11 feature videos, offscreen pause, FAQ, mobile menu, no document overflow, README anchors, the second videos in Tabbed and Layout Wheel, and unique IDs.
- ffprobe confirms each shipped MP4 is H.264, 1920×1080, 60 fps, with one video stream and no audio stream. The overview is 38.6 s. `assets/media/manifest.json` records the source, processing, poster frame time and probe facts for every video and GIF. The 11 GIFs are byte-for-byte copies of the sources (`cmp`).
- The posters were inspected on a contact sheet. Each shows the feature in action, not a blank or fading frame.
- Full-page screenshots at 1440 and 390 px were inspected section by section: hero, overview, feature rail, Adaptive, linked resizing, snapping, Saved Layouts, the Tabbed and Layout Wheel cards with their second videos, keyboard, "Also new in 0.6", ownership tiles, comparison, getting started, FAQ, closing and footer. Copy fits, the two cards' videos stay level at 1440 px, and every section stacks in order at 390 px.
- Measured widths 375, 390, 768, 1024 and 1440 px: no missing images, and `scrollX` stays 0 when the page is scrolled sideways. At 768 px `scrollWidth` reports 773 px because of the overview's blurred glow; the original site reports the same, and the page does not scroll sideways. The only controls under 44 px wide are the inline "Tabbed" and "GitHub" text links (44 px tall), and the footer links are 40 px tall; both are unchanged from the earlier site.
- Static output (`dist/`) is 81.4 MiB: 43.4 MiB of MP4s, 1.6 MiB of posters, 28.3 MiB of README GIFs and the rest of the site. The page loads no video until it scrolls into view.

## Limits

The videos are code-built Remotion replicas of 0.6.0, not live app screen recordings. Their accuracy notes are in the video project's README.

Browser checks ran in Remotion's chrome-headless-shell 149 through the DevTools protocol, with emulated viewports. Safari, Firefox, physical touch devices, VoiceOver and OS-level reduced-motion settings were not tested. The reduced-motion path was not rerun for this update. Remote links, including the new 0.6.0 release-notes link, were not crawled.

The site's Dark icon (`app-icon-native-dark-*`, from `docs/icon-composer/previews/ice-dark.png`) has the same artwork as the icon macOS draws for the installed 0.6.0 app, but a graphite body instead of the installed icon's near-black navy body. The icons were not regenerated.

No Swift tests or Xcode build ran because native code and resources were unchanged.

## App icon (2026-11-04)

The Dark icon exports `assets/identity/app-icon-native-dark-{32,64,128,256,512,1024}.png` now come from the icon macOS draws for the installed release 0.6.0 (NSWorkspace icon of `/Applications/BetterTile.app`, cropped to its 824 px body and resized). The previous exports came from an older Ice Dark preview with a grey body. The Light exports and the favicon are unchanged. `assets/identity/social-preview.png` was re-rendered from `social-preview.html` at 1200 × 630 (headless Chrome 149, 1x) with the new icon and the feature line "Linked resizing · Adaptive tiling · Tabbed · Saved Layouts". `npm run build` passed after the change; the browser checks were not re-run for this icon-only change.

The dated research notes in `research/` keep their findings; their product terms now read Adaptive and Resize Preview, with a dated note at the top of each file.
