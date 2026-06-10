import { test } from '@playwright/test';
import { env } from '../lib/env';
import { loginByForm } from '../lib/auth';
import { timeUntilVisible, perfMarks, emitMetric } from '../lib/measure';

// Content-visible signal for the Umbraco News dashboard.
//
// Verified live against 17.5.0-rc (probe spec, since deleted): after login the
// default section is Content and its default dashboard is the Umbraco News
// dashboard, hosted by <umb-umbraco-news-dashboard>. Inside it renders an
// <umb-news-container> (the dashboard's own content area) which in turn renders
// <umb-news-card> items pulled from the EXTERNAL umbraco.com feed.
//
// We anchor on <umb-news-container>, NOT the news cards: the container is the
// dashboard view's own content and renders once the dashboard has mounted,
// independent of whether the external feed returns any articles. The cards would
// be a flaky signal on an instance with no outbound internet. We fall back to the
// dashboard host element to stay robust if the container element is ever renamed.
const DASHBOARD_CONTENT = 'umb-news-container, umb-umbraco-news-dashboard';

// The Content section default view IS the News dashboard, so navigating to the
// section route renders it.
const DASHBOARD_URL = `${env.baseUrl}/umbraco/section/content`;

// reps × (fresh context + form login + cold nav + cached nav) adds up; keep the
// per-test budget generous so a slow tier doesn't trip the 120s default.
test.setTimeout(10 * 60_000);

// COLD  = first dashboard render in a fresh, cache-less browser context.
// CACHED = re-render of the same dashboard in the same (now-warm) context.
//
// loginByForm already navigates to /umbraco and warms the shell, so to make the
// cold/cached split meaningful we time an EXPLICIT goto to the dashboard route
// (cold) and then a reload of it (cached) — both windows capture the dashboard
// VIEW becoming content-visible, not just the shell.
test('news dashboard cold + cached load', async ({ browser }) => {
  const cold: number[] = [];
  const cached: number[] = [];
  let lastMarks: Record<string, number | null> = {};

  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    await loginByForm(page);

    // COLD: first navigation to the dashboard in this fresh context (no cache).
    const t0 = performance.now();
    await page.goto(DASHBOARD_URL);
    cold.push(await timeUntilVisible(t0, page.locator(DASHBOARD_CONTENT).first()));
    lastMarks = await perfMarks(page);

    // CACHED: reload the same dashboard in the same (now-warm) context.
    const t1 = performance.now();
    await page.reload();
    cached.push(await timeUntilVisible(t1, page.locator(DASHBOARD_CONTENT).first()));

    await context.close();
  }

  emitMetric('cold_dashboard_load', cold, lastMarks);
  emitMetric('cached_dashboard_load', cached);
});
