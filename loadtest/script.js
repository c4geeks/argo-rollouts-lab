// Steady-rate load against the lab ALB while a release rolls out.
//
// Every response carries X-Demo-Version, so this counts from the CLIENT side
// how many requests each version actually served. That is the blast-radius
// number: it does not depend on Prometheus, the analysis, or the controller
// being honest about what happened.
//
//   TARGET   http://<alb-dns-name>
//   HOST     Host header to send (demo.example.com or control.example.com)
//   RPS      requests per second (default 50)
//   DURATION test length (default 10m)

import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const responses = new Counter('responses_by_version');
const failures = new Counter('failures_by_version');
const byStatus = new Counter('failures_by_status');

const VERSIONS = ['v1', 'v2', 'v3', 'unknown'];
// 0 is a transport-level failure (connection reset), which is what an ALB
// deregistering a target looks like from the client. Distinguishing it from a
// real application 500 is the difference between blaming the release and
// blaming the load balancer.
const STATUSES = ['0', '500', '502', '503', '504'];

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RPS || 50),
      timeUnit: '1s',
      duration: __ENV.DURATION || '10m',
      preAllocatedVUs: 40,
      maxVUs: 300,
    },
  },
  // k6 only surfaces a tagged sub-metric in the summary if a threshold names it.
  // These are deliberately trivial: they exist to force the per-version
  // breakdown into the JSON summary, not to pass or fail the run.
  thresholds: Object.fromEntries(
    VERSIONS.flatMap((v) => [
      [`responses_by_version{version:${v}}`, ['count>=0']],
      [`failures_by_version{version:${v}}`, ['count>=0']],
    ]).concat(STATUSES.map((c) => [`failures_by_status{code:${c}}`, ['count>=0']]))
  ),
};

export default function () {
  const res = http.get(`${__ENV.TARGET}/api/color`, {
    headers: { Host: __ENV.HOST },
    tags: { name: 'api_color' },
  });

  const version = res.headers['X-Demo-Version'] || 'unknown';
  responses.add(1, { version });
  if (res.status === 0 || res.status >= 500) {
    failures.add(1, { version });
    byStatus.add(1, { code: String(res.status) });
  }

  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const pick = (metric, value, tag = 'version') => {
    const m = data.metrics[`${metric}{${tag}:${value}}`];
    return m && m.values ? m.values.count || 0 : 0;
  };

  const rows = VERSIONS.map((v) => ({
    version: v,
    responses: pick('responses_by_version', v),
    failures: pick('failures_by_version', v),
  })).filter((r) => r.responses > 0 || r.failures > 0);

  const total = rows.reduce((a, r) => a + r.responses, 0);
  const totalFailures = rows.reduce((a, r) => a + r.failures, 0);

  const report = {
    target_host: __ENV.HOST,
    rps: Number(__ENV.RPS || 50),
    duration: __ENV.DURATION || '10m',
    total_responses: total,
    total_failures: totalFailures,
    failure_pct: total ? Number(((totalFailures / total) * 100).toFixed(3)) : 0,
    by_version: rows.map((r) => ({
      ...r,
      share_pct: total ? Number(((r.responses / total) * 100).toFixed(2)) : 0,
    })),
    http_req_duration_p95_ms: Number(
      (data.metrics.http_req_duration?.values?.['p(95)'] || 0).toFixed(1)
    ),
    failures_by_status: Object.fromEntries(
      STATUSES.map((c) => [c, pick('failures_by_status', c, 'code')]).filter(([, n]) => n > 0)
    ),
  };

  const lines = [
    '',
    `total responses     ${report.total_responses}`,
    `total failures      ${report.total_failures} (${report.failure_pct}%)`,
    `p95 latency         ${report.http_req_duration_p95_ms} ms`,
    '',
    'version   responses   share     failures',
  ];
  for (const r of report.by_version) {
    lines.push(
      `${r.version.padEnd(9)} ${String(r.responses).padStart(9)}   ` +
        `${String(r.share_pct).padStart(6)}%   ${String(r.failures).padStart(8)}`
    );
  }
  lines.push('');

  lines.push('---SUMMARY-JSON-BEGIN---');
  lines.push(JSON.stringify(report));
  lines.push('---SUMMARY-JSON-END---');
  lines.push('');

  return {
    stdout: lines.join('\n'),
    '/results/summary.json': JSON.stringify(report, null, 2),
  };
}
