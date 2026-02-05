const host = __ENV.HOST_NAME || 'localhost';
const users = Number(__ENV.USERS) || 10;
const duration = __ENV.TEST_DURATION || '3m';

export const baseUrl = host.startsWith('http') ? host : `https://${host}`;
export const timeout = '30s';

export const stages = [
    { duration: '30s', target: users },
    { duration, target: users },
    { duration: '30s', target: 0 },
];

export const thresholds = {
    http_req_duration: ['p(95)<2000'],
    http_req_failed: ['rate<0.05'],
    checks: ['rate>0.95'],
};
