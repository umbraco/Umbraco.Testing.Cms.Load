import { Page, errors as PwErrors } from '@playwright/test';
import { env } from './env';

export const BACKOFFICE_PATH = '/umbraco';

// Real login-form submit with stored credentials, timed. Returns ms from
// navigation start until the section shell is visible. The username field is
// name="username" (NOT name="email").
export async function loginByForm(page: Page): Promise<number> {
  const start = performance.now();
  await page.goto(`${env.baseUrl}${BACKOFFICE_PATH}`);

  // An already-authenticated session redirects straight to the shell, so the
  // login form never appears. Only fill/submit when the username field shows up.
  const username = page.locator('input[name="username"]');
  // Treat ONLY a visibility timeout as "already authenticated, skip form"; let
  // any other error propagate instead of masking it as a 60s sidebar-wait.
  const loginFormShown = await username.waitFor({ state: 'visible', timeout: 15_000 })
    .then(() => true, (e) => { if (e instanceof PwErrors.TimeoutError) return false; throw e; });
  if (loginFormShown) {
    await username.fill(env.user);
    await page.locator('input[name="password"]').fill(env.password);
    await page.locator('button[type="submit"]').click();
  }

  await page.locator('umb-section-sidebar').first()
    .waitFor({ state: 'visible', timeout: 60_000 });
  return performance.now() - start;
}
