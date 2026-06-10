import { Page } from '@playwright/test';
// VERIFIED against @umbraco-cms/acceptance-test-helpers@17.4.2 (see
// docs/superpowers/acceptance-helpers-exports.txt). The real export is
// `ApiHelpers`, NOT `UmbracoApiHelpers`. Its constructor takes a Playwright
// `Page` (it issues all HTTP via `page.request`, reusing the browser context's
// auth cookies), NOT an APIRequestContext + baseUrl. baseUrl and credentials
// are read by the package from its own env-driven config (umbracoConfig):
//   URL, UMBRACO_USER_LOGIN, UMBRACO_USER_PASSWORD.
// Login is performed via `api.login.login(email, password)` (the PKCE flow),
// after which the auth token lives in the page's request context.
import { ApiHelpers } from '@umbraco-cms/acceptance-test-helpers';
import { env } from './env';

// Build an authenticated API helper bound to the target instance.
//
// The package reads baseUrl/credentials from process.env (URL /
// UMBRACO_USER_LOGIN / UMBRACO_USER_PASSWORD) at import time — those are mirrored
// from our env vars by lib/env-bridge.ts, which playwright.config.ts imports
// first. Do NOT set them here: by the time this runs the package has already
// frozen baseUrl, so an assignment here would be a no-op.
export async function makeApi(page: Page): Promise<ApiHelpers> {
  const api = new ApiHelpers(page);
  await api.login.login(env.user, env.password);
  return api;
}
