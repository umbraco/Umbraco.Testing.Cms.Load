// Central place to read runtime configuration. Keeps secrets out of source and
// lets the pipeline override every value via environment variables.

// `??` only catches null/undefined, not an empty-string env var (e.g. an
// unresolved pipeline variable) — Number('') is 0, not NaN, so a blank
// CLIENT_MEASURE_REPS would silently run zero reps and still emit a fake
// all-zero summary row. Validate explicitly instead.
function positiveIntEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`${name}='${raw}' is not a positive integer`);
  }
  return n;
}

export const env = {
  // Strip a trailing slash so URL concatenation (`${baseUrl}${path}`) never
  // double-slashes if the pipeline/operator sets UMBRACO_BASE_URL with one.
  baseUrl: (process.env.UMBRACO_BASE_URL ?? 'https://localhost:44339').replace(/\/+$/, ''),
  user: process.env.UMBRACO_USER ?? 'loadtest@example.invalid',
  password: process.env.UMBRACO_PASSWORD ?? 'LoadTest123!',
  // Repetitions per metric. 10 gives a usable median/p95 without ballooning runtime.
  reps: positiveIntEnv('CLIENT_MEASURE_REPS', 10),
  // Where per-metric NDJSON is appended (one dir, one file per metric).
  resultsDir: process.env.CLIENT_RESULTS_DIR ?? 'results',
  // Run metadata, injected by the pipeline; harmless defaults for local runs.
  runId: process.env.CLIENT_RUN_ID ?? 'local',
  umbracoVersion: process.env.CLIENT_UMBRACO_VERSION ?? 'local',
  tier: process.env.CLIENT_TIER ?? 'local',
  scenario: process.env.CLIENT_SCENARIO ?? 'Default',
};
