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

  // --- Page doc type: Content-tab property ordering --------------------------
  // documentType.get(id) returns ONLY the doc type's OWN properties/containers —
  // composed properties live on their compositions and are NOT inlined here. We
  // still filter to the OWN containers explicitly so the intent ("its own
  // Content-tab properties, not composed") is encoded, not assumed.
  const pageDtRef = await api.documentType.getByName('Page');
  const pageDt = await api.documentType.get(pageDtRef.id);

  const ownContainerIds = new Set<string>((pageDt.containers ?? []).map((c: any) => c.id));
  const ownProps = (pageDt.properties as any[])
    .filter((p) => ownContainerIds.has(p.container?.id))
    .slice()
    .sort((a, b) => a.sortOrder - b.sortOrder);

  // Resolve the editors by NAME (no hard-coded GUIDs) so we can assert the first
  // two properties actually point at the Rich Text (TipTap) and Media Picker
  // data types — alias AND data type identity must both line up.
  const richTextDt = await api.dataType.getByName('LT Rich Text');
  const mediaPickerDt = await api.dataType.getByName('LT Media Picker');
  expect(richTextDt?.id).toBeTruthy();
  expect(mediaPickerDt?.id).toBeTruthy();

  expect(ownProps.length).toBeGreaterThanOrEqual(2);
  // FIRST own property is the Rich Text (TipTap) editor.
  expect(ownProps[0].alias).toBe('ltRichText');
  expect(ownProps[0].dataType?.id).toBe(richTextDt.id);
  // SECOND own property is the Media Picker.
  expect(ownProps[1].alias).toBe('ltMediaPicker');
  expect(ownProps[1].dataType?.id).toBe(mediaPickerDt.id);

  // --- Page doc type: compositions applied -----------------------------------
  expect(Array.isArray(pageDt.compositions)).toBeTruthy();
  expect(pageDt.compositions.length).toBe(3);

  // --- Homepage: embedded image + both media pickers populated ---------------
  const homepageDoc = await api.document.get(homepage.id);
  const values = homepageDoc.values as any[];

  const richTextValue = values.find((v) => v.alias === 'ltRichText');
  expect(richTextValue).toBeTruthy();
  expect(richTextValue.editorAlias).toBe('Umbraco.RichText');
  expect(typeof richTextValue.value?.markup).toBe('string');
  const markup: string = richTextValue.value.markup;
  expect(markup).toContain('<img');
  // The embedded <img> must carry explicit dimensions so it renders (instead of
  // collapsing to zero) in the backoffice. Assert width AND height attributes
  // are present on the img tag.
  const imgTag = markup.match(/<img\b[^>]*>/i)?.[0] ?? '';
  expect(imgTag, 'an <img> tag exists in the RTE markup').toBeTruthy();
  expect(imgTag, 'img has a width attribute').toMatch(/\bwidth\s*=\s*"\d+"/i);
  expect(imgTag, 'img has a height attribute').toMatch(/\bheight\s*=\s*"\d+"/i);

  for (const pickerAlias of ['ltMediaPicker', 'ltMediaPicker2']) {
    const picker = values.find((v) => v.alias === pickerAlias);
    expect(picker, `media picker value ${pickerAlias}`).toBeTruthy();
    expect(picker.editorAlias).toBe('Umbraco.MediaPicker3');
    expect(Array.isArray(picker.value)).toBeTruthy();
    expect(picker.value.length).toBeGreaterThanOrEqual(1);
    // A non-empty media reference must be present.
    expect(picker.value[0].mediaKey).toBeTruthy();
  }

  // --- Homepage: Block Grid has at least one real block ----------------------
  // The Block Grid data type must allow the Hero Block element type, and the
  // Homepage's block-grid value must contain at least one populated block
  // (contentData non-empty, with a matching layout item).
  const heroBlockDt = await api.documentType.getByName('Hero Block');
  expect(heroBlockDt?.id, 'Hero Block element type exists').toBeTruthy();

  const blockGridDt = await api.dataType.getByName('LT Block Grid');
  const blockGridConfig = await api.dataType.get(blockGridDt.id);
  const blocksConfig = (blockGridConfig.values as any[]).find((v) => v.alias === 'blocks');
  expect(blocksConfig, 'Block Grid data type has a blocks config').toBeTruthy();
  expect(Array.isArray(blocksConfig.value)).toBeTruthy();
  expect(blocksConfig.value.length, 'Block Grid allows at least one block').toBeGreaterThanOrEqual(1);
  // The allowed block points at the Hero Block element type.
  expect(blocksConfig.value.some((b: any) => b.contentElementTypeKey === heroBlockDt.id)).toBeTruthy();

  const blockGridValue = values.find((v) => v.alias === 'ltBlockGrid');
  expect(blockGridValue, 'homepage block-grid value present').toBeTruthy();
  expect(blockGridValue.editorAlias).toBe('Umbraco.BlockGrid');
  expect(Array.isArray(blockGridValue.value?.contentData)).toBeTruthy();
  expect(
    blockGridValue.value.contentData.length,
    'block-grid value has at least one block',
  ).toBeGreaterThanOrEqual(1);
  // The block references the Hero Block element type and has a matching layout item.
  const firstBlock = blockGridValue.value.contentData[0];
  expect(firstBlock.contentTypeKey).toBe(heroBlockDt.id);
  const layoutItems = blockGridValue.value.layout?.['Umbraco.BlockGrid'] ?? [];
  expect(layoutItems.length).toBeGreaterThanOrEqual(1);
  expect(layoutItems.some((l: any) => l.contentKey === firstBlock.key)).toBeTruthy();

  // --- Homepage: Content Picker references a real, existing node -------------
  const contentPicker = values.find((v) => v.alias === 'ltContentPicker');
  expect(contentPicker, 'content-picker value present').toBeTruthy();
  expect(contentPicker.editorAlias).toBe('Umbraco.ContentPicker');
  expect(contentPicker.value, 'content-picker references a node').toBeTruthy();
  // The referenced node must actually exist (and not be the Homepage itself).
  expect(contentPicker.value).not.toBe(homepage.id);
  const referenced = await api.document.get(contentPicker.value);
  expect(referenced?.id, 'content-picker target node exists').toBeTruthy();

  // --- Homepage: Multi-URL Picker has a value --------------------------------
  const multiUrl = values.find((v) => v.alias === 'ltMultiUrlPicker');
  expect(multiUrl, 'multi-url value present').toBeTruthy();
  expect(multiUrl.editorAlias).toBe('Umbraco.MultiUrlPicker');
  expect(Array.isArray(multiUrl.value)).toBeTruthy();
  expect(multiUrl.value.length, 'multi-url has at least one link').toBeGreaterThanOrEqual(1);
  expect(multiUrl.value[0].url, 'multi-url first link has a url').toBeTruthy();

  // --- Homepage: textstring (title) + textarea (summary) populated -----------
  const title = values.find((v) => v.alias === 'ltTextstring');
  expect(title, 'title (textstring) present').toBeTruthy();
  expect(typeof title.value).toBe('string');
  expect(title.value.length, 'title is non-empty').toBeGreaterThan(0);

  const summary = values.find((v) => v.alias === 'ltTextarea');
  expect(summary, 'summary (textarea) present').toBeTruthy();
  expect(typeof summary.value).toBe('string');
  expect(summary.value.length, 'summary is non-empty').toBeGreaterThan(0);

  // --- Idempotency -----------------------------------------------------------
  // Building again must not change the root child count, the number of
  // compositions on Page, nor the count of Page's own properties (so a re-run
  // can't be shown to churn the schema, not just the root count).
  await buildContentModel(api);

  const rootsAfter = await rootItems(api);
  expect(rootsAfter.length).toBe(roots.length);

  const pageDtAfter = await api.documentType.get(pageDtRef.id);
  expect(pageDtAfter.compositions.length).toBe(3);
  const ownContainerIdsAfter = new Set<string>((pageDtAfter.containers ?? []).map((c: any) => c.id));
  const ownPropsAfter = (pageDtAfter.properties as any[]).filter((p) =>
    ownContainerIdsAfter.has(p.container?.id),
  );
  expect(ownPropsAfter.length).toBe(ownProps.length);
});
