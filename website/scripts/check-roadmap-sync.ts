#!/usr/bin/env bun
/**
 * check-roadmap-sync.ts — verify the website's roadmap copy hasn't drifted from
 * the canonical source in `docs/roadmap-v1.md` at the repo root.
 *
 * Strategy: strip the website-only chrome (frontmatter + Aside import + JSX
 * Aside block) off the .mdx file, then assert the remaining body contains
 * the start of the repo roadmap. "Contains" rather than equals so the script
 * tolerates trailing whitespace and intentional formatting tweaks; the spirit
 * is drift detection, not exact match.
 */

import { readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoadmapPath = join(here, '..', '..', 'docs', 'roadmap-v1.md');
const siteRoadmapPath = join(here, '..', 'src', 'content', 'docs', 'roadmap.mdx');

const repoRoadmap = await readFile(repoRoadmapPath, 'utf8');
const siteRoadmapRaw = await readFile(siteRoadmapPath, 'utf8');

// Strip frontmatter (--- ... ---), MDX imports, and the JSX <Aside>…</Aside>
// preamble. What remains should be the verbatim repo body.
const siteRoadmap = siteRoadmapRaw
  .replace(/^---[\s\S]*?---\n/, '')              // YAML frontmatter
  .replace(/^\s*import\s+[^;\n]+;?\n/gm, '')      // MDX imports
  .replace(/^\s*<Aside[\s\S]*?<\/Aside>\s*/m, '') // JSX Aside block
  .trimStart();

// Compare on the first N chars to avoid hidden trailing-whitespace mismatches
// and to keep the failure output readable. 1500 chars covers Vision + the
// "What v1 must prove" table — enough to detect any real drift.
const slice = 1500;
const repoHead = repoRoadmap.slice(0, slice);

if (!siteRoadmap.includes(repoHead)) {
  console.error('roadmap drift detected');
  console.error('---');
  console.error('expected (repo, first', slice, 'chars):');
  console.error(repoHead);
  console.error('---');
  console.error('site body starts with:');
  console.error(siteRoadmap.slice(0, slice));
  process.exit(1);
}

console.log('roadmap docs in sync ✓');
