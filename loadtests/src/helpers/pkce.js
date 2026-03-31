import crypto from 'k6/crypto';
import encoding from 'k6/encoding';

/**
 * Generates a PKCE code challenge from a code verifier.
 * Uses SHA-256 hash with base64 encoding (padding stripped).
 * Matches the Umbraco acceptance test implementation in LoginApiHelper.ts.
 */
export function generateCodeChallenge(codeVerifier) {
  const hash = crypto.sha256(codeVerifier, 'binary');
  return encoding.b64encode(hash, 'rawstd').replace(/=/g, '');
}
