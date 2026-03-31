import { config } from './config.js';
import { authenticate } from './helpers/auth.js';
import { contentTreeBrowse } from './scenarios/content-tree-browse.js';
import { saveAndPublish } from './scenarios/save-and-publish.js';
import { saveDocumentType } from './scenarios/save-document-type.js';
import { bulkPublish } from './scenarios/bulk-publish.js';

const users = parseInt(__ENV.users || '10');
const duration = __ENV.duration || '3m';
const rampUp = __ENV.rampUp || '30s';

export const options = {
  insecureSkipTLSVerify: true,
  scenarios: {
    content_tree: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampUp, target: users },
        { duration: duration, target: users },
        { duration: '30s', target: 0 },
      ],
      exec: 'contentTreeScenario',
    },
    save_publish: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampUp, target: Math.ceil(users * 0.4) },
        { duration: duration, target: Math.ceil(users * 0.4) },
        { duration: '30s', target: 0 },
      ],
      exec: 'savePublishScenario',
    },
    save_document_type: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampUp, target: Math.ceil(users * 0.2) },
        { duration: duration, target: Math.ceil(users * 0.2) },
        { duration: '30s', target: 0 },
      ],
      exec: 'saveDocumentTypeScenario',
    },
    bulk_publish: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampUp, target: Math.ceil(users * 0.1) },
        { duration: duration, target: Math.ceil(users * 0.1) },
        { duration: '30s', target: 0 },
      ],
      exec: 'bulkPublishScenario',
    },
  },
  thresholds: {
    // Overall thresholds (generous initial values — tighten after baseline runs)
    http_req_duration: ['p(95)<3000'],
    http_req_failed: ['rate<0.05'],
    checks: ['rate>0.95'],
    // Per-scenario thresholds
    'http_req_duration{name:tree_document_root}': ['p(95)<2000'],
    'http_req_duration{name:tree_document_children}': ['p(95)<2000'],
    'http_req_duration{name:save_publish_save}': ['p(95)<5000'],
    'http_req_duration{name:save_publish_publish}': ['p(95)<5000'],
    'http_req_duration{name:bulk_publish_with_descendants}': ['p(95)<10000'],
  },
};

// Per-VU auth state — each VU authenticates once on first iteration.
// Auth sets cookies in k6's per-VU cookie jar (Umbraco v17+ uses
// HTTP-only cookie-based token storage, not Bearer tokens).
const authDone = {};

function ensureAuth() {
  if (!authDone[__VU]) {
    authDone[__VU] = authenticate(config);
  }
  return authDone[__VU];
}

export function contentTreeScenario() {
  if (ensureAuth()) {
    contentTreeBrowse(config);
  }
}

export function savePublishScenario() {
  if (ensureAuth()) {
    saveAndPublish(config);
  }
}

export function saveDocumentTypeScenario() {
  if (ensureAuth()) {
    saveDocumentType(config);
  }
}

export function bulkPublishScenario() {
  if (ensureAuth()) {
    bulkPublish(config);
  }
}
