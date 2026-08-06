#!/usr/bin/env python3
"""Turn the raw experiment artifacts into the two tables the article publishes:

  1. blast radius   how many requests each version actually served, per experiment
  2. ALB lag        how long a weight change took to become live in AWS

Reads results/<exp>/{k6-summary.json,weights.csv,timing.json}.
"""
import csv
import json
import os
import statistics
import sys

RESULTS = sys.argv[1] if len(sys.argv) > 1 else "results"


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def blast_radius():
    rows = []
    for exp in sorted(os.listdir(RESULTS)):
        summary = load(os.path.join(RESULTS, exp, "k6-summary.json"))
        timing = load(os.path.join(RESULTS, exp, "timing.json")) or {}
        if not summary:
            continue
        bad = next((v for v in summary["by_version"] if v["version"] == "v3"), None)
        rows.append({
            "experiment": exp,
            "total": summary["total_responses"],
            "failures": summary["total_failures"],
            "failure_pct": summary["failure_pct"],
            "bad_version_responses": bad["responses"] if bad else 0,
            "bad_version_failures": bad["failures"] if bad else 0,
            "p95_ms": summary["http_req_duration_p95_ms"],
            "settle_s": timing.get("settle_seconds"),
        })
    return rows


def alb_lag():
    """For each weight change, the seconds between the Ingress annotation
    carrying the new weight and the ALB listener rule actually serving it.

    Input is the long-format log the sampler writes: ts,source,weight.
    """
    out = {}
    for exp in sorted(os.listdir(RESULTS)):
        path = os.path.join(RESULTS, exp, "weights.csv")
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            rows = list(csv.DictReader(fh))

        if not rows:
            continue
        # The sampler's own first read of each source is initial state, not a
        # change. Anything in the opening seconds of the log is discarded or the
        # poll interval itself gets reported as ALB latency.
        log_start = min(float(r["ts"]) for r in rows)
        rows = [r for r in rows if float(r["ts"]) > log_start + 5]

        first = {}   # (source, weight) -> earliest timestamp
        for r in rows:
            key = (r["source"], r["weight"])
            ts = float(r["ts"])
            if key not in first or ts < first[key]:
                first[key] = ts

        lags = []
        for (source, weight), ts in first.items():
            if source != "ingress":
                continue
            alb_ts = first.get(("alb", weight))
            # Only count changes where we saw the annotation move first; the
            # very first sample of each source is just initial state.
            if alb_ts and alb_ts > ts:
                lags.append((int(weight), round(alb_ts - ts, 1)))

        if lags:
            lags.sort()
            values = [v for _, v in lags]
            out[exp] = {
                "changes": len(values),
                "min": min(values),
                "median": round(statistics.median(values), 1),
                "max": max(values),
                "all": lags,
            }
    return out


def table(rows, cols, headers):
    widths = [max(len(h), *(len(str(r.get(c, ""))) for r in rows)) for c, h in zip(cols, headers)]
    line = "  ".join(h.ljust(w) for h, w in zip(headers, widths))
    print(line)
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(str(r.get(c, "")).ljust(w) for c, w in zip(cols, widths)))


def main():
    rows = blast_radius()
    if rows:
        print("\nBLAST RADIUS\n")
        table(rows,
              ["experiment", "total", "failures", "failure_pct",
               "bad_version_responses", "bad_version_failures", "p95_ms", "settle_s"],
              ["exp", "requests", "failed", "fail%",
               "v3 served", "v3 failed", "p95ms", "settle s"])

    lag = alb_lag()
    if lag:
        print("\nALB WEIGHT PROPAGATION (seconds from Ingress annotation to live rule)\n")
        table([{"exp": k, **{kk: vv for kk, vv in v.items() if kk != "all"}}
               for k, v in lag.items()],
              ["exp", "changes", "min", "median", "max"],
              ["exp", "changes", "min", "median", "max"])
        for k, v in lag.items():
            print(f"\n  {k} individual lags: {v['all']}")
    print()


if __name__ == "__main__":
    main()
