import assert from 'node:assert/strict';
import { readFile, access, readdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { brand, gifs, DOWNLOAD_URL } from './content.mjs';

const SITE = brand.site; // https://lmc-karma.github.io/BetterTile/
const pages = ['index.html','brand.html','export.html','social-preview.html','404.html','acknowledgements.html','privacy.html'];
const stylesheets = ['styles.css','brand-base.css','brand.css'];
const scripts = ['script.js','export-assets.js'];
const read = file => readFile(file,'utf8');
const visibleText = html => html.replace(/<(script|style|svg)[\s\S]*?<\/\1>/g,'').replace(/<[^>]+>/g,' ').replace(/&nbsp;|&#8209;/g,' ').replace(/\s+/g,' ');

// A URL on the site's own origin maps to a file in this branch. Any other http(s) URL is third-party.
const local = (url, from) => url.startsWith(SITE) ? url.slice(SITE.length) || 'index.html' : resolve(dirname(from), url);
async function mustExist(url, from) {
  const path = local(url.split('#')[0].split('?')[0], from);
  if (path) await access(path.endsWith('/') ? `${path}index.html` : path).catch(() => assert.fail(`${from}: missing ${url}`));
}
const thirdParty = url => /^(?:https?:)?\/\//.test(url) && !url.startsWith(SITE);

for (const file of pages) {
  const html = await read(file);
  assert.equal((html.match(/<h1[\s>]/g)||[]).length,1,`${file}: one main heading`);
  // Every local reference resolves, links included.
  for (const [,url] of html.matchAll(/\b(?:href|src|poster)="([^"]+)"/g)) {
    if (/^(?:mailto:|data:|#)/.test(url) || thirdParty(url)) continue;
    await mustExist(url, file);
  }
  // Nothing the browser loads comes from another origin: stylesheets, icons, preloads, scripts, images, media, frames.
  const loads = [
    ...[...html.matchAll(/<link\b[^>]*>/g)].map(([tag]) => tag.match(/\bhref="([^"]+)"/)?.[1]),
    ...[...html.matchAll(/<(?:script|img|source|video|audio|iframe|embed|track|input)\b[^>]*>/g)].flatMap(([tag]) => [...tag.matchAll(/\b(?:src|poster|srcset|data)="([^"]+)"/g)].map(m => m[1])),
    ...[...html.matchAll(/url\(\s*['"]?([^'")]+)/g)].map(m => m[1]),
    ...[...html.matchAll(/@import\s+(?:url\()?['"]?([^'");\s]+)/g)].map(m => m[1]),
  ].filter(Boolean);
  for (const url of loads) assert(!thirdParty(url), `${file}: loads a third-party resource: ${url}`);
  for (const [,url] of html.matchAll(/url\(\s*['"]?([^'")]+)/g)) if (!/^(?:#|data:)/.test(url)) await mustExist(url, file);
  // Internal files stay out of the published pages.
  assert(!/(?:href|src)="(?:\.\/)?(?:research\/|NOTES\.md|[A-Z-]+\.md)/.test(html),`${file}: no link to an internal file`);
  assert(!/competitors\/|Local\//.test(html),`${file}: no internal paths`);
}
for (const file of stylesheets) {
  const css = await read(file);
  for (const [,url] of css.matchAll(/url\(\s*['"]?([^'")]+)/g)) {
    if (/^(?:#|data:)/.test(url)) continue;
    assert(!thirdParty(url), `${file}: loads a third-party resource: ${url}`);
    await mustExist(url, file);
  }
  assert(!/@import/.test(css), `${file}: no @import`);
}
for (const file of scripts) {
  const js = await read(file);
  assert(!/(?:fetch|import)\(\s*['"`]https?:/.test(js) && !/new (?:XMLHttpRequest|WebSocket|EventSource)\b/.test(js), `${file}: no network requests to other origins`);
}

// Every Download link is the single stable constant from content.mjs. The build writes it into each <a data-download>.
assert.equal(brand.links.download,DOWNLOAD_URL);
assert.match(DOWNLOAD_URL,/^https:\/\/github\.com\/LMC-Karma\/BetterTile\/releases\/latest(?:\/download\/BetterTile\.dmg)?$/,'Download link is a latest-release URL');
let downloadCount = 0;
for (const file of pages) {
  const html = await read(file);
  for (const [tag, attrs, inner] of html.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/g)) {
    const href = attrs.match(/\bhref="([^"]*)"/)?.[1];
    // App downloads say "Download", "Download for Mac" or "Download BetterTile". Asset downloads on the brand page name the file.
    const isDownload = /^Download(?: for Mac| BetterTile)?$/.test(visibleText(inner).trim());
    if (/\bdata-download\b/.test(attrs) || isDownload) {
      assert.equal(href, DOWNLOAD_URL, `${file}: Download link must be DOWNLOAD_URL: ${tag.slice(0, 120)}`);
      downloadCount++;
    }
    if (file !== 'brand.html' && isDownload) assert(/\bdata-download\b/.test(attrs), `${file}: Download link needs data-download so the build sets it: ${tag.slice(0, 120)}`);
  }
  assert(!html.includes('/releases/download/'),`${file}: no version-specific download link`);
}
const html = await read('index.html');
assert.equal((html.match(/\bdata-download\b/g)||[]).length,4,'Home page: header, hero, closing and footer Download links');
assert(downloadCount>=5,'Download links found');

// Home page product facts and behaviour.
assert(html.includes('Apple silicon'),'Page states the Apple silicon requirement');
assert(html.includes('macOS 26 or later'),'Page states the macOS requirement');
assert(html.includes('notarized by Apple'),'Install steps say the app is notarized');
assert(!/Open(?:&nbsp;|\s)Anyway/.test(html),'No Open Anyway step remains');
assert(html.includes('Update checks'),'Privacy copy explains update checks');
assert(!/\b(?:Bento|ghost preview)\b/i.test(visibleText(html)),'Visible copy uses Adaptive and Resize Preview');
assert(!/theme-toggle|data-theme="light"/.test(html),'Midnight only');
const videos = [...html.matchAll(/<video\b[^>]*>/g)].map(([tag]) => tag);
assert.equal(videos.length,12,'The tour and eleven feature videos');
for (const tag of videos) {
  assert(/\bmuted\b/.test(tag) && /\bplaysinline\b/.test(tag) && /preload="none"/.test(tag) && !/\bautoplay\b/.test(tag),`Silent, inline, lazy video without autoplay: ${tag.slice(0, 80)}`);
  assert(/poster="assets\/media\/[\w-]+\.jpg"/.test(tag),'Each video has a local poster');
}
assert(/<figure[^>]*id="tour"/.test(html) && !/data-play="manual"/.test(html),'The tour plays in view like the feature demos');
assert(html.includes('<source src="assets/media/overview.mp4"'),'The tour is the overview video');
// Phones (600 px and narrower) get the small -phone encode; the desktop file stays the fallback after it.
for (const [, inner] of html.matchAll(/<video\b[^>]*>([\s\S]*?)<\/video>/g)) {
  const sources = [...inner.matchAll(/<source\b[^>]*>/g)].map(([tag]) => tag);
  const stem = sources[1]?.match(/src="assets\/media\/([\w-]+)\.mp4"/)?.[1];
  assert(stem && sources.length === 2 && sources[0] === `<source media="(max-width: 600px)" src="assets/media/${stem}-phone.mp4" type="video/mp4">`,`Phone source before the desktop source: ${sources.join(' ')}`);
}
// Every Play/Pause button names its own video.
const playLabels = [...html.matchAll(/<button class="play"[^>]*>/g)].map(([tag]) => [tag.match(/data-label-play="([^"]+)"/)?.[1], tag.match(/data-label-pause="([^"]+)"/)?.[1]]);
assert.equal(playLabels.length,12,'One Play/Pause button per video');
for (const [play,pause] of playLabels) assert(play && pause && pause === play.replace(/^Play/,'Pause'),`Play/Pause labels: ${play} / ${pause}`);
assert.equal(new Set(playLabels.map(([play]) => play)).size,12,'Play buttons have distinct names');
// The silent tour has a real text description.
const tourDescription = html.match(/aria-describedby="([\w-]+)"/)?.[1];
assert(tourDescription && new RegExp(`<p[^>]*id="${tourDescription}"[^>]*>[^<]{200,}</p>`).test(html),'The tour has a text description');
// Signature check names the Team ID; the privacy notice is linked from the home page and the acknowledgements.
assert(html.includes('spctl -a -vv /Applications/BetterTile.app') && html.includes('2BZVM9DDGQ'),'Install section shows the signature check and Team ID');
for (const file of ['index.html','acknowledgements.html']) assert((await read(file)).includes('href="privacy.html"'),`${file} links the privacy notice`);
assert((await read('404.html')).includes(`href="${SITE}privacy.html"`),'404.html links the privacy notice');
assert((await read('sitemap.xml')).includes(`<loc>${SITE}privacy.html</loc>`),'Sitemap lists the privacy notice');
// The app README on main links these anchors and GIFs.
for (const id of ['overview','features','bento','adaptive','linked','snapping','saved-layouts','tabbed','wheel','keyboard','more','install','privacy','faq'])
  assert.equal((html.match(new RegExp(`\\sid="${id}"`,'g'))||[]).length,1,`Anchor #${id}`);
for (const stem of gifs) await access(`assets/media/gifs/bettertile-${stem}.gif`);
assert.deepEqual((await readdir('assets/media/gifs')).sort(),gifs.map(stem=>`bettertile-${stem}.gif`).sort(),'Only the GIFs the app README links are published');
for (const file of ['assets/identity/app-icon-native-dark-256.png','assets/identity/app-icon-native-light-256.png','assets/media/overview.jpg']) await access(file);
// Internal planning files, research, competitor logos and unused files stay out of the published site.
for (const gone of ['NOTES.md','BRAND-GUIDE.md','CAPTURE-PLAN.md','COPY.md','OUTLINE.md','VALIDATION.md','ACKNOWLEDGEMENTS.md','research','assets/competitors','assets/app-icon.png','assets/fonts/Inter-variable.ttf','assets/fonts/InstrumentSerif-Italic.ttf','assets/identity/app-icon-concept.svg','assets/identity/concept-frame.svg','assets/identity/concept-type.svg','assets/media/overview-tiled.jpg','redesign.css','redesign.js'])
  await assert.rejects(access(gone),`${gone} is not published`);

// No release-specific facts: the site must not show a version, date or size that can go stale.
assert(!/\b0\.[6-9]\b/.test(visibleText(html)),'Visible text names no 0.6+ version');
assert(!/Version \d|\d+(?:\.\d)? MB disk image|>Latest</.test(html),'No version, size or Latest badge');
// No promise about the future price.
for (const file of pages) assert(!/\bforever\b/i.test(visibleText(await read(file))),`${file}: no "forever" promise`);
for (const file of ['identity.mjs','assets/identity/social-preview.svg']) assert(!/\bforever\b/i.test(await read(file)),`${file}: no "forever" promise`);

// Link-preview and search metadata.
for (const tag of ['og:url','og:site_name','og:image','twitter:card','twitter:title','twitter:description','twitter:image'])assert(html.includes(`"${tag}"`),`Meta ${tag}`);
assert(html.includes(`<link rel="canonical" href="${SITE}">`),'Canonical URL');
const ldMatch=html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
assert(ldMatch,'JSON-LD present');
const ld=JSON.parse(ldMatch[1]);
assert.equal(ld['@type'],'SoftwareApplication');assert.equal(ld.operatingSystem,'macOS 26 or later');assert.equal(ld.applicationCategory,'UtilitiesApplication');
assert.equal(ld.offers.price,'0');assert.equal(ld.downloadUrl,DOWNLOAD_URL);assert(!('softwareVersion' in ld),'JSON-LD lists no version');
assert((await read('404.html')).includes('<meta name="robots" content="noindex">'),'404 page is not indexed');
assert.match(await read('robots.txt'),/^Sitemap: https:\/\/lmc-karma\.github\.io\/BetterTile\/sitemap\.xml$/m);
assert((await read('sitemap.xml')).includes(`<loc>${SITE}</loc>`));
await access('favicon.ico');

// Text contrast on the midnight ground (tokens from styles.css).
const css = await read('styles.css');
const token = name => css.match(new RegExp(`--${name}:\\s*#([0-9a-f]{6})`,'i'))[1];
function luminance(hex){const c=hex.match(/\w\w/g).map(s=>parseInt(s,16)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return c[0]*.2126+c[1]*.7152+c[2]*.0722;}
for(const [label,fg,bg,min] of [['Body',token('muted'),token('bg'),4.5],['Dim',token('dim'),token('bg'),4.5],['Primary',token('text'),token('bg'),4.5],['Link',token('link'),token('bg'),4.5],['White on wallpaper',token('on-field').padEnd(6,'f'),token('field-base'),4.5]]){
  const ratio=(Math.max(luminance(fg),luminance(bg))+.05)/(Math.min(luminance(fg),luminance(bg))+.05);assert(ratio>=min,`${label} contrast ${ratio.toFixed(2)}`);console.log(`${label} contrast: ${ratio.toFixed(2)}:1`);
}
console.log('Static paths, download links, third-party loads, semantics, product constraints, metadata and contrast passed.');
