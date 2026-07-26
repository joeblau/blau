import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://blau.app',
  // The CSP in public/_headers forbids inline styles, so always emit external CSS.
  build: { inlineStylesheets: 'never' },
  vite: {
    build: {
      // The CSP also forbids inline scripts, so never inline small bundles.
      assetsInlineLimit: 0,
    },
  },
});
