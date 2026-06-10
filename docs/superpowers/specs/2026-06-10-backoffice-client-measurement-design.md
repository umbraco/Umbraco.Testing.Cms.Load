# Backoffice Client Measurement — Design

**Date:** 2026-06-10
**Branch:** `add/backoffice-client-measurement`
**Status:** Approved design (pre-implementation)

## 1. Overview

A new **third workload** — `client` — added alongside the existing `frontend`
(Locust) and `backoffice` (JMeter) workloads. Where those measure *server*
throughput under load, `client` measures **browser-perceived backoffice
performance** using Playwright in a real browser:

- **Cold** and **cached** load of the **News dashboard**.
- **Cold** and **cached** load of the **Home content node** (the rich page).
- An end-to-end **"time to first edit"** (open URL → log in → open Home → type a
  character into the TipTap editor), with a per-segment breakdown.

It reuses the existing Terraform provisioning and the long-lived
history/monitoring infrastructure, runs Playwright **on the pipeline agent**
against the provisioned Azure App Service, and publishes results to a
**dedicated** Log Analytics table and Workbook tab so client perceived-latency
metrics never mix with the throughput/p95 load metrics.

### Goal

Establish a reliable **clean-site baseline** for what the backoffice "feels
like" to load and start editing, across Umbraco versions and infrastructure
tiers — using the same provisioning, history, and trend/regression machinery the
load-test pipeline already provides.

### Decisions locked during brainstorming

| Axis | Decision |
|---|---|
| Run target | Reuse the existing Terraform **provision**; run Playwright **on the pipeline agent** against the ephemeral App Service. Tame client-timing noise with N repetitions + median/stddev. |
| Test data | **Hybrid**: `Umbraco.Cms.TestDataSeeder` lays down background bulk; `@umbraco-cms/acceptance-test-helpers` builds the precise content model via API. |
| Load signal | **Content-visible** — measure until a meaningful element is actually visible; also record Performance API marks (TTFB/DCL/load/LCP) for context. |
| First-edit metric | **End-to-end total + segment breakdown** (login, navigate-to-node, editor-ready, first-keystroke). |
| Results output | **Reuse infra, own table/tab** — same history blob storage + Log Analytics, new `ClientMeasurement_CL` table and its own Workbook tab. |

### Defaults (not separately asked; flagged for confirmation in review)

- **N = 10** repetitions per metric; report median + p75 + p95 + stddev; drop the
  first iteration as warm-up where noted.
- **One tier per run** by default — the operator picks via the existing tier
  checkboxes; running all four is supported but slow.

## 2. Architecture & where it fits

- A **separate pipeline** `azure-pipeline-client.yml` (not a new mode bolted onto
  the existing `azure-pipeline.yml`).
- Common stages extracted into **reusable templates** so both pipelines share one
  source of truth (pure extraction — no behavior change to the existing
  pipeline):
  - `templates/stages/provision.yml` — the
    `validateTestCases → ensureHistoryInfra → ensureMonitoringInfra → provision`
    chain.
  - `templates/stages/cleanup.yml` — the manual-validation + RG-delete stage.
  - `templates/jobs/client-measure-job.yml` — **new**, the Playwright counterpart
    to the existing `templates/load-test-job.yml`.
- Reused as-is (with the noted small additions):
  - `scripts/resolve-run-config.ps1` — gains `client` as a valid `workload`
    value, with validation that the chosen scenario has a `client/` Playwright
    project.
  - `scripts/ensure-history-infra.ps1` — unchanged.
  - `scripts/ensure-monitoring-infra.ps1` — gains the new `ClientMeasurement_CL`
    stream/table on the existing DCR/DCE.
  - `scripts/stop-all-app-services.ps1` — unchanged.
  - The **warm-up step** is reused so the **server** is warm before measuring —
    this isolates *client-cold* behaviour, not server-cold.

### Pipeline stage flow

```
validateTestCases   (shared) resolve workload=client + scenario has client/ project
ensureHistoryInfra  (shared) long-lived RG + storage + container
ensureMonitoringInfra (shared) Log Analytics + DCR/DCE + ClientMeasurement_CL stream
provision           (shared) Terraform: App Service + SQL + TestDataSeeder bulk
clientMeasure       (new)    per-tier: warm-up → Playwright globalSetup (build model)
                             → run measurement specs → publish NDJSON → mirror to LA
cleanup             (shared) manual-validation window → delete ephemeral RG
```

## 3. Test data layer (hybrid)

Data is built in two ordered phases:

1. **TestDataSeeder (existing provision path).** The `seederPreset`
   (Small/Medium/Large/Massive, resolved from the load profile or overridden)
   lays down background bulk content so the tree and database are realistically
   busy. This is the existing mechanism — unchanged.
2. **Playwright `globalSetup`.** Before the measurement specs run, `globalSetup`
   builds the *precise* model via `@umbraco-cms/acceptance-test-helpers` against
   the live instance. It must be **idempotent** (safe to re-run; checks for
   existing doctypes/content by alias/name before creating).

### Document types

- **`Page`** — uses **tabs**; created and placed in the content tree as the
  **Homepage**. This is the single fully-populated node.
- **`Product-page`**, **`Marketing-page`**, **`Newsletter-signup`** — exist but
  are empty (no properties required).

### `Page` — Content tab (properties directly on the doctype)

Ordered so TipTap and the first Media Picker sit at the top of the editing view:

1. **Rich Text (TipTap)** — at the top; body text contains **≥ 1 image**.
2. **Media Picker** (single) — top-right, immediately after TipTap, with a
   **picked image**.
3. **Block Grid** — a few blocks (content not rendered in a default install, so
   block type choice is arbitrary).
4. **Media Picker** (second) — lower on the page.
5. **Textstring** (e.g. Title).
6. **Textarea** (e.g. Summary).
7. **Numeric**.
8. **True/false** (toggle).
9. **Date picker**.

(Already ≥ 9 distinct property editors before compositions; the `Hero`
composition pushes the distinct-editor count past the required 10.)

### Compositions (3)

- **`Hero`** — adds a **Content Picker** + a **Multi-URL Picker** to the
  **Content** tab (satisfies "one composition adds property editors to the
  Content tab").
- **`Seo`** — adds a new **SEO tab** containing Meta Title (textstring), Meta
  Description (textarea), Canonical URL (Multi-URL Picker), No-index (toggle)
  (satisfies "one composition adds another tab including property editors").
- **`Tracking`** — a small third composition (Tags + a numeric "priority") to
  satisfy the "2–3 compositions" wish and add further distinct editor types.

### Content tree

- **~20 top-level nodes**, mostly `Page` with a few of the other doctypes mixed
  in.
- **Each top-level node has ≥ 1 child**, so the tree shows `hasChildren: true`
  broadly (simulating a real site).
- The **Homepage** is the only fully-populated node (TipTap + image, both media
  pickers, block grid, all compositions); the remaining nodes are lighter.
- Built via a helper-API loop.

**Requirement satisfied:** TipTap and a Media Picker are both at the top of the
Homepage editing view, in-view on load.

## 4. Playwright measurement harness

### Authentication

- **Time-to-first-edit** uses a **real login form submit** with **stored
  credentials** (the Terraform unattended-install admin,
  `loadtest@example.invalid` / `LoadTest123!`), because login is part of that
  journey.
- The **pure load measurements** (dashboard, home node) use a pre-authenticated
  Playwright **`storageState`** so auth-redirect variance doesn't pollute those
  numbers.

### Metrics

Each metric is repeated **N times (default 10)**; report **median + p75 + p95 +
stddev**; drop the first iteration as warm-up where noted.

| # | Metric | Start | Stop (content-visible signal) |
|---|---|---|---|
| 1 | **Cold News-dashboard load** | navigate (fresh context, cache disabled) | dashboard article-list element visible |
| 2 | **Cached News-dashboard load** | navigate (same context, second visit) | dashboard article-list element visible |
| 3 | **Cold Home-node load** | click Home node (fresh context) | TipTap field painted/visible |
| 4 | **Cached Home-node load** | click Home node (same context, second visit) | TipTap field painted/visible |
| 5 | **Time-to-first-edit (E2E)** | open URL | typed character rendered in TipTap |

Metric 5 also emits a **segment breakdown**: `login`, `navigate-to-node`,
`editor-ready`, `first-keystroke`.

### Cold vs cached semantics

- **Cold = browser-uncached against a warm server.** A fresh browser context
  with no storage/cache. The server is already warmed by the reused warm-up step,
  so this isolates client-side cold behaviour (JS bundle download, first API
  round-trips, SPA hydration) — *not* server cold-start.
- **Cached = repeat visit** in the same context, with browser cache and any
  app-side caches populated.
- Stated explicitly because the backoffice shell is **not** server-output-cached
  the way the rendered frontend is.

### Auxiliary data

Alongside the content-visible timing, each run captures **Performance API**
marks (TTFB, domContentLoaded, load event, LCP) via `page.evaluate` for context
and cross-checking.

## 5. Results & dashboard

- Playwright emits **NDJSON** per metric (one row per metric, carrying the same
  run metadata the existing publisher records: version, tier, scenario, SKU,
  seeder preset, commit, build id, plus the median/p75/p95/stddev and segment
  breakdown).
- `scripts/publish-client-results.ps1` writes the NDJSON into the **same**
  long-lived history blob container under a new **`client/`** prefix (mirroring
  the existing path convention `client/{major}/{version}/{tier}/{date}_{buildId}/`)
  and mirrors the rows into a **new `ClientMeasurement_CL`** custom table via the
  existing DCR / Logs-Ingestion path.
- `ensure-monitoring-infra.ps1` gains the **new stream** for that table.
- A **new Workbook tab** "Client measurements" charts cold/cached/first-edit
  medians per `(version × tier)` over time, alongside the segment breakdown for
  time-to-first-edit.
- **Regression gating:** `scripts/check-client-regression.ps1` mirrors
  `check-regression.ps1` (median-of-last-N baseline, percentage thresholds),
  **report-only** at first and gating per-cell once ≥ 3 baselines accrue — the
  same philosophy as the existing gate.

## 6. New / changed files

```
azure-pipeline-client.yml                      # new pipeline
templates/stages/provision.yml                 # extracted (shared with azure-pipeline.yml)
templates/stages/cleanup.yml                   # extracted (shared)
templates/jobs/client-measure-job.yml          # new (Playwright counterpart to load-test-job.yml)
loadtests/scenarios/Default/client/            # Playwright project
  playwright.config.ts
  global-setup.ts                              # acceptance-test-helpers model builder (idempotent)
  fixtures/contentModel.ts                     # the Page/compositions/tree spec
  measurements/dashboard.spec.ts               # metrics 1 & 2
  measurements/homeNode.spec.ts                # metrics 3 & 4
  measurements/timeToFirstEdit.spec.ts         # metric 5 + segments
  lib/measure.ts                               # timing helpers (content-visible + Perf API)
  package.json
scripts/publish-client-results.ps1             # NDJSON → blob + Log Analytics
scripts/check-client-regression.ps1            # client-metric regression gate
dashboards/loadtest.workbook.json              # + "Client measurements" tab
scripts/resolve-run-config.ps1                 # + 'client' workload value & validation
scripts/ensure-monitoring-infra.ps1            # + ClientMeasurement_CL stream/table
```

## 7. Testing strategy

- Validate against a **local Umbraco instance** first (operator names it):
  confirm the `globalSetup` model builder is idempotent and that each measurement
  produces stable medians before wiring the pipeline.
- Each measurement spec is **independently runnable** so a single metric can be
  debugged in isolation.
- Confirm the shared-template extraction (`provision.yml`, `cleanup.yml`) is a
  pure refactor: the existing `azure-pipeline.yml` produces an identical run plan
  after consuming the templates.

## 8. Open consideration — installed packages

We can't directly measure how third-party packages affect load (their loading
isn't controlled by us). But this harness produces a **clean-site baseline**, and
the same scripts can later run against an instance that *has* packages installed
— the **delta** is the package cost. Documented as a future extension, **not
built now**.
