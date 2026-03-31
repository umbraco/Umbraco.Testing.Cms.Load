import { check, sleep } from 'k6';
import { createClient } from '../helpers/http-client.js';

/**
 * Scenario: Content Tree Browsing
 * Navigates and expands the document tree, simulating a backoffice user
 * browsing through content with large content volumes.
 */
export function contentTreeBrowse(config) {
  const client = createClient(config.baseUrl, config.apiBase);

  // Fetch root nodes
  const rootRes = client.get('/tree/document/root?skip=0&take=100', {
    name: 'tree_document_root',
  });

  const rootOk = check(rootRes, {
    'tree root: status 200': (r) => r.status === 200,
  });

  if (!rootOk || !rootRes.body) {
    console.warn(`tree root failed: status=${rootRes.status}`);
    return;
  }

  const rootData = JSON.parse(rootRes.body);
  const rootItems = rootData.items || [];

  check(rootRes, {
    'tree root: has items': () => rootItems.length > 0,
  });

  if (rootItems.length === 0) {
    return;
  }

  // Expand children of each root node that has children
  for (const item of rootItems) {
    if (!item.hasChildren) {
      continue;
    }

    const childrenRes = client.get(
      `/tree/document/children?parentId=${item.id}&skip=0&take=100`,
      { name: 'tree_document_children' }
    );

    check(childrenRes, {
      'tree children: status 200': (r) => r.status === 200,
    });

    if (childrenRes.status !== 200) {
      continue;
    }

    const children = JSON.parse(childrenRes.body).items || [];

    // Expand one more level deep for the first child with children
    for (const child of children) {
      if (!child.hasChildren) {
        continue;
      }

      const grandchildrenRes = client.get(
        `/tree/document/children?parentId=${child.id}&skip=0&take=100`,
        { name: 'tree_document_grandchildren' }
      );

      check(grandchildrenRes, {
        'tree grandchildren: status 200': (r) => r.status === 200,
      });

      // Only expand one grandchild level per root item
      break;
    }
  }

  sleep(1);
}
