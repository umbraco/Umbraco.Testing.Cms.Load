import { test } from '@playwright/test';
import { env } from '../lib/env';
import { loginByForm } from '../lib/auth';
import { timeUntilVisible, perfMarks, emitMetric } from '../lib/measure';
import { HOMEPAGE_NAME } from '../fixtures/contentModel';

// Content-visible signal for the Home content node (a richly-populated `Page`
// whose first editor is a Rich Text / TipTap field).
//
// Verified live against 17.5.0-rc (probe spec, since deleted): opening the
// Homepage node renders <umb-input-tiptap>, which hosts the ProseMirror editor
// root (.tiptap / .ProseMirror). We anchor on the editor root INSIDE the
// component (`umb-input-tiptap .tiptap`) so the signal is the moment the rich
// text the user came to edit is actually painted — not merely the workspace
// shell. The bare `.tiptap`/`.ProseMirror` classes are generic ProseMirror
// markers; scoping them to umb-input-tiptap keeps the match specific. The plan's
// `[data-mark="tiptap-editor"]` does not exist on this version (probe: count=0),
// so it is dropped. We keep `.ProseMirror` as a fallback in case the inner class
// is ever renamed.
const TIPTAP = 'umb-input-tiptap .tiptap, umb-input-tiptap .ProseMirror';

// The Content section root: the Homepage node is a tree ROOT (probe confirmed it
// is directly visible as a uui-menu-item without expanding any parent), so this
// route is enough to reach the tree node.
const CONTENT_URL = `${env.baseUrl}/umbraco/section/content`;

// Probe-verified: the Homepage tree node renders as a <uui-menu-item> carrying
// label="Homepage"; clicking it routes to
//   /umbraco/section/content/workspace/document/edit/<id>/invariant
// and loads the document editing view. We click by label rather than navigating
// by id-URL because the id is not known statically and clicking the named tree
// node is the robust, user-faithful way to "open the node".
function homepageTreeItem(page: import('@playwright/test').Page) {
  return page.locator(`uui-menu-item[label="${HOMEPAGE_NAME}"]`).first();
}

// reps × (fresh context + form login + cold open + cached re-open) adds up; keep
// the per-test budget generous so a slow tier doesn't trip the 120s default.
test.setTimeout(10 * 60_000);

// COLD  = first open of the node in a fresh, cache-less browser context.
// CACHED = re-open of the SAME node in the same (now-warm) context, after
//          navigating away to the section root so the editor view is genuinely
//          re-mounted (not just left in place).
test('home node cold + cached load', async ({ browser }) => {
  const cold: number[] = [];
  const cached: number[] = [];
  // Perf marks from the last rep of each path. lcp_ms is expected to be null
  // here — the backoffice SPA doesn't emit a largest-contentful-paint entry in
  // headless Chromium — but ttfb/dcl/load populate. Captured for BOTH paths so
  // the cold and cached NDJSON rows carry the same schema (no join-time gaps).
  let coldMarks: Record<string, number | null> = {};
  let cachedMarks: Record<string, number | null> = {};

  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    await loginByForm(page);

    // Reach the Content section (renders the tree with the Homepage root node).
    await page.goto(CONTENT_URL);
    await homepageTreeItem(page).waitFor({ state: 'visible', timeout: 60_000 });

    // COLD: first open of the node in this fresh context (no cache).
    const t0 = performance.now();
    await homepageTreeItem(page).click();
    cold.push(await timeUntilVisible(t0, page.locator(TIPTAP).first()));
    coldMarks = await perfMarks(page);

    // CACHED: navigate back to the section root (re-mounts the tree, drops the
    // editor view) and re-open the SAME node in the same warm context.
    await page.goto(CONTENT_URL);
    await homepageTreeItem(page).waitFor({ state: 'visible', timeout: 60_000 });
    const t1 = performance.now();
    await homepageTreeItem(page).click();
    cached.push(await timeUntilVisible(t1, page.locator(TIPTAP).first()));
    cachedMarks = await perfMarks(page);

    await context.close();
  }

  emitMetric('cold_homenode_load', cold, coldMarks);
  emitMetric('cached_homenode_load', cached, cachedMarks);
});
