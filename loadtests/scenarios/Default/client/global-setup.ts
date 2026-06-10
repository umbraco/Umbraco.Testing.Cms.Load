// Runs once before any spec (wired via playwright.config.ts globalSetup).
// Builds the precise backoffice content model so measurements run against a
// known, stable tree. makeApi needs a Playwright Page (the package issues all
// HTTP through page.request and stores auth there), so we launch a throwaway
// browser here.
import './lib/env-bridge'; // first: bridge env vars before the package is required
import { chromium, FullConfig } from '@playwright/test';
import { makeApi } from './lib/api';
import { buildContentModel } from './fixtures/contentModel';
import { env } from './lib/env';

export default async function globalSetup(_config: FullConfig): Promise<void> {
  if (process.env.SKIP_GLOBAL_SETUP === '1') {
    return;
  }
  const browser = await chromium.launch();
  const context = await browser.newContext({ baseURL: env.baseUrl, ignoreHTTPSErrors: true });
  const page = await context.newPage();
  try {
    const api = await makeApi(page);
    await buildContentModel(api);
    console.log('[global-setup] content model ready');
  } finally {
    await browser.close();
  }
}
