import http from 'k6/http';
import {check} from 'k6';
import {sleep} from 'k6';

let host = __ENV.HOST_NAME;

if (!host.startsWith('http')) {
    host = `https://${host}`;
}
export let options = {
    vus: Number(__ENV.USERS) || 10, // Virtual users
    stages: [
        {duration: '150s', target: Number(__ENV.USERS) || 10}, // ramp-up
        {duration: '150s', target: Number(__ENV.USERS) || 10}, // steady state
    ],
};

// List of URLs to test
const urls = [
    '/',
    '/blog/',
    '/about/',
    '/blog/popular-blogs/',
];

export default function () {
    // Loop through each URL and make a GET request
    urls.forEach((url) => {
        let res = http.get(host + url);
        check(res, {[`${url} loaded`]: (r) => r.status === 200});
    });

    // Sleep between iterations
    sleep(1);
}
