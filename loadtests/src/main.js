import { stages, thresholds } from './config.js';

export const options = {
    scenarios: {
        // Add your scenarios here
    },
    thresholds,
};

// Add your scenario functions here

import { htmlReport } from 'https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js';
import { jUnit, textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';

export function handleSummary(data) {
    return {
        [__ENV.K6_SUMMARY_EXPORT || 'k6-summary.html']: htmlReport(data),
        'k6-results.xml': jUnit(data),
        stdout: textSummary(data, { indent: ' ', enableColors: true }),
    };
}
