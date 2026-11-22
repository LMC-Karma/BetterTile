import assert from 'node:assert/strict';
import { readFile, access, readdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { brand, comparison, media, gifs, release } from './content.mjs';
for(const file of ['index.html','brand.html','export.html','404.html','acknowledgements.html']){
  const html=await readFile(file,'utf8');
  assert.equal((html.match(/<h1[\s>]/g)||[]).length,1,`${file}: one main heading`);
  for(const [,url] of html.matchAll(/(?:href|src|poster)="([^"]+)"/g)){
    if(/^(?:https?:|data:|#)/.test(url))continue;
    const path=url.split('#')[0];
    if(path)await access(resolve(dirname(file),path));
  }
}
const html=await readFile('index.html','utf8');
assert(html.includes('data-theme="dark"'));
assert(!html.includes('app-visuals.js'));
assert(!html.includes('data-bento-toggle'));
assert(!html.includes('data-snap-next'));
assert(!html.includes('shared-edge'));
assert(!html.includes('data-replay'));
assert(!html.includes('appearance-picker'));
assert(!html.includes('assets/demo.mp4'));
assert.equal((html.match(/<video /g)||[]).length,12);
assert(!html.includes('theme-toggle')&&!html.includes('data-theme="light"')); // Midnight only
assert(html.includes('data-video-src="assets/media/overview.mp4"'));
assert(html.includes('notarization'));
assert(html.includes('Apple silicon'),'Page states the Apple silicon requirement');
assert(!/>[^<]*\b(?:Bento|ghost preview)\b/i.test(html),'Visible copy uses Adaptive and Resize Preview');
// The app README links these anchors and GIFs.
for(const id of ['overview','features','bento','adaptive','linked','snapping','saved-layouts','tabbed','wheel','keyboard','more'])assert(html.includes(`id="${id}"`),`Anchor #${id}`);
for(const stem of gifs)await access(`assets/media/gifs/bettertile-${stem}.gif`);
assert(html.includes('Update checks and downloads contact GitHub'));
assert(html.includes('hosted on GitHub Pages, which keeps its own request logs'),'Privacy copy names the website host');
// Internal planning files, research, competitor logos and unused media stay out of the published site.
for(const gone of ['BRAND-GUIDE.md','CAPTURE-PLAN.md','COPY.md','OUTLINE.md','VALIDATION.md','ACKNOWLEDGEMENTS.md','research','assets/competitors','assets/app-icon.png','assets/fonts/Inter-variable.ttf','assets/fonts/InstrumentSerif-Italic.ttf','assets/identity/app-icon-concept.svg','assets/identity/concept-frame.svg','assets/identity/concept-type.svg'])
  await assert.rejects(access(gone),`${gone} is not published`);
for(const file of ['index.html','brand.html','acknowledgements.html','404.html']){
  const page=await readFile(file,'utf8');
  assert(!/(?:href|src)="(?:\.\/)?(?:research\/|[A-Z-]+\.md)/.test(page),`${file}: no link to an internal file`);
  assert(!/competitors\//.test(page),`${file}: no competitor logos`);
}
// The app README on main links these files, so they must stay published.
for(const file of ['assets/identity/app-icon-native-dark-256.png','assets/identity/app-icon-native-light-256.png','assets/media/overview.jpg'])await access(file);
assert.deepEqual((await readdir('assets/media/gifs')).sort(),gifs.map(stem=>`bettertile-${stem}.gif`).sort(),'Only the GIFs the app README links are published');
// Link-preview and search metadata.
for(const tag of ['og:url','og:site_name','twitter:title','twitter:description','twitter:image'])assert(html.includes(`"${tag}"`),`Meta ${tag}`);
const ldMatch=html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
assert(ldMatch,'JSON-LD present');
const ld=JSON.parse(ldMatch[1]);
assert.equal(ld['@type'],'SoftwareApplication');assert.equal(ld.operatingSystem,'macOS 26 or later');assert.equal(ld.applicationCategory,'UtilitiesApplication');
assert.equal(ld.offers.price,'0');assert.equal(ld.downloadUrl,brand.links.download);assert.equal(ld.softwareVersion,release.latest.tag.replace(/^v/,''));
assert.match(await readFile('robots.txt','utf8'),/^Sitemap: https:\/\/lmc-karma\.github\.io\/BetterTile\/sitemap\.xml$/m);
assert((await readFile('sitemap.xml','utf8')).includes(`<loc>${brand.site}</loc>`));
await access('favicon.ico');
// The page text must not carry an older release as the latest one.
const older=release.recent.slice(1).map(r=>r.version.replace(' beta',''));
for(const version of older)assert(!html.includes(`Version ${version}`),`Page does not present ${version} as current`);
assert(!/\$\s?\d|US\$/i.test(html.slice(html.indexOf('comparison-section'),html.indexOf('id="start"'))),'Comparison shows no third-party prices');
assert.equal(comparison.length,4);
assert.match(brand.links.download,/^https:\/\/github\.com\/LMC-Karma\/BetterTile\/releases\/download\/v[\d.]+(-beta)?\/BetterTile-[\d.]+(-beta)?\.dmg$/,'Download links the latest disk image');
assert(html.includes(brand.links.download)&&html.includes(`Version ${brand.version}`),'Page shows the release from release.json');
for(const slot of Object.values(media)){
  assert.equal(slot.kind,'video');
  assert(slot.width===1920&&slot.height===1080);
    await access(slot.src);if(slot.poster)await access(slot.poster);
  assert(slot.width>0&&slot.height>0);
}
function luminance(hex){const c=hex.match(/\w\w/g).map(s=>parseInt(s,16)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return c[0]*.2126+c[1]*.7152+c[2]*.0722;}
for(const [label,fg,bg,min] of [["Body", "aab4c4", "07090d", 4.5], ["Primary", "f5f7fc", "07090d", 4.5], ["Button", "ffffff", "315cf4", 4.5], ["Button hover", "ffffff", "4266ee", 4.5], ["Teal control", "102a22", "63dec0", 4.5], ["Muted panel", "aab4c4", "1b2331", 4.5]]){
  const ratio=(Math.max(luminance(fg),luminance(bg))+.05)/(Math.min(luminance(fg),luminance(bg))+.05);assert(ratio>=min,label);console.log(`${label} contrast: ${ratio.toFixed(2)}:1`);
}
console.log('Static paths, semantics, product constraints, media configuration, and contrast passed.');
