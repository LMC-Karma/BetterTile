import { mkdir, copyFile } from 'node:fs/promises';
await mkdir('dist/assets', { recursive: true });
for (const file of ['index.html', 'styles.css', 'main.js', 'story.css', 'story.js', 'app-visuals.css', 'app-visuals.js', 'assets/app-icon.png']) {
  await copyFile(file, `dist/${file}`);
}
console.log('Built the static website in dist/.');
