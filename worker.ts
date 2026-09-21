// OpenNext generates this module during the build.
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore -- The module is absent before the first build.
import handler from './.open-next/worker.js';

const applications = {
  '/made': 'MADE_SITE',
  '/previral': 'PREVIRAL_SITE',
  '/shotreel': 'WEB_SHORTREEL',
  '/stint': 'STINT_SITE',
  '/stream': 'STREAM_SITE',
} as const;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const { pathname } = url;
    // Each app is built for its mount. Preserve URLs, bodies, and streams.
    if (url.hostname === 'blau.app') {
      for (const [mount, binding] of Object.entries(applications)) {
        if (pathname === mount || pathname.startsWith(`${mount}/`)) {
          return env[binding].fetch(request);
        }
      }
    }

    if (pathname === '/' || pathname.startsWith('/_next/')) {
      return handler.fetch(request, env, ctx);
    }

    // The made Worker serves assets under /made; preserve the complete URL.
    return env.MADE_SITE.fetch(request);
  },
} satisfies ExportedHandler<CloudflareEnv>;
