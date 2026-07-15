// Generate the Open Graph share image (public/og.png) from scripts/og.svg.
// Run with `bun run og` (or `node scripts/gen-og.mjs`). The PNG is committed,
// so the CI build serves it statically without re-rendering.
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = fileURLToPath(new URL('.', import.meta.url));
const svg = await readFile(here + 'og.svg');
const output = here + '../public/og.png';
const stamp = here + 'og.sha256';
const renderConfig = {
  version: 1,
  density: 144,
  width: 1200,
  height: 630,
  fit: 'fill',
  format: 'png',
  quality: 90,
};
const sourceDigest = createHash('sha256')
  .update(svg)
  .update('\0')
  .update(JSON.stringify(renderConfig))
  .digest('hex');

if (process.argv.includes('--check')) {
  const committed = await readFile(output);
  const committedDigest = (await readFile(stamp, 'utf8')).trim();
  if (committedDigest !== sourceDigest) {
    throw new Error('public/og.png is stale; run `bun run og` and commit it');
  }

  // Rendering text can differ across operating systems because librsvg resolves
  // system fonts differently. Validate the committed artifact without re-rendering.
  const metadata = await sharp(committed).metadata();
  if (
    metadata.format !== renderConfig.format ||
    metadata.width !== renderConfig.width ||
    metadata.height !== renderConfig.height
  ) {
    throw new Error('public/og.png is invalid; run `bun run og` and commit it');
  }
  console.log(`og.png source and metadata are current — ${(committed.length / 1024).toFixed(1)} KB`);
} else {
  const png = await sharp(svg, { density: renderConfig.density })
    .resize(renderConfig.width, renderConfig.height, { fit: renderConfig.fit })
    .png({ quality: renderConfig.quality })
    .toBuffer();
  await writeFile(output, png);
  await writeFile(stamp, `${sourceDigest}\n`);
  console.log(`og.png written — ${(png.length / 1024).toFixed(1)} KB`);
}
