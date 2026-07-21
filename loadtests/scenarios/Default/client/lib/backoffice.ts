import { Page, errors as PwErrors } from '@playwright/test';
import { env } from './env';

// TipTap rich-text editor root (verified on 17.5.0-rc).
export const TIPTAP = 'umb-input-tiptap .tiptap, umb-input-tiptap .ProseMirror';
// Content section root (renders the tree with the Homepage root node).
export const CONTENT_URL = `${env.baseUrl}/umbraco/section/content`;

// The Homepage tree node, scoped to the sidebar so it can't drift onto a
// same-named workspace/breadcrumb element.
export function homepageTreeItem(page: Page, homepageName: string) {
  return page.locator(`umb-section-sidebar uui-menu-item[label="${homepageName}"]`).first();
}

// Wait for the Homepage tree node with an actionable error if it's missing.
export async function waitForHomepageNode(page: Page, homepageName: string): Promise<void> {
  try {
    await homepageTreeItem(page, homepageName).waitFor({ state: 'visible', timeout: 60_000 });
  } catch (e) {
    if (e instanceof PwErrors.TimeoutError) {
      throw new Error(`Homepage tree node not found in the content tree — did the content model build (globalSetup) run on this instance?`);
    }
    throw e;
  }
}
