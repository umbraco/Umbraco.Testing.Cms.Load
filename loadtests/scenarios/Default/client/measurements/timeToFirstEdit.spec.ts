import { test, expect } from '@playwright/test';
import { env } from '../lib/env';
import { loginByForm } from '../lib/auth';
import { emitMetric } from '../lib/measure';
import { summarize } from '../lib/stats';
import { TIPTAP, CONTENT_URL, homepageTreeItem, waitForHomepageNode } from '../lib/backoffice';
import { HOMEPAGE_NAME } from '../fixtures/contentModel';

// A sentinel char absent from the Homepage body, so its appearance is an
// unambiguous signal that OUR keystroke rendered (not a pre-existing letter).
// Asserted absent before typing so the detection can't trivially pass.
const SENTINEL = '§';

test.setTimeout(15 * 60_000);

// End-to-end "time to first edit": login -> open the Home node -> type one char
// into TipTap -> stop when it renders. Emits ONE metric (time_to_first_edit) of
// end-to-end totals; the four segment medians ride along in `extra`.
test('time to first edit (end-to-end + segments)', async ({ browser }) => {
  const total: number[] = [];
  const seg = {
    login: [] as number[],
    navigate: [] as number[],
    editorReady: [] as number[],
    keystroke: [] as number[],
  };

  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();

    const tStart = performance.now();

    // Segment 1: login.
    seg.login.push(await loginByForm(page));

    // Segment 2: navigate to Content + open the Home node.
    const tNav = performance.now();
    await page.goto(CONTENT_URL);
    await waitForHomepageNode(page, HOMEPAGE_NAME);
    await homepageTreeItem(page, HOMEPAGE_NAME).click();
    seg.navigate.push(performance.now() - tNav);

    // Segment 3: editor ready (TipTap field visible).
    const tEditor = performance.now();
    const editor = page.locator(TIPTAP).first();
    await editor.waitFor({ state: 'visible', timeout: 60_000 });
    seg.editorReady.push(performance.now() - tEditor);

    // Segment 4: first keystroke rendered. Poll via waitForFunction on the
    // editor's ELEMENT HANDLE — the editor lives in a shadow root, so a
    // document.querySelector-based wait would never see it.
    await editor.click();
    const before = await editor.evaluate((el) => (el as HTMLElement).textContent ?? '');
    expect(before, 'sentinel must not pre-exist in editor text').not.toContain(SENTINEL);

    const handle = await editor.elementHandle();
    expect(handle, 'editor element handle must resolve').not.toBeNull();

    const tKey = performance.now();
    await page.keyboard.type(SENTINEL);
    await page.waitForFunction(
      (args) => ((args.el as HTMLElement).textContent ?? '').includes(args.s),
      { el: handle, s: SENTINEL },
      { timeout: 30_000, polling: 'raf' },
    );
    seg.keystroke.push(performance.now() - tKey);

    // Confirm the character actually landed (guards against a false-positive
    // resolution if the editor were ever swapped out mid-poll).
    const after = await editor.evaluate((el) => (el as HTMLElement).textContent ?? '');
    expect(after, 'typed sentinel must be rendered in editor text').toContain(SENTINEL);

    await handle!.dispose();

    total.push(performance.now() - tStart);
    await context.close();
  }

  emitMetric('time_to_first_edit', total, {
    seg_login_median: summarize(seg.login).median,
    seg_navigate_median: summarize(seg.navigate).median,
    seg_editor_ready_median: summarize(seg.editorReady).median,
    seg_keystroke_median: summarize(seg.keystroke).median,
  });
});
