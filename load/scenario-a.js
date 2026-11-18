// Scenario A: start the process via REST through Traefik and wait for the result (synchronous end-to-end).
// One run = one load level: 60 s warm-up (JIT of freshly started JVMs), then 60 s measured at the same number of VUs.
import http from 'k6/http';
import { check } from 'k6';

const LB = __ENV.LB || 'http://traefik.kube-system.svc.cluster.local';
const ENGINE = __ENV.ENGINE;
const VUS = Number(__ENV.VUS || 10);
const WARMUP_S = 60;
const MEASURE_S = 60;

// One request shape per engine; each must return only after the process has ended.
// Camunda-7 REST API, shared by the C7 forks.
const c7 = () => ({
  url: `${LB}/engine-rest/process-definition/key/ScenarioA/start`,
  body: JSON.stringify({ variables: { counter: { value: 0, type: 'Integer' } }, withVariablesInReturn: true }),
  ok: (r) => r.status === 200 && r.json('variables.counter.value') === 3,
});
// Kogito generates POST /<processId>; the response carries the variables once the process has ended.
const kogito = () => ({
  url: `${LB}/ScenarioA`,
  body: JSON.stringify({ counter: 0 }),
  ok: (r) => r.status === 201 && r.json('counter') === 3,
});
// Flowable REST: returnVariables gives the variables of the (already ended) instance.
const flowable = () => ({
  url: `${LB}/process-api/runtime/process-instances`,
  body: JSON.stringify({ processDefinitionKey: 'ScenarioA', variables: [{ name: 'counter', type: 'integer', value: 0 }], returnVariables: true }),
  ok: (r) => r.status === 201 && (r.json('variables') || []).some((v) => v.name === 'counter' && v.value === 3),
});
// Camunda 8 REST v2: awaitCompletion returns the variables once the instance has completed.
const camunda8 = () => ({
  url: `${LB}/v2/process-instances`,
  body: JSON.stringify({ processDefinitionId: 'ScenarioA', variables: { counter: 0 }, awaitCompletion: true }),
  ok: (r) => r.status === 200 && r.json('variables.counter') === 3,
});
const REQUESTS = { cibseven: c7, operaton: c7, flowable, camunda8 };
const req = REQUESTS[ENGINE] || (ENGINE && ENGINE.startsWith('kogito-') ? kogito : undefined);  // all Kogito variants share the API
if (!req) throw new Error(`unknown ENGINE ${ENGINE}`);

const M = '{phase:measure}';
export const options = {
  scenarios: {
    warmup: { executor: 'constant-vus', vus: VUS, duration: `${WARMUP_S}s`, tags: { phase: 'warmup' } },
    measure: { executor: 'constant-vus', vus: VUS, duration: `${MEASURE_S}s`, startTime: `${WARMUP_S}s`, tags: { phase: 'measure' } },
  },
  // Always-true thresholds only make k6 report the measure-phase submetrics in the summary.
  thresholds: { [`http_req_duration${M}`]: ['p(95)>=0'], [`http_reqs${M}`]: ['count>=0'], [`checks${M}`]: ['rate>=0'] },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const r = req();
  const res = http.post(r.url, r.body, { headers: { Host: `${ENGINE}.bench.local`, 'Content-Type': 'application/json' } });
  check(res, { 'process completed': r.ok });
}

export function handleSummary(data) {
  const d = data.metrics[`http_req_duration${M}`].values;
  const out = {
    engine: ENGINE, vus: VUS,
    throughput: +(data.metrics[`http_reqs${M}`].values.count / MEASURE_S).toFixed(1),
    p50_ms: +d.med.toFixed(1), p95_ms: +d['p(95)'].toFixed(1), p99_ms: +d['p(99)'].toFixed(1),
    ok_rate: data.metrics[`checks${M}`].values.rate,
  };
  return { stdout: `RESULT ${JSON.stringify(out)}\n` };
}
