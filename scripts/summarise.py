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
    carrying the new weight and the ALB listener rule serving it."""
    out = {}
    for exp in sorted(os.listdir(RESULTS)):
        path = os.path.join(RESULTS, exp, "weights.csv")
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            samples = [r for r in csv.DictReader(fh)]

        lags, pending = [], {}
        for r in samples:
            ts = float(r["ts"])
            ing = r["ingress"]
            alb = r["alb"]
            if ing and ing not in pending and ing != alb:
                pending[ing] = ts                      # annotation moved first
            if alb and alb in pending:
                lags.append(round(ts - pending.pop(alb), 1))

        if lags:
            out[exp] = {
                "changes": len(lags),
                "min": min(lags),
                "median": round(statistics.median(lags), 1),
                "max": max(lags),
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
