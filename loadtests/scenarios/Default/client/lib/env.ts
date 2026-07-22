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
