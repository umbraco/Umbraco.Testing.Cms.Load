import { Page, errors as PwErrors } from '@playwright/test';
import { env } from './env';

export const BACKOFFICE_PATH = '/umbraco';

// Real login-form submit with stored credentials, timed. Returns ms from
// navigation start until the backoffice section shell is visible. Used as the
// first segment of time-to-first-edit and to produce a reusable storageState.
//
// Selectors verified live against Umbraco 17.5.0-rc (umb-auth web component):
//   - email field is name="username" (id username-input) — NOT name="email"
//   - password field is name="password" (id password-input)
//   - submit is button[type="submit"] (label "Login")
//   - "logged in" signal: umb-section-sidebar renders in the shell
export async function loginByForm(page: Page): Promise<number> {
  const start = performance.now();
  await page.goto(`${env.baseUrl}${BACKOFFICE_PATH}`);

  // An already-authenticated session redirects straight to the shell, so the
  // login form never appears. Only fill/submit when the username field shows up.
  const username = page.locator('input[name="username"]');
  // Treat ONLY a visibility timeout as "already authenticated, no form" — let any
  // other error (page crash, navigation failure) propagate instead of falling
  // through to a misleading 60s sidebar-wait timeout.
  const loginFormShown = await username.waitFor({ state: 'visible', timeout: 15_000 })
    .then(() => true, (e) => { if (e instanceof PwErrors.TimeoutError) return false; throw e; });
  if (loginFormShown) {
    await username.fill(env.user);
    await page.locator('input[name="password"]').fill(env.password);
    await page.locator('button[type="submit"]').click();
  }

  // Section sidebar is the reliable "logged in" content-visible signal.
  await page.locator('umb-section-sidebar').first()
    .waitFor({ state: 'visible', timeout: 60_000 });
  return performance.now() - start;
}

// Note: the load measurements (dashboard, home node) log in per rep via
// loginByForm and start their timing AFTER login returns, so the login
// round-trip is excluded from the measured window — the same isolation a
// pre-authenticated storageState would give, without a separate auth-state file.
