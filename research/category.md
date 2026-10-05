# BetterTile category research

Checked **2026-10-03, America/Phoenix** (browser logs use 2026-10-04 UTC). Research only; no competitor apps installed or runtime performance tested. All product claims below come from the product's own site, documentation, repository, or developer-supplied App Store listing. Visual observations are separate from strategic interpretation.

## Decision for the website

Lead with coordinated windows: a shared boundary that visitors can move. Then explain adaptive Bento and familiar placement controls. Free and open source reinforce straightforward ownership; they do not distinguish BetterTile on their own. Rectangle, Loop, AeroSpace, and Amethyst also have free open-source offerings.

Do **not** claim exclusive adjacent-window resizing. Rectangle Pro documents it explicitly. Do not turn absence from a feature page into a red cross in a comparison. Moom's documented saved layouts are different from adaptive tiling, but this review does not prove that every form of coordinated resizing is absent.

Recommended positioning (creative recommendation): **For Mac users working across several windows, BetterTile keeps the workspace aligned as their work changes. Direct linked resizing, adaptive Bento, and familiar Mac controls reduce repeated window arranging. The brand should feel calm, capable, and easy to understand.**

## BetterTile facts checked locally

Read `README.md`, `CONTEXT.md`, and `SECURITY.md` in checkout `d5c5ef5` on `docs/brand-category-research`. `Package.swift` specifies `.macOS(.v26)`; both app build configurations specify `MACOSX_DEPLOYMENT_TARGET = 26.0`.

- Linked resizing operates on actual adjacent window boundaries. Ghost preview commits on release; live resizing updates during movement.
- Bento scores candidate splits to reduce movement/resizing as windows enter, and adopts native pane resizing.
- Tabbed groups windows in resizable panes. It is BetterTile-drawn tab UI, not native app tabbing. Stage Manager must be off. Assignments last for the app session; cross-display tab dragging is unavailable.
- Layout Wheel uses configured modifiers, optionally middle click. Default modifiers: Control + Option + Shift. Keyboard placement and bounded per-window placement undo are supported.
- Free forever, GPL v3 or later, no paid tier, advertising, behavioral tracking, or data sale.
- Accessibility is the only requested macOS permission. Window/configuration data are not transmitted. GitHub-hosted update checks are network requests; do not say the app never uses the internet.
- Public beta: stable self-signed BetterTile Beta certificate, no Apple Developer ID signature, no notarization. Download DMG, move into Applications, then use Privacy & Security → Open Anyway for first launch after verifying the download origin. Sparkle authenticates updates separately.
- Public Apple APIs are the default, with disclosed reviewed read-only private observations and fallback behavior. Do not claim “only public APIs.” No code injection or SIP workaround.
- No cross-Space window movement. Stage Manager groups are not synchronized as multi-window groups.

Sources: [README](https://github.com/LMC-Karma/BetterTile/blob/main/README.md), [glossary](https://github.com/LMC-Karma/BetterTile/blob/main/CONTEXT.md), [security](https://github.com/LMC-Karma/BetterTile/blob/main/SECURITY.md), [package](https://github.com/LMC-Karma/BetterTile/blob/main/Package.swift), [app project](https://github.com/LMC-Karma/BetterTile/blob/main/BetterTile.xcodeproj/project.pbxproj). Parent agent separately verified latest release `v0.5.0-beta` using `gh`. This research agent's sandbox `gh` request could not connect; web fetch of the release page cache-missed. Keep the public download linked to [latest release](https://github.com/LMC-Karma/BetterTile/releases/latest), rather than claiming an independently reverified release number here.

## Direct competitors

### Rectangle and Rectangle Pro

**Promise and name:** literal geometry name; free Rectangle centers on keyboard shortcuts and edge snapping. Pro presents faster placement and deeper customization. Free Rectangle supports macOS 10.15+, Intel/Apple Silicon. Live browser displayed **US$9.99** for Pro and a 10-day trial; Pro supports macOS 13.5+. [Rectangle](https://rectangleapp.com/), [Pro](https://rectangleapp.com/pro/).

**Relevant behavior:** Pro can resize adjacent windows after a dragged edge is released. Saved layouts can run on display changes, wake, or a window opening; this is verified automation, not evidence of Bento-style candidate-scored layout adaptation. [General settings](https://rectangleapp.com/pro/docs/general/), [layouts](https://rectangleapp.com/pro/docs/layouts/).

**Observed identity/site:** white opening, thin large sans-serif name, centered app icon, outlined download button. Icon: dark rounded square with a blue upright window occupying its right half; three small title-bar dots. Pro changes the foreground window to green. Subsequent sections show shortcuts and snap-area illustrations. At 375 px the icon and CTA stack at large scale. Simple silhouette; small dots and material effects are secondary. The full icon supplies the website identity, not a separate elaborate wordmark.

### Magnet

**Promise/name:** an everyday physical metaphor for bringing things into alignment. Developer copy prioritizes an organized workspace, snapping, shortcuts, menu-bar/window-button access, custom commands and display support. US App Store: **US$4.99**, perpetual license, no subscription, macOS 13+. [Website](https://magnet.crowdcafe.com/), [developer listing](https://apps.apple.com/us/app/magnet/id441258766?mt=12), [FAQ](https://magnet.crowdcafe.com/faq.html).

**Observed identity/site:** bright blue and white; bold sans-serif headings. Current icon has a blue rounded-square carrier and three white pane shapes: one tall left pane and two stacked right panes. The central silhouette resembles a partitioned B. This is an important collision to avoid. Hero illustrates the same arrangement inside an outlined laptop; further sections explain placement zones. At 375 px the laptop scales above stacked copy; navigation was visibly expanded in the inspected state. Adjacent-resize support was **not verified** in Magnet's own reviewed sources; Loop's comparison asserts it, but that is not an acceptable primary source for Magnet.

### Moom

**Promise/name:** playful contraction of move/zoom, directly supported by its product subtitle. A configurable window-control toolkit, especially saved arrangements, pop-up palettes, grids, shortcuts, and drag zones. Page displayed **$15**, $8 upgrade, perpetual license with at least one year of updates; currency code not stated on the inspected page. Version 4.6 requires macOS 10.13+. [Moom](https://manytricks.com/moom/).

**Observed identity/site:** white rounded-square icon containing a dimensional multicolor zigzag; bold serif product name contrasts with utility text. Broad atmospheric green/brown background, bright purchase/download buttons, and real Mac interface videos. The opening capture shows its configurable palette. At 375 px the hero overflowed horizontally in this desktop-user-agent viewport test; this is an observed limitation, not a claim about every mobile browser.

**Resizing caveat:** reviewed documentation describes single-window hover resizing and saved arrangements, including arrangements for the most recent N windows. A draggable linked seam was **not verified**, so publish no unsupported-feature claim. [Hover](https://manytricks.com/moom/help/hover.html), [overview](https://manytricks.com/moom/help/), [saved/custom actions](https://manytricks.com/moom/help/customactions.html).

### Loop

**Promise/name:** short motion word, reinforced by a circular directional interaction. Free, GPL-3.0; README says macOS 13+. Main concepts are a modifier-triggered radial selector, placement preview, shortcuts, cycles, and customizable appearance. [Repository/README](https://github.com/MrKai77/Loop).

**Observed identity/site:** GitHub README, centered identity and Mac screen demonstrations against painterly wallpaper, followed by feature videos. Actual classic app icon is a silver ring with a brightly lit top segment on a muted blue rounded square. Circular negative space is recognizable; bevels are app-icon finishing. The ring directly mirrors the selector rather than generic window tiles. [Inspected original icon](https://raw.githubusercontent.com/mrkai77/Loop/develop/assets/graphics/Classic.png).

README self-comparison marks adjacent resizing unsupported in Loop; record as **developer-stated**, not an independently tested result. Do not reuse its claims about other apps. Current README is on `develop`; features introduced there may precede release. This report relies on radial placement/preview as the central product story and does not promise every develop-branch feature is released.

### Lasso

**Promise/name:** an action metaphor for selecting an area; positioned around choosing a grid rectangle with mouse or keyboard. Custom layouts, shortcuts, modifier movement/resizing, multiple displays, import/export, and iCloud preferences. Live page showed macOS 13+ and v1.8.2. [Product](https://www.thelasso.app/).

**Pricing:** live browser showed **US$10.99** single Mac, **US$16.99** personal/three Macs, lifetime license code, seven-day trial. VAT may apply. [Pricing](https://www.thelasso.app/pricing).

**Observed identity/site:** pale gray grid background, rounded sans-serif type, oversized rotating mouse/keyboard headline, orange buttons, floating pill navigation, large real Mac capture. Navigation uses a detailed cream/brown pictorial app icon with a small traffic-light title bar; fine geometry was not resolved sufficiently to name its depicted object confidently. At 375 px the large headline stacks and CTA widens; the observed navigation state occupied substantial top space. Browser succeeded despite repeated web text-fetch timeouts. Adjacent resizing/adaptive automatic tiling were **not verified**.

### AeroSpace

**Promise/name:** expansive spatial compound. Explicitly an i3-like tree-based tiling manager, with keyboard/CLI workflow, plain-text configuration, and its own virtual-workspace model. Free MIT source; README links a 91-second demonstration. [Repository](https://github.com/nikitabobko/AeroSpace).

**Observed identity/site:** documentation-forward white page, red section headings, blue links, serif body copy, persistent table of contents. App icon is a white rounded square with overlapping red ×, yellow −, and green + circles, borrowing the vocabulary of window controls without being a pane grid. No bespoke wordmark observed. [Guide](https://nikitabobko.github.io/AeroSpace/guide).

Tree resizing and balancing are documented capabilities; do not frame all coordinated resizing as BetterTile-exclusive. AeroSpace's virtual-workspace ownership differs from BetterTile's native-Space boundary. Its mouse seam interaction was not tested. [Commands](https://nikitabobko.github.io/AeroSpace/commands#resize).

### Amethyst

**Promise/name:** gemstone name with personality rather than literal functionality. An xmonad-style automatic tiler. Free forever, macOS 10.15+, multiple layouts including tall, wide, columns and recursive BSP, keyboard pane sizing/focus/swap controls. Site links a community tutorial, not a first-party demonstration video. [Site](https://ianyh.com/amethyst/); MIT source: [repository](https://github.com/ianyh/Amethyst).

**Observed identity/site:** charcoal background, slim light wordmark, small upright faceted purple crystal symbol, lime download button, badges and long technical documentation. Large pale schematic Mac windows introduce tiling. The crystal is visually distinct from partitioned-window motifs. Its facets were visible at the heading size; no 16-pixel test performed. Website mark observed, macOS icon carrier not independently inspected. Mouse-linked boundary behavior **not verified**; documented keyboard pane sizing is sufficient evidence that coordinated layouts are already an established category.

### BetterSnapTool

**Promise/name:** “Better” + descriptive action + “Tool,” part of the same naming family as BetterTouchTool. Direct snapping competitor with edge/corner/custom snap areas, keyboard shortcuts and modifier movement/resizing. [Product](https://folivora.ai/bettersnaptool/).

US App Store displayed **US$1.99 · In-App Purchases**. Do not silently omit that qualifier or use it as a lifetime-total-cost claim. [Developer listing](https://apps.apple.com/us/app/bettersnaptool/id417375580?mt=12).

**Observed identity/site:** hosted within BetterTouchTool's dark purple/peach-gradient shell. White bold product name; icon consists of four silver rectangular panes separated by a dark cross-shaped gap. Settings screenshot gallery provides product evidence (some thumbnails were blank in the snapshot). Plain window geometry would overlap strongly with this established motif. Linked resizing and adaptive automatic tiling **not verified**.

## Adjacent Mac utility

### BetterTouchTool

Broader input customization and automation suite, including window management; classify it as adjacent, not simply another focused tiler. The promise is customization of the Mac through gestures, keyboard, mouse, devices and chainable actions. [Homepage](https://folivora.ai/).

Pricing page shows **$15** standard license with two years of updates, then perpetual use of that version; **$25** lifetime updates. Exact price depends on country/tax. Trial: 45 days. [Pricing](https://folivora.ai/buy/).

**Observed identity/site:** dark violet surfaces, peach-to-purple accent, bold white sans-serif type, laptop-framed interface carousel. Nav mark is a white outlined hand-like symbol on a dark rounded-square carrier. The brand is already strongly established around a “Better…Tool” verbal family. This is a **branding confusion risk**, not a legal conclusion about BetterTile.

## A fair, concise public comparison

Use a fit-oriented comparison, not a scoreboard. These four rows distinguish interaction models and acknowledge meaningful strengths. Date it and link the exact sources.

| Product | Strong fit | Coordinated behavior verified | Ownership / download context |
| --- | --- | --- | --- |
| BetterTile | A visible shared boundary plus adaptive Bento and Tabbed panes | Direct seam drag; ghost or live resizing; Bento changes as windows enter | Free, GPL v3 or later; macOS 26+ beta; self-signed, not notarized |
| Rectangle Pro | Custom placement commands and saved workspaces | Adjacent windows adjust on release after edge dragging; layouts can run when a window opens | US$9.99 displayed; 10-day trial; free Rectangle also exists |
| Moom | Reusable arrangements and a configurable palette | Saved multi-window arrangements, including recent-window layouts; shared seam not verified | $15 displayed; perpetual license, at least one year updates; trial |
| AeroSpace | Keyboard/CLI-driven tiling and virtual workspaces | Tree layouts with resize/balance commands; pointer seam not tested | Free MIT source; configuration-oriented workflow |

Sources: [BetterTile README](https://github.com/LMC-Karma/BetterTile/blob/main/README.md), [Rectangle Pro resize](https://rectangleapp.com/pro/docs/general/), [Rectangle Pro layouts](https://rectangleapp.com/pro/docs/layouts/), [Moom layouts](https://manytricks.com/moom/help/customactions.html), [Moom price](https://manytricks.com/moom/), [AeroSpace](https://github.com/nikitabobko/AeroSpace), [AeroSpace resize](https://nikitabobko.github.io/AeroSpace/commands#resize). Prices checked on the date above, not a permanent guarantee.

A short accompanying sentence can acknowledge that free Rectangle and Loop are good alternatives for placement shortcuts and radial placement. Do not imply a customer must pay to get ordinary snapping elsewhere.

## Crowded language and visuals

**Observed naming territories:** literal geometry (Rectangle), physical actions/metaphors (Magnet, Lasso, Loop), playful contraction (Moom), spatial compound (AeroSpace), unrelated evocative noun (Amethyst), and improvement-prefix utility compounds (BetterSnapTool/BetterTouchTool). “BetterTile” is clear and pronounceable but sits close to an existing Mac naming family and describes an incremental category improvement rather than its coordinated experience. This is strategic assessment, not trademark clearance.

**Observed motifs:** rounded-square macOS carriers; blue/green utility accents; partitions and title-bar traffic lights; window screenshots inside laptop frames; prominent download buttons. A simple three-pane B on blue is already especially close to Magnet. A four-pane grid approaches BetterSnapTool. A ring approaches Loop.

**Opportunity:** give the shared boundary a distinctive silhouette. An open frame and a central rail could carry the same idea through the symbol, section dividers, desktop demonstration, and moving window boundary. Keep that mark legible in one color; use blue/emerald as selective interaction signals, not the only identifying features. This is a recommendation, not evidence of exclusive ownership of the idea.

## Inspection coverage and limitations

- Own T3 browser tab: `tab_7`; other agents' tabs were not used. Desktop/mobile opening inspections: Rectangle 1280×800 and 375×812; Moom, Magnet, Lasso 1440×900 and 375×812. Resize changes CSS viewport but retains a desktop user agent.
- Additional desktop visual inspections: Loop README and its actual app icon, Amethyst website, AeroSpace guide and app icon, BetterTouchTool homepage, BetterSnapTool product page.
- Lasso's large Mac capture was viewed below the hero. Moom's opening video visibly changed between palette-related frames; no timing/duration conclusion is made. Lasso headline mouse/keyboard movement was observed across frames; no full motion audit performed. Other animations were not described as observed unless directly seen.
- No controlled small-size competitor icon test, accessibility audit, installed-app behavior check, purchase, account sign-in, or checkout transaction. Prices reflect first-party displayed values only.
- Scope here is the competitor/category portion. The six editorial reference websites and naming finalists are handled by the parent/other research task.
