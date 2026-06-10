import { Page } from '@playwright/test';
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
  if (await username.waitFor({ state: 'visible', timeout: 15_000 }).then(() => true, () => false)) {
    await username.fill(env.user);
    await page.fill('input[name="password"]', env.password);
    await page.click('button[type="submit"]');
  }

  // Section sidebar is the reliable "logged in" content-visible signal.
  await page.locator('umb-section-sidebar').first()
    .waitFor({ state: 'visible', timeout: 60_000 });
  return performance.now() - start;
}

// Save an authenticated storageState to disk for the load measurements (which
// must not pay the login cost on every rep).
export async function saveAuthState(page: Page, path: string): Promise<void> {
  await loginByForm(page);
  await page.context().storageState({ path });
}
