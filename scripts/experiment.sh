#!/usr/bin/env bash
# Runs one experiment end to end and leaves every artifact under results/<id>/.
#
#   e1  healthy canary v1 -> v2, analysis passes, rollout completes
#   e2  bad canary v2 -> v3 (10% 5xx), analysis fails, controller rolls back
#   e3  control: the same bad image through a plain Deployment RollingUpdate
#
# All three run the identical k6 profile against the identical ALB, which is the
# only reason the numbers can be compared at the end.
set -euo pipefail

EXP="${1:?usage: experiment.sh e1|e2|e3}"
REGION="${REGION:-eu-west-1}"
IMAGE="${IMAGE:-ghcr.io/c4geeks/rollouts-demo}"
RPS="${RPS:-50}"
DURATION="${DURATION:-8m}"
OUT="results/${EXP}"
K6_VERSION="${K6_VERSION:-2.1.0}"

mkdir -p "${OUT}"
cd "$(dirname "$0")/.."

alb_host() {
  kubectl get ingress -n demo rollouts-demo \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
}

start_load() {
  local host="$1" job="k6-${EXP}"
  kubectl delete job -n loadtest "${job}" --ignore-not-found >/dev/null 2>&1
  JOB_NAME="${job}" \
  TARGET="http://$(alb_host)" \
  HOST="${host}" \
  RPS="${RPS}" DURATION="${DURATION}" K6_VERSION="${K6_VERSION}" \
    envsubst < loadtest/job.yaml | kubectl apply -f - >/dev/null
  kubectl wait --for=condition=ready pod -l job-name="${job}" -n loadtest --timeout=120s >/dev/null
  echo "${job}"
}

collect_load() {
  local job="$1"
  echo "waiting for k6 to finish..."
  kubectl wait --for=condition=complete job/"${job}" -n loadtest --timeout=20m >/dev/null
  kubectl logs -n loadtest job/"${job}" --tail=-1 > "${OUT}/k6.log"
  local pod
  pod="$(kubectl get pod -n loadtest -l job-name="${job}" -o jsonpath='{.items[0].metadata.name}')"
  kubectl cp -n loadtest "${pod}:/results/summary.json" "${OUT}/k6-summary.json" 2>/dev/null || true
}

banner() { printf '\n\033[1;33m### %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------------------
case "${EXP}" in
e1|e2)
  if [ "${EXP}" = "e1" ]; then
    FROM=v1; TO=v2; EXPECT="rollout completes"
  else
    FROM=v2; TO=v3; EXPECT="analysis fails and the rollout aborts"
  fi

  banner "${EXP}: ${FROM} -> ${TO} (expect: ${EXPECT})"

  # Make sure we start from a fully promoted FROM version.
  kubectl argo rollouts set image rollouts-demo -n demo "demo=${IMAGE}:${FROM}" >/dev/null
  kubectl argo rollouts status rollouts-demo -n demo --timeout 10m >/dev/null
  echo "baseline ${FROM} is stable"

  JOB="$(start_load demo.example.com)"
  echo "load running at ${RPS} rps for ${DURATION}"
  sleep 30   # let the ALB settle and Prometheus collect a baseline

  python3 scripts/watch-weights.py "${OUT}/weights.csv" --region "${REGION}" &
  WATCHER=$!
  trap 'kill ${WATCHER} 2>/dev/null || true' EXIT

  START="$(date -u +%s)"
  kubectl argo rollouts set image rollouts-demo -n demo "demo=${IMAGE}:${TO}" >/dev/null
  echo "promoted image to ${TO} at $(date -u +%H:%M:%S)"

  # Record the controller's own view of what happened, as it happens.
  ( kubectl argo rollouts get rollout rollouts-demo -n demo --watch --timeout-seconds 900 \
      > "${OUT}/rollout-watch.log" 2>&1 || true ) &
  WATCH_PID=$!

  set +e
  kubectl argo rollouts status rollouts-demo -n demo --timeout 12m > "${OUT}/final-status.txt" 2>&1
  STATUS_RC=$?
  set -e
  END="$(date -u +%s)"
  kill ${WATCH_PID} ${WATCHER} 2>/dev/null || true

  echo "rollout settled after $((END-START))s (status rc=${STATUS_RC})"
  kubectl argo rollouts get rollout rollouts-demo -n demo > "${OUT}/rollout-final.txt" 2>&1 || true
  kubectl get analysisrun -n demo -o yaml > "${OUT}/analysisruns.yaml" 2>&1 || true
  kubectl describe rollout rollouts-demo -n demo > "${OUT}/rollout-events.txt" 2>&1 || true
  echo "{\"experiment\":\"${EXP}\",\"from\":\"${FROM}\",\"to\":\"${TO}\",\"start\":${START},\"end\":${END},\"settle_seconds\":$((END-START)),\"status_rc\":${STATUS_RC}}" \
    > "${OUT}/timing.json"

  collect_load "${JOB}"
  ;;

e3)
  banner "e3 control: plain Deployment v1 -> v3 (nothing is watching)"

  kubectl set image deployment/control-demo -n demo-control "demo=${IMAGE}:v1" >/dev/null
  kubectl rollout status deployment/control-demo -n demo-control --timeout=5m >/dev/null
  echo "baseline v1 is stable"

  JOB="$(start_load control.example.com)"
  echo "load running at ${RPS} rps for ${DURATION}"
  sleep 30

  START="$(date -u +%s)"
  kubectl set image deployment/control-demo -n demo-control "demo=${IMAGE}:v3" >/dev/null
  echo "promoted image to v3 at $(date -u +%H:%M:%S)"
  kubectl rollout status deployment/control-demo -n demo-control --timeout=10m \
    > "${OUT}/final-status.txt" 2>&1 || true
  END="$(date -u +%s)"

  kubectl get deployment control-demo -n demo-control -o yaml > "${OUT}/deployment-final.yaml"
  echo "{\"experiment\":\"e3\",\"from\":\"v1\",\"to\":\"v3\",\"start\":${START},\"end\":${END},\"settle_seconds\":$((END-START))}" \
    > "${OUT}/timing.json"

  collect_load "${JOB}"
  ;;

*)
  echo "unknown experiment: ${EXP}" >&2
  exit 1
  ;;
esac

banner "${EXP} complete - artifacts in ${OUT}/"
ls -1 "${OUT}"
