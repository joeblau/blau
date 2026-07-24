import { readdir, stat } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist');
const cssBudget = 35_000;

async function filesUnder(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path));
    else files.push(path);
  }
  return files;
}

const css = (await filesUnder(dist)).filter((path) => extname(path) === '.css');
const cssBytes = (await Promise.all(css.map((path) => stat(path))))
  .reduce((sum, item) => sum + item.size, 0);

if (cssBytes > cssBudget) {
  console.error(`Web build budget failed: CSS totals ${cssBytes} bytes (budget ${cssBudget})`);
  process.exitCode = 1;
} else {
  console.log(`Web build budget: CSS / ${cssBytes} bytes`);
}
