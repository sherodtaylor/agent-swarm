# agent-smith website

Public marketing + docs site for [agent-smith](https://github.com/sherodtaylor/agent-smith).
Built with [Astro](https://astro.build) + [Starlight](https://starlight.astro.build),
deployed to GitHub Pages on every push to `main` that touches `website/**`,
`docs/**`, `README.md`, or `.github/workflows/website.yml`.

Operator playbook lives at [`docs/runbooks/website-deploy.md`](../docs/runbooks/website-deploy.md).

---

## Local dev

```sh
bun install
cp src/data/crew-status.example.json src/data/crew-status.json
bun run dev
```

The dev server boots at `http://localhost:4321/agent-smith`. The
`crew-status.json` copy is git-ignored — `refresh-crew-status.ts` rewrites it
on every CI build with live GitHub data, but local dev uses the example so
you don't need a token in your shell.

## Tests

```sh
bun test               # bun:test suite (refresh-crew-status, etc.)
bun run check          # astro check — type-checks .astro / .ts
bun run check:roadmap  # asserts roadmap MDX matches the source-of-truth list
```

CI runs all three on every push.

## Build

```sh
bun run build && bun run preview
```

`build` writes the static site to `./dist/`. `preview` serves it locally so
you can verify the production bundle (correct `base:` path, no dev-only
HMR scripts) before pushing.

## Custom-domain swap (when ready)

Four steps, in order:

1. Drop a `public/CNAME` file containing the apex/sub domain (e.g.
   `agentsmith.sherodtaylor.dev`).
2. In repo Settings → Pages → Custom domain, paste the same value and tick
   "Enforce HTTPS" once the cert provisions.
3. Flip `base: '/agent-smith'` → `base: '/'` and update `site:` to the new
   origin in `astro.config.mjs`. Rebuild and re-deploy.
4. Wait for DNS propagation + Let's Encrypt issuance (usually <15 min).
   The runbook covers rollback if anything in the chain breaks.

Until that's done the canonical URL is
`https://sherodtaylor.github.io/agent-smith/`.

## Analytics

**None for v1.** Deliberate choice:

- No third-party scripts means no consent banner, no GDPR/CCPA surface, no
  extra render-blocking JS on a site whose perf budget is tight.
- Traffic shape isn't actionable yet — this is a docs/landing site for an
  OSS project with a single-digit operator count. Adding analytics before
  there's a decision to make wastes the trade-off.
- GitHub already surfaces clone/visit counts under repo Insights for the
  rare case we want a sanity check.

If/when we ship a feature that needs measurement (e.g. comparing two CTA
copies), reach for [Plausible](https://plausible.io) or
[GoatCounter](https://www.goatcounter.com) — both are first-party-friendly
and don't require a banner. Revisit then, not before.
