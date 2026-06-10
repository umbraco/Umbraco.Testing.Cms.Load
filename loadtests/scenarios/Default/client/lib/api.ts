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
// IMPORTANT for callers: the package reads baseUrl/credentials from process.env
// (URL / UMBRACO_USER_LOGIN / UMBRACO_USER_PASSWORD) at import time. Our env.ts
// uses different variable names; to keep a single source of truth we mirror our
// values onto the package's expected env names here if they are not already set.
export async function makeApi(page: Page): Promise<ApiHelpers> {
  process.env.URL ??= env.baseUrl;
  process.env.UMBRACO_USER_LOGIN ??= env.user;
  process.env.UMBRACO_USER_PASSWORD ??= env.password;

  const api = new ApiHelpers(page);
  await api.login.login(env.user, env.password);
  return api;
}
