// Builds a precise, idempotent backoffice content model against a LIVE Umbraco
// instance via @umbraco-cms/acceptance-test-helpers. Run once by Playwright
// globalSetup before any measurement.
//
// Every create is guarded by a doesNameExist / getByName check: the package's
// createDefault* helpers DELETE on name collision, so calling them unguarded
// would churn the whole model on every run.
import { randomUUID } from 'crypto';
import {
  ApiHelpers,
  DocumentTypeBuilder,
  DocumentBuilder,
  BlockGridDataTypeBuilder,
} from '@umbraco-cms/acceptance-test-helpers';

export const HOMEPAGE_NAME = 'Homepage';
export const EXTRA_DOC_TYPES = ['Product-page', 'Marketing-page', 'Newsletter-signup'] as const;
export const TOP_LEVEL_NODE_COUNT = 20;

const PAGE_DOC_TYPE = 'Page';
const CONTENT_TAB = 'Content';
const SEO_TAB = 'SEO';

// Data types we own (created once, reused). TipTap first, Media Picker second.
const DT = {
  richText: 'LT Rich Text',
  mediaPicker: 'LT Media Picker',
  blockGrid: 'LT Block Grid',
  mediaPicker2: 'LT Media Picker 2',
  textstring: 'LT Textstring',
  textarea: 'LT Textarea',
  numeric: 'LT Numeric',
  trueFalse: 'LT True False',
  datePicker: 'LT Date Picker',
  // composition 1 (extra editors on Content tab)
  contentPicker: 'LT Content Picker',
  multiUrl: 'LT Multi URL Picker',
  // composition 2 (SEO tab) — all simple text-ish editors
  metaTitle: 'LT Meta Title',
  metaDescription: 'LT Meta Description',
  canonicalUrl: 'LT Canonical URL',
  noIndex: 'LT No Index',
  // composition 3 (small)
  tags: 'LT Tags',
  numeric2: 'LT Numeric 2',
};

const COMPOSITION_CONTENT = 'Page Content Extras';
const COMPOSITION_SEO = 'Page SEO';
const COMPOSITION_SMALL = 'Page Extras';

// The single allowed block in the Block Grid. Its id doubles as the
// contentElementTypeKey of the data type's "blocks" config and the contentTypeKey
// of the block's contentData on the Homepage.
const HERO_BLOCK_ELEMENT_TYPE = 'Hero Block';
const HERO_BLOCK_HEADING = 'heading'; // Textstring
const HERO_BLOCK_TEXT = 'text'; // Textarea

// Best-effort: the tree is visible in the management API without publishing, so
// a transient slow publish must not abort the build. Swallow timeouts/errors.
async function tryPublish(api: ApiHelpers, id: string): Promise<void> {
  try {
    await Promise.race([
      api.document.publish(id),
      new Promise((resolve) => setTimeout(resolve, 15_000)),
    ]);
  } catch {
    // ignore — document still exists in the tree even if unpublished.
  }
}

// camelCase alias matching AliasHelper.toAlias used elsewhere in the package.
function toAlias(text: string): string {
  return text
    // Split on spaces AND hyphens so names like "Product-page" become clean
    // camelCase ("productPage"), not a literal hyphen. Drop empty segments
    // (double separators) so el[0] can't be undefined.
    .split(/[\s-]+/)
    .filter((el) => el.length > 0)
    .map((el, idx) => (idx === 0 ? el.toLowerCase() : el[0].toUpperCase() + el.slice(1).toLowerCase()))
    .join('');
}

// --- data type creation (guarded) --------------------------------------------

async function ensureDataTypes(api: ApiHelpers): Promise<Record<string, string>> {
  const ids: Record<string, string> = {};

  async function ensure(name: string, create: () => Promise<string>): Promise<string> {
    const existing = await api.dataType.getByName(name);
    if (existing?.id) {
      return existing.id;
    }
    return create();
  }

  ids[DT.richText] = await ensure(DT.richText, () => api.dataType.createDefaultTiptapDataType(DT.richText));
  ids[DT.mediaPicker] = await ensure(DT.mediaPicker, () => api.dataType.createDefaultMediaPickerDataType(DT.mediaPicker));
  ids[DT.blockGrid] = await ensure(DT.blockGrid, () => api.dataType.createEmptyBlockGrid(DT.blockGrid));
  ids[DT.mediaPicker2] = await ensure(DT.mediaPicker2, () => api.dataType.createDefaultMediaPickerDataType(DT.mediaPicker2));
  ids[DT.textstring] = await ensure(DT.textstring, () => api.dataType.createTextstringDataType(DT.textstring));
  ids[DT.textarea] = await ensure(DT.textarea, () => api.dataType.createTextareaDataType(DT.textarea));
  ids[DT.numeric] = await ensure(DT.numeric, () => api.dataType.createDefaultNumericDataType(DT.numeric));
  ids[DT.trueFalse] = await ensure(DT.trueFalse, () => api.dataType.createDefaultTrueFalseDataType(DT.trueFalse));
  ids[DT.datePicker] = await ensure(DT.datePicker, () => api.dataType.createDefaultDateTimeDataType(DT.datePicker));

  ids[DT.contentPicker] = await ensure(DT.contentPicker, () => api.dataType.createDefaultContentPickerDataType(DT.contentPicker));
  ids[DT.multiUrl] = await ensure(DT.multiUrl, () => api.dataType.createDefaultMultiUrlPickerDataType(DT.multiUrl));

  ids[DT.metaTitle] = await ensure(DT.metaTitle, () => api.dataType.createTextstringDataType(DT.metaTitle));
  ids[DT.metaDescription] = await ensure(DT.metaDescription, () => api.dataType.createTextareaDataType(DT.metaDescription));
  ids[DT.canonicalUrl] = await ensure(DT.canonicalUrl, () => api.dataType.createTextstringDataType(DT.canonicalUrl));
  ids[DT.noIndex] = await ensure(DT.noIndex, () => api.dataType.createDefaultTrueFalseDataType(DT.noIndex));

  ids[DT.tags] = await ensure(DT.tags, () => api.dataType.createDefaultTagsDataType(DT.tags));
  ids[DT.numeric2] = await ensure(DT.numeric2, () => api.dataType.createDefaultNumericDataType(DT.numeric2));

  return ids;
}

// --- element-type compositions (guarded) -------------------------------------

interface PropSpec {
  name: string;
  dataTypeId: string;
}

// Build an element type with one tab containing one group with the given
// properties. Returns the element type id (existing or newly created).
async function ensureCompositionElementType(
  api: ApiHelpers,
  name: string,
  tabName: string,
  props: PropSpec[],
  groupName: string = tabName + ' Group',
): Promise<string> {
  const existing = await api.documentType.doesNameExist(name);
  if (existing?.id) {
    return existing.id;
  }

  const tabId = randomUUID();
  const groupId = randomUUID();
  let builder = new DocumentTypeBuilder()
    .withName(name)
    .withAlias(toAlias(name))
    .withIsElement(true)
    .addContainer()
    .withName(tabName)
    .withId(tabId)
    .withType('Tab')
    .done()
    .addContainer()
    .withName(groupName)
    .withId(groupId)
    .withType('Group')
    .withParentId(tabId)
    .done();

  for (const prop of props) {
    builder = builder
      .addProperty()
      .withContainerId(groupId)
      .withName(prop.name)
      .withAlias(toAlias(prop.name))
      .withDataTypeId(prop.dataTypeId)
      .done();
  }

  return api.documentType.create(builder.build());
}

// Allow the Hero Block in the Block Grid data type, updated IN PLACE via PUT so
// its id is preserved (recreating it would orphan the Page property). Idempotent:
// skips if a non-empty "blocks" entry already exists.
async function ensureBlockGridAllowsHeroBlock(
  api: ApiHelpers,
  blockGridDataTypeId: string,
  heroBlockElementTypeId: string,
): Promise<void> {
  const current = await api.dataType.get(blockGridDataTypeId);
  const blocksValue = (current.values ?? []).find((v: any) => v.alias === 'blocks');
  if (blocksValue && Array.isArray(blocksValue.value) && blocksValue.value.length > 0) {
    return;
  }

  const built = new BlockGridDataTypeBuilder()
    .withName(DT.blockGrid)
    .addBlock()
    .withContentElementTypeKey(heroBlockElementTypeId)
    .withAllowAtRoot(true)
    .done()
    .build().values;

  // Merge into current.values rather than replacing it outright: the builder
  // only ever emits 'blocks' + 'blockGroups', so a wholesale replace would
  // silently drop any other pre-existing config (validationLimit, gridColumns,
  // useLiveEditing, maxPropertyWidth, ...) on this data type's first write.
  const builtAliases = new Set(built.map((v: any) => v.alias));
  const values = [
    ...(current.values ?? []).filter((v: any) => !builtAliases.has(v.alias)),
    ...built,
  ];

  await api.dataType.update(blockGridDataTypeId, {
    name: current.name,
    editorAlias: current.editorAlias,
    editorUiAlias: current.editorUiAlias,
    values,
  });
}

// --- Page document type (tabbed, composed) -----------------------------------

async function ensurePageDocType(
  api: ApiHelpers,
  dt: Record<string, string>,
  compositionIds: string[],
): Promise<string> {
  const existing = await api.documentType.doesNameExist(PAGE_DOC_TYPE);
  if (existing?.id) {
    return existing.id;
  }

  const tabId = randomUUID();
  const groupId = randomUUID();

  // Content tab properties: TipTap FIRST, Media Picker SECOND.
  const contentProps: PropSpec[] = [
    { name: DT.richText, dataTypeId: dt[DT.richText] },
    { name: DT.mediaPicker, dataTypeId: dt[DT.mediaPicker] },
    { name: DT.blockGrid, dataTypeId: dt[DT.blockGrid] },
    { name: DT.mediaPicker2, dataTypeId: dt[DT.mediaPicker2] },
    { name: DT.textstring, dataTypeId: dt[DT.textstring] },
    { name: DT.textarea, dataTypeId: dt[DT.textarea] },
    { name: DT.numeric, dataTypeId: dt[DT.numeric] },
    { name: DT.trueFalse, dataTypeId: dt[DT.trueFalse] },
    { name: DT.datePicker, dataTypeId: dt[DT.datePicker] },
  ];

  let builder = new DocumentTypeBuilder()
    .withName(PAGE_DOC_TYPE)
    .withAlias(toAlias(PAGE_DOC_TYPE))
    .withAllowedAsRoot(true)
    .addContainer()
    .withName(CONTENT_TAB)
    .withId(tabId)
    .withType('Tab')
    .done()
    .addContainer()
    .withName('Body')
    .withId(groupId)
    .withType('Group')
    .withParentId(tabId)
    .done();

  let sortOrder = 0;
  for (const prop of contentProps) {
    builder = builder
      .addProperty()
      .withContainerId(groupId)
      .withName(prop.name)
      .withAlias(toAlias(prop.name))
      .withDataTypeId(prop.dataTypeId)
      .withSortOrder(sortOrder++)
      .done();
  }

  for (const compositionId of compositionIds) {
    builder = builder.addComposition().withDocumentTypeId(compositionId).done();
  }

  return api.documentType.create(builder.build());
}

// Make Page allow Page as a child. A separate update because a doc type cannot
// reference its own id at create time (it has none yet).
async function ensurePageAllowsPageChild(api: ApiHelpers, pageId: string): Promise<void> {
  const docType = await api.documentType.get(pageId);
  const already = (docType.allowedDocumentTypes ?? []).some(
    (a: any) => a.documentType?.id === pageId,
  );
  if (already) {
    return;
  }
  docType.allowedDocumentTypes = [
    ...(docType.allowedDocumentTypes ?? []),
    { documentType: { id: pageId }, sortOrder: 0 },
  ];
  await api.put(
    api.baseUrl + '/umbraco/management/api/v1/document-type/' + pageId,
    docType,
  );
}

// --- homepage (fully populated) ----------------------------------------------

async function ensureHomepage(
  api: ApiHelpers,
  pageId: string,
  imageMediaKey: string,
  heroBlockElementTypeId: string,
  relatedNodeId: string,
): Promise<string> {
  const existing = await api.document.getByName(HOMEPAGE_NAME);
  if (existing?.id) {
    return existing.id;
  }

  // Rich text markup with an <img> carrying explicit width/height so it renders
  // at a real size in the backoffice instead of collapsing to zero.
  const richTextValue = {
    markup:
      `<p>Welcome to the homepage.</p>` +
      `<figure>` +
      `<img src="/media/${imageMediaKey}" ` +
      `data-udi="umb://media/${imageMediaKey.replace(/-/g, '')}" ` +
      `alt="hero" width="800" height="450" />` +
      `</figure>` +
      `<p>An image is embedded above.</p>`,
    blocks: { layout: {}, contentData: [], settingsData: [], expose: [] },
  };

  // Block Grid value with exactly one Hero Block. The layout item's contentKey
  // must match the contentData entry's key; the block is exposed so it renders.
  const blockContentKey = randomUUID();

  const builder = new DocumentBuilder()
    .withDocumentTypeId(pageId)
    .addVariant()
    .withName(HOMEPAGE_NAME)
    .done()
    .addValue()
    .withAlias(toAlias(DT.richText))
    .withValue(richTextValue)
    .done()
    .addValue()
    .withAlias(toAlias(DT.mediaPicker))
    .addMediaPickerValue()
    .withMediaKey(imageMediaKey)
    .done()
    .done()
    .addValue()
    .withAlias(toAlias(DT.mediaPicker2))
    .addMediaPickerValue()
    .withMediaKey(imageMediaKey)
    .done()
    .done()
    .addValue()
    .withAlias(toAlias(DT.blockGrid))
    .addBlockGridValue()
    .addContentData()
    .withContentTypeKey(heroBlockElementTypeId)
    .withKey(blockContentKey)
    .addContentDataValue()
    .withAlias(HERO_BLOCK_HEADING)
    .withValue('Welcome to our site')
    .done()
    .addContentDataValue()
    .withAlias(HERO_BLOCK_TEXT)
    .withValue('This hero block is rendered inside the Block Grid editor.')
    .done()
    .done()
    .addLayout()
    .withContentKey(blockContentKey)
    .withColumnSpan(12)
    .withRowSpan(1)
    .done()
    .addExpose()
    .withContentKey(blockContentKey)
    .done()
    .done()
    .done()
    .addValue()
    .withAlias(toAlias(DT.textstring))
    .withValue('Homepage headline')
    .done()
    .addValue()
    .withAlias(toAlias(DT.textarea))
    .withValue('A concise summary of what this homepage is all about.')
    .done()
    .addValue()
    .withAlias(toAlias(DT.contentPicker))
    .withValue(relatedNodeId)
    .done()
    .addValue()
    .withAlias(toAlias(DT.multiUrl))
    .addURLPickerValue()
    .withName('Umbraco')
    .withUrl('https://umbraco.com')
    .withType('external')
    .withTarget('_blank')
    .withIcon('icon-link')
    .done()
    .done()
    // SEO composition values.
    .addValue()
    .withAlias(toAlias(DT.metaTitle))
    .withValue('Homepage | Load Test Site')
    .done()
    .addValue()
    .withAlias(toAlias(DT.metaDescription))
    .withValue('The homepage of the load test site, used for backoffice measurements.')
    .done()
    .addValue()
    .withAlias(toAlias(DT.canonicalUrl))
    .withValue('https://example.com/')
    .done();

  const id = await api.document.create(builder.build());
  await tryPublish(api, id);
  return id;
}

// --- tree (root nodes + a child each) ----------------------------------------

// Ensure `parentId` has >= 1 child; if childless, create one named `childName`
// of doc type `pageId` and best-effort publish it. No-op if children exist.
async function ensureHasChild(
  api: ApiHelpers,
  pageId: string,
  parentId: string,
  childName: string,
): Promise<void> {
  const children = await api.document.getChildren(parentId);
  if (children && children.length > 0) {
    return;
  }
  const childDoc = new DocumentBuilder()
    .withDocumentTypeId(pageId)
    .withParentId(parentId)
    .addVariant()
    .withName(childName)
    .done()
    .build();
  const childId = await api.document.create(childDoc);
  await tryPublish(api, childId);
}

async function ensureRootTree(api: ApiHelpers, pageId: string): Promise<void> {
  for (let i = 1; i < TOP_LEVEL_NODE_COUNT; i++) {
    const name = `Page ${i}`;
    let parentId: string;
    const existing = await api.document.getByName(name);
    if (existing?.id) {
      parentId = existing.id;
    } else {
      const doc = new DocumentBuilder()
        .withDocumentTypeId(pageId)
        .addVariant()
        .withName(name)
        .done()
        .build();
      parentId = await api.document.create(doc);
      await tryPublish(api, parentId);
    }

    // Ensure this root has >= 1 child.
    await ensureHasChild(api, pageId, parentId, `${name} - child`);
  }
}

// Ensure the Homepage has at least one child too (it is one of the root nodes).
async function ensureHomepageChild(api: ApiHelpers, pageId: string, homepageId: string): Promise<void> {
  await ensureHasChild(api, pageId, homepageId, 'Homepage - child');
}

// --- extra doc types ----------------------------------------------------------

async function ensureExtraDocTypes(api: ApiHelpers): Promise<void> {
  for (const name of EXTRA_DOC_TYPES) {
    const existing = await api.documentType.doesNameExist(name);
    if (existing?.id) {
      continue;
    }
    const builder = new DocumentTypeBuilder()
      .withName(name)
      .withAlias(toAlias(name))
      .build();
    await api.documentType.create(builder);
  }
}

// Final sweep so every root (including stray pre-existing content) has >= 1
// child. Tries a child of the root's OWN doc type, then Page; if neither is
// allowed, recycle-bins the stray root so the criterion holds. Idempotent.
async function ensureEveryRootHasChild(api: ApiHelpers, fallbackPageId: string): Promise<void> {
  const res = await api.document.getAllAtRoot();
  const json = await res.json();
  for (const root of json.items as any[]) {
    if (root.hasChildren) {
      continue;
    }
    const rootDocTypeId: string = root.documentType?.id;
    const rootName: string = root.variants?.[0]?.name ?? root.id;
    const childName = `${rootName} - child`;
    const existingChild = await api.document.getByName(childName);
    if (existingChild?.id) {
      continue;
    }
    let created = false;
    for (const docTypeId of [rootDocTypeId, fallbackPageId]) {
      if (!docTypeId) {
        continue;
      }
      try {
        const childDoc = new DocumentBuilder()
          .withDocumentTypeId(docTypeId)
          .withParentId(root.id)
          .addVariant()
          .withName(childName)
          .done()
          .build();
        const childId = await api.document.create(childDoc);
        if (childId) {
          await tryPublish(api, childId);
          created = true;
          break;
        }
      } catch {
        // try next doc type
      }
    }
    if (!created) {
      // Could not give this stray root a child (its type forbids children and
      // does not allow Page). Remove it so the tree is consistent.
      console.log(`[contentModel] moving root "${rootName}" (${root.id}) to recycle bin: no doc type permits a child`);
      await api.document.moveToRecycleBin(root.id);
    }
  }
}

// --- entry point --------------------------------------------------------------

export async function buildContentModel(api: ApiHelpers): Promise<void> {
  const dt = await ensureDataTypes(api);

  const image = await ensureImage(api);

  // Three compositions: Content-tab editors, an SEO tab, and a small one.
  const contentExtrasId = await ensureCompositionElementType(api, COMPOSITION_CONTENT, CONTENT_TAB, [
    { name: DT.contentPicker, dataTypeId: dt[DT.contentPicker] },
    { name: DT.multiUrl, dataTypeId: dt[DT.multiUrl] },
  ]);
  const seoId = await ensureCompositionElementType(api, COMPOSITION_SEO, SEO_TAB, [
    { name: DT.metaTitle, dataTypeId: dt[DT.metaTitle] },
    { name: DT.metaDescription, dataTypeId: dt[DT.metaDescription] },
    { name: DT.canonicalUrl, dataTypeId: dt[DT.canonicalUrl] },
    { name: DT.noIndex, dataTypeId: dt[DT.noIndex] },
  ]);
  const smallId = await ensureCompositionElementType(api, COMPOSITION_SMALL, 'Extras', [
    { name: DT.tags, dataTypeId: dt[DT.tags] },
    { name: DT.numeric2, dataTypeId: dt[DT.numeric2] },
  ]);

  // Hero Block element type (Heading/Text aliases resolve to HERO_BLOCK_HEADING /
  // HERO_BLOCK_TEXT via toAlias), then wire it into the empty Block Grid.
  const heroBlockId = await ensureCompositionElementType(
    api,
    HERO_BLOCK_ELEMENT_TYPE,
    'Content',
    [
      { name: 'Heading', dataTypeId: dt[DT.textstring] },
      { name: 'Text', dataTypeId: dt[DT.textarea] },
    ],
    'Body',
  );
  await ensureBlockGridAllowsHeroBlock(api, dt[DT.blockGrid], heroBlockId);

  const pageId = await ensurePageDocType(api, dt, [contentExtrasId, seoId, smallId]);
  await ensurePageAllowsPageChild(api, pageId);

  await ensureExtraDocTypes(api);

  // Build the root tree first so the Homepage's Content Picker can reference a
  // real, existing content node (we pick "Page 1").
  await ensureRootTree(api, pageId);
  const relatedNodeId = await resolveRelatedNodeId(api);

  const homepageId = await ensureHomepage(api, pageId, image, heroBlockId, relatedNodeId);
  await ensureHomepageChild(api, pageId, homepageId);
  await ensureEveryRootHasChild(api, pageId);
}

// Pick a real existing content node (not the Homepage) for the Content Picker
// value. Prefers "Page 1"; falls back to the first non-Homepage root node.
async function resolveRelatedNodeId(api: ApiHelpers): Promise<string> {
  const page1 = await api.document.getByName('Page 1');
  if (page1?.id) {
    return page1.id;
  }
  const res = await api.document.getAllAtRoot();
  const json = await res.json();
  for (const item of json.items as any[]) {
    const name = item.variants?.[0]?.name;
    if (name !== HOMEPAGE_NAME) {
      return item.id;
    }
  }
  throw new Error('No existing content node found to use as Content Picker value');
}

// Reuse a single known image across runs (guarded by name).
const IMAGE_NAME = 'LT Hero Image';
async function ensureImage(api: ApiHelpers): Promise<string> {
  const existing = await api.media.getByName(IMAGE_NAME);
  if (existing?.id) {
    return existing.id;
  }
  return api.media.createDefaultMediaWithImage(IMAGE_NAME);
}
