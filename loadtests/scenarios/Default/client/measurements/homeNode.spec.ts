import { test } from '@playwright/test';
import { timeUntilVisible, runColdCached } from '../lib/measure';
import { TIPTAP, CONTENT_URL, homepageTreeItem, waitForHomepageNode } from '../lib/backoffice';
import { HOMEPAGE_NAME } from '../fixtures/contentModel';

// reps × (fresh context + form login + cold open + cached re-open) adds up; keep
// the per-test budget generous so a slow tier doesn't trip the 120s default.
test.setTimeout(10 * 60_000);

// COLD  = first open of the node in a fresh, cache-less browser context.
// CACHED = re-open of the SAME node in the same (now-warm) context, after
//          navigating away to the section root so the editor view is genuinely
//          re-mounted (not just left in place).
test('home node cold + cached load', async ({ browser }) => {
  await runColdCached(browser, {
    coldMetric: 'cold_homenode_load',
    cachedMetric: 'cached_homenode_load',
    // Reach the Content section (renders the tree with the Homepage root node).
    beforeEach: async (page) => {
      await page.goto(CONTENT_URL);
      await waitForHomepageNode(page, HOMEPAGE_NAME);
    },
    // COLD: first open of the node in this fresh context (no cache).
    cold: async (page) => {
      const t0 = performance.now();
      await homepageTreeItem(page, HOMEPAGE_NAME).click();
      return timeUntilVisible(t0, page.locator(TIPTAP).first());
    },
    // CACHED: navigate back to the section root (re-mounts the tree, drops the
    // editor view) and re-open the SAME node in the same warm context.
    cached: async (page) => {
      await page.goto(CONTENT_URL);
      await waitForHomepageNode(page, HOMEPAGE_NAME);
      const t1 = performance.now();
      await homepageTreeItem(page, HOMEPAGE_NAME).click();
      return timeUntilVisible(t1, page.locator(TIPTAP).first());
    },
  });
});
