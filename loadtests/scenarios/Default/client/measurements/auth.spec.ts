import { test, expect } from '@playwright/test';
import { loginByForm, BACKOFFICE_PATH } from '../lib/auth';

test('loginByForm authenticates and lands in the backoffice', async ({ page }) => {
  const ms = await loginByForm(page);
  expect(ms).toBeGreaterThan(0);
  // After login we are inside the backoffice section shell.
  await expect(page).toHaveURL(new RegExp(`${BACKOFFICE_PATH}`));
});
