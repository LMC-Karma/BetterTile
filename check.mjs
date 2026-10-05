import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { brand, comparison, media } from './content.mjs';
for(const file of ['index.html','brand.html','export.html']){
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
assert.equal((html.match(/<video /g)||[]).length,7);
assert(html.includes('class="theme-toggle"'));
assert(html.includes('data-video-src="assets/media/overview.mp4"'));
assert(html.includes('notarization'));
assert(html.includes('Update checks and downloads contact GitHub'));
assert.equal(comparison.length,4);
assert.equal(brand.links.download,'https://github.com/LMC-Karma/BetterTile/releases/latest');
for(const slot of Object.values(media)){
  assert.equal(slot.kind,'video');
  assert(slot.width===1920&&slot.height===1080);
    await access(slot.src);if(slot.poster)await access(slot.poster);
  assert(slot.width>0&&slot.height>0);
}
function luminance(hex){const c=hex.match(/\w\w/g).map(s=>parseInt(s,16)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return c[0]*.2126+c[1]*.7152+c[2]*.0722;}
for(const [label,fg,bg,min] of [["Body", "aab4c4", "07090d", 4.5], ["Primary", "f5f7fc", "07090d", 4.5], ["Button", "ffffff", "315cf4", 4.5], ["Button hover", "ffffff", "4266ee", 4.5], ["Teal control", "102a22", "63dec0", 4.5], ["Muted panel", "aab4c4", "1b2331", 4.5], ["Light primary", "172338", "f6f8fc", 4.5], ["Light secondary", "4e6078", "f6f8fc", 4.5], ["Light teal", "087158", "f6f8fc", 4.5]]){
  const ratio=(Math.max(luminance(fg),luminance(bg))+.05)/(Math.min(luminance(fg),luminance(bg))+.05);assert(ratio>=min,label);console.log(`${label} contrast: ${ratio.toFixed(2)}:1`);
}
console.log('Static paths, semantics, product constraints, media configuration, and contrast passed.');
