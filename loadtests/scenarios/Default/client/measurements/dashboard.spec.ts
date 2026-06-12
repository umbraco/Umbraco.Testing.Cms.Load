import { test } from '@playwright/test';
import { env } from '../lib/env';
import { timeUntilVisible, runColdCached } from '../lib/measure';

// Content-visible signal for the Umbraco News dashboard. Anchor on the
// container, NOT the news cards: the container renders once the dashboard mounts
// regardless of the external umbraco.com feed (cards are flaky with no internet);
// the dashboard host is a fallback if the container is ever renamed.
const DASHBOARD_CONTENT = 'umb-news-container, umb-umbraco-news-dashboard';

const DASHBOARD_URL = `${env.baseUrl}/umbraco/section/content`;

// reps × (fresh context + form login + cold nav + cached nav) adds up; keep the
// per-test budget generous so a slow tier doesn't trip the 120s default.
test.setTimeout(10 * 60_000);

// COLD = explicit goto to the dashboard route in a fresh context; CACHED = a
// reload of it in the same warm context. loginByForm already warmed the shell,
// so both windows time the dashboard VIEW becoming content-visible, not the shell.
test('news dashboard cold + cached load', async ({ browser }) => {
  await runColdCached(browser, {
    coldMetric: 'cold_dashboard_load',
    cachedMetric: 'cached_dashboard_load',
    cold: async (page) => {
      const t0 = performance.now();
      await page.goto(DASHBOARD_URL);
      return timeUntilVisible(t0, page.locator(DASHBOARD_CONTENT).first());
    },
    cached: async (page) => {
      const t1 = performance.now();
      await page.reload();
      return timeUntilVisible(t1, page.locator(DASHBOARD_CONTENT).first());
    },
  });
});
