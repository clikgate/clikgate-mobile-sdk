/**
 * No real network in tests: Apple's App Store lookup answers "not found" unless a test lists a bundle ID in
 * `appStoreListings`. Everything else (the mock server on localhost) goes to the real fetch.
 */
export const appStoreListings = new Map<string, { trackId: number; trackName: string }>();
const realFetch = globalThis.fetch;
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  if (url.startsWith('https://itunes.apple.com/lookup')) {
    const bundleId = new URL(url).searchParams.get('bundleId') ?? '';
    const hit = appStoreListings.get(bundleId);
    const results = hit ? [{ ...hit, bundleId, trackViewUrl: `https://apps.apple.com/us/app/x/id${hit.trackId}?uo=4` }] : [];
    return new Response(JSON.stringify({ resultCount: results.length, results }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  return realFetch(input, init);
}) as typeof fetch;
