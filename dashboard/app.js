// Umbraco load-test dashboard — single-page, client-side only.
//
// On load: lists all summary.ndjson blobs in the history container, downloads
// them in parallel, parses, groups rows by run_id (each NDJSON file is one run
// expanded as N per-sampler rows). Renders three tabs: Trends, Compare, Runs.
// Filter state lives in the URL hash so links are shareable.

(() => {
    "use strict";

    // ---- Config + small utils -------------------------------------------------

    const CFG = window.DASHBOARD_CONFIG ?? {};
    const ACCOUNT = CFG.storageAccount;
    const CONTAINER = CFG.container;
    const SAS = (CFG.sas && CFG.sas[0] === "?") ? CFG.sas : "?" + (CFG.sas ?? "");

    const TIER_ORDER = ["Starter", "Standard", "Pro"];

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
        const cap = 10;
        const allRows = [];
        for (let i = 0; i < blobs.length; i += cap) {
            const slice = blobs.slice(i, i + cap);
            const results = await Promise.all(slice.map(b => fetchNdjson(b).catch(err => {
                console.warn("skip", b, err);
                return [];
            })));
            for (const r of results) allRows.push(...r);
        }
        const runs = groupByRun(allRows);
        const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
        $("#footer-status").textContent = `Loaded ${runs.length} run(s) from ${blobs.length} file(s) in ${elapsed}s.`;
        return runs;
    }

    // ---- Filter state in URL hash --------------------------------------------

    function readHashState() {
        const params = new URLSearchParams(location.hash.replace(/^#/, ""));
        return {
            tab: params.get("tab") || "trends",
            scenario: params.get("scenario") || "",
            version: params.get("version") || "",
            tier: params.get("tier") || "",
            from: params.get("from") || "",
            to: params.get("to") || "",
            baseline: params.get("baseline") || "",
            candidate: params.get("candidate") || "",
            threshold: params.get("threshold") || "10",
            metric: params.get("metric") || "p95",
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

    function renderTrends(runs, state) {
        const container = $("#trends-content");
        destroyChartsByPrefix("trend:");
        if (runs.length === 0) {
            container.innerHTML = `<p><em>No runs match the current filter.</em></p>`;
            return;
        }

        // Bucket by sampler name -> version -> tier -> [runs]
        const samplers = new Set();
        const versions = new Set();
        const tiers = new Set();
        const cells = new Map(); // key: sampler|version|tier -> array of {p95, p99, error_rate}

        for (const run of runs) {
            versions.add(run.version);
            tiers.add(run.tier);
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
        const metric = state.metric || "p95";

        // Per-sampler time-series datasets: one line per (version, tier) cell,
        // x-axis is the run timestamp.
        const seriesBySampler = new Map();
        for (const run of runs) {
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

        let html = `
            <div class="metric-toggle">
                <strong>Metric:</strong>
                <label><input type="radio" name="trend-metric" value="p95"${metric === "p95" ? " checked" : ""}> p95 (ms)</label>
                <label><input type="radio" name="trend-metric" value="p99"${metric === "p99" ? " checked" : ""}> p99 (ms)</label>
                <label><input type="radio" name="trend-metric" value="err"${metric === "err" ? " checked" : ""}> error rate</label>
            </div>
        `;

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

        // Attach the metric toggle handler — re-renders Trends only.
        container.querySelectorAll('input[name="trend-metric"]').forEach(input => {
            input.addEventListener("change", () => {
                const s = readHashState();
                s.metric = input.value;
                writeHashState(s);
                rerender(window._runs);
            });
        });

        // Now that the canvases exist, instantiate the charts.
        for (const samp of sampList) {
            const safeId = samp.replace(/[^A-Za-z0-9]/g, "-");
            const canvas = $(`#trend-chart-${safeId}`);
            if (!canvas) continue;
            const seriesMap = seriesBySampler.get(samp) ?? new Map();
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
            const yLabel = metric === "err" ? "error rate" : metric + " (ms)";
            const chart = new Chart(canvas.getContext("2d"), {
                type: "line",
                data: { datasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    parsing: { xAxisKey: "x", yAxisKey: "y" },
                    scales: {
                        x: { type: "time", time: { tooltipFormat: "yyyy-MM-dd HH:mm" }, title: { display: true, text: "run started" } },
                        y: { title: { display: true, text: yLabel }, beginAtZero: false },
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
            // Note: Chart.js v4 needs the date adapter for type:"time". If it's
            // not loaded, fall back to category scale. We try-catch above; if
            // Chart construction failed for any reason we just leave the canvas blank.
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

    function renderCompare(runs, state) {
        // Populate the run dropdowns from the (filtered) run list.
        const baseline = $("#compare-baseline");
        const candidate = $("#compare-candidate");
        const optHtml = `<option value="">—</option>` + runs.map(r =>
            `<option value="${r.run_id}">${escapeHtml(r.started ?? "?")} · ${escapeHtml(r.scenario)} / ${escapeHtml(r.version)} / ${escapeHtml(r.tier)} (#${escapeHtml(r.run_id)})</option>`
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
        const a = runs.find(r => r.run_id === state.baseline);
        const b = runs.find(r => r.run_id === state.candidate);
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
            html += `<td>${sa?.request_count ?? "<em>missing</em>"}</td>`;
            html += `<td>${sb?.request_count ?? "<em>missing</em>"}</td>`;
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
        for (const [label, key, suffix] of serverFields) {
            const va = a.server?.[key], vb = b.server?.[key];
            html += `<tr>
                <td>${escapeHtml(label)}</td>
                <td>${va == null ? "—" : fmtNum(va) + suffix}</td>
                <td>${vb == null ? "—" : fmtNum(vb) + suffix}</td>
                <td>${formatDelta(va, vb, threshold)}</td>
            </tr>`;
        }
        html += `</tbody></table>`;

        content.innerHTML = html;

        // Build the per-sampler bar chart: grouped bars baseline vs candidate
        // for p50 / p95 / p99 across each sampler. Visualises what the table
        // shows numerically; spotting "every sampler regressed by ~X%" is a
        // chart-shaped task more than a row-of-numbers one.
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
        let html = `<table><thead><tr>
            <th>Started</th><th>Scenario</th><th>Version</th><th>Tier</th>
            <th>Run #</th><th>Commit</th><th>Status</th>
        </tr></thead><tbody>`;
        for (const r of runs) {
            html += `<tr>
                <td>${escapeHtml(r.started?.replace("T", " ").replace(/\.\d+/, "").substring(0, 19) ?? "?")}</td>
                <td>${escapeHtml(r.scenario ?? "")}</td>
                <td><code>${escapeHtml(r.version ?? "")}</code></td>
                <td>${escapeHtml(r.tier ?? "")}</td>
                <td>${escapeHtml(r.run_id)}</td>
                <td><code>${escapeHtml((r.commit ?? "").substring(0, 8))}</code></td>
                <td>${r.parse_status === "ok" ? "✓" : `<span class="muted">${escapeHtml(r.parse_status ?? "?")}</span>`}</td>
            </tr>`;
        }
        html += `</tbody></table>`;
        container.innerHTML = html;
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
    }

    function rerender(runs) {
        const state = readHashState();
        const filtered = applyFilters(runs, state);
        renderTrends(filtered, state);
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
            writeHashState(state);
            rerender(runs);
        };
        ["filter-scenario", "filter-version", "filter-tier", "filter-from", "filter-to",
         "compare-baseline", "compare-candidate", "compare-threshold"].forEach(id => {
            $(`#${id}`).addEventListener("change", updateFromControls);
        });
        $("#refresh-link").addEventListener("click", async e => {
            e.preventDefault();
            $("#footer-status").textContent = "Reloading…";
            try {
                const fresh = await loadAllRuns();
                runs.length = 0; runs.push(...fresh);
                populateFilters(runs);
                rerender(runs);
            } catch (err) {
                showError(`Reload failed: ${err.message}`);
            }
        });
    }

    // ---- Bootstrap ------------------------------------------------------------

    async function init() {
        $("#storage-source").textContent = `${ACCOUNT}/${CONTAINER}`;
        if (!ACCOUNT || ACCOUNT === "REPLACE_AT_DEPLOY") {
            showError("Dashboard config wasn't replaced at deploy time. config.js still has placeholders.");
            return;
        }
        try {
            const runs = await loadAllRuns();
            window._runs = runs;  // exposed for the metric-toggle handler in renderTrends
            populateFilters(runs);
            wireEvents(runs);
            rerender(runs);
        } catch (err) {
            console.error(err);
            showError(`Failed to load history: ${err.message}. Check storage CORS rule and SAS validity.`);
        }
    }

    document.addEventListener("DOMContentLoaded", init);
})();
