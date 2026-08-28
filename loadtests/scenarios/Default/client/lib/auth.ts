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
  const sidebar = page.locator('umb-section-sidebar').first();

  // Wait for whichever appears first, rather than guessing "already
  // authenticated" from a short timeout on the login field alone: under the
  // load this harness itself generates, a genuinely-showing login form can take
  // longer than a short guess-timeout to render, which previously got
  // misclassified as "already authenticated" and masked as a 60s sidebar-wait
  // failure with no hint of the real cause.
  try {
    await username.or(sidebar).first().waitFor({ state: 'visible', timeout: 60_000 });
  } catch (e) {
    if (e instanceof PwErrors.TimeoutError) {
      throw new Error('Neither the login form nor the backoffice sidebar appeared within 60s - the app may be down or unresponsive.');
    }
    throw e;
  }

  if (await username.isVisible()) {
    await username.fill(env.user);
    await page.locator('input[name="password"]').fill(env.password);
    await page.locator('button[type="submit"]').click();
    try {
      await sidebar.waitFor({ state: 'visible', timeout: 60_000 });
    } catch (e) {
      if (e instanceof PwErrors.TimeoutError) {
        throw new Error('Login form was submitted but the backoffice sidebar never appeared - check credentials/seeded member state or the auth backend.');
      }
      throw e;
    }
  }

  return performance.now() - start;
}
