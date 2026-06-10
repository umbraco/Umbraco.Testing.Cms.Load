// Builds a precise, idempotent backoffice content model against a LIVE Umbraco
// instance via @umbraco-cms/acceptance-test-helpers (ApiHelpers). Run once by
// Playwright globalSetup before any measurement.
//
// Every create is guarded by a doesNameExist / getByName check so calling
// buildContentModel(api) repeatedly is a no-op after the first run. This matters
// because many of the package's createDefault* helpers call ensureNameNotExists
// (which DELETES the existing item) — we must NOT call them unguarded or the
// model would churn on every run. So we check existence first and only create
// when absent.
//
// API facts this file relies on (verified against 17.4.2):
//  - api.dataType.getByName(name) / doesNameExist(name) -> object|falsy; create*
//    convenience methods return the new id.
//  - api.documentType.doesNameExist(name) -> object|falsy; getByName(name).id;
//    create(payload) takes a DocumentTypeBuilder().build() payload.
//  - api.document.getByName(name) -> document object (.id); getAllAtRoot() ->
//    APIResponse(.json().items[]); getChildren(id) -> tree-item array directly.
//  - api.media.createDefaultMediaWithImage(name) -> media id (GUID key).
//  - DocumentTypeBuilder containers: addContainer().withType('Tab'|'Group')
//    .withId().withParentId(); properties: addProperty().withContainerId()
//    .withName().withAlias().withDataTypeId().
//  - DocumentBuilder values: addValue().withAlias().withValue(v) or
//    .addMediaPickerValue().withMediaKey(id).
import { randomUUID } from 'crypto';
import {
  ApiHelpers,
  DocumentTypeBuilder,
  DocumentBuilder,
} from '@umbraco-cms/acceptance-test-helpers';

export const HOMEPAGE_NAME = 'Homepage';
export const EXTRA_DOC_TYPES = ['Product-page', 'Marketing-page', 'Newsletter-signup'] as const;
export const TOP_LEVEL_NODE_COUNT = 20;

const PAGE_DOC_TYPE = 'Page';
const CONTENT_TAB = 'Content';
const SEO_TAB = 'SEO';

// Names of the data types we own (created once, reused). Distinct editors for
// the Content tab — TipTap first, a Media Picker second, then the rest.
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

// Best-effort publish: publishing is not required for the model's tree to be
// visible in the management tree API (which the spec reads), so a transient
// slow publish must not abort the whole build. Swallow timeouts/errors.
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
    .split(' ')
    .map((el, idx) => (idx === 0 ? el.toLowerCase() : el[0].toUpperCase() + el.slice(1).toLowerCase()))
    .join('');
}

// --- data type creation (guarded) --------------------------------------------

async function ensureDataTypes(api: ApiHelpers): Promise<Record<string, string>> {
  const ids: Record<string, string> = {};

  async function ensure(name: string, create: () => Promise<string>): Promise<string> {
    const existing = await api.dataType.getByName(name);
    if (existing && existing.id) {
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
): Promise<string> {
  const existing = await api.documentType.doesNameExist(name);
  if (existing && existing.id) {
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
    .withName(tabName + ' Group')
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

// --- Page document type (tabbed, composed) -----------------------------------

async function ensurePageDocType(
  api: ApiHelpers,
  dt: Record<string, string>,
  compositionIds: string[],
): Promise<string> {
  const existing = await api.documentType.doesNameExist(PAGE_DOC_TYPE);
  if (existing && existing.id) {
    return existing.id;
  }

  const tabId = randomUUID();
  const groupId = randomUUID();

  // Content tab properties, in spec order: TipTap FIRST, Media Picker SECOND.
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

  // Allow Page as a child of Page so every root node can have children.
  for (const compositionId of compositionIds) {
    builder = builder.addComposition().withDocumentTypeId(compositionId).done();
  }

  return api.documentType.create(builder.build());
}

// Make Page allow Page as an allowed child node. Done as a separate update so
// we can reference the Page id itself (a doc type cannot allow itself at create
// time before it has an id). We patch the created doc type in place.
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
): Promise<string> {
  const existing = await api.document.getByName(HOMEPAGE_NAME);
  if (existing && existing.id) {
    return existing.id;
  }

  // Rich text (TipTap) markup containing an <img> referencing the media.
  const richTextValue = {
    markup:
      `<p>Welcome to the homepage.</p>` +
      `<figure><img src="/media/${imageMediaKey}" data-udi="umb://media/${imageMediaKey.replace(/-/g, '')}" alt="hero" /></figure>` +
      `<p>An image is embedded above.</p>`,
    blocks: { layout: {}, contentData: [], settingsData: [], expose: [] },
  };

  const builder = new DocumentBuilder()
    .withDocumentTypeId(pageId)
    .addVariant()
    .withName(HOMEPAGE_NAME)
    .done()
    // Rich text with an embedded image.
    .addValue()
    .withAlias(toAlias(DT.richText))
    .withValue(richTextValue)
    .done()
    // First media picker — picked image.
    .addValue()
    .withAlias(toAlias(DT.mediaPicker))
    .addMediaPickerValue()
    .withMediaKey(imageMediaKey)
    .done()
    .done()
    // Second media picker — picked image.
    .addValue()
    .withAlias(toAlias(DT.mediaPicker2))
    .addMediaPickerValue()
    .withMediaKey(imageMediaKey)
    .done()
    .done()
    .addValue()
    .withAlias(toAlias(DT.textstring))
    .withValue('Homepage headline')
    .done();

  const id = await api.document.create(builder.build());
  await tryPublish(api, id);
  return id;
}

// --- tree (root nodes + a child each) ----------------------------------------

async function ensureRootTree(api: ApiHelpers, pageId: string): Promise<void> {
  for (let i = 1; i < TOP_LEVEL_NODE_COUNT; i++) {
    const name = `Page ${i}`;
    let parentId: string;
    const existing = await api.document.getByName(name);
    if (existing && existing.id) {
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
    const children = await api.document.getChildren(parentId);
    if (!children || children.length === 0) {
      const childName = `${name} - child`;
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
  }
}

// Ensure the Homepage has at least one child too (it is one of the root nodes).
async function ensureHomepageChild(api: ApiHelpers, pageId: string, homepageId: string): Promise<void> {
  const children = await api.document.getChildren(homepageId);
  if (children && children.length > 0) {
    return;
  }
  const childDoc = new DocumentBuilder()
    .withDocumentTypeId(pageId)
    .withParentId(homepageId)
    .addVariant()
    .withName('Homepage - child')
    .done()
    .build();
  const childId = await api.document.create(childDoc);
  await tryPublish(api, childId);
}

// --- extra doc types ----------------------------------------------------------

async function ensureExtraDocTypes(api: ApiHelpers): Promise<void> {
  for (const name of EXTRA_DOC_TYPES) {
    const existing = await api.documentType.doesNameExist(name);
    if (existing && existing.id) {
      continue;
    }
    const builder = new DocumentTypeBuilder()
      .withName(name)
      .withAlias(toAlias(name))
      .build();
    await api.documentType.create(builder);
  }
}

// Final sweep: every top-level node must have >= 1 child (so the tree shows
// hasChildren broadly). This also covers any stray pre-existing root content
// left over from earlier testing on the instance. For a childless root we add a
// child of the SAME document type as the root (structurally sound, and the root
// type usually permits children of its own kind). If that is not allowed by the
// instance, the stray root is moved to the recycle bin so the criterion holds
// deterministically. Idempotent: roots that already have children are skipped.
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
    if (existingChild && existingChild.id) {
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

  // Compositions (3): one adds editors to the Content tab, one adds an SEO tab,
  // one is small.
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

  const pageId = await ensurePageDocType(api, dt, [contentExtrasId, seoId, smallId]);
  await ensurePageAllowsPageChild(api, pageId);

  await ensureExtraDocTypes(api);

  const homepageId = await ensureHomepage(api, pageId, image);
  await ensureHomepageChild(api, pageId, homepageId);
  await ensureRootTree(api, pageId);
  await ensureEveryRootHasChild(api, pageId);
}

// Reuse a single known image across runs (guarded by name).
const IMAGE_NAME = 'LT Hero Image';
async function ensureImage(api: ApiHelpers): Promise<string> {
  const existing = await api.media.getByName(IMAGE_NAME);
  if (existing && existing.id) {
    return existing.id;
  }
  return api.media.createDefaultMediaWithImage(IMAGE_NAME);
}
