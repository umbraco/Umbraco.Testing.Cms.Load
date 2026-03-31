import http from 'k6/http';

/**
 * Creates an authenticated HTTP client that relies on k6's cookie jar.
 *
 * Umbraco v17+ stores auth tokens in HTTP-only cookies (not Bearer tokens).
 * After the PKCE auth flow, the cookies are automatically stored in k6's
 * per-VU cookie jar and sent with subsequent requests.
 */
export function createClient(baseUrl, apiBase) {
  const apiUrl = `${baseUrl}${apiBase}`;

  function headers() {
    return {
      'Content-Type': 'application/json',
      Accept: 'application/json',
    };
  }

  return {
    get(path, tags) {
      return http.get(`${apiUrl}${path}`, {
        headers: headers(),
        tags,
      });
    },

    put(path, body, tags) {
      return http.put(`${apiUrl}${path}`, JSON.stringify(body), {
        headers: headers(),
        tags,
      });
    },

    post(path, body, tags) {
      return http.post(`${apiUrl}${path}`, JSON.stringify(body), {
        headers: headers(),
        tags,
      });
    },
  };
}
