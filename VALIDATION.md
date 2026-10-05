# Validation — video integration

Checked 4 October 2026. Scope: the approved Midnight website, its media, icons and appearance control. Native app code and resources are unchanged.

## Completed

- Publication copy rebuilt from the approved preview with unchanged product CSS and playback code. All 31 browser checks passed again from a nested URL. Static output is approximately 27.6 MiB, including seven videos and the separate brand board.

- Build passes JavaScript syntax, generated HTML, local paths, single main headings, product constraints, 7 configured 1080p videos and current contrast pairs.
- All 31 browser checks passed (the final full-length overview was also rechecked at 25 seconds and through its closing-card loop boundary): correct overview placement; six matching feature videos; no simulation, old video, replay buttons or placeholders; muted inline loops; direct theme switch and persistence; native icon selection; actual playback, pause persistence, loop wrap for every video, offscreen suspension, FAQ, mobile menu, unique IDs and no overflow.
- ffprobe confirms every shipped video is H.264, 1920×1080, 60 fps, with one video stream and no audio stream. `assets/media/manifest.json` records durations and source mapping.
- Feature loops retain their original encoded video. Their last frames were inspected: no brand/download outros. The full 25-second overview keeps its BetterTile logo/name closing card at the user’s request; its original video stream is preserved and audio removed. Original source files are unchanged.
- Measured widths 375, 768, 1024 and 1440 px: no horizontal overflow, missing images or visible buttons below 44×44 px. Inspected desktop/mobile opening and the linked-resizing media row.
- New native Dark and Ice Blue icon exports are used in navigation, closing, favicon, brand board and regenerated social image. Website derivative PNGs retain transparency.
- An isolated same-origin reduced-motion check confirms posters stay paused/unloaded until explicit Play. Playback then starts successfully. Theme switching also works with browser storage disabled. This is a simulated preference test, not an OS setting test.
- Impeccable detector ran once. Two existing Inter warnings remain; the selected typography was preserved. No animation-layout warning remains after removing the simulation.

## Limits

The supplied videos are rendered demonstrations, not live app screen recordings. The separate recording output folder is empty. Their behavior is described in the video project's source/README.

Browser checks use the collaborative desktop engine with resized viewports. Safari, physical touch devices, VoiceOver and OS-level reduced-motion settings have not been tested. Screenshots are representative viewport captures, sometimes resampled by the browser stream, not full-page exports. Remote source links were not exhaustively crawled again.

No Swift tests or Xcode build ran because native code and resources were unchanged. Earlier design review artifacts document a superseded simulation-based version; they are not evidence for the current video behavior.
