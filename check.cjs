const assert = require('node:assert/strict');
const fs = require('node:fs');
const { clamp, keyMove } = require('./main.js');
const { storyFrame } = require('./story.js');
const { sectorPath, wheelMarkup, innerActions, outerActions, placements } = require('./app-visuals.js');
assert.equal(new Set([...innerActions, ...outerActions]).size, 16, 'Two distinct rings of eight actions');
assert.equal(outerActions[7], 'Repair Bento');
assert.equal((wheelMarkup(true).match(/role="button"/g) || []).length, 17, 'Sixteen sectors and one cancel hub');
assert.ok(!wheelMarkup().includes('tabindex'), 'Story wheel is decorative, not focusable');
const firstPoint = path => path.match(/^M([\d.-]+) ([\d.-]+)/).slice(1).map(Number);
const top = firstPoint(sectorPath(23, 68, 0));
const right = firstPoint(sectorPath(23, 68, 2));
assert.ok(top[0] < 0 && top[1] < -23, 'Top sector stays above the hub');
assert.ok(Math.abs(top[0] - right[1]) < .001 && Math.abs(top[1] + right[0]) < .001, 'Sector geometry rotates clockwise by 90 degrees');
for (const action of innerActions) {
  const [x, y, width, height] = placements[action];
  assert.ok(x >= 0 && y >= 0 && x + width <= 1 && y + height <= 1, `${action} fits on screen`);
}

assert.deepEqual(storyFrame(-1), storyFrame(0), 'Story clamps before its first chapter');
assert.deepEqual(storyFrame(9), storyFrame(4), 'Story clamps after its last chapter');
for (const progress of [1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]) {
  const [studio, notes, music] = storyFrame(progress);
  assert.equal(notes[0] + notes[2] + 2, studio[0], 'Linked windows keep their shared gap');
  if (progress >= 3) assert.equal(studio[1] + studio[3] + 2, music[1], 'Bento makes room without overlap');
}
assert.equal(storyFrame(2)[2][4], 0, 'Music starts hidden');
assert.equal(storyFrame(3)[2][4], 1, 'Music joins the Bento layout');

assert.equal(clamp(-100), 25);
assert.equal(clamp(54.6), 55);
assert.equal(clamp(100), 75);
assert.deepEqual(keyMove(50, 50, 'ArrowRight'), [52, 50]);
assert.deepEqual(keyMove(50, 50, 'ArrowUp', true), [50, 40]);
assert.deepEqual(keyMove(73, 25, 'ArrowRight', true), [75, 25]);
assert.deepEqual(keyMove(63, 72, 'Home'), [50, 50]);
assert.equal(keyMove(50, 50, 'Escape'), null);

const html = fs.readFileSync('index.html', 'utf8');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
assert.equal(new Set(ids).size, ids.length, 'Duplicate HTML ids');
for (const [, anchor] of html.matchAll(/href="#([^"]+)"/g)) assert.ok(ids.includes(anchor), `Missing anchor: ${anchor}`);
for (const [, path] of html.matchAll(/(?:src|href)="((?:assets\/|styles\.|main\.|story\.|app-visuals\.)[^"]+)"/g)) assert.ok(fs.existsSync(path), `Missing asset: ${path}`);
assert.equal((html.match(/<h1\b/g) || []).length, 1);

const pageButtons = [...html.matchAll(/data-demo-page="([^"]+)"/g)].map((match) => match[1]);
const pagePanels = [...html.matchAll(/data-page-panel="([^"]+)"/g)].map((match) => match[1]);
assert.deepEqual([...pageButtons].sort(), [...pagePanels].sort(), 'Every demo navigation item has one panel');
assert.ok(html.includes('Native') && html.includes('Bento'));
assert.ok(html.includes('No app settings or real windows are changed.'));

console.log('Passed: story geometry, demo bounds, keyboard movement, page mapping, anchors, and assets.');
