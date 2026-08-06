#!/usr/bin/env python3
"""Sample, once a second, the three places a canary weight exists:

  desired    what the Rollout controller has decided the canary weight is
  ingress    what it has written into the ALB action annotation
  alb        what is actually live on the ALB listener rule in AWS

desired -> ingress is Kubernetes-side and effectively instant. ingress -> alb is
the AWS reconcile, and that gap is the number worth publishing: it is how long
real traffic keeps following the old split after Argo Rollouts believes it has
moved on.

Usage: watch-weights.py OUTPUT.csv [--namespace demo] [--rollout rollouts-demo]
"""
import argparse
import json
import subprocess
import sys
import time


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout.strip()


def sh_json(*cmd):
    out = sh(*cmd)
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def desired_weight(ns, rollout):
    out = sh("kubectl", "get", "rollout", rollout, "-n", ns, "-o",
             "jsonpath={.status.canary.weights.canary.weight}")
    return int(out) if out.isdigit() else None


def ingress_weight(ns, ingress, root_service):
    ann = sh("kubectl", "get", "ingress", ingress, "-n", ns, "-o",
             f"jsonpath={{.metadata.annotations.alb\\.ingress\\.kubernetes\\.io/actions\\.{root_service}}}")
    if not ann:
        return None
    try:
        groups = json.loads(ann)["ForwardConfig"]["TargetGroups"]
    except (json.JSONDecodeError, KeyError):
        return None
    for g in groups:
        if str(g.get("ServiceName", "")).endswith("-canary"):
            return int(g.get("Weight", 0))
    return 0


def resolve_target_groups(ns, region):
    """Map target-group ARN -> service name, via the TargetGroupBinding CRs the
    load balancer controller creates."""
    data = sh_json("kubectl", "get", "targetgroupbindings", "-n", ns, "-o", "json")
    mapping = {}
    if data:
        for item in data.get("items", []):
            spec = item.get("spec", {})
            arn = spec.get("targetGroupARN")
            svc = spec.get("serviceRef", {}).get("name")
            if arn and svc:
                mapping[arn] = svc
    return mapping


def resolve_listener(region, name_contains):
    lbs = sh_json("aws", "elbv2", "describe-load-balancers", "--region", region)
    if not lbs:
        return None
    for lb in lbs.get("LoadBalancers", []):
        if name_contains in lb.get("LoadBalancerName", ""):
            listeners = sh_json("aws", "elbv2", "describe-listeners", "--region", region,
                                "--load-balancer-arn", lb["LoadBalancerArn"])
            if listeners and listeners.get("Listeners"):
                return listeners["Listeners"][0]["ListenerArn"]
    return None


def alb_weight(region, listener_arn, tg_to_service):
    rules = sh_json("aws", "elbv2", "describe-rules", "--region", region,
                    "--listener-arn", listener_arn)
    if not rules:
        return None
    for rule in rules.get("Rules", []):
        for action in rule.get("Actions", []):
            groups = action.get("ForwardConfig", {}).get("TargetGroups", [])
            if len(groups) < 2:
                continue
            for g in groups:
                svc = tg_to_service.get(g.get("TargetGroupArn"), "")
                if svc.endswith("-canary"):
                    return int(g.get("Weight", 0))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output")
    ap.add_argument("--namespace", default="demo")
    ap.add_argument("--rollout", default="rollouts-demo")
    ap.add_argument("--ingress", default="rollouts-demo")
    ap.add_argument("--root-service", default="rollouts-demo-root")
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--lb-name-contains", default="cfg-lab")
    args = ap.parse_args()

    listener = resolve_listener(args.region, args.lb_name_contains)
    if not listener:
        print("could not resolve ALB listener", file=sys.stderr)
        sys.exit(1)

    tg_map = resolve_target_groups(args.namespace, args.region)
    print(f"listener {listener.split('/')[-1]}  target-groups {len(tg_map)}", file=sys.stderr)

    with open(args.output, "w", buffering=1) as fh:
        fh.write("ts,desired,ingress,alb\n")
        refresh = 0
        while True:
            # Target groups are recreated as the rollout progresses; re-resolve
            # periodically or the ALB column goes blank mid-run.
            if refresh % 15 == 0:
                new_map = resolve_target_groups(args.namespace, args.region)
                if new_map:
                    tg_map = new_map
            refresh += 1

            ts = time.time()
            d = desired_weight(args.namespace, args.rollout)
            i = ingress_weight(args.namespace, args.ingress, args.root_service)
            a = alb_weight(args.region, listener, tg_map)
            fh.write(f"{ts:.3f},{'' if d is None else d},"
                     f"{'' if i is None else i},{'' if a is None else a}\n")
            time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
