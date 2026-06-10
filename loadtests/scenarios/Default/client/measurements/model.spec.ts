import { test, expect } from '@playwright/test';
import { makeApi } from '../lib/api';
import {
  buildContentModel,
  HOMEPAGE_NAME,
  EXTRA_DOC_TYPES,
  TOP_LEVEL_NODE_COUNT,
} from '../fixtures/contentModel';

// Count children of a tree node. document.getChildren(id) returns the tree-item
// array directly (each item: { id, hasChildren, variants:[{name}], ... }).
async function rootItems(api: Awaited<ReturnType<typeof makeApi>>): Promise<any[]> {
  const res = await api.document.getAllAtRoot();
  const json = await res.json();
  return json.items as any[];
}

test('content model is built to spec', async ({ page }) => {
  const api = await makeApi(page);

  // Document types exist.
  expect(await api.documentType.doesNameExist('Page')).toBeTruthy();
  for (const dt of EXTRA_DOC_TYPES) {
    expect(await api.documentType.doesNameExist(dt)).toBeTruthy();
  }

  // Homepage exists at root.
  const homepage = await api.document.getByName(HOMEPAGE_NAME);
  expect(homepage).toBeTruthy();
  expect(homepage.id).toBeTruthy();

  // ~20 top-level nodes at root.
  const roots = await rootItems(api);
  expect(roots.length).toBeGreaterThanOrEqual(TOP_LEVEL_NODE_COUNT);

  // Each top-level node has >= 1 child.
  for (const node of roots) {
    expect(node.hasChildren).toBeTruthy();
  }

  // Idempotency: building again does not change root child count.
  await buildContentModel(api);
  const rootsAfter = await rootItems(api);
  expect(rootsAfter.length).toBe(roots.length);
});
