// Scenario B: start a process with one business rule task (100-rule pricing table, COLLECT + SUM) via REST and wait
// for the result. Every request gets random inputs; the expected fee is computed from the same rules the DMN was
// generated from (load/scenario-b-rules.json, see load/gen-pricing-dmn.py), so a wrong evaluation counts as failed.
// Timing as in scenario A: 60 s warm-up, then 60 s measured at the same number of VUs.
import http from 'k6/http';
import { check } from 'k6';

const LB = __ENV.LB || 'http://traefik.kube-system.svc.cluster.local';
const ENGINE = __ENV.ENGINE;
const VUS = Number(__ENV.VUS || 10);
const WARMUP_S = 60;
const MEASURE_S = 60;
const RULES = JSON.parse(open('./scenario-b-rules.json'));
const COUNTRIES = ['DE', 'AT', 'CH', 'FR', 'NL'];
const TYPES = ['standard', 'premium', 'business', 'student'];

const pick = (a) => a[Math.floor(Math.random() * a.length)];
const between = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));
const inRange = (r, v) => r === null || (r[0] <= v && v <= r[1]);
const expectedFee = (i) => RULES
  .filter((r) => inRange(r.age, i.age) && inRange(r.amount, i.amount)
    && (r.country === null || r.country === i.country) && (r.customerType === null || r.customerType === i.customerType))
  .reduce((s, r) => s + r.fee, 0);

// One request shape per engine; each must return only after the process has ended. Numbers are compared with ==
// after Number(): engines return the sum as integer, long or decimal.
const c7 = (i, fee) => ({
  url: `${LB}/engine-rest/process-definition/key/ScenarioB/start`,
  body: JSON.stringify({
    variables: {
      age: { value: i.age, type: 'Integer' }, amount: { value: i.amount, type: 'Integer' },
      country: { value: i.country, type: 'String' }, customerType: { value: i.customerType, type: 'String' },
    },
    withVariablesInReturn: true,
  }),
  ok: (r) => r.status === 200 && Number(r.json('variables.fee.value')) === fee,
});
const kogito = (i, fee) => ({
  url: `${LB}/ScenarioB`,
  body: JSON.stringify(i),
  ok: (r) => r.status === 201 && Number(r.json('fee')) === fee,
});
const flowable = (i, fee) => ({
  url: `${LB}/process-api/runtime/process-instances`,
  body: JSON.stringify({
    processDefinitionKey: 'ScenarioB', returnVariables: true,
    variables: [{ name: 'age', type: 'integer', value: i.age }, { name: 'amount', type: 'integer', value: i.amount },
      { name: 'country', type: 'string', value: i.country }, { name: 'customerType', type: 'string', value: i.customerType }],
  }),
  ok: (r) => r.status === 201 && (r.json('variables') || []).some((v) => v.name === 'fee' && Number(v.value) === fee),
});
const camunda8 = (i, fee) => ({
  url: `${LB}/v2/process-instances`,
  body: JSON.stringify({ processDefinitionId: 'ScenarioB', variables: i, awaitCompletion: true }),
  ok: (r) => r.status === 200 && Number(r.json('variables.fee')) === fee,
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
  const i = { age: between(18, 99), amount: between(0, 100000), country: pick(COUNTRIES), customerType: pick(TYPES) };
  const r = req(i, expectedFee(i));
  const res = http.post(r.url, r.body, { headers: { Host: `${ENGINE}.bench.local`, 'Content-Type': 'application/json' } });
  check(res, { 'fee correct': r.ok });
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
