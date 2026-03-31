import { check, sleep } from 'k6';
import { createClient } from '../helpers/http-client.js';

/**
 * Scenario: Save Complex Document Type
 * Fetches a document type with many properties and re-saves it.
 * Simulates a backoffice user editing document type definitions.
 */
export function saveDocumentType(config) {
  const client = createClient(config.baseUrl, config.apiBase);

  // Fetch document type tree root
  const rootRes = client.get(
    '/tree/document-type/root?skip=0&take=100&foldersOnly=false',
    { name: 'doctype_tree_root' }
  );

  const rootOk = check(rootRes, {
    'doctype root: status 200': (r) => r.status === 200,
  });

  if (!rootOk || !rootRes.body) {
    return;
  }

  const rootItems = JSON.parse(rootRes.body).items;
  if (!rootItems || rootItems.length === 0) {
    console.warn('save-document-type: no document types found');
    return;
  }

  // Pick the first non-folder document type
  const target = rootItems.find((item) => !item.isFolder);
  if (!target) {
    console.warn('save-document-type: no non-folder document types found');
    return;
  }

  // Fetch the full document type definition
  const docTypeRes = client.get(`/document-type/${target.id}`, {
    name: 'doctype_get',
  });

  const docTypeOk = check(docTypeRes, {
    'doctype get: status 200': (r) => r.status === 200,
  });

  if (!docTypeOk || !docTypeRes.body) {
    return;
  }

  const docType = JSON.parse(docTypeRes.body);

  // Re-save the document type (simulates editing)
  const saveRes = client.put(`/document-type/${target.id}`, docType, {
    name: 'doctype_save',
  });

  check(saveRes, {
    'doctype save: status 200': (r) => r.status === 200,
  });

  sleep(1);
}
