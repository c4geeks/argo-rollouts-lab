#!/usr/bin/env python3
"""Measure how long an ALB takes to actually serve a canary weight change.

A weight exists in three places:

  desired    what the Rollout controller has decided
  ingress    what it has written into the ALB action annotation (Kubernetes side)
  alb        what is live on the ALB listener rule (AWS side)

The number worth publishing is ingress -> alb: how long real traffic keeps
following the old split after Argo Rollouts believes it has moved on.

Each source is polled on its own thread with its own timestamp. Sampling them
sequentially in one loop does not work: a single `aws elbv2 describe-rules` call
takes about a second, so by the time the ALB is read the annotation may already
have changed, and the measured lag comes out jittered or even negative.

Output is append-only, one row per observed change:  ts,source,weight

Usage: watch-weights.py OUTPUT.csv [--namespace demo] [--region eu-west-1]
"""
import argparse
import json
import subprocess
import sys
import threading
import time


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout.strip()


def sh_json(*cmd):
    out = sh(*cmd)
    try:
        return json.loads(out) if out else None
    except json.JSONDecodeError:
        return None


class Recorder:
    """Append-only log of (timestamp, source, weight), one row per change."""

    def __init__(self, path):
        self.fh = open(path, "w", buffering=1)
        self.fh.write("ts,source,weight\n")
        self.last = {}
        self.lock = threading.Lock()
        self.stop = threading.Event()

    def record(self, source, weight):
        if weight is None:
            return
        with self.lock:
            if self.last.get(source) != weight:
                self.last[source] = weight
                self.fh.write(f"{time.time():.3f},{source},{weight}\n")


def poll_desired(rec, ns, rollout):
    while not rec.stop.is_set():
        out = sh("kubectl", "get", "rollout", rollout, "-n", ns,
                 "-o", "jsonpath={.status.canary.weights.canary.weight}")
        rec.record("desired", int(out) if out.isdigit() else None)
        time.sleep(0.4)


def poll_ingress(rec, ns, ingress, root_service):
    key = ("jsonpath={.metadata.annotations.alb\\.ingress\\.kubernetes\\.io/"
           f"actions\\.{root_service}}}")
    while not rec.stop.is_set():
        ann = sh("kubectl", "get", "ingress", ingress, "-n", ns, "-o", key)
        weight = None
        if ann:
            try:
                for g in json.loads(ann)["ForwardConfig"]["TargetGroups"]:
                    if str(g.get("ServiceName", "")).endswith("-canary"):
                        weight = int(g.get("Weight", 0))
            except (json.JSONDecodeError, KeyError):
                pass
        rec.record("ingress", weight)
        time.sleep(0.4)


def target_group_map(ns):
    data = sh_json("kubectl", "get", "targetgroupbindings", "-n", ns, "-o", "json")
    out = {}
    for item in (data or {}).get("items", []):
        arn = item.get("spec", {}).get("targetGroupARN")
        svc = item.get("spec", {}).get("serviceRef", {}).get("name")
        if arn and svc:
            out[arn] = svc
    return out


def poll_alb(rec, ns, region, listener_arn):
    tg_map = target_group_map(ns)
    i = 0
    while not rec.stop.is_set():
        # Target groups are recreated as the rollout progresses.
        if i % 20 == 0:
            fresh = target_group_map(ns)
            if fresh:
                tg_map = fresh
        i += 1

        rules = sh_json("aws", "elbv2", "describe-rules", "--region", region,
                        "--listener-arn", listener_arn)
        weight = None
        for rule in (rules or {}).get("Rules", []):
            for action in rule.get("Actions", []):
                groups = action.get("ForwardConfig", {}).get("TargetGroups", [])
                if len(groups) < 2:
                    continue
                for g in groups:
                    if tg_map.get(g.get("TargetGroupArn"), "").endswith("-canary"):
                        weight = int(g.get("Weight", 0))
        rec.record("alb", weight)


def resolve_listener(region, name_contains):
    lbs = sh_json("aws", "elbv2", "describe-load-balancers", "--region", region)
    for lb in (lbs or {}).get("LoadBalancers", []):
        if name_contains in lb.get("LoadBalancerName", ""):
            listeners = sh_json("aws", "elbv2", "describe-listeners", "--region", region,
                                "--load-balancer-arn", lb["LoadBalancerArn"])
            if listeners and listeners.get("Listeners"):
                return listeners["Listeners"][0]["ListenerArn"]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output")
    ap.add_argument("--namespace", default="demo")
    ap.add_argument("--rollout", default="rollouts-demo")
    ap.add_argument("--ingress", default="rollouts-demo")
    ap.add_argument("--root-service", default="rollouts-demo-root")
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--lb-name-contains", default="cfglab")
    args = ap.parse_args()

    listener = resolve_listener(args.region, args.lb_name_contains)
    if not listener:
        print("could not resolve ALB listener", file=sys.stderr)
        sys.exit(1)
    print(f"listener {listener.split('/')[-1]}", file=sys.stderr)

    rec = Recorder(args.output)
    for target, extra in (
        (poll_desired, (rec, args.namespace, args.rollout)),
        (poll_ingress, (rec, args.namespace, args.ingress, args.root_service)),
        (poll_alb, (rec, args.namespace, args.region, listener)),
    ):
        threading.Thread(target=target, args=extra, daemon=True).start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        rec.stop.set()


if __name__ == "__main__":
    main()
