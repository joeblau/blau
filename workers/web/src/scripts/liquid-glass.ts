/*
 * Liquid Glass edge refraction for the landing buttons, after the technique
 * described in https://aave.com/design/building-glass-for-the-web: a
 * displacement map is generated from each button's lens shape and fed to an
 * SVG feDisplacementMap filter that the stylesheet references through
 * backdrop-filter. Real glass bends light mostly at its curved rim, so the
 * map leaves the lens interior neutral and pushes hardest at the edge, with
 * a small per-channel scale split for the chromatic fringe. Rim and
 * specular lighting live in global.css: an in-filter feSpecularLighting
 * pass was tried and washes the whole lens at button sizes, because the
 * curved zone spans most of a small button.
 *
 * Only Chromium implements url() in backdrop-filter, so the enhancement is
 * gated on Chromium; every other browser keeps the frosted-glass material
 * from global.css. Maps are rebuilt only when a lens changes shape, never
 * when it merely moves, and each map is computed with four-fold symmetry:
 * one quadrant is evaluated and mirrored with negated X/Y components.
 */

const SVG_NS = 'http://www.w3.org/2000/svg';
const MAX_LENSES = 6;
const MAX_DPR = 2;

/* Lens profile, in CSS pixels, in the article's vocabulary: `depth` is how
 * far inward the bend reaches from the edge, `scale` is the peak sample
 * offset at the rim, `curvature` shapes the lens profile, and `chroma`
 * splits the per-channel refraction. */
const DEPTH_FRACTION = 0.22;
const DEPTH_MIN = 7;
const DEPTH_MAX = 12;
const SCALE = 24;
const CURVATURE = 0.96;
const CHROMA = 0.2;
/* Full channel swing maps to +/- SCALE * 1.2 px of sample offset, so the
 * chroma split can never push an encoded value out of range. */
const DISPLACEMENT_SCALE = SCALE * 2 * 1.2;

type LensGeometry = {
  key: string;
  width: number;
  height: number;
  radius: number;
};

type NavigatorUA = Navigator & { userAgentData?: { brands: { brand: string }[] } };

const clamp = (value: number, minimum: number, maximum: number): number =>
  Math.min(maximum, Math.max(minimum, value));

const isChromium = Boolean((navigator as NavigatorUA).userAgentData);
const buttons = isChromium
  ? Array.from(document.querySelectorAll<HTMLElement>('.landing .button'))
  : [];

function svgEl<K extends keyof SVGElementTagNameMap>(
  name: K,
  attributes: Record<string, string>,
): SVGElementTagNameMap[K] {
  const node = document.createElementNS(SVG_NS, name);
  for (const [key, value] of Object.entries(attributes)) {
    node.setAttribute(key, value);
  }
  return node;
}

/* Signed distance to the rounded-rect lens boundary (negative inside). */
function roundedRectSdf(
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
): number {
  const qx = Math.abs(x - width / 2) - (width / 2 - radius);
  const qy = Math.abs(y - height / 2) - (height / 2 - radius);
  const outwardX = Math.max(qx, 0);
  const outwardY = Math.max(qy, 0);
  return Math.hypot(outwardX, outwardY) + Math.min(Math.max(qx, qy), 0) - radius;
}

function lensDepth(lens: LensGeometry): number {
  return clamp(Math.min(lens.width, lens.height) * DEPTH_FRACTION, DEPTH_MIN, DEPTH_MAX);
}

/* Sample offset in map pixels: zero in the flat interior, ramping up toward
 * the rim along the slope of a circular lens profile, pointing inward so
 * edge content reads as magnified through the glass. */
function sampleOffset(
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
  depth: number,
  maxBend: number,
): [number, number] {
  const distance = roundedRectSdf(x, y, width, height, radius);
  if (distance >= 0) return [0, 0];
  const edge = Math.min(1, -distance / depth); // 0 in the flat interior, 1 at the rim
  if (edge <= 0) return [0, 0];
  const slope = edge / Math.sqrt(1 - CURVATURE * edge * edge) / 5; // normalized to 1 at the rim
  const bend = slope * maxBend;
  const epsilon = 0.75;
  const normalX =
    roundedRectSdf(x + epsilon, y, width, height, radius) -
    roundedRectSdf(x - epsilon, y, width, height, radius);
  const normalY =
    roundedRectSdf(x, y + epsilon, width, height, radius) -
    roundedRectSdf(x, y - epsilon, width, height, radius);
  const length = Math.hypot(normalX, normalY) || 1;
  return [(-normalX / length) * bend, (-normalY / length) * bend];
}

function buildMapDataUrl(lens: LensGeometry, dpr: number): string {
  const width = Math.max(2, Math.round(lens.width * dpr));
  const height = Math.max(2, Math.round(lens.height * dpr));
  const radius = lens.radius * dpr;
  const depth = lensDepth(lens) * dpr;
  const maxBend = SCALE * dpr;

  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d');
  if (!context) return '';

  const image = context.createImageData(width, height);
  const encode = (offset: number): number =>
    clamp(Math.round(128 + (offset / dpr / DISPLACEMENT_SCALE) * 255), 0, 255);
  const write = (x: number, y: number, red: number, green: number): void => {
    const index = (y * width + x) * 4;
    image.data[index] = red;
    image.data[index + 1] = green;
    image.data[index + 2] = 128;
    image.data[index + 3] = 255;
  };

  /* Four-fold symmetry: evaluate the top-left quadrant and mirror it,
   * negating the X component across the vertical axis and the Y component
   * across the horizontal one. */
  for (let y = 0; y < Math.ceil(height / 2); y += 1) {
    for (let x = 0; x < Math.ceil(width / 2); x += 1) {
      const [dx, dy] = sampleOffset(x + 0.5, y + 0.5, width, height, radius, depth, maxBend);
      const red = encode(dx);
      const green = encode(dy);
      write(x, y, red, green);
      write(width - 1 - x, y, 256 - red, green);
      write(x, height - 1 - y, red, 256 - green);
      write(width - 1 - x, height - 1 - y, 256 - red, 256 - green);
    }
  }

  context.putImageData(image, 0, 0);
  return canvas.toDataURL('image/png');
}

/* Channel-keeping feColorMatrix rows; alpha is forced opaque because the
 * three passes are summed back together arithmetically. */
const CHANNEL_MATRICES: [name: string, scale: number, values: string][] = [
  ['red', 1 + CHROMA, '1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1'],
  ['green', 1, '0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 1'],
  ['blue', 1 - CHROMA, '0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 1'],
];

function buildFilter(id: string, lens: LensGeometry, dpr: number): SVGFilterElement {
  const filter = svgEl('filter', {
    id,
    filterUnits: 'userSpaceOnUse',
    primitiveUnits: 'userSpaceOnUse',
    x: '0',
    y: '0',
    width: String(lens.width),
    height: String(lens.height),
    'color-interpolation-filters': 'sRGB',
  });
  filter.append(
    svgEl('feImage', {
      result: 'lens-map',
      x: '0',
      y: '0',
      width: String(lens.width),
      height: String(lens.height),
      preserveAspectRatio: 'none',
      href: buildMapDataUrl(lens, dpr),
    }),
  );

  /* Chromatic fringe: each channel refracts at a slightly different scale,
   * strongest where the rim bends hardest. */
  let composite = '';
  for (const [name, factor, values] of CHANNEL_MATRICES) {
    filter.append(
      svgEl('feDisplacementMap', {
        in: 'SourceGraphic',
        in2: 'lens-map',
        scale: String(DISPLACEMENT_SCALE * factor),
        xChannelSelector: 'R',
        yChannelSelector: 'G',
        result: `refracted-${name}`,
      }),
      svgEl('feColorMatrix', {
        in: `refracted-${name}`,
        type: 'matrix',
        values,
        result: name,
      }),
    );
    composite =
      composite === ''
        ? name
        : (() => {
            const merged = `${composite}-${name}`;
            filter.append(
              svgEl('feComposite', {
                in: composite,
                in2: name,
                operator: 'arithmetic',
                k1: '0',
                k2: '1',
                k3: '1',
                k4: '0',
                result: merged,
              }),
            );
            return merged;
          })();
  }
  return filter;
}

if (buttons.length > 0) {
  const svg = svgEl('svg', {
    class: 'glass-defs',
    'aria-hidden': 'true',
    focusable: 'false',
    width: '0',
    height: '0',
  });
  const defs = svgEl('defs', {});
  svg.append(defs);
  document.body.append(svg);

  const rebuild = (): void => {
    const dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR);
    const keyByButton = new Map<HTMLElement, string>();
    const lenses: LensGeometry[] = [];

    for (const button of buttons) {
      const rect = button.getBoundingClientRect();
      const radius = parseFloat(getComputedStyle(button).borderTopLeftRadius) || 0;
      const key = `${Math.round(rect.width)}x${Math.round(rect.height)}r${Math.round(radius)}`;
      keyByButton.set(button, key);
      if (lenses.length < MAX_LENSES && !lenses.some((lens) => lens.key === key)) {
        lenses.push({ key, width: rect.width, height: rect.height, radius });
      }
    }

    defs.replaceChildren(
      ...lenses.map((lens, index) => buildFilter(`glass-lens-${index}`, lens, dpr)),
    );

    for (const button of buttons) {
      const index = lenses.findIndex((lens) => lens.key === keyByButton.get(button));
      if (index >= 0) {
        button.dataset.glassLens = String(index);
      } else {
        delete button.dataset.glassLens;
      }
    }
  };

  let scheduled = false;
  const requestRebuild = (): void => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      rebuild();
    });
  };

  const observer = new ResizeObserver(requestRebuild);
  for (const button of buttons) observer.observe(button);

  rebuild();
}

/* Module scope keeps top-level names out of the global script namespace. */
export {};
