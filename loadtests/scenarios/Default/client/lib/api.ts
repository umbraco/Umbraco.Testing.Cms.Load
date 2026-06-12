import { Page } from '@playwright/test';
// ApiHelpers takes a Playwright Page (issues HTTP via page.request) and logs in
// via api.login.login(email, password); baseUrl/creds come from the package's
// own env config (URL / UMBRACO_USER_LOGIN / UMBRACO_USER_PASSWORD).
import { ApiHelpers } from '@umbraco-cms/acceptance-test-helpers';
import { env } from './env';

// Do NOT set the package's env vars here: it freezes baseUrl at import time, so
// an assignment now is a no-op — lib/env-bridge.ts mirrors them first instead.
export async function makeApi(page: Page): Promise<ApiHelpers> {
  const api = new ApiHelpers(page);
  await api.login.login(env.user, env.password);
  return api;
}
