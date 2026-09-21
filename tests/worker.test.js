import { beforeEach, describe, expect, mock, test } from 'bun:test';

// Exercise the actual router without requiring a generated OpenNext build.
const nextFetch = mock(async () => new Response('blau'));
mock.module('../.open-next/worker.js', () => ({ default: { fetch: nextFetch } }));
const { default: worker } = await import('../worker.ts');

let env;
const ctx = {};

beforeEach(() => {
  nextFetch.mockClear();
  env = {
    MADE_SITE: { fetch: mock(async () => new Response('made')) },
    WEB_SHORTREEL: { fetch: mock(async () => new Response('shortreel')) },
    PREVIRAL_SITE: { fetch: mock(async () => new Response('previral')) },
    STINT_SITE: { fetch: mock(async () => new Response('stint')) },
    STREAM_SITE: { fetch: mock(async () => new Response('stream')) },
  };
});

describe.each([
  ['/made', 'MADE_SITE'],
  ['/previral', 'PREVIRAL_SITE'],
  ['/stint', 'STINT_SITE'],
  ['/stream', 'STREAM_SITE'],
])('%s mount', (mount, binding) => {
  test.each(['', '/', '/nested/page', '/_next/static/app.js', '/icon.png', '?from=home&value=a%2Fb'])('forwards %s unchanged to the correct service', async (suffix) => {
    const request = new Request(`https://blau.app${mount}${suffix}`);
    await worker.fetch(request, env, ctx);
    expect(env[binding].fetch).toHaveBeenCalledTimes(1);
    expect(env[binding].fetch.mock.calls[0][0]).toBe(request);
    for (const [name, service] of Object.entries(env)) {
      if (name !== binding) expect(service.fetch).not.toHaveBeenCalled();
    }
    expect(nextFetch).not.toHaveBeenCalled();
  });

  test('preserves POST body and streamed response', async () => {
    const request = new Request(`https://blau.app${mount}/action?q=1`, {
      method: 'POST', body: 'payload', headers: { 'x-test': 'retained' },
    });
    const response = new Response(new ReadableStream({ start(c) { c.close(); } }), { status: 202 });
    env[binding].fetch.mockResolvedValueOnce(response);
    expect(await worker.fetch(request, env, ctx)).toBe(response);
    expect(env[binding].fetch.mock.calls[0][0]).toBe(request);
    expect(request.bodyUsed).toBe(false);
    expect(await request.text()).toBe('payload');
  });

  test.each(['s', '-other'])('does not claim lookalike prefix %s', async (suffix) => {
    const request = new Request(`https://blau.app${mount}${suffix}`);
    await worker.fetch(request, env, ctx);
    expect(env.MADE_SITE.fetch.mock.calls[0][0]).toBe(request);
    for (const [name, service] of Object.entries(env)) {
      if (name !== 'MADE_SITE') expect(service.fetch).not.toHaveBeenCalled();
    }
  });

  test('preserves fallback routing on other hosts', async () => {
    const request = new Request(`https://example.com${mount}`);
    await worker.fetch(request, env, ctx);
    expect(env.MADE_SITE.fetch.mock.calls[0][0]).toBe(request);
    for (const [name, service] of Object.entries(env)) {
      if (name !== 'MADE_SITE') expect(service.fetch).not.toHaveBeenCalled();
    }
  });
});

describe('ShortReel mount', () => {
  test.each([
    '/shotreel',
    '/shotreel/',
    '/shotreel/nested/page',
    '/shotreel/_next/static/chunks/app.js',
    '/shotreel/_next/static/styles.css',
    '/shotreel/icon.svg',
    '/shotreel/public-file.txt',
    '/shotreel?source=blau&value=a%2Fb&tag=one&tag=two',
    '/shotreel/nested?view=full',
  ])('forwards %s with its prefix and query intact', async (path) => {
    const request = new Request(`https://blau.app${path}`);
    expect(await (await worker.fetch(request, env, ctx)).text()).toBe('shortreel');
    expect(env.WEB_SHORTREEL.fetch).toHaveBeenCalledTimes(1);
    expect(env.WEB_SHORTREEL.fetch).toHaveBeenCalledWith(request);
    expect(env.MADE_SITE.fetch).not.toHaveBeenCalled();
    expect(nextFetch).not.toHaveBeenCalled();
  });

  test.each(['POST', 'PUT', 'PATCH', 'DELETE'])('preserves %s bodies and headers without consuming them', async (method) => {
    const request = new Request('https://blau.app/shotreel/api/draft?save=1', {
      method,
      headers: { 'content-type': 'application/json', authorization: 'Bearer test', 'x-custom': 'keep' },
      body: '{"draft":"hello"}',
    });
    await worker.fetch(request, env, ctx);
    const forwarded = env.WEB_SHORTREEL.fetch.mock.calls[0][0];
    expect(forwarded).toBe(request);
    expect(forwarded.method).toBe(method);
    expect(forwarded.headers.get('authorization')).toBe('Bearer test');
    expect(forwarded.headers.get('x-custom')).toBe('keep');
    expect(forwarded.bodyUsed).toBe(false);
    expect(await forwarded.text()).toBe('{"draft":"hello"}');
  });

  test.each(['HEAD', 'OPTIONS'])('forwards %s requests unchanged', async (method) => {
    const request = new Request('https://blau.app/shotreel', { method });
    await worker.fetch(request, env, ctx);
    expect(env.WEB_SHORTREEL.fetch).toHaveBeenCalledTimes(1);
    expect(env.WEB_SHORTREEL.fetch).toHaveBeenCalledWith(request);
  });

  test('preserves framework navigation headers and query', async () => {
    const request = new Request('https://blau.app/shotreel?_rsc=abc', {
      headers: { RSC: '1', 'Next-Router-State-Tree': '["",{}]', 'Next-Router-Prefetch': '1' },
    });
    await worker.fetch(request, env, ctx);
    expect(env.WEB_SHORTREEL.fetch).toHaveBeenCalledTimes(1);
    expect(env.WEB_SHORTREEL.fetch).toHaveBeenCalledWith(request);
  });

  test('returns the original response stream, status, and headers', async () => {
    const body = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('first chunk'));
        controller.close();
      },
    });
    const upstream = new Response(body, {
      status: 201,
      headers: { 'content-type': 'text/plain', 'set-cookie': 'session=test; Path=/shotreel; Secure' },
    });
    env.WEB_SHORTREEL.fetch.mockResolvedValueOnce(upstream);
    const response = await worker.fetch(new Request('https://blau.app/shotreel'), env, ctx);
    expect(response).toBe(upstream);
    expect(response.body).toBe(body);
    expect(response.bodyUsed).toBe(false);
    expect(response.status).toBe(201);
    expect(response.headers.get('set-cookie')).toBe('session=test; Path=/shotreel; Secure');
    expect(await response.text()).toBe('first chunk');
  });

  test('preserves the target trailing-slash redirect', async () => {
    const upstream = new Response(null, { status: 308, headers: { location: '/shotreel?source=blau' } });
    env.WEB_SHORTREEL.fetch.mockResolvedValueOnce(upstream);
    expect(await worker.fetch(new Request('https://blau.app/shotreel/?source=blau'), env, ctx)).toBe(upstream);
  });
});

describe('existing routing', () => {
  test.each(['/shotreel-other', '/shotreels', '/shortreel', '/SHOTREEL', '/other', '/made/nested'])('%s still falls through to MADE', async (path) => {
    const request = new Request(`https://blau.app${path}`);
    await worker.fetch(request, env, ctx);
    expect(env.MADE_SITE.fetch).toHaveBeenCalledTimes(1);
    expect(env.MADE_SITE.fetch).toHaveBeenCalledWith(request);
    expect(env.WEB_SHORTREEL.fetch).not.toHaveBeenCalled();
    expect(nextFetch).not.toHaveBeenCalled();
  });

  test.each(['/', '/?source=shortreel', '/_next/static/blau.js'])('%s still uses the host Next.js app', async (path) => {
    const request = new Request(`https://blau.app${path}`);
    await worker.fetch(request, env, ctx);
    expect(nextFetch).toHaveBeenCalledTimes(1);
    expect(nextFetch).toHaveBeenCalledWith(request, env, ctx);
    expect(env.WEB_SHORTREEL.fetch).not.toHaveBeenCalled();
    expect(env.MADE_SITE.fetch).not.toHaveBeenCalled();
  });

  test.each(['/made', '/made/'])('%s preserves its prefix, query, and body for made', async (path) => {
    const request = new Request(`https://blau.app${path}?from=directory`, { method: 'POST', body: 'hello' });
    await worker.fetch(request, env, ctx);
    const forwarded = env.MADE_SITE.fetch.mock.calls[0][0];
    expect(forwarded).toBe(request);
    expect(forwarded.url).toBe(`https://blau.app${path}?from=directory`);
    expect(forwarded.method).toBe('POST');
    expect(await forwarded.text()).toBe('hello');
    expect(env.WEB_SHORTREEL.fetch).not.toHaveBeenCalled();
  });

  test.each(['example.com', 'www.blau.app', 'blau.app.example.com', 'localhost'])('does not mount ShortReel on %s', async (host) => {
    const request = new Request(`https://${host}/shotreel/nested`);
    await worker.fetch(request, env, ctx);
    expect(env.MADE_SITE.fetch).toHaveBeenCalledTimes(1);
    expect(env.MADE_SITE.fetch).toHaveBeenCalledWith(request);
    expect(env.WEB_SHORTREEL.fetch).not.toHaveBeenCalled();
  });
});
