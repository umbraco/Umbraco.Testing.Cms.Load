import { check, sleep } from 'k6';
import { createClient } from '../helpers/http-client.js';

/**
 * Scenario: Save and Publish
 * Fetches a content node, modifies a text property, saves, and publishes it.
 * Simulates a backoffice user editing and publishing content.
 */
export function saveAndPublish(config) {
  const client = createClient(config.baseUrl, config.apiBase);

  // Fetch root nodes to find a document to edit
  const rootRes = client.get('/tree/document/root?skip=0&take=100', {
    name: 'save_publish_tree_root',
  });

  const rootOk = check(rootRes, {
    'save-publish root: status 200': (r) => r.status === 200,
  });

  if (!rootOk || !rootRes.body) {
    return;
  }

  const rootItems = JSON.parse(rootRes.body).items;
  if (!rootItems || rootItems.length === 0) {
    console.warn('save-and-publish: no root documents found');
    return;
  }

  // Pick the first document (seeded data produces consistent content)
  const targetId = rootItems[0].id;

  // Fetch the full document
  const docRes = client.get(`/document/${targetId}`, {
    name: 'save_publish_get_document',
  });

  const docOk = check(docRes, {
    'save-publish get doc: status 200': (r) => r.status === 200,
  });

  if (!docOk || !docRes.body) {
    return;
  }

  const document = JSON.parse(docRes.body);

  // Save the document (re-submit with minor modification to simulate editing)
  const saveBody = {
    values: document.values,
    variants: document.variants,
    template: document.template,
  };

  const saveRes = client.put(`/document/${targetId}`, saveBody, {
    name: 'save_publish_save',
  });

  check(saveRes, {
    'save-publish save: status 200': (r) => r.status === 200,
  });

  // Publish the document (invariant, immediate)
  const publishRes = client.put(
    `/document/${targetId}/publish`,
    {
      publishSchedules: [
        {
          culture: null,
          schedule: null,
        },
      ],
    },
    { name: 'save_publish_publish' }
  );

  check(publishRes, {
    'save-publish publish: status 200': (r) => r.status === 200,
  });

  sleep(1);
}
