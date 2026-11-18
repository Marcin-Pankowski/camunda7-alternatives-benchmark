// Smoke test: requests go through Traefik (the load balancer), exactly like the engine benchmarks will.
import http from 'k6/http';
import { check } from 'k6';

const LB = __ENV.LB || 'http://traefik.kube-system.svc.cluster.local';
const HOST = __ENV.HOST || 'whoami.bench.local';

export const options = {
  vus: 10,
  duration: '20s',
  thresholds: { http_req_failed: ['rate<0.01'], checks: ['rate>0.99'] },
};

export default function () {
  const res = http.get(`${LB}/`, { headers: { Host: HOST } });
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function teardown() {
  const seen = new Set();
  for (let i = 0; i < 20; i++) {
    const m = http.get(`${LB}/`, { headers: { Host: HOST } }).body.match(/^Hostname: (.+)$/m);
    if (m) seen.add(m[1]);
  }
  console.log(`backends seen behind the load balancer: ${[...seen].join(', ')}`);
  if (seen.size < 2) throw new Error('load balancer did not spread requests over both pods');
}
