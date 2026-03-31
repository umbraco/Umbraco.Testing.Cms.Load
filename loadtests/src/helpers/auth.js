import http from 'k6/http';
import { check, sleep } from 'k6';
import { generateCodeChallenge } from './pkce.js';

const CODE_VERIFIER = '12345';
const STATE_VALUE = 'k6LoadTestState';
const AUTH_TIMEOUT = '120s';
const MAX_RETRIES = 3;

/**
 * Authenticates against the Umbraco backoffice using the OAuth2 PKCE flow.
 * Mirrors the 3-step flow in Umbraco's LoginApiHelper.ts:
 *   1. POST /login — establish session cookies
 *   2. GET /authorize — get PKCE cookie (authorization code stored in cookie)
 *   3. POST /token — exchange for access_token
 *
 * Includes per-VU staggered delay and retry logic to avoid overwhelming
 * the server with concurrent token creation (EF Core concurrency on OpenIddict).
 *
 * Returns the access_token string for use in Bearer auth headers.
 */
export function authenticate(config) {
  // Stagger auth requests: each VU waits (VU_number * 2) seconds
  // to avoid thundering herd on the token endpoint
  sleep(__VU * 2);

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    const token = tryAuthenticate(config);
    if (token) {
      return token;
    }
    console.warn(`Auth attempt ${attempt}/${MAX_RETRIES} failed for VU ${__VU}, retrying...`);
    sleep(3 * attempt);
  }

  console.error(`Auth failed after ${MAX_RETRIES} attempts for VU ${__VU}`);
  return null;
}

function tryAuthenticate(config) {
  const authBase = `${config.baseUrl}${config.apiBase}/security/back-office`;

  // Step 1: Login to get session cookies
  const loginRes = http.post(
    `${authBase}/login`,
    JSON.stringify({
      username: config.username,
      password: config.password,
    }),
    {
      headers: {
        'Content-Type': 'application/json',
        Referer: config.baseUrl,
        Origin: config.baseUrl,
      },
      tags: { name: 'auth_login' },
      timeout: AUTH_TIMEOUT,
    }
  );

  const loginOk = check(loginRes, {
    'login: status 200': (r) => r.status === 200,
  });

  if (!loginOk) {
    console.error(`Login failed: status=${loginRes.status} body=${loginRes.body}`);
    return null;
  }

  // Step 2: Authorize to get the PKCE cookie
  const codeChallenge = generateCodeChallenge(CODE_VERIFIER);
  const authorizeUrl =
    `${authBase}/authorize?` +
    `client_id=${config.clientId}` +
    `&response_type=code` +
    `&redirect_uri=${encodeURIComponent(config.redirectUri)}` +
    `&code_challenge_method=S256` +
    `&code_challenge=${codeChallenge}` +
    `&state=${STATE_VALUE}` +
    `&scope=offline_access` +
    `&prompt=consent` +
    `&access_type=offline`;

  const authorizeRes = http.get(authorizeUrl, {
    headers: {
      Referer: config.baseUrl,
    },
    redirects: 0,
    tags: { name: 'auth_authorize' },
    timeout: AUTH_TIMEOUT,
  });

  check(authorizeRes, {
    'authorize: status 302': (r) => r.status === 302,
  });

  // Extract __Host-umbPkceCode cookie from Set-Cookie header
  const setCookie = authorizeRes.headers['Set-Cookie'] || '';
  const pkceMatch = setCookie.match(/__Host-umbPkceCode=[A-Za-z0-9_-]+;/);
  const pkceCookie = pkceMatch ? pkceMatch[0] : '';

  // Step 3: Exchange code for tokens
  // The code value is literally '[redacted]' — the real authorization code
  // is in the __Host-umbPkceCode cookie (Umbraco v17+ secure cookie storage)
  const tokenRes = http.post(
    `${authBase}/token`,
    `grant_type=authorization_code` +
      `&client_id=${config.clientId}` +
      `&redirect_uri=${encodeURIComponent(config.redirectUri)}` +
      `&code=${encodeURIComponent('[redacted]')}` +
      `&code_verifier=${CODE_VERIFIER}`,
    {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Cookie: pkceCookie + setCookie,
        Origin: config.baseUrl,
      },
      tags: { name: 'auth_token' },
      timeout: AUTH_TIMEOUT,
    }
  );

  const tokenOk = check(tokenRes, {
    'token: status 200': (r) => r.status === 200,
  });

  if (!tokenOk) {
    console.error(`Token exchange failed: status=${tokenRes.status} body=${tokenRes.body}`);
    return null;
  }

  // Auth tokens are stored in HTTP-only cookies by Umbraco v17+.
  // k6's cookie jar now holds the auth cookies for subsequent requests.
  return true;
}
