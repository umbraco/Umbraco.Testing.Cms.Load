// Umbraco load-test dashboard — single-page, client-side only.
//
// On load: lists all summary.ndjson blobs in the history container, downloads
// them in parallel, parses, groups rows by run_id (each NDJSON file is one run
// expanded as N per-sampler rows). Renders four tabs: Trends, Tiers, Compare,
// Runs. Filter state lives in the URL hash so links are shareable.

(() => {
    "use strict";

    // ---- Config + small utils -------------------------------------------------

    const CFG = window.DASHBOARD_CONFIG ?? {};
    const ACCOUNT = CFG.storageAccount;
    const CONTAINER = CFG.container;
    const SAS = (CFG.sas && CFG.sas[0] === "?") ? CFG.sas : "?" + (CFG.sas ?? "");

    const TIER_ORDER = ["Starter", "Standard", "Pro"];
    const VALID_TABS = ["trends", "tiers", "compare", "runs"];

    const $ = (sel) => document.querySelector(sel);
    const fmtPct = (v) => (v == null) ? "—" : (v * 100).toFixed(2) + "%";
    const fmtMs = (v) => (v == null) ? "—" : Math.round(v);
    const fmtNum = (v, dp = 1) => (v == null) ? "—" : Number(v).toFixed(dp);

    // Median + population stddev for the n>=2 cell rendering.
    function median(values) {
        const v = values.filter(x => x != null).sort((a, b) => a - b);
        if (v.length === 0) return null;
        const mid = v.length >>> 1;
        return v.length % 2 === 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
    }
    function stddev(values) {
        const v = values.filter(x => x != null);
        if (v.length < 2) return 0;
        const mean = v.reduce((a, b) => a + b, 0) / v.length;
        const sq = v.reduce((a, b) => a + (b - mean) ** 2, 0);
        return Math.sqrt(sq / v.length); // population
    }

    // ---- Data loading ---------------------------------------------------------

    function showError(msg) {
        const el = $("#error-banner");
        el.textContent = msg;
        el.classList.remove("hidden");
    }

    async function listSummaryBlobs() {
        const url = `https://${ACCOUNT}.blob.core.windows.net/${CONTAINER}${SAS}&restype=container&comp=list`;
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Blob list failed: ${res.status} ${res.statusText}`);
        const xml = await res.text();
        // Parse XML response — the names ending in summary.ndjson are what we want.
        // Quick regex parse instead of full XML walk; the response shape is stable.
        const names = [];
        for (const m of xml.matchAll(/<Name>([^<]+)<\/Name>/g)) {
            if (m[1].endsWith("summary.ndjson")) names.push(m[1]);
        }
        return names;
    }

    async function fetchNdjson(blobName) {
        const url = `https://${ACCOUNT}.blob.core.windows.net/${CONTAINER}/${blobName}${SAS}`;
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Blob download failed for ${blobName}: ${res.status}`);
        const text = await res.text();
        const rows = [];
        for (const line of text.split("\n")) {
            const trimmed = line.trim();
            if (!trimmed) continue;
            try { rows.push(JSON.parse(trimmed)); }
            catch { /* skip malformed lines, keep loading */ }
        }
        return rows;
    }

    // Group N per-sampler rows that share a run_id into a single run object
    // with metadata + samplers[]. Defensive — missing fields default to null.
    function groupByRun(rows) {
        const byRun = new Map();
        for (const row of rows) {
            const id = row.run_id;
            if (!id) continue;
            if (!byRun.has(id)) {
                byRun.set(id, {
                    run_id: id,
                    test_case_id: row.test_case_id ?? null,
                    commit: row.commit ?? null,
                    branch: row.branch ?? null,
                    started: row.run_started_at ?? null,
                    scenario: row.scenario ?? null,
                    version: row.umbraco_version ?? null,
                    tier: row.infra_tier ?? null,
                    seeder: row.seeder_preset ?? null,
                    user_count: row.user_count ?? null,
                    duration_seconds: row.duration_seconds ?? null,
                    cold_start: row.cold_start ?? null,
                    app_sku: row.app_service_sku ?? null,
                    sql_sku: row.sql_sku ?? null,
                    parse_status: row.parse_status ?? null,
                    server: {
                        plan_cpu_avg: row.plan_CpuPercentage_avg ?? null,
                        plan_cpu_max: row.plan_CpuPercentage_max ?? null,
                        plan_mem_avg: row.plan_MemoryPercentage_avg ?? null,
                        plan_mem_max: row.plan_MemoryPercentage_max ?? null,
                        sql_dtu_avg: row.sql_dtu_consumption_percent_avg ?? null,
                        sql_dtu_max: row.sql_dtu_consumption_percent_max ?? null,
                        sql_cpu_avg: row.sql_cpu_percent_avg ?? null,
                        sql_cpu_max: row.sql_cpu_percent_max ?? null,
                        sql_log_avg: row.sql_log_write_percent_avg ?? null,
                        sql_log_max: row.sql_log_write_percent_max ?? null,
                        app_5xx_max: row.app_Http5xx_max ?? null,
                        app_4xx_max: row.app_Http4xx_max ?? null,
                    },
                    samplers: [],
                });
            }
            // Per-sampler rows have scenario_name; metadata-only rows don't.
            if (row.scenario_name) {
                byRun.get(id).samplers.push({
                    name: row.scenario_name,
                    request_count: row.request_count ?? 0,
                    failure_count: row.failure_count ?? 0,
                    error_rate: row.error_rate ?? 0,
                    avg_ms: row.avg_ms ?? null,
                    p50_ms: row.p50_ms ?? null,
                    p90_ms: row.p90_ms ?? null,
                    p95_ms: row.p95_ms ?? null,
                    p99_ms: row.p99_ms ?? null,
                    max_ms: row.max_ms ?? null,
                });
            }
        }
        // Newest first by default — render code can re-sort if needed.
        return Array.from(byRun.values()).sort((a, b) => (b.started ?? "").localeCompare(a.started ?? ""));
    }

    async function loadAllRuns() {
        const t0 = performance.now();
        const blobs = await listSummaryBlobs();
        $("#footer-status").textContent = `Loading ${blobs.length} run(s)…`;

        // Parallel fetch with a soft concurrency cap.
        let skipped = 0;
        const cap = 10;
        const allRows = [];
        for (let i = 0; i < blobs.length; i += cap) {
            const slice = blobs.slice(i, i + cap);
            const results = await Promise.all(slice.map(b => fetchNdjson(b).catch(err => {
                console.warn("skip", b, err);
                skipped++;
                return [];
            })));
            for (const r of results) allRows.push(...r);
        }
        const runs = groupByRun(allRows);
        const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
        const skipMsg = skipped > 0 ? `, ${skipped} skipped` : "";
        $("#footer-status").textContent = `Loaded ${runs.length} run(s) from ${blobs.length} file(s)${skipMsg} in ${elapsed}s.`;
        return runs;
    }

    // ---- Filter state in URL hash --------------------------------------------

    function readHashState() {
        const params = new URLSearchParams(location.hash.replace(/^#/, ""));
        const tab = params.get("tab") || "trends";
        return {
            tab: VALID_TABS.includes(tab) ? tab : "trends",
            scenario: params.get("scenario") || "",
            version: params.get("version") || "",
            tier: params.get("tier") || "",
            from: params.get("from") || "",
            to: params.get("to") || "",
            baseline: params.get("baseline") || "",
            candidate: params.get("candidate") || "",
            threshold: params.get("threshold") || "10",
            metric: params.get("metric") || "p95",
            tiersScenario: params.get("tiersScenario") || "",
            tiersVersion: params.get("tiersVersion") || "",
            tiersBaseline: params.get("tiersBaseline") || "",
            tiersMetric: params.get("tiersMetric") || "p95",
        };
    }
    function writeHashState(state) {
        const params = new URLSearchParams();
        for (const [k, v] of Object.entries(state)) {
            if (v) params.set(k, v);
        }
        const newHash = "#" + params.toString();
        if (location.hash !== newHash) {
            history.replaceState(null, "", newHash);
        }
    }

    function applyFilters(runs, state) {
        return runs.filter(r => {
            if (state.scenario && r.scenario !== state.scenario) return false;
            if (state.version && r.version !== state.version) return false;
            if (state.tier && r.tier !== state.tier) return false;
            if (state.from && (r.started ?? "") < state.from) return false;
            // To-date is end-of-day inclusive: compare to YYYY-MM-DDT23:59
            if (state.to && (r.started ?? "") > state.to + "T23:59:59Z") return false;
            return true;
        });
    }

    // ---- Renderers ------------------------------------------------------------

    // Track chart instances so we can destroy them before re-render — Chart.js
    // leaks the canvas otherwise.
    const _chartInstances = new Map();
    function destroyChart(key) {
        if (_chartInstances.has(key)) {
            _chartInstances.get(key).destroy();
            _chartInstances.delete(key);
        }
    }
    function destroyChartsByPrefix(prefix) {
        for (const key of Array.from(_chartInstances.keys())) {
            if (key.startsWith(prefix)) destroyChart(key);
        }
    }

    // Sort a `[seriesKey, points][]` collection where seriesKey is "version/tier".
    // Default Array.sort would put Pro < Standard < Starter alphabetically; we
    // want TIER_ORDER, with version compared lexicographically as the outer key.
    function sortSeriesByVerThenTier(entries) {
        const tierOrder = (t) => {
            const i = TIER_ORDER.indexOf(t);
            return i === -1 ? Number.MAX_SAFE_INTEGER : i;
        };
        return entries.sort(([ka], [kb]) => {
            const [va, ta] = ka.split("/");
            const [vb, tb] = kb.split("/");
            if (va !== vb) return va.localeCompare(vb);
            return tierOrder(ta) - tierOrder(tb);
        });
    }

    // Stable color palette for (version × tier) lines on the trends chart.
    function colorFor(label, idx) {
        // Cycle through a hand-picked palette. Pico's accent colours don't reach
        // far enough for many simultaneous lines so we use our own.
        const palette = [
            "#0ea5e9", "#22c55e", "#f59e0b", "#ef4444", "#8b5cf6",
            "#ec4899", "#14b8a6", "#f97316", "#3b82f6", "#a855f7",
            "#10b981", "#eab308", "#dc2626", "#6366f1", "#06b6d4",
        ];
        return palette[idx % palette.length];
    }

    // Per-sampler latency metrics use run.samplers[].p95_ms etc.; server-side
    // metrics live on run.server.* and don't have a sampler dimension, so they
    // render a single chart instead of one-per-sampler.
    const SERVER_METRICS = {
        plan_cpu_max: "Plan CPU max %",
        sql_dtu_max:  "SQL DTU max %",
    };

    function metricToggleHtml(metric) {
        const opts = [
            ["p95", "p95 (ms)"],
            ["p99", "p99 (ms)"],
            ["err", "error rate"],
            ["plan_cpu_max", "Plan CPU max %"],
            ["sql_dtu_max", "SQL DTU max %"],
        ];
        return `<div class="metric-toggle"><strong>Metric:</strong>` +
            opts.map(([v, label]) =>
                `<label><input type="radio" name="trend-metric" value="${v}"${metric === v ? " checked" : ""}> ${label}</label>`
            ).join("") +
            `</div>`;
    }

    function attachMetricToggleHandler(container) {
        container.querySelectorAll('input[name="trend-metric"]').forEach(input => {
            input.addEventListener("change", () => {
                const s = readHashState();
                s.metric = input.value;
                writeHashState(s);
                rerender(window._runs);
            });
        });
    }

    function renderTrends(runs, state) {
        const container = $("#trends-content");
        destroyChartsByPrefix("trend:");
        if (runs.length === 0) {
            container.innerHTML = `<p><em>No runs match the current filter.</em></p>`;
            return;
        }

        const rawMetric = state.metric || "p95";
        if (rawMetric in SERVER_METRICS) {
            renderServerTrends(container, runs, rawMetric);
            attachMetricToggleHandler(container);
            return;
        }
        const metric = ["p95", "p99", "err"].includes(rawMetric) ? rawMetric : "p95";

        // Bucket by sampler name -> version -> tier -> [runs]
        const samplers = new Set();
        const versions = new Set();
        const tiers = new Set();
        const cells = new Map(); // key: sampler|version|tier -> array of {p95, p99, error_rate}

        for (const run of runs) {
            if (run.version) versions.add(run.version);
            if (run.tier) tiers.add(run.tier);
            for (const s of run.samplers) {
                samplers.add(s.name);
                const key = `${s.name}|${run.version}|${run.tier}`;
                if (!cells.has(key)) cells.set(key, []);
                cells.get(key).push({ p95: s.p95_ms, p99: s.p99_ms, err: s.error_rate });
            }
        }

        const sampList = Array.from(samplers).sort();
        const verList = Array.from(versions).sort();
        const tierList = [...TIER_ORDER.filter(t => tiers.has(t)), ...Array.from(tiers).filter(t => !TIER_ORDER.includes(t))];

        // Per-sampler time-series datasets: one line per (version, tier) cell,
        // x-axis is the run timestamp. Need version/tier for series grouping
        // and started for the time axis — skip runs missing any of them.
        const seriesBySampler = new Map();
        for (const run of runs) {
            if (!run.version || !run.tier || !run.started) continue;
            for (const s of run.samplers) {
                const seriesKey = `${run.version}/${run.tier}`;
                const point = {
                    x: run.started,
                    y: metric === "p95" ? s.p95_ms : metric === "p99" ? s.p99_ms : s.error_rate,
                    runId: run.run_id,
                    commit: run.commit,
                };
                if (point.y == null) continue;
                if (!seriesBySampler.has(s.name)) seriesBySampler.set(s.name, new Map());
                const seriesMap = seriesBySampler.get(s.name);
                if (!seriesMap.has(seriesKey)) seriesMap.set(seriesKey, []);
                seriesMap.get(seriesKey).push(point);
            }
        }

        let html = metricToggleHtml(metric);

        for (const samp of sampList) {
            const safeId = samp.replace(/[^A-Za-z0-9]/g, "-");
            html += `<h3>${escapeHtml(samp)}</h3>`;
            html += `<div class="chart-wrap"><canvas id="trend-chart-${safeId}"></canvas></div>`;
            html += `<details><summary>Matrix view (median ±stddev)</summary>`;
            html += `<table><thead><tr><th>Version</th>`;
            for (const t of tierList) html += `<th>${escapeHtml(t)}</th>`;
            html += `</tr></thead><tbody>`;
            for (const v of verList) {
                html += `<tr><td><code>${escapeHtml(v)}</code></td>`;
                for (const t of tierList) {
                    const arr = cells.get(`${samp}|${v}|${t}`) ?? [];
                    html += `<td>${formatTrendCell(arr)}</td>`;
                }
                html += `</tr>`;
            }
            html += `</tbody></table></details>`;
        }
        container.innerHTML = html;

        attachMetricToggleHandler(container);

        // Now that the canvases exist, instantiate the charts.
        for (const samp of sampList) {
            const safeId = samp.replace(/[^A-Za-z0-9]/g, "-");
            const canvas = $(`#trend-chart-${safeId}`);
            if (!canvas) continue;
            const seriesMap = seriesBySampler.get(samp) ?? new Map();
            const datasets = [];
            let i = 0;
            for (const [seriesKey, points] of sortSeriesByVerThenTier(Array.from(seriesMap.entries()))) {
                points.sort((a, b) => (a.x ?? "").localeCompare(b.x ?? ""));
                datasets.push({
                    label: seriesKey,
                    data: points,
                    borderColor: colorFor(seriesKey, i),
                    backgroundColor: colorFor(seriesKey, i),
                    tension: 0.2,
                    pointRadius: 4,
                    pointHoverRadius: 6,
                });
                i++;
            }
            const yLabel = metric === "err" ? "error rate" : metric + " (ms)";
            const yTicks = metric === "err"
                ? { callback: (v) => (v * 100).toFixed(2) + "%" }
                : undefined;
            const chart = new Chart(canvas.getContext("2d"), {
                type: "line",
                data: { datasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    parsing: { xAxisKey: "x", yAxisKey: "y" },
                    scales: {
                        x: { type: "time", time: { tooltipFormat: "yyyy-MM-dd HH:mm" }, title: { display: true, text: "run started" } },
                        y: { title: { display: true, text: yLabel }, beginAtZero: false, ticks: yTicks },
                    },
                    plugins: {
                        tooltip: {
                            callbacks: {
                                title: (items) => items.length ? new Date(items[0].parsed.x).toISOString().replace("T", " ").substring(0, 19) : "",
                                label: (ctx) => {
                                    const p = ctx.raw;
                                    const valStr = metric === "err" ? (p.y * 100).toFixed(2) + "%" : Math.round(p.y) + " ms";
                                    return `${ctx.dataset.label}: ${valStr}  (run #${p.runId}${p.commit ? ", " + p.commit.substring(0, 8) : ""})`;
                                },
                            },
                        },
                        legend: { position: "bottom" },
                    },
                },
            });
            _chartInstances.set(`trend:${samp}`, chart);
        }
    }

    function formatTrendCell(arr) {
        if (arr.length === 0) return `<span class="muted">—</span>`;
        const p95s = arr.map(x => x.p95).filter(x => x != null);
        const p99s = arr.map(x => x.p99).filter(x => x != null);
        const errs = arr.map(x => x.err).filter(x => x != null);
        if (p95s.length === 0) return `<span class="muted">no metrics</span>`;
        if (arr.length === 1) {
            return `${fmtMs(p95s[0])} / ${fmtMs(p99s[0])} <span class="muted">(${fmtPct(errs[0])})</span>`;
        }
        const p95Med = median(p95s), p99Med = median(p99s);
        const p95Std = stddev(p95s), p99Std = stddev(p99s);
        const errMed = median(errs);
        return `${fmtMs(p95Med)} ±${fmtNum(p95Std, 0)} / ${fmtMs(p99Med)} ±${fmtNum(p99Std, 0)} <span class="muted">(${fmtPct(errMed)} n=${arr.length})</span>`;
    }

    // Server-side metric trends: one chart, one matrix, no per-sampler split.
    // Lines are still (version × tier); points are run-level values.
    function renderServerTrends(container, runs, metric) {
        const versions = new Set();
        const tiers = new Set();
        const cells = new Map();        // version|tier -> [values]
        const seriesMap = new Map();    // "v/t" -> [points]
        for (const run of runs) {
            if (!run.version || !run.tier) continue;
            versions.add(run.version);
            tiers.add(run.tier);
            const v = run.server?.[metric];
            const cellKey = `${run.version}|${run.tier}`;
            if (!cells.has(cellKey)) cells.set(cellKey, []);
            cells.get(cellKey).push(v);
            // Need a timestamp for the time axis; matrix view tolerates missing
            // started (just bucketed by cell) but the chart would NaN.
            if (v == null || !run.started) continue;
            const seriesKey = `${run.version}/${run.tier}`;
            if (!seriesMap.has(seriesKey)) seriesMap.set(seriesKey, []);
            seriesMap.get(seriesKey).push({ x: run.started, y: v, runId: run.run_id, commit: run.commit });
        }
        const verList = Array.from(versions).sort();
        const tierList = [...TIER_ORDER.filter(t => tiers.has(t)), ...Array.from(tiers).filter(t => !TIER_ORDER.includes(t))];

        let html = metricToggleHtml(metric);
        html += `<h3>${escapeHtml(SERVER_METRICS[metric])}</h3>`;
        html += `<div class="chart-wrap"><canvas id="trend-chart-server"></canvas></div>`;
        html += `<details><summary>Matrix view (median ±stddev)</summary>`;
        html += `<table><thead><tr><th>Version</th>`;
        for (const t of tierList) html += `<th>${escapeHtml(t)}</th>`;
        html += `</tr></thead><tbody>`;
        for (const v of verList) {
            html += `<tr><td><code>${escapeHtml(v)}</code></td>`;
            for (const t of tierList) {
                const arr = (cells.get(`${v}|${t}`) ?? []).filter(x => x != null);
                html += `<td>${formatServerCell(arr)}</td>`;
            }
            html += `</tr>`;
        }
        html += `</tbody></table></details>`;
        container.innerHTML = html;

        const canvas = $("#trend-chart-server");
        if (!canvas) return;
        const datasets = [];
        let i = 0;
        for (const [seriesKey, points] of Array.from(seriesMap.entries()).sort()) {
            points.sort((a, b) => (a.x ?? "").localeCompare(b.x ?? ""));
            datasets.push({
                label: seriesKey,
                data: points,
                borderColor: colorFor(seriesKey, i),
                backgroundColor: colorFor(seriesKey, i),
                tension: 0.2,
                pointRadius: 4,
                pointHoverRadius: 6,
            });
            i++;
        }
        const chart = new Chart(canvas.getContext("2d"), {
            type: "line",
            data: { datasets },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                parsing: { xAxisKey: "x", yAxisKey: "y" },
                scales: {
                    x: { type: "time", time: { tooltipFormat: "yyyy-MM-dd HH:mm" }, title: { display: true, text: "run started" } },
                    y: { title: { display: true, text: "%" }, beginAtZero: true, suggestedMax: 100 },
                },
                plugins: {
                    tooltip: {
                        callbacks: {
                            title: (items) => items.length ? new Date(items[0].parsed.x).toISOString().replace("T", " ").substring(0, 19) : "",
                            label: (ctx) => {
                                const p = ctx.raw;
                                return `${ctx.dataset.label}: ${fmtNum(p.y)}%  (run #${p.runId}${p.commit ? ", " + p.commit.substring(0, 8) : ""})`;
                            },
                        },
                    },
                    legend: { position: "bottom" },
                },
            },
        });
        _chartInstances.set("trend:server", chart);
    }

    function formatServerCell(arr) {
        if (arr.length === 0) return `<span class="muted">—</span>`;
        if (arr.length === 1) return `${fmtNum(arr[0])}%`;
        return `${fmtNum(median(arr))}% ±${fmtNum(stddev(arr))} <span class="muted">(n=${arr.length})</span>`;
    }

    // Cross-tier snapshot: pick scenario + version, show the latest run per
    // tier side-by-side. Receives the FULL run list (not the globally filtered
    // one) because the tier dimension is what we're comparing — a tier filter
    // applied above would defeat the whole view.
    function renderTiers(allRuns, state) {
        const container = $("#tiers-content");
        const scenarioSel = $("#tiers-scenario");
        const versionSel = $("#tiers-version");
        destroyChartsByPrefix("tiers:");

        // Populate the two pickers from the entire history.
        const scenarios = new Set(), versions = new Set();
        for (const r of allRuns) {
            if (r.scenario) scenarios.add(r.scenario);
            if (r.version) versions.add(r.version);
        }
        const buildOpts = (values, current) =>
            `<option value="">— pick —</option>` +
            Array.from(values).sort().map(v =>
                `<option value="${escapeHtml(v)}"${v === current ? " selected" : ""}>${escapeHtml(v)}</option>`
            ).join("");
        scenarioSel.innerHTML = buildOpts(scenarios, state.tiersScenario);
        versionSel.innerHTML = buildOpts(versions, state.tiersVersion);

        if (!state.tiersScenario || !state.tiersVersion) {
            container.innerHTML = `<p class="muted">Pick a scenario and version above.</p>`;
            return;
        }

        const matched = allRuns.filter(r =>
            r.scenario === state.tiersScenario && r.version === state.tiersVersion
        );
        if (matched.length === 0) {
            container.innerHTML = `<p><em>No runs match <code>${escapeHtml(state.tiersScenario)}</code> / <code>${escapeHtml(state.tiersVersion)}</code>.</em></p>`;
            return;
        }

        // Latest run per tier — newest started timestamp wins.
        const latestByTier = new Map();
        for (const r of matched) {
            if (!r.tier) continue;
            const existing = latestByTier.get(r.tier);
            if (!existing || (r.started ?? "") > (existing.started ?? "")) {
                latestByTier.set(r.tier, r);
            }
        }
        const tiersFound = [
            ...TIER_ORDER.filter(t => latestByTier.has(t)),
            ...Array.from(latestByTier.keys()).filter(t => !TIER_ORDER.includes(t)).sort(),
        ];
        if (tiersFound.length === 0) {
            container.innerHTML = `<p><em>No tier data for that selection.</em></p>`;
            return;
        }

        const baselineTier = latestByTier.has(state.tiersBaseline) ? state.tiersBaseline : tiersFound[0];
        const metric = ["p95", "p99", "avg"].includes(state.tiersMetric) ? state.tiersMetric : "p95";
        const metricField = metric === "p95" ? "p95_ms" : metric === "p99" ? "p99_ms" : "avg_ms";
        // Reuse the user's Compare threshold so the dashboard has a single
        // "what counts as significant" knob, not two.
        const threshold = Number(state.threshold) || 10;

        // Sampler universe + per-(sampler, tier) lookup.
        const samplerNames = new Set();
        const sampByTier = new Map();
        for (const [tier, r] of latestByTier) {
            for (const s of r.samplers) {
                samplerNames.add(s.name);
                sampByTier.set(`${s.name}|${tier}`, s);
            }
        }
        const samplerList = Array.from(samplerNames).sort();

        // ---- HTML ------------------------------------------------------------

        let html = `<div class="grid">
            <label>Baseline tier
                <select id="tiers-baseline">
                    ${tiersFound.map(t =>
                        `<option value="${escapeHtml(t)}"${t === baselineTier ? " selected" : ""}>${escapeHtml(t)}</option>`
                    ).join("")}
                </select>
            </label>
            <label>Metric
                <select id="tiers-metric">
                    <option value="p95"${metric === "p95" ? " selected" : ""}>p95 (ms)</option>
                    <option value="p99"${metric === "p99" ? " selected" : ""}>p99 (ms)</option>
                    <option value="avg"${metric === "avg" ? " selected" : ""}>avg (ms)</option>
                </select>
            </label>
        </div>`;

        // Show which run was picked per tier so users know what they're seeing.
        html += `<p class="muted">Latest runs picked: `;
        html += tiersFound.map(t => {
            const r = latestByTier.get(t);
            const when = (r.started ?? "?").substring(0, 19).replace("T", " ");
            return `<code>${escapeHtml(t)}</code> #${escapeHtml(r.run_id)} <span class="muted">(${escapeHtml(when)})</span>`;
        }).join(" · ");
        html += `</p>`;

        // Per-sampler grouped bar chart.
        html += `<h3>${escapeHtml(metric)} per sampler</h3>`;
        html += `<div class="chart-wrap"><canvas id="tiers-chart-bar"></canvas></div>`;

        // Per-sampler delta table.
        html += `<h3>Per-sampler — Δ vs <code>${escapeHtml(baselineTier)}</code></h3>`;
        html += `<table><thead><tr><th>Sampler</th>`;
        for (const t of tiersFound) {
            html += `<th>${escapeHtml(t)}</th>`;
            if (t !== baselineTier) html += `<th>Δ</th>`;
        }
        html += `</tr></thead><tbody>`;
        for (const name of samplerList) {
            const baseSamp = sampByTier.get(`${name}|${baselineTier}`);
            const baseVal = baseSamp?.[metricField];
            html += `<tr><td><code>${escapeHtml(name)}</code></td>`;
            for (const t of tiersFound) {
                const samp = sampByTier.get(`${name}|${t}`);
                const v = samp?.[metricField];
                html += `<td>${fmtMs(v)}</td>`;
                if (t !== baselineTier) html += `<td>${formatDelta(baseVal, v, threshold)}</td>`;
            }
            html += `</tr>`;
        }
        html += `</tbody></table>`;

        // Server-side block — one column per tier (no Δ — absolute % is what matters).
        html += `<h3>Server-side</h3>`;
        html += `<table><thead><tr><th>Metric</th>`;
        for (const t of tiersFound) html += `<th>${escapeHtml(t)}</th>`;
        html += `</tr></thead><tbody>`;
        const serverFields = [
            ["Plan CPU max",      "plan_cpu_max"],
            ["Plan CPU avg",      "plan_cpu_avg"],
            ["Plan Memory max",   "plan_mem_max"],
            ["SQL DTU max",       "sql_dtu_max"],
            ["SQL DTU avg",       "sql_dtu_avg"],
            ["SQL CPU max",       "sql_cpu_max"],
            ["SQL Log-write max", "sql_log_max"],
        ];
        for (const [label, key] of serverFields) {
            html += `<tr><td>${escapeHtml(label)}</td>`;
            for (const t of tiersFound) {
                const r = latestByTier.get(t);
                const v = r.server?.[key];
                html += `<td>${v == null ? `<span class="muted">—</span>` : fmtNum(v) + "%"}</td>`;
            }
            html += `</tr>`;
        }
        html += `</tbody></table>`;

        container.innerHTML = html;

        // ---- Wire dynamic dropdowns + build the chart -----------------------

        $("#tiers-baseline").addEventListener("change", () => {
            const s = readHashState();
            s.tiersBaseline = $("#tiers-baseline").value;
            writeHashState(s);
            renderTiers(window._runs, readHashState());
        });
        $("#tiers-metric").addEventListener("change", () => {
            const s = readHashState();
            s.tiersMetric = $("#tiers-metric").value;
            writeHashState(s);
            renderTiers(window._runs, readHashState());
        });

        const canvas = $("#tiers-chart-bar");
        if (canvas) {
            const datasets = tiersFound.map((t, i) => ({
                label: t,
                data: samplerList.map(n => sampByTier.get(`${n}|${t}`)?.[metricField] ?? null),
                backgroundColor: colorFor(t, i),
            }));
            const chart = new Chart(canvas.getContext("2d"), {
                type: "bar",
                data: { labels: samplerList, datasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        x: { stacked: false },
                        y: { title: { display: true, text: `${metric} (ms)` }, beginAtZero: true },
                    },
                    plugins: { legend: { position: "bottom" } },
                },
            });
            _chartInstances.set("tiers:bar", chart);
        }
    }

    function renderCompare(runs, state) {
        // Populate the run dropdowns from the (filtered) run list.
        const baseline = $("#compare-baseline");
        const candidate = $("#compare-candidate");
        const optHtml = `<option value="">—</option>` + runs.map(r =>
            `<option value="${escapeHtml(r.run_id)}">${escapeHtml(r.started ?? "?")} · ${escapeHtml(r.scenario)} / ${escapeHtml(r.version)} / ${escapeHtml(r.tier)} (#${escapeHtml(r.run_id)})</option>`
        ).join("");
        baseline.innerHTML = optHtml;
        candidate.innerHTML = optHtml;
        if (state.baseline) baseline.value = state.baseline;
        if (state.candidate) candidate.value = state.candidate;

        const content = $("#compare-content");
        if (!state.baseline || !state.candidate) {
            content.innerHTML = `<p class="muted">Pick two runs to compare.</p>`;
            return;
        }
        // Normalise run_id: option values are strings (URL hash + DOM), but
        // r.run_id may arrive as a number from JSON.
        const a = runs.find(r => String(r.run_id) === state.baseline);
        const b = runs.find(r => String(r.run_id) === state.candidate);
        if (!a || !b) {
            content.innerHTML = `<p><em>One of the selected runs isn't in the current filter — adjust filters or pick again.</em></p>`;
            return;
        }
        const threshold = Number(state.threshold) || 10;

        let html = `
            <h3>Per-sampler — ${escapeHtml(a.scenario)} / ${escapeHtml(a.tier)} / ${escapeHtml(a.version)} → ${escapeHtml(b.scenario)} / ${escapeHtml(b.tier)} / ${escapeHtml(b.version)}</h3>
            <div class="chart-wrap"><canvas id="compare-chart-bar"></canvas></div>
            <table><thead><tr>
                <th>Sampler</th>
                <th>Baseline count</th><th>Candidate count</th>
                <th>Avg Δ</th><th>p95 Δ</th><th>p99 Δ</th>
            </tr></thead><tbody>`;

        const aBy = Object.fromEntries(a.samplers.map(s => [s.name, s]));
        const bBy = Object.fromEntries(b.samplers.map(s => [s.name, s]));
        const allNames = Array.from(new Set([...Object.keys(aBy), ...Object.keys(bBy)])).sort();

        for (const name of allNames) {
            const sa = aBy[name], sb = bBy[name];
            html += `<tr><td><code>${escapeHtml(name)}</code></td>`;
            html += `<td>${sa?.request_count ?? `<span class="muted">—</span>`}</td>`;
            html += `<td>${sb?.request_count ?? `<span class="muted">—</span>`}</td>`;
            html += `<td>${formatDelta(sa?.avg_ms, sb?.avg_ms, threshold)}</td>`;
            html += `<td>${formatDelta(sa?.p95_ms, sb?.p95_ms, threshold)}</td>`;
            html += `<td>${formatDelta(sa?.p99_ms, sb?.p99_ms, threshold)}</td>`;
            html += `</tr>`;
        }
        html += `</tbody></table>`;

        // Server-side comparison block.
        html += `<h3>Server-side</h3><table><thead><tr><th>Metric</th><th>Baseline</th><th>Candidate</th><th>Δ</th></tr></thead><tbody>`;
        const serverFields = [
            ["Plan CPU max", "plan_cpu_max", "%"],
            ["Plan CPU avg", "plan_cpu_avg", "%"],
            ["Plan Memory max", "plan_mem_max", "%"],
            ["SQL DTU max", "sql_dtu_max", "%"],
            ["SQL DTU avg", "sql_dtu_avg", "%"],
            ["SQL CPU max", "sql_cpu_max", "%"],
            ["SQL Log-write max", "sql_log_max", "%"],
        ];
        const muted = `<span class="muted">—</span>`;
        for (const [label, key, suffix] of serverFields) {
            const va = a.server?.[key], vb = b.server?.[key];
            html += `<tr>
                <td>${escapeHtml(label)}</td>
                <td>${va == null ? muted : fmtNum(va) + suffix}</td>
                <td>${vb == null ? muted : fmtNum(vb) + suffix}</td>
                <td>${formatDelta(va, vb, threshold)}</td>
            </tr>`;
        }
        html += `</tbody></table>`;

        content.innerHTML = html;

        // Build the per-sampler bar chart: grouped bars baseline vs candidate
        // for p95 and p99 across each sampler. Spotting "every sampler
        // regressed by ~X%" is a chart-shaped task more than a row-of-numbers
        // one.
        destroyChart("compare:bar");
        const canvas = $("#compare-chart-bar");
        if (canvas) {
            const labels = allNames;
            const datasets = [
                { label: "Baseline p95", data: labels.map(n => aBy[n]?.p95_ms ?? null), backgroundColor: "#0ea5e9" },
                { label: "Candidate p95", data: labels.map(n => bBy[n]?.p95_ms ?? null), backgroundColor: "#22c55e" },
                { label: "Baseline p99", data: labels.map(n => aBy[n]?.p99_ms ?? null), backgroundColor: "#0369a1" },
                { label: "Candidate p99", data: labels.map(n => bBy[n]?.p99_ms ?? null), backgroundColor: "#15803d" },
            ];
            const chart = new Chart(canvas.getContext("2d"), {
                type: "bar",
                data: { labels, datasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {
                        x: { stacked: false },
                        y: { title: { display: true, text: "ms" }, beginAtZero: true },
                    },
                    plugins: { legend: { position: "bottom" } },
                },
            });
            _chartInstances.set("compare:bar", chart);
        }
    }

    function formatDelta(a, b, threshold) {
        if (a == null || b == null) return `<span class="muted">—</span>`;
        if (a === 0) return b === 0 ? "0%" : `<span class="muted">n/a</span>`;
        const pct = ((b - a) / a) * 100;
        const sign = pct > 0 ? "+" : "";
        const str = `${sign}${pct.toFixed(0)}%`;
        const significant = Math.abs(pct) >= threshold;
        const cls = significant ? (pct > 0 ? "delta-bad" : "delta-good") : "";
        return `<span class="${cls}">${str}</span>`;
    }

    function renderRuns(runs, state) {
        const container = $("#runs-content");
        if (runs.length === 0) {
            container.innerHTML = `<p><em>No runs match the current filter.</em></p>`;
            return;
        }
        let html = `<table class="runs-table"><thead><tr>
            <th></th>
            <th>Started</th><th>Scenario</th><th>Version</th><th>Tier</th>
            <th>Run #</th><th>Commit</th><th>Status</th>
        </tr></thead><tbody>`;
        for (const r of runs) {
            const started = r.started?.replace("T", " ").replace(/\.\d+/, "").substring(0, 19) ?? "?";
            const id = String(r.run_id);
            html += `<tr class="run-row" data-run-id="${escapeHtml(id)}">
                <td class="run-toggle" aria-label="expand">▸</td>
                <td>${escapeHtml(started)}</td>
                <td>${escapeHtml(r.scenario ?? "")}</td>
                <td><code>${escapeHtml(r.version ?? "")}</code></td>
                <td>${escapeHtml(r.tier ?? "")}</td>
                <td>${escapeHtml(id)}</td>
                <td><code>${escapeHtml((r.commit ?? "").substring(0, 8))}</code></td>
                <td>${r.parse_status === "ok" ? "✓" : `<span class="muted">${escapeHtml(r.parse_status ?? "?")}</span>`}</td>
            </tr>
            <tr class="run-detail hidden" data-detail-for="${escapeHtml(id)}">
                <td colspan="8">${renderRunDetail(r)}</td>
            </tr>`;
        }
        html += `</tbody></table>`;
        container.innerHTML = html;

        container.querySelectorAll(".run-row").forEach(row => {
            row.addEventListener("click", () => {
                const id = row.dataset.runId;
                const detail = container.querySelector(`.run-detail[data-detail-for="${CSS.escape(id)}"]`);
                if (!detail) return;
                const open = detail.classList.toggle("hidden") === false;
                row.classList.toggle("expanded", open);
                row.querySelector(".run-toggle").textContent = open ? "▾" : "▸";
            });
        });
    }

    // Inline drill-down for a single run: metadata + per-sampler table +
    // server-side metrics. Rendered into the detail row's <td colspan>.
    function renderRunDetail(r) {
        const meta = [
            ["Run ID", r.run_id],
            ["Started", r.started],
            ["Branch", r.branch],
            ["Commit", r.commit],
            ["Test case", r.test_case_id],
            ["Seeder preset", r.seeder],
            ["User count", r.user_count],
            ["Duration (s)", r.duration_seconds],
            ["Cold start", r.cold_start],
            ["App SKU", r.app_sku],
            ["SQL SKU", r.sql_sku],
            ["Parse status", r.parse_status],
        ];
        let html = `<div class="run-detail-content">`;

        html += `<div><strong>Run metadata</strong><dl>`;
        for (const [k, v] of meta) {
            const cell = (v == null || v === "") ? `<span class="muted">—</span>` : `<code>${escapeHtml(String(v))}</code>`;
            html += `<dt>${escapeHtml(k)}</dt><dd>${cell}</dd>`;
        }
        html += `</dl></div>`;

        html += `<div><strong>Per-sampler</strong>`;
        if (!r.samplers || r.samplers.length === 0) {
            html += `<p class="muted">No sampler data.</p>`;
        } else {
            html += `<table><thead><tr>
                <th>Sampler</th>
                <th>Reqs</th><th>Fails</th><th>Err %</th>
                <th>Avg</th><th>p50</th><th>p90</th><th>p95</th><th>p99</th><th>Max</th>
            </tr></thead><tbody>`;
            for (const s of r.samplers) {
                html += `<tr>
                    <td><code>${escapeHtml(s.name)}</code></td>
                    <td>${s.request_count}</td>
                    <td>${s.failure_count}</td>
                    <td>${fmtPct(s.error_rate)}</td>
                    <td>${fmtMs(s.avg_ms)}</td>
                    <td>${fmtMs(s.p50_ms)}</td>
                    <td>${fmtMs(s.p90_ms)}</td>
                    <td>${fmtMs(s.p95_ms)}</td>
                    <td>${fmtMs(s.p99_ms)}</td>
                    <td>${fmtMs(s.max_ms)}</td>
                </tr>`;
            }
            html += `</tbody></table>`;
        }
        html += `</div>`;

        // Suffix "%" for percentage fields, "" for integer counts (so app_5xx_max
        // renders as "5", not "5.0%").
        const serverFields = [
            ["Plan CPU avg",    r.server?.plan_cpu_avg, "%"],
            ["Plan CPU max",    r.server?.plan_cpu_max, "%"],
            ["Plan Memory avg", r.server?.plan_mem_avg, "%"],
            ["Plan Memory max", r.server?.plan_mem_max, "%"],
            ["SQL DTU avg",     r.server?.sql_dtu_avg,  "%"],
            ["SQL DTU max",     r.server?.sql_dtu_max,  "%"],
            ["SQL CPU avg",     r.server?.sql_cpu_avg,  "%"],
            ["SQL CPU max",     r.server?.sql_cpu_max,  "%"],
            ["SQL Log-write avg", r.server?.sql_log_avg, "%"],
            ["SQL Log-write max", r.server?.sql_log_max, "%"],
            ["App 5xx max",     r.server?.app_5xx_max,  ""],
            ["App 4xx max",     r.server?.app_4xx_max,  ""],
        ];
        html += `<div><strong>Server-side</strong><dl>`;
        for (const [k, v, suffix] of serverFields) {
            let cell;
            if (v == null) cell = `<span class="muted">—</span>`;
            else if (suffix === "%") cell = `${fmtNum(v)}%`;
            else cell = String(Math.round(v));
            html += `<dt>${escapeHtml(k)}</dt><dd>${cell}</dd>`;
        }
        html += `</dl></div>`;

        html += `</div>`;
        return html;
    }

    // ---- Filter dropdown population ------------------------------------------

    function populateFilters(runs) {
        const scenarios = new Set(), versions = new Set(), tiers = new Set();
        for (const r of runs) {
            if (r.scenario) scenarios.add(r.scenario);
            if (r.version) versions.add(r.version);
            if (r.tier) tiers.add(r.tier);
        }
        const fillOptions = (selectId, values, current) => {
            const sel = $(selectId);
            sel.innerHTML = `<option value="">— all —</option>` + Array.from(values).sort().map(v =>
                `<option value="${escapeHtml(v)}"${v === current ? " selected" : ""}>${escapeHtml(v)}</option>`
            ).join("");
        };
        const state = readHashState();
        fillOptions("#filter-scenario", scenarios, state.scenario);
        fillOptions("#filter-version", versions, state.version);
        // Tier order: known first, others alphabetical.
        const tierList = [...TIER_ORDER.filter(t => tiers.has(t)), ...Array.from(tiers).filter(t => !TIER_ORDER.includes(t)).sort()];
        fillOptions("#filter-tier", tierList, state.tier);
        $("#filter-from").value = state.from;
        $("#filter-to").value = state.to;
        $("#compare-threshold").value = state.threshold;
    }

    // ---- Wiring + escaping ----------------------------------------------------

    function escapeHtml(s) {
        return String(s ?? "").replace(/[&<>"']/g, c => (
            { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
        ));
    }

    function activateTab(tabId) {
        document.querySelectorAll(".tab").forEach(t => t.classList.add("hidden"));
        document.querySelectorAll('nav a[data-tab]').forEach(a => a.classList.remove("active"));
        $(`#tab-${tabId}`).classList.remove("hidden");
        document.querySelector(`nav a[data-tab="${tabId}"]`).classList.add("active");
        // Charts created inside a hidden tab initialise at 0×0 because
        // display:none doesn't always fire ResizeObserver. Force a resize
        // now that the relevant container has real dimensions; charts in
        // still-hidden tabs no-op.
        for (const chart of _chartInstances.values()) chart.resize();
    }

    function rerender(runs) {
        const state = readHashState();
        const filtered = applyFilters(runs, state);
        renderTrends(filtered, state);
        renderTiers(runs, state);    // intentionally unfiltered — see renderTiers
        renderCompare(filtered, state);
        renderRuns(filtered, state);
        activateTab(state.tab);
    }

    function wireEvents(runs) {
        document.querySelectorAll('nav a[data-tab]').forEach(a => {
            a.addEventListener("click", e => {
                e.preventDefault();
                const state = readHashState();
                state.tab = a.dataset.tab;
                writeHashState(state);
                activateTab(state.tab);
            });
        });
        const updateFromControls = () => {
            const state = readHashState();
            state.scenario = $("#filter-scenario").value;
            state.version = $("#filter-version").value;
            state.tier = $("#filter-tier").value;
            state.from = $("#filter-from").value;
            state.to = $("#filter-to").value;
            state.baseline = $("#compare-baseline").value;
            state.candidate = $("#compare-candidate").value;
            state.threshold = $("#compare-threshold").value;
            state.tiersScenario = $("#tiers-scenario").value;
            state.tiersVersion = $("#tiers-version").value;
            writeHashState(state);
            rerender(runs);
        };
        ["filter-scenario", "filter-version", "filter-tier", "filter-from", "filter-to",
         "compare-baseline", "compare-candidate", "compare-threshold",
         "tiers-scenario", "tiers-version"].forEach(id => {
            $(`#${id}`).addEventListener("change", updateFromControls);
        });
        let reloading = false;
        $("#refresh-link").addEventListener("click", async e => {
            e.preventDefault();
            if (reloading) return;
            reloading = true;
            $("#footer-status").textContent = "Reloading…";
            try {
                const fresh = await loadAllRuns();
                runs.length = 0; runs.push(...fresh);
                populateFilters(runs);
                rerender(runs);
            } catch (err) {
                showError(`Reload failed: ${err.message}`);
            } finally {
                reloading = false;
            }
        });
    }

    // ---- Bootstrap ------------------------------------------------------------

    async function init() {
        $("#storage-source").textContent = `${ACCOUNT}/${CONTAINER}`;
        const placeholder = "REPLACE_AT_DEPLOY";
        if (!ACCOUNT || !CONTAINER || !CFG.sas ||
            ACCOUNT === placeholder || CONTAINER === placeholder || CFG.sas === placeholder) {
            showError("Dashboard config wasn't replaced at deploy time. config.js still has placeholders.");
            return;
        }
        try {
            const runs = await loadAllRuns();
            // Exposed so handlers rendered into dynamic HTML (Trends metric toggle,
            // Tiers baseline/metric pickers) can re-render without re-fetching.
            window._runs = runs;
            populateFilters(runs);
            wireEvents(runs);
            rerender(runs);
        } catch (err) {
            console.error(err);
            showError(`Failed to load history: ${err.message}. Check storage CORS rule and SAS validity.`);
            $("#footer-status").textContent = "";
        }
    }

    document.addEventListener("DOMContentLoaded", init);
})();
