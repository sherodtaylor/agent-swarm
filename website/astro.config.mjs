import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://sherodtaylor.github.io',
  base: '/agent-smith',
  trailingSlash: 'never',
  output: 'static',
  integrations: [
    // Starlight first — it injects astro-expressive-code which must precede mdx().
    starlight({
      title: 'agent-smith',
      customCss: ['./src/styles/tokens.css', './src/styles/global.css'],
      // We provide our own terminal-styled 404 page at src/pages/404.astro.
      disable404Route: true,
      sidebar: [
        { label: 'Getting Started', slug: 'getting-started' },
        { label: 'Architecture',    slug: 'architecture' },
        { label: 'Agents',          slug: 'agents' },
        { label: 'Security',        slug: 'security' },
        { label: 'Operations',      slug: 'operations' },
        { label: 'Contributing',    slug: 'contributing' },
        { label: 'Roadmap',         slug: 'roadmap' },
      ],
      // Dark-only — disable the toggle (v1 spec §1.2).
      components: {
        ThemeProvider: './src/components/empty.astro',
        ThemeSelect:   './src/components/empty.astro',
      },
    }),
    mdx(),
    sitemap(),
  ],
});
