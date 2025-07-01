import http from 'k6/http';
import {check, sleep} from 'k6';
import {htmlReport} from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";
import {jUnit, textSummary} from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';



// Environment Configuration
const { HOST_NAME, USERS, K6_SUMMARY_EXPORT } = __ENV;


let host = HOST_NAME;

if (!host.startsWith('http')) {
    host = `https://${host}`;
}
export let options = {
    vus: Number(USERS) || 10,
    stages: [
        {duration: '2s', target: Number(USERS) || 10},
        {duration: '2s', target: Number(USERS) || 10},
    ],
};

const summaryExport = K6_SUMMARY_EXPORT || "k6-summary.html";

const urls = [
    '/',
    '/blog/',
    '/about/',
    '/blog/popular-blogs/',
];

export default function () {
    urls.forEach((url) => {
        let res = http.get(host + url);
        check(res, {[`${url} loaded`]: (r) => r.status === 200});
    });
    sleep(1);
}

export function handleSummary(data) {
    return {
        [summaryExport]: htmlReport(data),
        'k6-results.xml': jUnit(data),
        stdout: textSummary(data, {indent: ' ', enableColors: true})
    };
}