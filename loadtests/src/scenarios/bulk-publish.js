import { check, sleep } from 'k6';
import { createClient } from '../helpers/http-client.js';

/**
 * Scenario: Bulk Publish
 * Finds a parent content node with children and publishes the entire subtree.
 * Simulates a backoffice user performing bulk publish operations.
 */
export function bulkPublish(config) {
  const client = createClient(config.baseUrl, config.apiBase);

  // Fetch root nodes to find one with children
  const rootRes = client.get('/tree/document/root?skip=0&take=100', {
    name: 'bulk_publish_tree_root',
  });

  const rootOk = check(rootRes, {
    'bulk-publish root: status 200': (r) => r.status === 200,
  });

  if (!rootOk || !rootRes.body) {
    return;
  }

  const rootItems = JSON.parse(rootRes.body).items;
  if (!rootItems || rootItems.length === 0) {
    console.warn('bulk-publish: no root documents found');
    return;
  }

  // Find a node with children for bulk publish
  const parentNode = rootItems.find((item) => item.hasChildren) || rootItems[0];

  // Publish with descendants
  const publishRes = client.put(
    `/document/${parentNode.id}/publish-with-descendants`,
    {
      cultures: [],
      includeUnpublishedDescendants: true,
    },
    { name: 'bulk_publish_with_descendants' }
  );

  check(publishRes, {
    'bulk-publish: status 200': (r) => r.status === 200,
  });

  sleep(2);
}
