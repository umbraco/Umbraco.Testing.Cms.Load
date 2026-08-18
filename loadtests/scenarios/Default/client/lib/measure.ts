import { Browser, Page, Locator } from '@playwright/test';
import { appendFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { summarize } from './stats';
import { env } from './env';
import { loginByForm } from './auth';

// Time from `start` until `locator` is visible to the user (content-visible
// signal). Returns elapsed ms using the high-resolution timer.
export async function timeUntilVisible(start: number, locator: Locator, timeoutMs = 60_000): Promise<number> {
  await locator.waitFor({ state: 'visible', timeout: timeoutMs });
  return performance.now() - start;
}

// Browser Navigation Timing + LCP marks, captured for context alongside the
// content-visible number. Best-effort: returns nulls if the API is unavailable.
export async function perfMarks(page: Page): Promise<Record<string, number | null>> {
  return page.evaluate(() => {
    const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined;
    // LCP is NOT returned by getEntriesByType — it is only delivered to a
    // PerformanceObserver. A buffered observer replays entries recorded before
    // this call; take the latest (LCP can update over the page's life). Marks are
    // captured after the page has settled, so buffered replay resolves promptly.
    const lcpMs = new Promise<number | null>((resolve) => {
      try {
        let last: number | null = null;
        const obs = new PerformanceObserver((list) => {
          for (const e of list.getEntries()) last = Math.round(e.startTime);
        });
        obs.observe({ type: 'largest-contentful-paint', buffered: true });
        // buffered entries are appended to the observer buffer during observe(),
        // so drain them synchronously; then yield one task turn to catch any
        // async delivery. Avoids a fixed multi-hundred-ms wait per call.
        for (const e of obs.takeRecords()) last = Math.round(e.startTime);
        setTimeout(() => {
          for (const e of obs.takeRecords()) last = Math.round(e.startTime);
          obs.disconnect();
          resolve(last);
        }, 0);
      } catch {
        resolve(null); // API unavailable (non-Chromium / no LCP element)
      }
    });
    return lcpMs.then((lcp_ms) => ({
      ttfb_ms: nav ? Math.round(nav.responseStart) : null,
      dcl_ms: nav ? Math.round(nav.domContentLoadedEventEnd) : null,
      load_ms: nav ? Math.round(nav.loadEventEnd) : null,
      lcp_ms,
    }));
  });
}

// Append one NDJSON summary row for a metric. `samples` is the per-rep ms array;
// `extra` carries any metric-specific fields (e.g. segment medians). Run metadata
// (run_id, version, tier, scenario) is attached from env so downstream publish
// has everything without a join.
export function emitMetric(
  metric: string,
  samples: number[],
  extra: Record<string, unknown> = {},
  dir: string = env.resultsDir,
): void {
  mkdirSync(dir, { recursive: true });
  const s = summarize(samples);
  const row = {
    metric,
    run_id: env.runId,
    umbraco_version: env.umbracoVersion,
    infra_tier: env.tier,
    scenario: env.scenario,
    count: s.count,
    median: s.median,
    p75: s.p75,
    p95: s.p95,
    min: s.min,
    max: s.max,
    stddev: Math.round(s.stddev * 100) / 100,
    samples,
    ...extra,
  };
  appendFileSync(join(dir, `${metric}.ndjson`), JSON.stringify(row) + '\n', 'utf8');
}

// Runs env.reps reps in fresh, cache-less contexts. Login is per-rep and
// EXCLUDED from the timed windows; `beforeEach` (optional) runs after login,
// before `cold`. perfMarks are captured after both `cold` and `cached` so the
// two emitted rows share one schema.

// Median across reps, per mark key — so the emitted ttfb/dcl/load/lcp summarize
// the whole run like median/p95 do, rather than reflecting only the final rep.
// Nulls (API unavailable that rep) are dropped; a key with no numbers stays null.
function medianMarks(samples: Record<string, number | null>[]): Record<string, number | null> {
  const keys = new Set<string>();
  for (const m of samples) for (const k of Object.keys(m)) keys.add(k);
  const out: Record<string, number | null> = {};
  for (const k of keys) {
    const nums = samples.map((m) => m[k]).filter((v): v is number => typeof v === 'number');
    out[k] = nums.length ? Math.round(summarize(nums).median) : null;
  }
  return out;
}

export async function runColdCached(
  browser: Browser,
  opts: {
    coldMetric: string;
    cachedMetric: string;
    beforeEach?: (page: Page) => Promise<void>;
    cold: (page: Page) => Promise<number>;
    cached: (page: Page) => Promise<number>;
  },
): Promise<void> {
  const cold: number[] = [];
  const cached: number[] = [];
  const coldMarks: Record<string, number | null>[] = [];
  const cachedMarks: Record<string, number | null>[] = [];
  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    await loginByForm(page);
    if (opts.beforeEach) await opts.beforeEach(page);
    cold.push(await opts.cold(page));
    coldMarks.push(await perfMarks(page));
    cached.push(await opts.cached(page));
    cachedMarks.push(await perfMarks(page));
    await context.close();
  }
  emitMetric(opts.coldMetric, cold, medianMarks(coldMarks));
  emitMetric(opts.cachedMetric, cached, medianMarks(cachedMarks));
}
