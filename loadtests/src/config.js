export const config = {
  baseUrl: `https://${__ENV.hostName || 'localhost'}`,
  username: __ENV.username || 'admin@admin.admin',
  password: __ENV.password || '1234567890',
  clientId: 'umbraco-back-office',
  apiBase: '/umbraco/management/api/v1',
};

config.redirectUri = `${config.baseUrl}/umbraco/oauth_complete`;
