# Backoffice Client Measurement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third pipeline workload, `client`, that measures browser-perceived Umbraco backoffice performance (cold/cached load of the News dashboard and the Home content node, and end-to-end time-to-first-edit) with Playwright, reusing the existing provisioning + history/monitoring infra and publishing to a dedicated Log Analytics table and Workbook tab.

**Architecture:** A Playwright project lives under `loadtests/scenarios/Default/client/`. A `globalSetup` builds a precise content model via `@umbraco-cms/acceptance-test-helpers` (API) on top of TestDataSeeder bulk. Three spec files measure the five metrics, each repeated N times, emitting per-run NDJSON. A new `azure-pipeline-client.yml` reuses extracted shared stage templates (`provision.yml`, `cleanup.yml`) plus a new `client-measure-job.yml`; results publish to the same history blob storage + a new `ClientMeasurement_CL` Log Analytics table with its own Workbook tab and a report-only regression gate.

**Tech Stack:** Playwright (TypeScript, `@playwright/test`), `@umbraco-cms/acceptance-test-helpers`, Node 20+, PowerShell 7.3+ (publish/regression scripts), Azure Pipelines YAML, Azure CLI, Log Analytics Logs-Ingestion API, Azure Workbook JSON.

**Spec:** `docs/superpowers/specs/2026-06-10-backoffice-client-measurement-design.md`

---

## Conventions used throughout this plan

- **Local-first.** Phases A–B are developed and verified against a **local Umbraco instance** the operator names (env var `UMBRACO_BASE_URL`, default `https://localhost:44339`). The pipeline (Phase C) is wired only after the harness is proven locally.
- **Credentials** for local dev come from env vars `UMBRACO_USER` / `UMBRACO_PASSWORD` (default `loadtest@example.invalid` / `LoadTest123!` — the Terraform unattended-install admin). Never hard-code real secrets.
- **Working directory** for all `npm`/`npx` commands is `loadtests/scenarios/Default/client/` unless stated otherwise.
- **N (repetitions)** defaults to `10`, overridable via env var `CLIENT_MEASURE_REPS`.
- Run **`git add` + `git commit`** at the end of each task. Commit messages use the `feat:`/`refactor:`/`test:` prefix shown.

---

## File Structure

```
loadtests/scenarios/Default/client/
  package.json                       # Playwright + acceptance-test-helpers deps, scripts
  playwright.config.ts               # projects, globalSetup, reporters, output dir
  tsconfig.json                      # TS config for the project
  .gitignore                         # node_modules, test-results, *.ndjson
  global-setup.ts                    # builds the content model (idempotent) before specs
  lib/
    env.ts                           # reads UMBRACO_BASE_URL/USER/PASSWORD/CLIENT_MEASURE_REPS
    api.ts                           # thin wrapper that constructs the acceptance-test-helpers API client
    stats.ts                         # median / p75 / p95 / stddev over number[]
    measure.ts                       # content-visible timing + Performance API capture + per-run NDJSON append
    auth.ts                          # login-by-form (timed) + storageState helper
  fixtures/
    contentModel.ts                  # the Page/compositions/extra-doctypes/tree spec as data + builder fns
  measurements/
    dashboard.spec.ts                # metrics 1 & 2 (cold/cached News dashboard)
    homeNode.spec.ts                 # metrics 3 & 4 (cold/cached Home node)
    timeToFirstEdit.spec.ts          # metric 5 (E2E + segment breakdown)
  results/                           # gitignored; per-metric NDJSON lands here at runtime

scripts/
  publish-client-results.ps1         # results/*.ndjson -> history blob + ClientMeasurement_CL
  check-client-regression.ps1        # median-of-last-N regression gate for client metrics
  ensure-monitoring-infra.ps1        # MODIFIED: add ClientMeasurement_CL table + stream
  resolve-run-config.ps1             # MODIFIED: add 'client' workload value + validation

templates/
  stages/provision.yml               # EXTRACTED from azure-pipeline.yml (shared)
  stages/cleanup.yml                 # EXTRACTED from azure-pipeline.yml (shared)
  jobs/client-measure-job.yml        # NEW per-tier Playwright job

azure-pipeline.yml                   # MODIFIED: consume stages/provision.yml + stages/cleanup.yml
azure-pipeline-client.yml            # NEW client-measurement pipeline
dashboards/loadtest.workbook.json    # MODIFIED: add "Client measurements" tab
README.md                            # MODIFIED: document the client workload
```

---

# Phase A — Playwright harness (local-first)

## Task A1: Scaffold the Playwright project and pin the acceptance-test-helpers API surface

**Why first:** the exact method names of `@umbraco-cms/acceptance-test-helpers` (for the target Umbraco major) are an external dependency this plan must not guess. This task installs it and records the real signatures used by every later task. Treat the smoke test as the source of truth — if a method name differs from what later tasks assume, update the later task to match what this test proves.

**Files:**
- Create: `loadtests/scenarios/Default/client/package.json`
- Create: `loadtests/scenarios/Default/client/tsconfig.json`
- Create: `loadtests/scenarios/Default/client/.gitignore`
- Create: `loadtests/scenarios/Default/client/playwright.config.ts`
- Create: `loadtests/scenarios/Default/client/lib/env.ts`
- Create: `loadtests/scenarios/Default/client/lib/api.ts`
- Create: `loadtests/scenarios/Default/client/measurements/smoke.spec.ts` (temporary; deleted in Step 8)

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "umbraco-client-measurement",
  "version": "1.0.0",
  "private": true,
  "description": "Playwright browser-perceived backoffice performance measurement",
  "scripts": {
    "measure": "playwright test",
    "smoke": "playwright test smoke.spec.ts"
  },
  "devDependencies": {
    "@playwright/test": "^1.48.0",
    "@types/node": "^20.0.0",
    "typescript": "^5.4.0"
  },
  "dependencies": {
    "@umbraco-cms/acceptance-test-helpers": "latest"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "CommonJS",
    "moduleResolution": "Node",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "types": ["node"]
  },
  "include": ["**/*.ts"]
}
```

- [ ] **Step 3: Create `.gitignore`**

```gitignore
node_modules/
test-results/
playwright-report/
results/
.auth/
*.log
```

- [ ] **Step 4: Create `lib/env.ts`**

```ts
// Central place to read runtime configuration. Keeps secrets out of source and
// lets the pipeline override every value via environment variables.
export const env = {
  baseUrl: process.env.UMBRACO_BASE_URL ?? 'https://localhost:44339',
  user: process.env.UMBRACO_USER ?? 'loadtest@example.invalid',
  password: process.env.UMBRACO_PASSWORD ?? 'LoadTest123!',
  // Repetitions per metric. 10 gives a usable median/p95 without ballooning runtime.
  reps: Number(process.env.CLIENT_MEASURE_REPS ?? '10'),
  // Where per-metric NDJSON is appended (one dir, one file per metric).
  resultsDir: process.env.CLIENT_RESULTS_DIR ?? 'results',
  // Run metadata, injected by the pipeline; harmless defaults for local runs.
  runId: process.env.CLIENT_RUN_ID ?? 'local',
  umbracoVersion: process.env.CLIENT_UMBRACO_VERSION ?? 'local',
  tier: process.env.CLIENT_TIER ?? 'local',
  scenario: process.env.CLIENT_SCENARIO ?? 'Default',
};
```

- [ ] **Step 5: Create `lib/api.ts` — the thin API-client wrapper**

This wrapper is the single import point for the acceptance-test-helpers API. Step 7's smoke test proves the actual constructor + method shape; if the real package differs from the import below, fix it HERE and every later task inherits the correction.

```ts
import { APIRequestContext } from '@playwright/test';
// The acceptance-test-helpers package exposes an API helper that wraps an
// authenticated Playwright APIRequestContext. The exact export name is verified
// by smoke.spec.ts (Step 7). Adjust this import to match what the smoke test proves.
import { UmbracoApiHelpers } from '@umbraco-cms/acceptance-test-helpers';
import { env } from './env';

// Build an authenticated API helper bound to the target instance.
export async function makeApi(request: APIRequestContext): Promise<UmbracoApiHelpers> {
  const api = new UmbracoApiHelpers(request, env.baseUrl);
  await api.login(env.user, env.password);
  return api;
}
```

- [ ] **Step 6: Install dependencies and browsers**

Run (in `loadtests/scenarios/Default/client/`):
```bash
npm install
npx playwright install chromium
```
Expected: install completes; `node_modules/@umbraco-cms/acceptance-test-helpers/` exists.

- [ ] **Step 7: Inspect the installed API surface, then write the smoke test**

First, record the real surface so later tasks reference real names:
```bash
node -e "const h=require('@umbraco-cms/acceptance-test-helpers'); console.log(Object.keys(h)); " > ../../../../docs/superpowers/acceptance-helpers-exports.txt
cat ../../../../docs/superpowers/acceptance-helpers-exports.txt
```
Then open `node_modules/@umbraco-cms/acceptance-test-helpers/dist/` (or `lib/`) and note the document-type / document / data-type helper method names. Record them at the top of `fixtures/contentModel.ts` in Task A2.

Create `measurements/smoke.spec.ts`:
```ts
import { test, expect } from '@playwright/test';
import { makeApi } from '../lib/api';

// Proves: (a) the API client constructs + authenticates, (b) we can create and
// delete a document type. The method names below are the contract every later
// data-builder task depends on — if these differ in the installed package,
// this is where the truth is established.
test('acceptance-test-helpers can create and delete a document type', async ({ request }) => {
  const api = await makeApi(request);
  const name = 'SmokeProbeDocType';

  await api.documentType.ensureNameNotExists(name);
  const id = await api.documentType.createDefaultDocumentType(name);
  expect(id).toBeTruthy();

  const exists = await api.documentType.doesNameExist(name);
  expect(exists).toBe(true);

  await api.documentType.delete(id);
  const stillExists = await api.documentType.doesNameExist(name);
  expect(stillExists).toBe(false);
});
```

- [ ] **Step 8: Create `playwright.config.ts`**

```ts
import { defineConfig } from '@playwright/test';
import { env } from './lib/env';

export default defineConfig({
  testDir: './measurements',
  // Measurements must not run in parallel — concurrent browsers contend for the
  // agent's CPU and pollute timing. One worker, serial.
  workers: 1,
  fullyParallel: false,
  // No retries: a failed measurement is data we want to see, not paper over.
  retries: 0,
  // Generous: cold loads on a small tier can be slow; reps multiply duration.
  timeout: 120_000,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: env.baseUrl,
    // Self-signed localhost certs on local dev instances.
    ignoreHTTPSErrors: true,
    headless: true,
    viewport: { width: 1920, height: 1080 },
  },
});
```

- [ ] **Step 9: Run the smoke test against the local instance**

Run:
```bash
UMBRACO_BASE_URL=https://localhost:44339 npx playwright test smoke.spec.ts
```
Expected: PASS. If method names differ, fix `lib/api.ts` and the test to match the real package, re-run until green. Record the confirmed method names for Task A2.

- [ ] **Step 10: Delete the temporary smoke test**

```bash
rm measurements/smoke.spec.ts
```

- [ ] **Step 11: Commit**

```bash
git add loadtests/scenarios/Default/client docs/superpowers/acceptance-helpers-exports.txt
git commit -m "feat: scaffold client-measurement Playwright project + pin acceptance-test-helpers API"
```

---

## Task A2: Build the content model (idempotent) via globalSetup

**Files:**
- Create: `loadtests/scenarios/Default/client/fixtures/contentModel.ts`
- Create: `loadtests/scenarios/Default/client/global-setup.ts`
- Test: `loadtests/scenarios/Default/client/measurements/model.spec.ts`

> The `api.documentType.*` / `api.document.*` / `api.dataType.*` method names below MUST match what Task A1 Step 9 confirmed. Where this plan and the real package disagree, the package wins — adjust the calls, keep the structure.

- [ ] **Step 1: Write the failing test `measurements/model.spec.ts`**

```ts
import { test, expect } from '@playwright/test';
import { makeApi } from '../lib/api';
import { buildContentModel, HOMEPAGE_NAME, EXTRA_DOC_TYPES, TOP_LEVEL_NODE_COUNT } from '../fixtures/contentModel';

// Verifies globalSetup's builder produced exactly the spec'd model. Idempotent:
// running twice must not duplicate doctypes or nodes.
test('content model is built to spec', async ({ request }) => {
  const api = await makeApi(request);

  // Page doctype exists and uses tabs with a Content tab + an SEO tab (from composition).
  expect(await api.documentType.doesNameExist('Page')).toBe(true);

  // The three extra doctypes exist.
  for (const dt of EXTRA_DOC_TYPES) {
    expect(await api.documentType.doesNameExist(dt)).toBe(true);
  }

  // Homepage exists at root and has >= 10 distinct property editors populated.
  const homepageId = await api.document.getIdByName(HOMEPAGE_NAME);
  expect(homepageId).toBeTruthy();

  // ~20 top-level nodes, each with >= 1 child.
  const rootChildren = await api.document.getChildrenIds(null);
  expect(rootChildren.length).toBeGreaterThanOrEqual(TOP_LEVEL_NODE_COUNT);
  for (const nodeId of rootChildren) {
    const kids = await api.document.getChildrenIds(nodeId);
    expect(kids.length).toBeGreaterThanOrEqual(1);
  }

  // Idempotency: a second build adds nothing.
  await buildContentModel(api);
  const rootChildrenAgain = await api.document.getChildrenIds(null);
  expect(rootChildrenAgain.length).toBe(rootChildren.length);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
npx playwright test model.spec.ts
```
Expected: FAIL — `buildContentModel` not exported / model not built.

- [ ] **Step 3: Write `fixtures/contentModel.ts`**

```ts
import type { UmbracoApiHelpers } from '@umbraco-cms/acceptance-test-helpers';

// === Confirmed acceptance-test-helpers method names (from Task A1 Step 9) ===
// documentType.doesNameExist / createDefaultDocumentType / delete / addTab /
//   addPropertyEditor / addComposition ; document.create / getIdByName /
//   getChildrenIds ; dataType / media helpers as recorded. Adjust if different.

export const HOMEPAGE_NAME = 'Homepage';
export const EXTRA_DOC_TYPES = ['Product-page', 'Marketing-page', 'Newsletter-signup'] as const;
export const TOP_LEVEL_NODE_COUNT = 20;

// Distinct property editors on the Page Content tab (>= 9 here; the Hero
// composition adds 2 more -> > 10 distinct, satisfying the spec).
const CONTENT_TAB_PROPERTIES = [
  { alias: 'bodyText', name: 'Body Text', editor: 'Umbraco.RichText' },       // TipTap, top
  { alias: 'heroImage', name: 'Hero Image', editor: 'Umbraco.MediaPicker3' }, // top-right
  { alias: 'blocks', name: 'Blocks', editor: 'Umbraco.BlockGrid' },
  { alias: 'gallery', name: 'Gallery', editor: 'Umbraco.MediaPicker3' },      // second media picker
  { alias: 'title', name: 'Title', editor: 'Umbraco.TextBox' },
  { alias: 'summary', name: 'Summary', editor: 'Umbraco.TextArea' },
  { alias: 'sortOrder', name: 'Sort Order', editor: 'Umbraco.Integer' },
  { alias: 'featured', name: 'Featured', editor: 'Umbraco.TrueFalse' },
  { alias: 'publishDate', name: 'Publish Date', editor: 'Umbraco.DateTime' },
];

// Composition: adds editors to the EXISTING Content tab.
const HERO_COMPOSITION_PROPERTIES = [
  { alias: 'relatedPage', name: 'Related Page', editor: 'Umbraco.ContentPicker' },
  { alias: 'links', name: 'Links', editor: 'Umbraco.MultiUrlPicker' },
];

// Composition: adds a NEW SEO tab.
const SEO_COMPOSITION_PROPERTIES = [
  { alias: 'metaTitle', name: 'Meta Title', editor: 'Umbraco.TextBox' },
  { alias: 'metaDescription', name: 'Meta Description', editor: 'Umbraco.TextArea' },
  { alias: 'canonicalUrl', name: 'Canonical URL', editor: 'Umbraco.MultiUrlPicker' },
  { alias: 'noIndex', name: 'No Index', editor: 'Umbraco.TrueFalse' },
];

// Third small composition for the "2-3 compositions" wish.
const TRACKING_COMPOSITION_PROPERTIES = [
  { alias: 'tags', name: 'Tags', editor: 'Umbraco.Tags' },
  { alias: 'priority', name: 'Priority', editor: 'Umbraco.Integer' },
];

// Idempotent end-to-end model build. Safe to call repeatedly.
export async function buildContentModel(api: UmbracoApiHelpers): Promise<void> {
  // 1. Compositions first (Page composes them).
  const heroId = await ensureComposition(api, 'Hero', 'Content', HERO_COMPOSITION_PROPERTIES);
  const seoId = await ensureComposition(api, 'Seo', 'SEO', SEO_COMPOSITION_PROPERTIES);
  const trackingId = await ensureComposition(api, 'Tracking', 'Tracking', TRACKING_COMPOSITION_PROPERTIES);

  // 2. Page doctype with a Content tab + its own properties + compositions.
  const pageId = await ensurePageDocType(api, [heroId, seoId, trackingId]);

  // 3. Extra empty doctypes.
  for (const dt of EXTRA_DOC_TYPES) {
    if (!(await api.documentType.doesNameExist(dt))) {
      await api.documentType.createDefaultDocumentType(dt);
    }
  }

  // 4. Homepage: the single fully-populated Page node, built first so it's node #1.
  await ensureHomepage(api, pageId);

  // 5. Remaining top-level nodes + one child each.
  await ensureTree(api, pageId);
}

async function ensureComposition(
  api: UmbracoApiHelpers, name: string, tab: string,
  props: { alias: string; name: string; editor: string }[],
): Promise<string> {
  if (await api.documentType.doesNameExist(name)) {
    return api.documentType.getIdByName(name);
  }
  const id = await api.documentType.createDefaultDocumentType(name);
  await api.documentType.addTab(id, tab);
  for (const p of props) {
    await api.documentType.addPropertyEditor(id, tab, p.alias, p.name, p.editor);
  }
  return id;
}

async function ensurePageDocType(api: UmbracoApiHelpers, compositionIds: string[]): Promise<string> {
  if (await api.documentType.doesNameExist('Page')) {
    return api.documentType.getIdByName('Page');
  }
  const id = await api.documentType.createDefaultDocumentType('Page');
  await api.documentType.addTab(id, 'Content');
  for (const p of CONTENT_TAB_PROPERTIES) {
    await api.documentType.addPropertyEditor(id, 'Content', p.alias, p.name, p.editor);
  }
  for (const compId of compositionIds) {
    await api.documentType.addComposition(id, compId);
  }
  // Allow at root so it can be the homepage + top-level nodes.
  await api.documentType.allowAtRoot(id, true);
  await api.documentType.allowAsChild(id, id); // Page can nest under Page (children)
  return id;
}

async function ensureHomepage(api: UmbracoApiHelpers, pageDocTypeId: string): Promise<void> {
  if (await api.document.getIdByName(HOMEPAGE_NAME)) return;
  // Pick one already-seeded media item id for the media pickers + an inline image.
  const mediaId = await api.media.getFirstImageId();
  await api.document.create({
    name: HOMEPAGE_NAME,
    documentTypeId: pageDocTypeId,
    parentId: null,
    values: {
      // RichText body that embeds one image (TipTap renders it on load).
      bodyText: api.richText.withImage('<p>Welcome to the homepage.</p>', mediaId),
      heroImage: api.mediaPicker.single(mediaId),
      gallery: api.mediaPicker.single(mediaId),
      title: 'Home',
      summary: 'Performance baseline homepage.',
      featured: true,
    },
  });
}

async function ensureTree(api: UmbracoApiHelpers, pageDocTypeId: string): Promise<void> {
  const existing = await api.document.getChildrenIds(null);
  for (let i = existing.length; i < TOP_LEVEL_NODE_COUNT; i++) {
    const nodeId = await api.document.create({
      name: `Node ${i}`,
      documentTypeId: pageDocTypeId,
      parentId: null,
      values: { title: `Node ${i}` },
    });
    // One child so the tree shows hasChildren: true broadly.
    await api.document.create({
      name: `Node ${i} child`,
      documentTypeId: pageDocTypeId,
      parentId: nodeId,
      values: { title: `Node ${i} child` },
    });
  }
}
```

- [ ] **Step 4: Write `global-setup.ts`**

```ts
import { request, FullConfig } from '@playwright/test';
import { makeApi } from './lib/api';
import { buildContentModel } from './fixtures/contentModel';
import { env } from './lib/env';

// Runs once before any spec. Builds the precise content model on top of whatever
// TestDataSeeder bulk already exists. Idempotent so re-runs (and the model.spec
// idempotency assertion) are safe.
export default async function globalSetup(_config: FullConfig): Promise<void> {
  const ctx = await request.newContext({ baseURL: env.baseUrl, ignoreHTTPSErrors: true });
  try {
    const api = await makeApi(ctx);
    await buildContentModel(api);
    console.log('[global-setup] content model ready');
  } finally {
    await ctx.dispose();
  }
}
```

- [ ] **Step 5: Wire globalSetup into `playwright.config.ts`**

Modify `playwright.config.ts` — add inside `defineConfig({ ... })`:
```ts
  globalSetup: require.resolve('./global-setup'),
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
npx playwright test model.spec.ts
```
Expected: PASS (globalSetup builds the model; assertions + idempotency hold). If a helper method name is wrong, fix it in `fixtures/contentModel.ts` per the real package and re-run.

- [ ] **Step 7: Commit**

```bash
git add loadtests/scenarios/Default/client
git commit -m "feat: build precise backoffice content model via acceptance-test-helpers"
```

---

## Task A3: Stats helpers

**Files:**
- Create: `loadtests/scenarios/Default/client/lib/stats.ts`
- Test: `loadtests/scenarios/Default/client/measurements/stats.spec.ts`

- [ ] **Step 1: Write the failing test `measurements/stats.spec.ts`**

```ts
import { test, expect } from '@playwright/test';
import { summarize } from '../lib/stats';

test('summarize computes median, p75, p95, stddev', () => {
  const s = summarize([10, 20, 30, 40, 50, 60, 70, 80, 90, 100]);
  expect(s.count).toBe(10);
  expect(s.median).toBe(55);          // mean of 50 and 60
  expect(s.p75).toBe(80);             // nearest-rank p75
  expect(s.p95).toBe(100);            // nearest-rank p95
  expect(s.min).toBe(10);
  expect(s.max).toBe(100);
  expect(Math.round(s.stddev)).toBe(29);
});

test('summarize handles a single value', () => {
  const s = summarize([42]);
  expect(s.median).toBe(42);
  expect(s.p95).toBe(42);
  expect(s.stddev).toBe(0);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx playwright test stats.spec.ts`
Expected: FAIL — `summarize` not defined.

- [ ] **Step 3: Write `lib/stats.ts`**

```ts
export interface Summary {
  count: number;
  median: number;
  p75: number;
  p95: number;
  min: number;
  max: number;
  stddev: number;
}

// Nearest-rank percentile on a sorted copy. p(50) returns the mean of the two
// middle values for even-length input (classic median), higher percentiles use
// nearest-rank for stability on small N.
function percentile(sorted: number[], p: number): number {
  if (sorted.length === 1) return sorted[0];
  if (p === 50) {
    const mid = sorted.length / 2;
    return Number.isInteger(mid)
      ? (sorted[mid - 1] + sorted[mid]) / 2
      : sorted[Math.floor(mid)];
  }
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(rank, sorted.length) - 1];
}

export function summarize(values: number[]): Summary {
  if (values.length === 0) {
    return { count: 0, median: 0, p75: 0, p95: 0, min: 0, max: 0, stddev: 0 };
  }
  const sorted = [...values].sort((a, b) => a - b);
  const mean = sorted.reduce((acc, v) => acc + v, 0) / sorted.length;
  const variance = sorted.reduce((acc, v) => acc + (v - mean) ** 2, 0) / sorted.length;
  return {
    count: sorted.length,
    median: percentile(sorted, 50),
    p75: percentile(sorted, 75),
    p95: percentile(sorted, 95),
    min: sorted[0],
    max: sorted[sorted.length - 1],
    stddev: Math.sqrt(variance),
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx playwright test stats.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add loadtests/scenarios/Default/client/lib/stats.ts loadtests/scenarios/Default/client/measurements/stats.spec.ts
git commit -m "feat: add stats summary helper (median/p75/p95/stddev)"
```

---

## Task A4: Measurement helpers (content-visible timing + NDJSON emit)

**Files:**
- Create: `loadtests/scenarios/Default/client/lib/measure.ts`
- Test: `loadtests/scenarios/Default/client/measurements/measure.spec.ts`

- [ ] **Step 1: Write the failing test `measurements/measure.spec.ts`**

```ts
import { test, expect } from '@playwright/test';
import { mkdtempSync, readFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { emitMetric } from '../lib/measure';

test('emitMetric appends one NDJSON row with stats + metadata', () => {
  const dir = mkdtempSync(join(tmpdir(), 'cm-'));
  emitMetric('cold_homepage_load', [120, 130, 140], { extra: 'x' }, dir);
  const file = join(dir, 'cold_homepage_load.ndjson');
  const row = JSON.parse(readFileSync(file, 'utf8').trim());
  expect(row.metric).toBe('cold_homepage_load');
  expect(row.median).toBe(130);
  expect(row.count).toBe(3);
  expect(row.extra).toBe('x');
  expect(row.run_id).toBeTruthy();
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx playwright test measure.spec.ts`
Expected: FAIL — `emitMetric` not defined.

- [ ] **Step 3: Write `lib/measure.ts`**

```ts
import { Page, Locator } from '@playwright/test';
import { appendFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { summarize } from './stats';
import { env } from './env';

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx playwright test measure.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add loadtests/scenarios/Default/client/lib/measure.ts loadtests/scenarios/Default/client/measurements/measure.spec.ts
git commit -m "feat: add content-visible timing + NDJSON metric emitter"
```

---

## Task A5: Auth helper (timed login + storageState)

**Files:**
- Create: `loadtests/scenarios/Default/client/lib/auth.ts`
- Test: `loadtests/scenarios/Default/client/measurements/auth.spec.ts`

> Selectors below target the Umbraco v14+ login screen (`umb-login` web component). Confirm the exact field/button selectors against the live instance during Step 4; adjust if the markup differs for the target major.

- [ ] **Step 1: Write the failing test `measurements/auth.spec.ts`**

```ts
import { test, expect } from '@playwright/test';
import { loginByForm, BACKOFFICE_PATH } from '../lib/auth';

test('loginByForm authenticates and lands in the backoffice', async ({ page }) => {
  const ms = await loginByForm(page);
  expect(ms).toBeGreaterThan(0);
  // After login we are inside the backoffice section shell.
  await expect(page).toHaveURL(new RegExp(`${BACKOFFICE_PATH}`));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx playwright test auth.spec.ts`
Expected: FAIL — `loginByForm` not defined.

- [ ] **Step 3: Write `lib/auth.ts`**

```ts
import { Page } from '@playwright/test';
import { env } from './env';

export const BACKOFFICE_PATH = '/umbraco';

// Real login-form submit with stored credentials, timed. Returns ms from
// navigation start until the backoffice section shell is visible. Used as the
// first segment of time-to-first-edit and to produce a reusable storageState.
export async function loginByForm(page: Page): Promise<number> {
  const start = performance.now();
  await page.goto(`${env.baseUrl}${BACKOFFICE_PATH}`);
  // Umbraco v14+ login is a web component; fields carry name=email / name=password.
  await page.fill('input[name="email"]', env.user);
  await page.fill('input[name="password"]', env.password);
  await page.click('button[type="submit"]');
  // Section sidebar is the reliable "logged in" content-visible signal.
  await page.locator('umb-section-sidebar, [data-mark="section-sidebar"]').first()
    .waitFor({ state: 'visible', timeout: 60_000 });
  return performance.now() - start;
}

// Save an authenticated storageState to disk for the load measurements (which
// must not pay the login cost on every rep).
export async function saveAuthState(page: Page, path: string): Promise<void> {
  await loginByForm(page);
  await page.context().storageState({ path });
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx playwright test auth.spec.ts`
Expected: PASS. If selectors don't match, inspect the live login page (`npx playwright codegen $UMBRACO_BASE_URL/umbraco`), fix selectors, re-run.

- [ ] **Step 5: Commit**

```bash
git add loadtests/scenarios/Default/client/lib/auth.ts loadtests/scenarios/Default/client/measurements/auth.spec.ts
git commit -m "feat: add timed backoffice login + storageState helper"
```

---

## Task A6: Cold/cached News dashboard measurement (metrics 1 & 2)

**Files:**
- Create: `loadtests/scenarios/Default/client/measurements/dashboard.spec.ts`

> The News dashboard renders an article list. Confirm the article-list container selector against the live dashboard during Step 3; the `[data-mark]` / component selector below is the content-visible signal.

- [ ] **Step 1: Write the spec `measurements/dashboard.spec.ts`**

```ts
import { test } from '@playwright/test';
import { env } from '../lib/env';
import { loginByForm } from '../lib/auth';
import { timeUntilVisible, perfMarks, emitMetric } from '../lib/measure';

const ARTICLE_LIST = 'umb-dashboard-feedback, .umb-dashboard, [data-mark="dashboard-news"]';

// Cold = fresh browser context, no cache, against an already-warm server.
// Cached = second visit in the same context.
test('news dashboard cold + cached load', async ({ browser }) => {
  const cold: number[] = [];
  const cached: number[] = [];
  let lastMarks: Record<string, number | null> = {};

  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    await loginByForm(page);

    // COLD: first navigation to the dashboard in this fresh context.
    const t0 = performance.now();
    await page.goto(`${env.baseUrl}/umbraco`);
    cold.push(await timeUntilVisible(t0, page.locator(ARTICLE_LIST).first()));
    lastMarks = await perfMarks(page);

    // CACHED: reload the same dashboard in the same (now-warm) context.
    const t1 = performance.now();
    await page.reload();
    cached.push(await timeUntilVisible(t1, page.locator(ARTICLE_LIST).first()));

    await context.close();
  }

  emitMetric('cold_dashboard_load', cold, lastMarks);
  emitMetric('cached_dashboard_load', cached);
});
```

- [ ] **Step 2: Run the spec against the local instance**

Run:
```bash
npx playwright test dashboard.spec.ts
```
Expected: PASS; `results/cold_dashboard_load.ndjson` and `results/cached_dashboard_load.ndjson` each contain one row with `count == reps`. Cached median should be ≤ cold median (sanity check). If the article-list selector never becomes visible, fix `ARTICLE_LIST` via `npx playwright codegen`.

- [ ] **Step 3: Commit**

```bash
git add loadtests/scenarios/Default/client/measurements/dashboard.spec.ts
git commit -m "feat: measure cold/cached news dashboard load"
```

---

## Task A7: Cold/cached Home node measurement (metrics 3 & 4)

**Files:**
- Create: `loadtests/scenarios/Default/client/measurements/homeNode.spec.ts`

> The content-visible signal is the TipTap editor field painted. Confirm the TipTap container selector (`umb-input-tiptap` / the ProseMirror editor root) against the live Homepage during Step 2.

- [ ] **Step 1: Write the spec `measurements/homeNode.spec.ts`**

```ts
import { test } from '@playwright/test';
import { env } from '../lib/env';
import { loginByForm } from '../lib/auth';
import { timeUntilVisible, perfMarks, emitMetric } from '../lib/measure';
import { HOMEPAGE_NAME } from '../fixtures/contentModel';

const TIPTAP = 'umb-input-tiptap .tiptap, .ProseMirror, [data-mark="tiptap-editor"]';

// Opens the Home content node (the rich Page) and times until the TipTap editor
// field is painted — the moment the user can see the content they came to edit.
test('home node cold + cached load', async ({ browser }) => {
  const cold: number[] = [];
  const cached: number[] = [];
  let lastMarks: Record<string, number | null> = {};

  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    await loginByForm(page);

    // Navigate to Content section and open the Homepage node.
    await page.goto(`${env.baseUrl}/umbraco`);
    await page.locator('umb-section-sidebar a, [data-mark="section:content"]').first().click();

    // COLD: first open of the node in this fresh context.
    const t0 = performance.now();
    await page.getByText(HOMEPAGE_NAME, { exact: true }).first().click();
    cold.push(await timeUntilVisible(t0, page.locator(TIPTAP).first()));
    lastMarks = await perfMarks(page);

    // CACHED: navigate away and back to the same node in the same context.
    await page.goBack();
    const t1 = performance.now();
    await page.getByText(HOMEPAGE_NAME, { exact: true }).first().click();
    cached.push(await timeUntilVisible(t1, page.locator(TIPTAP).first()));

    await context.close();
  }

  emitMetric('cold_homenode_load', cold, lastMarks);
  emitMetric('cached_homenode_load', cached);
});
```

- [ ] **Step 2: Run the spec against the local instance**

Run:
```bash
npx playwright test homeNode.spec.ts
```
Expected: PASS; `results/cold_homenode_load.ndjson` + `results/cached_homenode_load.ndjson` each have one row with `count == reps`. Fix selectors via `codegen` if the tree-node click or TipTap wait fails.

- [ ] **Step 3: Commit**

```bash
git add loadtests/scenarios/Default/client/measurements/homeNode.spec.ts
git commit -m "feat: measure cold/cached home node load"
```

---

## Task A8: Time-to-first-edit measurement (metric 5 + segments)

**Files:**
- Create: `loadtests/scenarios/Default/client/measurements/timeToFirstEdit.spec.ts`

- [ ] **Step 1: Write the spec `measurements/timeToFirstEdit.spec.ts`**

```ts
import { test } from '@playwright/test';
import { env } from '../lib/env';
import { loginByForm, BACKOFFICE_PATH } from '../lib/auth';
import { emitMetric } from '../lib/measure';
import { summarize } from '../lib/stats';
import { HOMEPAGE_NAME } from '../fixtures/contentModel';

const TIPTAP = 'umb-input-tiptap .tiptap, .ProseMirror, [data-mark="tiptap-editor"]';

// End-to-end: open URL -> login -> open Home node -> cursor into TipTap -> type a
// character -> until that character is rendered. Also captures the four segment
// timings so we can see where the total goes.
test('time to first edit (end-to-end + segments)', async ({ browser }) => {
  const total: number[] = [];
  const seg = { login: [] as number[], navigate: [] as number[], editorReady: [] as number[], keystroke: [] as number[] };

  for (let i = 0; i < env.reps; i++) {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();

    const tStart = performance.now();

    // Segment 1: login (real form submit with stored creds).
    seg.login.push(await loginByForm(page));

    // Segment 2: navigate to the Home node.
    const tNav = performance.now();
    await page.locator('umb-section-sidebar a, [data-mark="section:content"]').first().click();
    await page.getByText(HOMEPAGE_NAME, { exact: true }).first().click();
    seg.navigate.push(performance.now() - tNav);

    // Segment 3: editor ready (TipTap field visible).
    const tEditor = performance.now();
    const editor = page.locator(TIPTAP).first();
    await editor.waitFor({ state: 'visible', timeout: 60_000 });
    seg.editorReady.push(performance.now() - tEditor);

    // Segment 4: first keystroke rendered.
    const tKey = performance.now();
    await editor.click();
    await page.keyboard.type('x');
    await editor.getByText('x', { exact: false }).first().waitFor({ state: 'visible', timeout: 30_000 });
    seg.keystroke.push(performance.now() - tKey);

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
```

- [ ] **Step 2: Run the spec against the local instance**

Run:
```bash
npx playwright test timeToFirstEdit.spec.ts
```
Expected: PASS; `results/time_to_first_edit.ndjson` has one row with `count == reps` and the four `seg_*_median` fields populated. The four segment medians should roughly sum to ≤ the total median.

- [ ] **Step 3: Run the whole suite to confirm all five metrics emit**

Run:
```bash
rm -rf results && npx playwright test
ls results
```
Expected: 5 NDJSON files — `cold_dashboard_load`, `cached_dashboard_load`, `cold_homenode_load`, `cached_homenode_load`, `time_to_first_edit`.

- [ ] **Step 4: Commit**

```bash
git add loadtests/scenarios/Default/client/measurements/timeToFirstEdit.spec.ts
git commit -m "feat: measure end-to-end time-to-first-edit with segment breakdown"
```

---

# Phase B — Publish + monitoring infra

## Task B1: Add the ClientMeasurement_CL table + stream to ensure-monitoring-infra.ps1

**Files:**
- Modify: `scripts/ensure-monitoring-infra.ps1`

- [ ] **Step 1: Add the client table parameter**

In the `param(...)` block (after `$SeriesTableName`, around line 35), add:
```powershell
    # Client-side perceived-latency table (Playwright client workload). One row
    # per (run × metric) — cold/cached dashboard + home-node load, time-to-first-edit.
    # Semantically distinct from the load-test throughput tables, so it gets its
    # own table + stream rather than overloading LoadTestSummary_CL.
    [string]$ClientTableName = "ClientMeasurement_CL",
```

- [ ] **Step 2: Add the client column schema**

After the `$seriesColumns = @(...)` block (around line 145), add:
```powershell
# Client-measurement schema. One row per (run × metric). Kept narrow: run
# metadata + the summary stats the Playwright emitter produces + optional
# segment medians for time_to_first_edit (null for the other metrics).
$clientColumns = @(
    @{ name = "TimeGenerated";          type = "datetime" }
    @{ name = "run_id";                 type = "string"   }
    @{ name = "commit";                 type = "string"   }
    @{ name = "branch";                 type = "string"   }
    @{ name = "umbraco_version";        type = "string"   }
    @{ name = "app_service_sku";        type = "string"   }
    @{ name = "pool_dtu_max";           type = "int"      }
    @{ name = "seeder_preset";          type = "string"   }
    @{ name = "infra_tier";             type = "string"   }
    @{ name = "scenario";               type = "string"   }
    @{ name = "metric";                 type = "string"   }   # cold_dashboard_load, etc.
    @{ name = "count";                  type = "int"      }
    @{ name = "median_ms";              type = "real"     }
    @{ name = "p75_ms";                 type = "real"     }
    @{ name = "p95_ms";                 type = "real"     }
    @{ name = "min_ms";                 type = "real"     }
    @{ name = "max_ms";                 type = "real"     }
    @{ name = "stddev_ms";              type = "real"     }
    @{ name = "ttfb_ms";                type = "real"     }
    @{ name = "dcl_ms";                 type = "real"     }
    @{ name = "load_ms";                type = "real"     }
    @{ name = "lcp_ms";                 type = "real"     }
    # Segment medians — populated only for time_to_first_edit.
    @{ name = "seg_login_ms";           type = "real"     }
    @{ name = "seg_navigate_ms";        type = "real"     }
    @{ name = "seg_editor_ready_ms";    type = "real"     }
    @{ name = "seg_keystroke_ms";       type = "real"     }
    # Regression-check marker rows (parse_status pattern mirrors LoadTestSummary_CL).
    @{ name = "regression_status";      type = "string"   }
    @{ name = "regressed_metrics";      type = "string"   }
)
```

- [ ] **Step 3: Define the client stream name**

After `$seriesStreamName = "Custom-$SeriesTableName"` (around line 148), add:
```powershell
$clientStreamName = "Custom-$ClientTableName"
```

- [ ] **Step 4: Create the client table**

After `Set-CustomTable -Name $SeriesTableName -Columns $seriesColumns` (around line 222), add:
```powershell
Set-CustomTable -Name $ClientTableName -Columns $clientColumns
```

- [ ] **Step 5: Register the client stream + dataflow in the DCR body**

In the `$dcrBody` hashtable, add to `streamDeclarations` (alongside `$streamName` / `$seriesStreamName`):
```powershell
            $clientStreamName = @{ columns = $clientColumns }
```
and add a third entry to the `dataFlows` array:
```powershell
            ,@{
                streams      = @($clientStreamName)
                destinations = @("loadtest-workspace")
                outputStream = $clientStreamName
                transformKql = "source"
            }
```

- [ ] **Step 6: Emit the client stream name as an output**

In the final output block (around line 370 and again in the `if ($EmitPipelineVars)` block around line 376), add:
```powershell
Write-Host "  ClientStreamName: $clientStreamName"
```
and (inside `if ($EmitPipelineVars)`):
```powershell
    Write-Host "##vso[task.setvariable variable=MonitoringClientStreamName;isOutput=true]$clientStreamName"
```

- [ ] **Step 7: Syntax-check the script**

Run:
```bash
pwsh -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('scripts/ensure-monitoring-infra.ps1',[ref]\$null,[ref]\$null); 'parsed ok'"
```
Expected: `parsed ok` (no parse errors). A live idempotency run happens in Phase C.

- [ ] **Step 8: Commit**

```bash
git add scripts/ensure-monitoring-infra.ps1
git commit -m "feat: add ClientMeasurement_CL table + stream to monitoring infra"
```

---

## Task B2: publish-client-results.ps1

**Files:**
- Create: `scripts/publish-client-results.ps1`
- Test: `scripts/tests/publish-client-results.Tests.ps1`

- [ ] **Step 1: Write the failing Pester test `scripts/tests/publish-client-results.Tests.ps1`**

```powershell
# Verifies the NDJSON->row transform without touching Azure: the script's
# Build-ClientRows function must turn the Playwright per-metric NDJSON into LA-shaped
# rows carrying run metadata. Azure blob/LA POSTs are covered by the live Phase C run.
BeforeAll {
    . "$PSScriptRoot/../publish-client-results.ps1" -DotSourceForTest
}

Describe 'Build-ClientRows' {
    It 'maps a metric NDJSON file to a row with metadata + stats' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        @'
{"metric":"cold_dashboard_load","run_id":"local","count":10,"median":130,"p75":140,"p95":160,"min":110,"max":180,"stddev":15.2,"ttfb_ms":40,"dcl_ms":200,"load_ms":300,"lcp_ms":250}
'@ | Out-File (Join-Path $tmp 'cold_dashboard_load.ndjson') -Encoding utf8

        $rows = Build-ClientRows -ResultsDir $tmp -UmbracoVersion '17.0.0' -Tier 'Starter' `
            -Scenario 'Default' -AppServiceSku 'P0v3' -PoolDtuMax 20 -SeederPreset 'Medium' `
            -BuildId '123' -Commit 'abc' -Branch 'main' -RunStartedAt '2026-06-10T00:00:00Z'

        $rows.Count | Should -Be 1
        $rows[0].metric | Should -Be 'cold_dashboard_load'
        $rows[0].median_ms | Should -Be 130
        $rows[0].umbraco_version | Should -Be '17.0.0'
        $rows[0].infra_tier | Should -Be 'Starter'
        $rows[0].run_id | Should -Be '123'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester scripts/tests/publish-client-results.Tests.ps1 -Output Detailed"
```
Expected: FAIL — script/function not found.

- [ ] **Step 3: Write `scripts/publish-client-results.ps1`**

```powershell
#requires -Version 7.3

# Publish client-measurement results to history storage + Log Analytics:
#   client/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/summary.ndjson
#   client/{major}/{umbracoVersion}/{tier}/{yyyy-MM-dd}_{buildId}/raw/...   (per-metric NDJSON)
#
# Mirrors publish-load-test-results.ps1 but for the Playwright `client` workload.
# Client perceived-latency rows go to their own table (ClientMeasurement_CL) so
# they never mix with the load-test throughput schema.

[CmdletBinding()]
param(
    [string]$ResultsDir,
    [string]$HistoryResourceGroup,
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$BuildId,
    [string]$Commit,
    [string]$Branch,
    [string]$RunStartedAt,
    [string]$UmbracoVersion,
    [string]$AppServiceSku,
    [int]$PoolDtuMax,
    [string]$SeederPreset,
    [string]$Tier,
    [string]$Scenario,
    [string]$LogAnalyticsDceUri,
    [string]$LogAnalyticsDcrImmutableId,
    [string]$LogAnalyticsClientStreamName,
    # Lets the Pester test dot-source the file to test Build-ClientRows without running main.
    [switch]$DotSourceForTest
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"

# Transform the Playwright per-metric NDJSON files into LA-shaped rows carrying
# full run metadata, so cross-run queries need no joins. Pure function — unit-tested.
function Build-ClientRows {
    param(
        [Parameter(Mandatory)] [string]$ResultsDir,
        [Parameter(Mandatory)] [string]$UmbracoVersion,
        [Parameter(Mandatory)] [string]$Tier,
        [Parameter(Mandatory)] [string]$Scenario,
        [Parameter(Mandatory)] [string]$AppServiceSku,
        [Parameter(Mandatory)] [int]$PoolDtuMax,
        [Parameter(Mandatory)] [string]$SeederPreset,
        [Parameter(Mandatory)] [string]$BuildId,
        [Parameter(Mandatory)] [string]$Commit,
        [Parameter(Mandatory)] [string]$Branch,
        [Parameter(Mandatory)] [string]$RunStartedAt
    )
    $rows = @()
    $files = @(Get-ChildItem -Path $ResultsDir -Filter '*.ndjson' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        foreach ($line in (Get-Content $f.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $m = $line | ConvertFrom-Json
            $rows += [pscustomobject][ordered]@{
                TimeGenerated       = $RunStartedAt
                run_id              = $BuildId
                commit              = $Commit
                branch              = $Branch
                umbraco_version     = $UmbracoVersion
                app_service_sku     = $AppServiceSku
                pool_dtu_max        = $PoolDtuMax
                seeder_preset       = $SeederPreset
                infra_tier          = $Tier
                scenario            = $Scenario
                metric              = $m.metric
                count               = $m.count
                median_ms           = $m.median
                p75_ms              = $m.p75
                p95_ms              = $m.p95
                min_ms              = $m.min
                max_ms              = $m.max
                stddev_ms           = $m.stddev
                ttfb_ms             = $m.ttfb_ms
                dcl_ms              = $m.dcl_ms
                load_ms             = $m.load_ms
                lcp_ms              = $m.lcp_ms
                seg_login_ms        = $m.seg_login_median
                seg_navigate_ms     = $m.seg_navigate_median
                seg_editor_ready_ms = $m.seg_editor_ready_median
                seg_keystroke_ms    = $m.seg_keystroke_median
            }
        }
    }
    return $rows
}

# Logs Ingestion mirror — same shape as publish-load-test-results.ps1's sender.
function Send-ClientRowsToLogAnalytics {
    param([Parameter(Mandatory)] [object[]]$Rows)
    if (-not ($LogAnalyticsDceUri -and $LogAnalyticsDcrImmutableId -and $LogAnalyticsClientStreamName)) { return }
    Write-Host "Posting $($Rows.Count) client row(s) to Log Analytics ($LogAnalyticsClientStreamName)"
    try {
        $token = az account get-access-token --resource https://monitor.azure.com --query accessToken -o tsv
        $body  = ConvertTo-Json -InputObject @($Rows) -Depth 5 -Compress -AsArray
        $url   = "$LogAnalyticsDceUri/dataCollectionRules/$LogAnalyticsDcrImmutableId/streams/${LogAnalyticsClientStreamName}?api-version=2023-01-01"
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" `
            -Headers @{ Authorization = "Bearer $token" } | Out-Null
        Write-Host "   ok"
    } catch {
        $msg = "Client Log Analytics ingestion failed: $($_.Exception.Message). Blob upload remains source of truth."
        Write-Warning $msg
        Write-Host "##vso[task.logissue type=warning]$msg"
    }
}

if ($DotSourceForTest) { return }

if (-not (Test-Path $ResultsDir)) {
    Write-Warning "Results dir '$ResultsDir' not found - nothing to publish."
    exit 0
}

$rows = Build-ClientRows -ResultsDir $ResultsDir -UmbracoVersion $UmbracoVersion -Tier $Tier `
    -Scenario $Scenario -AppServiceSku $AppServiceSku -PoolDtuMax $PoolDtuMax -SeederPreset $SeederPreset `
    -BuildId $BuildId -Commit $Commit -Branch $Branch -RunStartedAt $RunStartedAt
if ($rows.Count -eq 0) { Write-Warning "No client metric rows parsed from $ResultsDir."; }

# Blob path mirrors publish-load-test-results.ps1 with a 'client/' top-level prefix.
$pipelineStarted = [DateTime]::Parse($RunStartedAt, [System.Globalization.CultureInfo]::InvariantCulture)
$datePart        = $pipelineStarted.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
$majorVersion    = (Get-UmbracoMajor $UmbracoVersion).ToString()
$blobPrefix      = "client/$majorVersion/$UmbracoVersion/$Tier/${datePart}_$BuildId"

$summaryFile = Join-Path (Split-Path -Parent $ResultsDir) "client-summary.ndjson"
$rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Out-File -FilePath $summaryFile -Encoding utf8

$storageKey = Get-StorageAccountKey -StorageAccountName $StorageAccountName -ResourceGroupName $HistoryResourceGroup
Write-Host "Uploading to https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobPrefix/"
az storage blob upload --account-name $StorageAccountName --account-key $storageKey `
    --container-name $ContainerName --file $summaryFile --name "$blobPrefix/summary.ndjson" --overwrite | Out-Null
az storage blob upload-batch --account-name $StorageAccountName --account-key $storageKey `
    --destination $ContainerName --destination-path "$blobPrefix/raw" --source $ResultsDir --pattern "*.ndjson" --overwrite | Out-Null

Send-ClientRowsToLogAnalytics -Rows $rows
Write-Host "Published $($rows.Count) client metric row(s)."
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester scripts/tests/publish-client-results.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish-client-results.ps1 scripts/tests/publish-client-results.Tests.ps1
git commit -m "feat: publish client measurement results to blob + Log Analytics"
```

---

## Task B3: check-client-regression.ps1

**Files:**
- Create: `scripts/check-client-regression.ps1`
- Test: `scripts/tests/check-client-regression.Tests.ps1`

- [ ] **Step 1: Write the failing Pester test `scripts/tests/check-client-regression.Tests.ps1`**

```powershell
BeforeAll {
    . "$PSScriptRoot/../check-client-regression.ps1" -DotSourceForTest
}

Describe 'Test-ClientRegression' {
    It 'flags a metric whose candidate median exceeds baseline median x threshold' {
        $r = Test-ClientRegression -CandidateMedian 130 -BaselineMedians @(100,100,100) -Threshold 0.10
        $r.Regressed | Should -BeTrue
    }
    It 'passes a metric within threshold' {
        $r = Test-ClientRegression -CandidateMedian 105 -BaselineMedians @(100,100,100) -Threshold 0.10
        $r.Regressed | Should -BeFalse
    }
    It 'reports insufficient baseline when fewer than MinBaselineRuns' {
        $r = Test-ClientRegression -CandidateMedian 999 -BaselineMedians @(100) -Threshold 0.10 -MinBaselineRuns 3
        $r.Insufficient | Should -BeTrue
        $r.Regressed | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester scripts/tests/check-client-regression.Tests.ps1 -Output Detailed"
```
Expected: FAIL — function not found.

- [ ] **Step 3: Write `scripts/check-client-regression.ps1`**

```powershell
#requires -Version 7.3

# Client-measurement regression gate. Reads client summary.ndjson rows from
# history storage, takes the latest run per (version × tier × metric) as the
# candidate, compares its median against the median-of-last-N baseline. Mirrors
# check-regression.ps1's philosophy: report-only until >= MinBaselineRuns accrue,
# then fails the build (unless -NoFailOnRegression) so it can gate the pipeline.

[CmdletBinding()]
param(
    [string]$Scenario,
    [int]$Major,
    [string]$HistoryResourceGroup,
    [string]$StorageAccountName,
    [string]$ContainerName,
    [string]$OutputPath,
    [double]$MedianThreshold = 0.10,
    [int]$MinBaselineRuns = 3,
    [int]$BaselineWindow = 5,
    [switch]$NoFailOnRegression,
    [switch]$DotSourceForTest
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

. "$PSScriptRoot/_helpers.ps1"
. "$PSScriptRoot/_history-helpers.ps1"

# Pure decision function — unit-tested. A metric regresses when it has enough
# baseline runs AND the candidate median exceeds the baseline median x (1+threshold).
function Test-ClientRegression {
    param(
        [Parameter(Mandatory)] [double]$CandidateMedian,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [double[]]$BaselineMedians,
        [double]$Threshold = 0.10,
        [int]$MinBaselineRuns = 3
    )
    if ($BaselineMedians.Count -lt $MinBaselineRuns) {
        return [pscustomobject]@{ Insufficient = $true; Regressed = $false; BaselineMedian = $null }
    }
    $sorted = [double[]]($BaselineMedians | Sort-Object)
    $mid = $sorted.Count / 2
    $baseMedian = if ($sorted.Count % 2 -eq 0) { ($sorted[$mid-1] + $sorted[$mid]) / 2 } else { $sorted[[math]::Floor($mid)] }
    $regressed = $CandidateMedian -gt ($baseMedian * (1 + $Threshold))
    return [pscustomobject]@{ Insufficient = $false; Regressed = $regressed; BaselineMedian = $baseMedian }
}

if ($DotSourceForTest) { return }

# --- Live path: pull client rows from history, evaluate, write report. ---
# Get-HistorySummaryRows is provided by _history-helpers.ps1; it lists blobs under
# the prefix and parses summary.ndjson. We pass the 'client/' prefix shape.
$rows = Get-HistorySummaryRows -StorageAccountName $StorageAccountName `
    -ResourceGroupName $HistoryResourceGroup -ContainerName $ContainerName `
    -Prefix "client/$Major/"

# Group by (version × tier × metric); newest run = candidate, prior = baseline window.
$report = New-Object System.Text.StringBuilder
[void]$report.AppendLine("# Client measurement regression report`n")
$any = $false
$regressedAny = $false
$grouped = $rows | Group-Object umbraco_version, infra_tier, metric
foreach ($g in $grouped) {
    $ordered = $g.Group | Sort-Object run_started_at
    if ($ordered.Count -lt 2) { continue }
    $candidate = $ordered[-1]
    $baseline  = @($ordered[0..($ordered.Count-2)] | Select-Object -Last $BaselineWindow)
    $verdict = Test-ClientRegression -CandidateMedian ([double]$candidate.median_ms) `
        -BaselineMedians ([double[]]($baseline | ForEach-Object { [double]$_.median_ms })) `
        -Threshold $MedianThreshold -MinBaselineRuns $MinBaselineRuns
    $any = $true
    if ($verdict.Insufficient) {
        [void]$report.AppendLine("- $($g.Name): insufficient baseline ($($baseline.Count) < $MinBaselineRuns runs)")
    } elseif ($verdict.Regressed) {
        $regressedAny = $true
        [void]$report.AppendLine("- **$($g.Name): REGRESSED** candidate $([math]::Round($candidate.median_ms))ms > baseline-median $([math]::Round($verdict.BaselineMedian))ms x $(1+$MedianThreshold)")
    } else {
        [void]$report.AppendLine("- $($g.Name): ok ($([math]::Round($candidate.median_ms))ms vs $([math]::Round($verdict.BaselineMedian))ms)")
    }
}
if (-not $any) { [void]$report.AppendLine("No comparable client runs found under client/$Major/.") }

if ($OutputPath) { $report.ToString() | Out-File -FilePath $OutputPath -Encoding utf8 }
Write-Host $report.ToString()

if ($regressedAny -and -not $NoFailOnRegression) {
    Write-Host "##vso[task.logissue type=error]Client measurement regression detected."
    exit 1
}
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester scripts/tests/check-client-regression.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Verify `_history-helpers.ps1` exposes `Get-HistorySummaryRows`**

Run:
```bash
pwsh -NoProfile -Command ". scripts/_history-helpers.ps1; Get-Command Get-HistorySummaryRows -ErrorAction SilentlyContinue | Select-Object Name"
```
Expected: prints `Get-HistorySummaryRows`. **If it prints nothing**, the helper has a different name — open `scripts/_history-helpers.ps1`, find the function that lists+parses history `summary.ndjson` (used by `show-trends.ps1` / `check-regression.ps1`), and replace the call in Step 3 with the real name + its real parameter set (match how `check-regression.ps1` calls it).

- [ ] **Step 6: Commit**

```bash
git add scripts/check-client-regression.ps1 scripts/tests/check-client-regression.Tests.ps1
git commit -m "feat: add client measurement regression gate"
```

---

# Phase C — Pipeline + templates

## Task C1: Extract the shared provision + cleanup stages into templates

**Goal:** lift the `validateTestCases → ensureHistoryInfra → ensureMonitoringInfra → provision` chain and the `cleanup` stage out of `azure-pipeline.yml` into reusable stage templates, then have the existing pipeline consume them. **Pure refactor — the existing pipeline's run plan must not change.**

**Files:**
- Create: `templates/stages/provision.yml`
- Create: `templates/stages/cleanup.yml`
- Modify: `azure-pipeline.yml`

- [ ] **Step 1: Record the current pipeline's compiled YAML as a baseline**

Run (requires Azure CLI `devops` extension + a configured org, OR use the AzDO portal's "Download full YAML"):
```bash
# If az devops is configured:
az pipelines run --name load_test_pipeline --open --parameters umbracoVersion=17.0.0 2>/dev/null || echo "Use AzDO portal: Edit pipeline -> ... -> Download full YAML, save as /tmp/baseline-compiled.yml"
```
If the CLI path is unavailable, open the pipeline in AzDO → **Edit** → **⋯** → **Download full YAML** and save as `/tmp/baseline-compiled.yml`. This is the diff target for Step 6.

- [ ] **Step 2: Create `templates/stages/provision.yml`**

Move the four stages (`validateTestCases`, `ensureHistoryInfra`, `ensureMonitoringInfra`, `provision`) verbatim from `azure-pipeline.yml` (lines 171–431) into this file under a `stages:` key, parameterizing the values the two pipelines differ on. Header:
```yaml
# Shared provisioning stage chain: validate -> ensure history infra ->
# ensure monitoring infra -> Terraform provision. Consumed by both
# azure-pipeline.yml (load test) and azure-pipeline-client.yml (client measurement).
# Extracted verbatim — behaviour identical to the inline version it replaced.
parameters:
  - name: umbracoVersion
    type: string
  - name: scenario
    type: string
  - name: workload
    type: string
  - name: loadProfile
    type: string
  - name: resourcePrefix
    type: string
  - name: azureRegion
    type: string
  - name: runStarter
    type: boolean
  - name: runStandard
    type: boolean
  - name: runPro
    type: boolean
  - name: runEnterprise
    type: boolean
  - name: poolDtuOverride
    type: string
  - name: appSkuOverride
    type: string
  - name: seederPresetOverride
    type: string

stages:
  # <<< paste lines 171-431 of azure-pipeline.yml here, replacing every
  #     ${{ parameters.X }} reference with the matching template parameter
  #     above (they are already named identically, so the paste needs no
  #     textual change beyond living under this template's parameters). >>>
```

- [ ] **Step 3: Create `templates/stages/cleanup.yml`**

Move the `cleanup` stage verbatim (lines 595–652) into this file:
```yaml
# Shared cleanup stage: manual-validation keep-window then RG delete on
# reject/timeout/skip. Runs on always() so the ephemeral RG is never orphaned.
parameters:
  - name: validationTimeoutMinutes
    type: number
  - name: dependsOn
    type: object
    # The stages this cleanup must wait for differs per pipeline (loadTest vs
    # clientMeasure), so the caller passes the list.

stages:
  - stage: cleanup
    displayName: Cleanup
    dependsOn: ${{ parameters.dependsOn }}
    condition: always()
    # <<< paste the jobs: block from the cleanup stage (lines ~602-652) here. >>>
```

- [ ] **Step 4: Refactor `azure-pipeline.yml` to consume `provision.yml`**

Replace the four inline stages (lines 171–431) with:
```yaml
stages:
  - template: templates/stages/provision.yml
    parameters:
      umbracoVersion: '${{ parameters.umbracoVersion }}'
      scenario: '${{ parameters.scenario }}'
      workload: '${{ parameters.workload }}'
      loadProfile: '${{ parameters.loadProfile }}'
      resourcePrefix: '${{ parameters.resourcePrefix }}'
      azureRegion: '${{ parameters.azureRegion }}'
      runStarter: ${{ parameters.runStarter }}
      runStandard: ${{ parameters.runStandard }}
      runPro: ${{ parameters.runPro }}
      runEnterprise: ${{ parameters.runEnterprise }}
      poolDtuOverride: '${{ parameters.poolDtuOverride }}'
      appSkuOverride: '${{ parameters.appSkuOverride }}'
      seederPresetOverride: '${{ parameters.seederPresetOverride }}'
```
Keep the existing `loadTest` and `regression` stages inline (they are load-test-specific). Leave their `dependsOn` references unchanged — the stage names inside the template are identical.

- [ ] **Step 5: Refactor `azure-pipeline.yml` to consume `cleanup.yml`**

Replace the inline `cleanup` stage (lines 595–652) with:
```yaml
  - template: templates/stages/cleanup.yml
    parameters:
      validationTimeoutMinutes: ${{ parameters.validationTimeoutMinutes }}
      dependsOn:
        - provision
        - loadTest
        - regression
```

- [ ] **Step 6: Diff the recompiled YAML against the baseline**

Re-download the compiled YAML the same way as Step 1, save as `/tmp/refactored-compiled.yml`, then:
```bash
diff <(grep -v '^\s*#' /tmp/baseline-compiled.yml) <(grep -v '^\s*#' /tmp/refactored-compiled.yml)
```
Expected: **no differences** (comments stripped). Any difference is a refactor bug — reconcile it before continuing.

- [ ] **Step 7: Commit**

```bash
git add templates/stages/provision.yml templates/stages/cleanup.yml azure-pipeline.yml
git commit -m "refactor: extract shared provision + cleanup stages into templates"
```

---

## Task C2: Add the 'client' workload to resolve-run-config.ps1

**Files:**
- Modify: `scripts/resolve-run-config.ps1`
- Test: `scripts/tests/resolve-run-config.client.Tests.ps1`

- [ ] **Step 1: Write the failing Pester test `scripts/tests/resolve-run-config.client.Tests.ps1`**

```powershell
Describe 'resolve-run-config client workload validation' {
    It 'rejects client workload when scenario has no client/ project' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        New-Item -ItemType Directory -Path (Join-Path $tmp 'loadtests/scenarios/Bare') -Force | Out-Null
        $out = pwsh -NoProfile -File "$PSScriptRoot/../resolve-run-config.ps1" `
            -Profile standard -UmbracoVersion 17.0.0 -Scenario Bare `
            -RunStarter True -RunStandard False -RunPro False -RunEnterprise False `
            -PoolDtuOverride Auto -AppSkuOverride Auto -SeederPresetOverride Auto `
            -Workload client -WorkspaceRoot $tmp 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join "`n") | Should -Match 'client/'
    }
    It 'accepts client workload when scenario has a client/ project' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid()))
        New-Item -ItemType Directory -Path (Join-Path $tmp 'loadtests/scenarios/Default/client') -Force | Out-Null
        'export default {}' | Out-File (Join-Path $tmp 'loadtests/scenarios/Default/client/playwright.config.ts')
        New-Item -ItemType Directory -Path (Join-Path $tmp 'scripts') -Force | Out-Null
        Copy-Item "$PSScriptRoot/../prepare-test-cases.ps1" (Join-Path $tmp 'scripts') -ErrorAction SilentlyContinue
        # Validation should pass the client-specific check (may still fail later in
        # prepare-test-cases if that helper isn't present — we only assert the client
        # check itself didn't fire).
        $out = pwsh -NoProfile -File "$PSScriptRoot/../resolve-run-config.ps1" `
            -Profile standard -UmbracoVersion 17.0.0 -Scenario Default `
            -RunStarter True -RunStandard False -RunPro False -RunEnterprise False `
            -PoolDtuOverride Auto -AppSkuOverride Auto -SeederPresetOverride Auto `
            -Workload client -WorkspaceRoot $tmp 2>&1
        ($out -join "`n") | Should -Not -Match 'has no client/ project'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester scripts/tests/resolve-run-config.client.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `client` is rejected by the `ValidateSet` on `$Workload` before any client check runs.

- [ ] **Step 3: Add 'client' to the Workload ValidateSet**

In `scripts/resolve-run-config.ps1` line 26, change:
```powershell
    [Parameter(Mandatory = $true)] [ValidateSet('frontend', 'backoffice')] [string]$Workload,
```
to:
```powershell
    [Parameter(Mandatory = $true)] [ValidateSet('frontend', 'backoffice', 'client')] [string]$Workload,
```

- [ ] **Step 4: Add the client-workload validation branch**

In the workload validation block (after the `elseif ($Workload -eq 'backoffice')` branch, around line 101), add:
```powershell
} elseif ($Workload -eq 'client') {
    # The client workload runs the Playwright project under the scenario's client/
    # folder. Fail at queue-time (minute 0) if it's absent, mirroring the
    # frontend/backoffice file checks above.
    $clientConfig = Join-Path $scenarioRoot 'client/playwright.config.ts'
    if (-not (Test-Path -LiteralPath $clientConfig)) {
        Write-PipelineError "Workload=client selected but scenario '$Scenario' has no client/ project (looked for $clientConfig). Add a Playwright project under loadtests/scenarios/$Scenario/client/ or pick a different workload."
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester scripts/tests/resolve-run-config.client.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/resolve-run-config.ps1 scripts/tests/resolve-run-config.client.Tests.ps1
git commit -m "feat: accept 'client' workload + validate scenario has a client/ project"
```

---

## Task C3: The client-measure-job template

**Files:**
- Create: `templates/jobs/client-measure-job.yml`

- [ ] **Step 1: Create `templates/jobs/client-measure-job.yml`**

```yaml
# Per-tier client-measurement job: read terraform outputs -> start App Service ->
# warm up (server warm, so we measure client-cold) -> run Playwright -> publish.
# The Playwright counterpart to templates/load-test-job.yml. Parameters mirror it
# so the calling pipeline's tier-expansion block looks familiar.
parameters:
  - name: testCaseId
    type: string
  - name: tier
    type: string
  - name: scenario
    type: string
  - name: umbracoVersion
    type: string
  - name: skipWarmup
    type: boolean
    default: false
  - name: logAnalyticsDceUri
    type: string
    default: ''
  - name: logAnalyticsDcrImmutableId
    type: string
    default: ''
  - name: logAnalyticsClientStreamName
    type: string
    default: ''

steps:
  # Reuse the exact terraform-output read from load-test-job.yml so host/app
  # names + seeder metadata resolve identically.
  - task: PowerShell@2
    displayName: 'Read terraform outputs [${{ parameters.testCaseId }}]'
    env:
      RESOLVED_TEST_CASES: $(resolvedTestCases)
      TEST_CASE_OUTPUTS: $(testCaseOutputs)
      SEEDER_RESULTS: $(seederResults)
    inputs:
      targetType: 'inline'
      script: |
        $resolved = $env:RESOLVED_TEST_CASES | ConvertFrom-Json
        $outputs  = $env:TEST_CASE_OUTPUTS   | ConvertFrom-Json
        $testCaseId = '${{ parameters.testCaseId }}'
        $myCase = $resolved.$testCaseId
        $tfOut  = $outputs.$testCaseId
        if (-not $tfOut) { Write-Host "##vso[task.logissue type=error]No terraform output for $testCaseId"; exit 1 }
        Write-Host "##vso[task.setvariable variable=hostName]$($tfOut.hostname)"
        Write-Host "##vso[task.setvariable variable=appServiceName]$($tfOut.app_service_name)"
        Write-Host "##vso[task.setvariable variable=appServiceSku]$($tfOut.app_service_sku)"
        Write-Host "##vso[task.setvariable variable=poolDtuMax]$($tfOut.pool_dtu_max)"

  - task: AzureCLI@2
    displayName: 'Start App Service [${{ parameters.testCaseId }}]'
    inputs:
      azureSubscription: '$(serviceConnection)'
      scriptType: 'pscore'
      scriptLocation: 'inlineScript'
      inlineScript: az webapp start -n $(appServiceName) -g $(azureResourceGroup)

  # Warm the SERVER (poll for 200) so the measurement isolates client-cold, not
  # server cold-start. Reuses the simple poll from load-test-job's warmup phase 1.
  - ${{ if not(parameters.skipWarmup) }}:
    - task: PowerShell@2
      displayName: 'Warm up server [${{ parameters.testCaseId }}]'
      inputs:
        targetType: 'inline'
        script: |
          $base = "https://$(hostName)"
          $deadline = (Get-Date).AddMinutes(5)
          do {
            try { if ((Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 15).StatusCode -eq 200) { Write-Host "warm"; break } } catch { }
            Start-Sleep -Seconds 5
          } while ((Get-Date) -lt $deadline)

  - task: NodeTool@0
    displayName: 'Install Node.js'
    inputs:
      versionSpec: '20.x'

  - task: PowerShell@2
    displayName: 'Run Playwright client measurement [${{ parameters.testCaseId }}]'
    env:
      UMBRACO_BASE_URL: 'https://$(hostName)'
      # Terraform unattended-install admin (the only account that can auth — see README).
      UMBRACO_USER: 'loadtest@example.invalid'
      UMBRACO_PASSWORD: 'LoadTest123!'
      CLIENT_RUN_ID: '$(Build.BuildId)'
      CLIENT_UMBRACO_VERSION: '${{ parameters.umbracoVersion }}'
      CLIENT_TIER: '${{ parameters.tier }}'
      CLIENT_SCENARIO: '${{ parameters.scenario }}'
      CLIENT_RESULTS_DIR: '$(System.DefaultWorkingDirectory)/client-results'
    inputs:
      targetType: 'inline'
      workingDirectory: '$(System.DefaultWorkingDirectory)/loadtests/scenarios/${{ parameters.scenario }}/client'
      script: |
        npm ci
        npx playwright install --with-deps chromium
        # continueOnError semantics: a failing assertion is data; publish anyway.
        npx playwright test
      # Don't fail the job on a non-zero test exit — we still want to publish what we got.
    continueOnError: true

  - task: AzureCLI@2
    displayName: 'Publish client results [${{ parameters.testCaseId }}]'
    condition: succeededOrFailed()
    continueOnError: true
    inputs:
      azureSubscription: '$(serviceConnection)'
      scriptType: 'pscore'
      scriptLocation: 'scriptPath'
      scriptPath: '$(System.DefaultWorkingDirectory)/scripts/publish-client-results.ps1'
      arguments: >
        -ResultsDir "$(System.DefaultWorkingDirectory)/client-results"
        -HistoryResourceGroup "$(historyResourceGroup)"
        -StorageAccountName "$(historyStorageAccount)"
        -ContainerName "$(historyContainer)"
        -BuildId "$(Build.BuildId)"
        -Commit "$(Build.SourceVersion)"
        -Branch "$(Build.SourceBranchName)"
        -RunStartedAt "$(System.PipelineStartTime)"
        -UmbracoVersion "${{ parameters.umbracoVersion }}"
        -AppServiceSku "$(appServiceSku)"
        -PoolDtuMax $(poolDtuMax)
        -SeederPreset "$(resolvedSeederPreset)"
        -Tier "${{ parameters.tier }}"
        -Scenario "${{ parameters.scenario }}"
        -LogAnalyticsDceUri "${{ parameters.logAnalyticsDceUri }}"
        -LogAnalyticsDcrImmutableId "${{ parameters.logAnalyticsDcrImmutableId }}"
        -LogAnalyticsClientStreamName "${{ parameters.logAnalyticsClientStreamName }}"

  - task: PublishBuildArtifacts@1
    displayName: 'Publish client artifacts [${{ parameters.testCaseId }}]'
    condition: succeededOrFailed()
    continueOnError: true
    inputs:
      PathtoPublish: '$(System.DefaultWorkingDirectory)/client-results'
      ArtifactName: 'client-results-$(safeTestCaseId)'
      publishLocation: 'Container'
```

- [ ] **Step 2: Lint the YAML**

Run:
```bash
pwsh -NoProfile -Command "Get-Content templates/jobs/client-measure-job.yml -Raw | Out-Null; 'read ok'"
python -c "import yaml,sys; yaml.safe_load(open('templates/jobs/client-measure-job.yml')); print('yaml ok')"
```
Expected: `yaml ok`. (Azure expression `${{ }}` blocks are valid YAML strings; safe_load only checks structure.)

- [ ] **Step 3: Commit**

```bash
git add templates/jobs/client-measure-job.yml
git commit -m "feat: add per-tier Playwright client-measure job template"
```

---

## Task C4: The client pipeline

**Files:**
- Create: `azure-pipeline-client.yml`

- [ ] **Step 1: Create `azure-pipeline-client.yml`**

```yaml
name: client_measurement_pipeline

trigger: none
pr: none

pool:
  vmImage: 'ubuntu-latest'

parameters:
  - name: umbracoVersion
    displayName: Umbraco version (e.g. 17.0.0)
    type: string
    default: '17.0.0'
  - name: scenario
    displayName: Scenario (must have a client/ Playwright project)
    type: string
    default: 'Default'
    values:
      - 'Default'
  - name: loadProfile
    displayName: 'Seeder bulk size (smoke=Small, standard=Medium, stress=Large)'
    type: string
    default: 'standard'
    values:
      - 'smoke'
      - 'standard'
      - 'stress'
  # Client measurement is single-browser; running multiple tiers in one queue is
  # supported but slow. Default to Starter only.
  - name: runStarter
    type: boolean
    default: true
  - name: runStandard
    type: boolean
    default: false
  - name: runPro
    type: boolean
    default: false
  - name: runEnterprise
    type: boolean
    default: false
  - name: azureRegion
    type: string
    default: West Europe
    values: [West Europe, North Europe, East US, West US 2]
  - name: resourcePrefix
    type: string
    default: umbraco-client
  - name: skipWarmup
    type: boolean
    default: false
  - name: validationTimeoutMinutes
    type: number
    default: 60
    values: [15, 30, 60, 120, 240]
  - name: poolDtuOverride
    type: string
    default: 'Auto'
    values: ['Auto', '10', '20', '50', '100', '200']
  - name: appSkuOverride
    type: string
    default: 'Auto'
    values: ['Auto', 'P0v3', 'P1v3', 'P2v3', 'P3v3']
  - name: seederPresetOverride
    type: string
    default: 'Auto'
    values: ['Auto', 'Small', 'Medium', 'Large', 'Massive']

variables:
  - group: umbraco-loadtest-history
  - name: serviceConnection
    value: 'terraform-umbraco-load-testing-az-connection'
  - name: azureResourceGroup
    value: '${{ parameters.resourcePrefix }}-rg'
  - name: terraformWorkingDirectory
    value: '$(System.DefaultWorkingDirectory)/Terraform'
  - name: historyWorkspaceName
    value: 'umbraco-loadtest-laws'
  - name: historyDceName
    value: 'umbraco-loadtest-dce'
  - name: historyDcrName
    value: 'umbraco-loadtest-dcr'

stages:
  # Shared provisioning chain (workload fixed to 'client').
  - template: templates/stages/provision.yml
    parameters:
      umbracoVersion: '${{ parameters.umbracoVersion }}'
      scenario: '${{ parameters.scenario }}'
      workload: 'client'
      loadProfile: '${{ parameters.loadProfile }}'
      resourcePrefix: '${{ parameters.resourcePrefix }}'
      azureRegion: '${{ parameters.azureRegion }}'
      runStarter: ${{ parameters.runStarter }}
      runStandard: ${{ parameters.runStandard }}
      runPro: ${{ parameters.runPro }}
      runEnterprise: ${{ parameters.runEnterprise }}
      poolDtuOverride: '${{ parameters.poolDtuOverride }}'
      appSkuOverride: '${{ parameters.appSkuOverride }}'
      seederPresetOverride: '${{ parameters.seederPresetOverride }}'

  - stage: clientMeasure
    displayName: Run client measurements
    dependsOn:
      - validateTestCases
      - ensureMonitoringInfra
      - provision
    condition: succeeded('provision')
    variables:
      testCaseOutputs:        $[ stageDependencies.provision.apply.outputs['outputVars.testCaseOutputs'] ]
      seederResults:          $[ stageDependencies.provision.apply.outputs['outputVars.seederResults'] ]
      resolvedTestCases:      $[ stageDependencies.validateTestCases.prepareTestCases.outputs['out.resolvedTestCases'] ]
      resolvedSeederPreset:   $[ stageDependencies.validateTestCases.prepareTestCases.outputs['out.resolvedSeederPreset'] ]
      monitoringDceUri:           $[ stageDependencies.ensureMonitoringInfra.ensure.outputs['ensureMon.MonitoringDceUri'] ]
      monitoringDcrImmutableId:   $[ stageDependencies.ensureMonitoringInfra.ensure.outputs['ensureMon.MonitoringDcrImmutableId'] ]
      monitoringClientStreamName: $[ stageDependencies.ensureMonitoringInfra.ensure.outputs['ensureMon.MonitoringClientStreamName'] ]
    jobs:
      - job: runClientMeasurements
        displayName: Run Client Measurements
        timeoutInMinutes: 360
        steps:
          - ${{ if eq(parameters.runStarter, true) }}:
            - template: templates/jobs/client-measure-job.yml
              parameters:
                testCaseId: '${{ parameters.umbracoVersion }}__Starter__${{ parameters.scenario }}'
                tier: 'Starter'
                scenario: '${{ parameters.scenario }}'
                umbracoVersion: '${{ parameters.umbracoVersion }}'
                skipWarmup: ${{ parameters.skipWarmup }}
                logAnalyticsDceUri: $(monitoringDceUri)
                logAnalyticsDcrImmutableId: $(monitoringDcrImmutableId)
                logAnalyticsClientStreamName: $(monitoringClientStreamName)
          - ${{ if eq(parameters.runStandard, true) }}:
            - template: templates/jobs/client-measure-job.yml
              parameters:
                testCaseId: '${{ parameters.umbracoVersion }}__Standard__${{ parameters.scenario }}'
                tier: 'Standard'
                scenario: '${{ parameters.scenario }}'
                umbracoVersion: '${{ parameters.umbracoVersion }}'
                skipWarmup: ${{ parameters.skipWarmup }}
                logAnalyticsDceUri: $(monitoringDceUri)
                logAnalyticsDcrImmutableId: $(monitoringDcrImmutableId)
                logAnalyticsClientStreamName: $(monitoringClientStreamName)
          - ${{ if eq(parameters.runPro, true) }}:
            - template: templates/jobs/client-measure-job.yml
              parameters:
                testCaseId: '${{ parameters.umbracoVersion }}__Pro__${{ parameters.scenario }}'
                tier: 'Pro'
                scenario: '${{ parameters.scenario }}'
                umbracoVersion: '${{ parameters.umbracoVersion }}'
                skipWarmup: ${{ parameters.skipWarmup }}
                logAnalyticsDceUri: $(monitoringDceUri)
                logAnalyticsDcrImmutableId: $(monitoringDcrImmutableId)
                logAnalyticsClientStreamName: $(monitoringClientStreamName)
          - ${{ if eq(parameters.runEnterprise, true) }}:
            - template: templates/jobs/client-measure-job.yml
              parameters:
                testCaseId: '${{ parameters.umbracoVersion }}__Enterprise__${{ parameters.scenario }}'
                tier: 'Enterprise'
                scenario: '${{ parameters.scenario }}'
                umbracoVersion: '${{ parameters.umbracoVersion }}'
                skipWarmup: ${{ parameters.skipWarmup }}
                logAnalyticsDceUri: $(monitoringDceUri)
                logAnalyticsDcrImmutableId: $(monitoringDcrImmutableId)
                logAnalyticsClientStreamName: $(monitoringClientStreamName)

          - task: AzureCLI@2
            displayName: 'Stop all App Services'
            condition: succeededOrFailed()
            env:
              TEST_CASE_OUTPUTS: $(testCaseOutputs)
            inputs:
              azureSubscription: '$(serviceConnection)'
              scriptType: 'pscore'
              scriptLocation: 'scriptPath'
              scriptPath: '$(System.DefaultWorkingDirectory)/scripts/stop-all-app-services.ps1'
              arguments: '-ResourceGroupName "$(azureResourceGroup)"'

  - stage: clientRegression
    displayName: Client regression check
    dependsOn:
      - clientMeasure
    condition: succeeded('clientMeasure')
    jobs:
      - job: clientRegressionCheck
        displayName: Client regression check
        steps:
          - task: AzureCLI@2
            displayName: Compare client run against baseline
            inputs:
              azureSubscription: '$(serviceConnection)'
              scriptType: 'pscore'
              scriptLocation: 'inlineScript'
              inlineScript: |
                . "$(System.DefaultWorkingDirectory)/scripts/_helpers.ps1"
                $major = Get-UmbracoMajor '${{ parameters.umbracoVersion }}'
                # Report-only until >=3 baselines accrue (same posture as the load-test gate).
                & "$(System.DefaultWorkingDirectory)/scripts/check-client-regression.ps1" `
                    -Scenario '${{ parameters.scenario }}' -Major $major `
                    -HistoryResourceGroup '$(historyResourceGroup)' `
                    -StorageAccountName '$(historyStorageAccount)' `
                    -ContainerName '$(historyContainer)' `
                    -OutputPath "$(System.DefaultWorkingDirectory)/client-regression-report.md" `
                    -NoFailOnRegression
          - task: PublishBuildArtifacts@1
            displayName: Publish client regression report
            condition: succeededOrFailed()
            continueOnError: true
            inputs:
              PathtoPublish: '$(System.DefaultWorkingDirectory)/client-regression-report.md'
              ArtifactName: 'client-regression-report'
              publishLocation: 'Container'

  - template: templates/stages/cleanup.yml
    parameters:
      validationTimeoutMinutes: ${{ parameters.validationTimeoutMinutes }}
      dependsOn:
        - provision
        - clientMeasure
        - clientRegression
```

- [ ] **Step 2: Lint the YAML**

Run:
```bash
python -c "import yaml; yaml.safe_load(open('azure-pipeline-client.yml')); print('yaml ok')"
```
Expected: `yaml ok`.

- [ ] **Step 3: Commit**

```bash
git add azure-pipeline-client.yml
git commit -m "feat: add client measurement pipeline"
```

---

# Phase D — Dashboard + docs + end-to-end

## Task D1: Add the "Client measurements" Workbook tab

**Files:**
- Modify: `dashboards/loadtest.workbook.json`

- [ ] **Step 1: Inspect the existing workbook structure**

Run:
```bash
python -c "import json; d=json.load(open('dashboards/loadtest.workbook.json')); print(type(d), list(d.keys())[:10]); print('items:', len(d.get('items', [])))"
```
Expected: prints the top-level keys and item count. Note how tabs/groups are structured (the existing Trends/Tiers/Versions/Compare/Runs/Glossary tabs) so the new tab follows the same shape.

- [ ] **Step 2: Add a "Client measurements" tab item**

Append a new group item to the workbook `items` array following the existing tab pattern. The tab contains one KQL query visualised as a time chart. Use this query (matches the `ClientMeasurement_CL` schema from Task B1):
```kql
ClientMeasurement_CL
| where isnotempty(metric)
| summarize median_ms = avg(median_ms) by bin(TimeGenerated, 1d), umbraco_version, infra_tier, metric
| order by TimeGenerated asc
```
Insert it by editing the JSON (preserve existing items; add one group). Concretely, locate the `"items"` array and append:
```json
{
  "type": 12,
  "content": {
    "version": "NotebookGroup/1.0",
    "groupType": "editable",
    "title": "Client measurements",
    "items": [
      {
        "type": 3,
        "content": {
          "version": "KqlItem/1.0",
          "query": "ClientMeasurement_CL\n| where isnotempty(metric)\n| summarize median_ms = avg(median_ms) by bin(TimeGenerated, 1d), umbraco_version, infra_tier, metric\n| order by TimeGenerated asc",
          "size": 0,
          "title": "Client perceived latency (median ms) over time",
          "timeContext": { "durationMs": 7776000000 },
          "queryType": 0,
          "resourceType": "microsoft.operationalinsights/workspaces",
          "visualization": "timechart"
        },
        "name": "client-latency-trend"
      }
    ]
  },
  "name": "group-client-measurements"
}
```

- [ ] **Step 3: Validate the workbook JSON still parses**

Run:
```bash
python -c "import json; json.load(open('dashboards/loadtest.workbook.json')); print('json ok')"
```
Expected: `json ok`.

- [ ] **Step 4: Commit**

```bash
git add dashboards/loadtest.workbook.json
git commit -m "feat: add Client measurements tab to the workbook"
```

---

## Task D2: Document the client workload in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Client measurement (Playwright)" subsection**

Under the "Workload modes" section, add a third mode description after the backoffice paragraphs:
```markdown
### Client measurement (Playwright)

The `client` workload (run via the separate `azure-pipeline-client.yml`) measures
**browser-perceived** backoffice performance in a real Chromium browser, rather
than server throughput. It reuses the same Terraform provisioning and
history/monitoring infra, then runs the Playwright project under
`loadtests/scenarios/{scenario}/client/` **on the pipeline agent** against the
provisioned App Service.

Metrics (each repeated N times — default 10 — reported as median / p75 / p95 / stddev):

| Metric | What it captures |
|---|---|
| `cold_dashboard_load` / `cached_dashboard_load` | News dashboard until the article list is visible (fresh context vs repeat visit) |
| `cold_homenode_load` / `cached_homenode_load` | Home content node until the TipTap editor is painted |
| `time_to_first_edit` | URL → login → open Home → type a character rendered (+ login / navigate / editor-ready / keystroke segment breakdown) |

"Cold" = browser-uncached against an already-warm server (the warm-up step warms
the server so we isolate client-cold, not server cold-start). Results land in the
`ClientMeasurement_CL` Log Analytics table + the "Client measurements" Workbook tab,
and the `client/` prefix of the history storage container.

**Test data** is hybrid: `TestDataSeeder` lays down background bulk during
provisioning, then the Playwright `globalSetup` builds the precise content model
(a tabbed `Page` doctype with TipTap+image, two media pickers, a block grid, three
compositions including an SEO tab; three extra empty doctypes; ~20 top-level nodes
each with a child) via `@umbraco-cms/acceptance-test-helpers`.

**Local dev:** `cd loadtests/scenarios/Default/client && npm install && npx playwright install chromium`,
then `UMBRACO_BASE_URL=https://localhost:44339 npx playwright test`.

**Installed-package cost:** we can't measure third-party package load directly,
but this produces a clean-site baseline; running the same suite against an
instance with packages installed makes the delta the package cost.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document the client measurement workload"
```

---

## Task D3: End-to-end local dry run

**Files:** none (verification only)

- [ ] **Step 1: Run the full Playwright suite clean against the local instance**

Run (in `loadtests/scenarios/Default/client/`):
```bash
rm -rf results
UMBRACO_BASE_URL=https://localhost:44339 CLIENT_MEASURE_REPS=3 npx playwright test
ls results
```
Expected: 5 NDJSON files, each with one row, `count == 3`.

- [ ] **Step 2: Run the publisher against the local results in test mode (no Azure)**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester scripts/tests -Output Detailed"
```
Expected: all Pester tests PASS (publish + regression + resolve-run-config client).

- [ ] **Step 3: Verify the Build-ClientRows transform on real local NDJSON**

Run:
```bash
pwsh -NoProfile -Command ". scripts/publish-client-results.ps1 -DotSourceForTest; (Build-ClientRows -ResultsDir 'loadtests/scenarios/Default/client/results' -UmbracoVersion 'local' -Tier 'local' -Scenario 'Default' -AppServiceSku 'local' -PoolDtuMax 0 -SeederPreset 'none' -BuildId 'local' -Commit 'x' -Branch 'main' -RunStartedAt '2026-06-10T00:00:00Z').Count"
```
Expected: prints `5` (one row per metric NDJSON).

- [ ] **Step 4: Final commit (if any working-tree changes remain)**

```bash
git add -A
git commit -m "test: end-to-end local dry run of client measurement harness" --allow-empty
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** §3 content model → Task A2; §4 metrics 1–5 + cold/cache + Perf marks → A4/A6/A7/A8; §4 auth → A5; §5 publish + table + workbook + regression → B1/B2/B3/D1; §2 templates + pipeline + resolver → C1/C2/C3/C4; §8 installed-packages note → D2. §7 testing → local-first throughout + D3.
- **External-API risk:** the `@umbraco-cms/acceptance-test-helpers` method names in A2 are the single biggest unknown — Task A1 pins them and A2 must be reconciled to whatever A1 proves. Likewise the v17 backoffice **selectors** (login fields, dashboard article list, tree node, TipTap root) are confirmed live in A5/A6/A7 via `codegen`; treat the selectors in those specs as starting points, not gospel.
- **`_history-helpers.ps1` function name** used by B3 is verified in B3 Step 5; reconcile if it differs.
- **Template extraction** (C1) is the one change touching the working pipeline — the Step 6 compiled-YAML diff is the safety net; do not skip it.
