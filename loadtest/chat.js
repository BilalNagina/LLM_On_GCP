// k6 load test against the OpenAI-compatible llama.cpp endpoint.
// Env: TARGET (base URL), VUS, DURATION, MAX_TOKENS
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const failures = new Counter('failed_requests');
const byVersion = new Counter('served_by_version');

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 4),
      duration: __ENV.DURATION || '4m',
    },
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  // NO_REUSE=1: new TCP connection per request. With keep-alive, requests keep
  // reaching a terminating pod over existing connections after its endpoint
  // is removed (see docs/troubleshooting-log.md #8).
  noConnectionReuse: __ENV.NO_REUSE === '1',
};

const prompts = [
  'Explain Kubernetes readiness probes in one sentence.',
  'What is a GKE node pool? Answer briefly.',
  'Name two ways to reduce cloud compute cost.',
  'What does a load balancer health check do?',
];

export default function () {
  const body = JSON.stringify({
    messages: [{ role: 'user', content: prompts[Math.floor(Math.random() * prompts.length)] }],
    max_tokens: Number(__ENV.MAX_TOKENS || 48),
    temperature: 0.2,
  });
  const res = http.post(`${__ENV.TARGET}/v1/chat/completions`, body, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '120s',
  });
  const ok = check(res, { 'status is 200': (r) => r.status === 200 });
  if (!ok) {
    failures.add(1, { status: String(res.status), error: res.error_code ? String(res.error_code) : 'none' });
  } else {
    try { byVersion.add(1, { model: res.json('model') }); } catch (_) { /* ignore */ }
  }
}
