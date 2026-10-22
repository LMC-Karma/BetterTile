// Refreshes release.json from GitHub's public releases API. Run `npm run release` after each app release.
// The website build reads only release.json, so it stays offline and repeatable.
import { writeFile } from 'node:fs/promises';
const repo = 'LMC-Karma/BetterTile';
const response = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=10`, {headers: {Accept: 'application/vnd.github+json'}});
if (!response.ok) throw Error(`GitHub releases request failed: ${response.status}`);
const releases = (await response.json()).filter(r => !r.draft);
const version = r => r.tag_name.replace(/^v/, '').replace(/-beta$/, ' beta');
const date = r => new Date(r.published_at).toLocaleDateString('en-GB', {day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC'});
const latest = releases[0], dmg = latest.assets.find(a => a.name.endsWith('.dmg'));
if (!dmg) throw Error(`${latest.tag_name} has no disk image`);
const data = {
  checked: new Date().toISOString().slice(0, 10),
  latest: {version: version(latest), tag: latest.tag_name, date: date(latest), notes: latest.html_url, dmg: dmg.browser_download_url, dmgName: dmg.name, sizeMB: Math.round(dmg.size / 1048576 * 10) / 10},
  recent: releases.slice(0, 3).map(r => ({version: version(r), date: date(r), notes: r.html_url})),
};
await writeFile('release.json', JSON.stringify(data, null, 2) + '\n');
console.log(`release.json: ${data.latest.version}, ${data.latest.date}, ${data.latest.dmgName}`);
