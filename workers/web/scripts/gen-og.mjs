// Generate the Open Graph share image (public/og.png) from scripts/og.svg.
// Run with `bun run og` (or `node scripts/gen-og.mjs`). The PNG is committed,
// so the CI build serves it statically without re-rendering (avoids font drift).
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = fileURLToPath(new URL('.', import.meta.url));
const svg = await readFile(here + 'og.svg');

const png = await sharp(svg, { density: 144 })
  .resize(1200, 630, { fit: 'fill' })
  .png({ quality: 90 })
  .toBuffer();

const output = here + '../public/og.png';
if (process.argv.includes('--check')) {
  const committed = await readFile(output);
  if (!committed.equals(png)) {
    throw new Error('public/og.png is stale; run `bun run og` and commit it');
  }
  console.log(`og.png is deterministic and current — ${(png.length / 1024).toFixed(1)} KB`);
} else {
  await writeFile(output, png);
  console.log(`og.png written — ${(png.length / 1024).toFixed(1)} KB`);
}
