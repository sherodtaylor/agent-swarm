// Generate website/public/og-image.png at exactly 1280x640 from the brand
// palette and the existing pixel sprites. We render an SVG and rasterise it
// via `sharp`. Run with: `bun run scripts/generate-og-image.mjs` (or `node`).
//
// Why an SVG → PNG pipeline rather than ImageMagick: the build container has
// no `convert`/`rsvg-convert`/`inkscape`, but `sharp` is already a transitive
// dep of the website toolchain.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = dirname(fileURLToPath(import.meta.url));
const publicDir = resolve(here, '..', 'public');

// Brand tokens (mirror of src/styles/tokens.css).
const BG       = '#0b0d10';
const BG_ELEV  = '#13171b';
const FG       = '#d4d7dc';
const FG_MUTED = '#7a818c';
const ACCENT   = '#5fbf8d';
const ACCENT_W = '#d4a85f';

// Extract the inner shape data (everything between the outermost <svg…> and
// </svg>) so we can embed the sprite into a larger composition with our own
// transform.
function spriteInner(filename) {
  const raw = readFileSync(resolve(publicDir, 'sprites', filename), 'utf8');
  const open = raw.indexOf('>');
  const close = raw.lastIndexOf('</svg>');
  return raw.slice(open + 1, close);
}

// Sprites are 16x16. We scale them up by 14× → 224×224 each, side by side
// near the bottom-right of the card.
const SPRITE_SCALE = 14;
const SPRITE_SIZE = 16 * SPRITE_SCALE; // 224
const SPRITE_Y = 640 - SPRITE_SIZE - 56;
const DEVBOT_X = 1280 - SPRITE_SIZE - 80;
const INFRABOT_X = DEVBOT_X - SPRITE_SIZE - 32;

const devbotInner = spriteInner('devbot.svg');
const infrabotInner = spriteInner('infrabot.svg');

// `currentColor` inside sprite resolves to the wrapping <g>'s `color` attr.
// The accent fills are already inlined via var() fallbacks, but for raster
// output we replace them with explicit hex values so sharp's SVG renderer
// (resvg) doesn't have to resolve CSS variables.
function inlineColors(svgFragment) {
  return svgFragment
    .replaceAll('var(--accent,#5fbf8d)', ACCENT)
    .replaceAll('var(--accent-warn,#d4a85f)', ACCENT_W);
}

const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="640" viewBox="0 0 1280 640">
  <defs>
    <style>
      .h1 { font: 700 76px 'JetBrains Mono', ui-monospace, Menlo, monospace; fill: ${FG}; }
      .h1-accent { font: 700 76px 'JetBrains Mono', ui-monospace, Menlo, monospace; fill: ${ACCENT}; }
      .sub { font: 400 28px 'JetBrains Mono', ui-monospace, Menlo, monospace; fill: ${FG_MUTED}; }
      .mono { font: 400 22px 'JetBrains Mono', ui-monospace, Menlo, monospace; fill: ${FG_MUTED}; }
      .name { font: 700 24px 'JetBrains Mono', ui-monospace, Menlo, monospace; fill: ${FG}; }
    </style>
  </defs>

  <!-- background -->
  <rect width="1280" height="640" fill="${BG}"/>

  <!-- subtle elevated band along the bottom for "terminal floor" feel -->
  <rect x="0" y="556" width="1280" height="84" fill="${BG_ELEV}"/>

  <!-- top-left brand mark / shell prompt -->
  <text x="80" y="120" class="mono">$ agent-smith</text>

  <!-- headline (two lines) -->
  <text x="80" y="220" class="h1">your sandbox</text>
  <text x="80" y="304" class="h1">workforce of</text>
  <text x="80" y="388" class="h1-accent">AI engineers.</text>

  <!-- sub-tagline -->
  <text x="80" y="448" class="sub">a framework for force-multiplier agents</text>

  <!-- footer URL -->
  <text x="80" y="608" class="mono">github.com/sherodtaylor/agent-smith</text>

  <!-- right-side sprites: InfraBot + DevBot, scaled and labelled -->
  <g transform="translate(${INFRABOT_X} ${SPRITE_Y}) scale(${SPRITE_SCALE})" color="${FG}">
    ${inlineColors(infrabotInner)}
  </g>
  <text x="${INFRABOT_X + SPRITE_SIZE / 2}" y="${SPRITE_Y + SPRITE_SIZE + 32}" text-anchor="middle" class="name">InfraBot</text>

  <g transform="translate(${DEVBOT_X} ${SPRITE_Y}) scale(${SPRITE_SCALE})" color="${FG}">
    ${inlineColors(devbotInner)}
  </g>
  <text x="${DEVBOT_X + SPRITE_SIZE / 2}" y="${SPRITE_Y + SPRITE_SIZE + 32}" text-anchor="middle" class="name">DevBot</text>
</svg>
`;

const outPath = resolve(publicDir, 'og-image.png');
const outSvgPath = resolve(publicDir, 'og-image.svg');

// Keep the SVG source on disk too — useful for hand-tweaks later.
writeFileSync(outSvgPath, svg);

await sharp(Buffer.from(svg))
  .resize(1280, 640)
  .png({ compressionLevel: 9 })
  .toFile(outPath);

const meta = await sharp(outPath).metadata();
console.log(`wrote ${outPath} — ${meta.width}x${meta.height}`);
if (meta.width !== 1280 || meta.height !== 640) {
  console.error('ERROR: dimensions do not match 1280x640');
  process.exit(1);
}
