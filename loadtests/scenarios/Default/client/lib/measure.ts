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
    const lcp = performance.getEntriesByType('largest-contentful-paint').slice(-1)[0] as PerformanceEntry | undefined;
    return {
      ttfb_ms: nav ? Math.round(nav.responseStart) : null,
      dcl_ms: nav ? Math.round(nav.domContentLoadedEventEnd) : null,
      load_ms: nav ? Math.round(nav.loadEventEnd) : null,
      lcp_ms: lcp ? Math.round(lcp.startTime) : null,
    };
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

// Runs env.reps measurement reps in fresh, cache-less browser contexts (login per
// rep, excluded from the timed windows). `cold`/`cached` each perform their own
// navigation+timing and return elapsed ms; `beforeEach` (optional) runs after login
// and before the cold step (e.g. navigate to the content section). perfMarks are
// captured after each step so both emitted rows carry the same schema. Emits
// coldMetric and cachedMetric.
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
  let coldMarks: Record<string, number | null> = {};
  let cachedMarks: Record<string, number | null> = {};
  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    await loginByForm(page);
    if (opts.beforeEach) await opts.beforeEach(page);
    cold.push(await opts.cold(page));
    coldMarks = await perfMarks(page);
    cached.push(await opts.cached(page));
    cachedMarks = await perfMarks(page);
    await context.close();
  }
  emitMetric(opts.coldMetric, cold, coldMarks);
  emitMetric(opts.cachedMetric, cached, cachedMarks);
}
