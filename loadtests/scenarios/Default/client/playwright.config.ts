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
