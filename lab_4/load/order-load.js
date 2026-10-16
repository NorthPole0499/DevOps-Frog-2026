import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://api:8080';
const PEAK = Number(__ENV.PEAK_RPS || 20);
const STEP = Number(__ENV.STEP_MINUTES || 6);
const RAMP = '2m';

function profile(name) {
  const quarter = Math.max(1, Math.round(PEAK / 4));
  const half = Math.max(1, Math.round(PEAK / 2));
  const profiles = {
    probe: [
      { target: PEAK, duration: `${STEP}m` },
    ],
    day: [
      { target: quarter, duration: RAMP },
      { target: quarter, duration: `${STEP}m` },
      { target: half, duration: RAMP },
      { target: half, duration: `${STEP}m` },
      { target: PEAK, duration: RAMP },
      { target: PEAK, duration: `${STEP * 2}m` },
      { target: quarter, duration: RAMP },
      { target: quarter, duration: `${STEP}m` },
    ],
    steady: [
      { target: PEAK, duration: RAMP },
      { target: PEAK, duration: `${STEP}m` },
    ],
  };
  if (!profiles[name]) {
    throw new Error(`unknown PROFILE ${name}`);
  }
  return profiles[name];
}

export const options = {
  discardResponseBodies: true,
  scenarios: {
    orders: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 200,
      stages: profile(__ENV.PROFILE || 'day'),
    },
  },
  thresholds: {
    'http_req_failed': ['rate<0.01'],
    'http_req_duration{name:order}': ['p(95)<300'],
  },
};

export default function () {
  const order = http.post(`${BASE}/order`, JSON.stringify({ item: 'k6' }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'order' },
  });
  check(order, { 'order created': (r) => r.status === 201 });
  const list = http.get(`${BASE}/orders?limit=20`, { tags: { name: 'orders' } });
  check(list, { 'orders listed': (r) => r.status === 200 });
}
