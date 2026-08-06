#!/usr/bin/env bash
# Installs everything the lab needs on top of a running EKS cluster:
#
#   1. AWS Load Balancer Controller  (ALB provisioning + weighted target groups)
#   2. Argo Rollouts                 (the controller that shifts the weights)
#   3. Argo CD                       (GitOps delivery for both the Kustomize and Helm paths)
#   4. kube-prometheus-stack         (the metrics the canary analysis queries)
#
# Every step is idempotent. Re-running is safe.
set -euo pipefail

CLUSTER="${CLUSTER:-cfg-lab-eks}"
REGION="${REGION:-eu-west-1}"

# Chart versions, with the app version each one ships. Verified 2026-08-06.
LBC_CHART="${LBC_CHART:-3.5.0}"             # app v3.5.0
LBC_APP="${LBC_APP:-3.5.0}"                 # tag used for the IAM policy document
ROLLOUTS_CHART="${ROLLOUTS_CHART:-2.41.1}"  # app v1.9.1
ARGOCD_CHART="${ARGOCD_CHART:-10.3.0}"      # app v3.5.0
KPS_CHART="${KPS_CHART:-88.1.5}"            # prometheus-operator v0.93.0

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------------------
say "kubeconfig for ${CLUSTER}"
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" >/dev/null
kubectl get nodes

# ------------------------------------------------------------------------------
say "IAM for the AWS Load Balancer Controller (EKS Pod Identity)"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/CFGLabAWSLoadBalancerControllerPolicy"
if ! aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  curl -fsSL -o /tmp/lbc-policy.json \
    "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${LBC_APP}/docs/install/iam_policy.json"
  aws iam create-policy \
    --policy-name CFGLabAWSLoadBalancerControllerPolicy \
    --policy-document file:///tmp/lbc-policy.json >/dev/null
fi

# Pod Identity trust policy: the EKS service principal, not an OIDC federation.
# This is the mechanism that replaced IRSA for new clusters.
cat >/tmp/pod-identity-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
JSON

ensure_role() {
  local role="$1" policy="$2"
  aws iam get-role --role-name "${role}" >/dev/null 2>&1 || \
    aws iam create-role --role-name "${role}" \
      --assume-role-policy-document file:///tmp/pod-identity-trust.json >/dev/null
  aws iam attach-role-policy --role-name "${role}" --policy-arn "${policy}" >/dev/null
}

ensure_association() {
  local ns="$1" sa="$2" role="$3"
  local existing
  existing="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER}" \
    --region "${REGION}" --namespace "${ns}" --service-account "${sa}" \
    --query 'associations[0].associationId' --output text 2>/dev/null || echo None)"
  if [ "${existing}" = "None" ]; then
    aws eks create-pod-identity-association --cluster-name "${CLUSTER}" \
      --region "${REGION}" --namespace "${ns}" --service-account "${sa}" \
      --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${role}" >/dev/null
  fi
}

ensure_role CFGLabLBCRole "${POLICY_ARN}"
ensure_association kube-system aws-load-balancer-controller CFGLabLBCRole

# Argo Rollouts needs its own read-only ELB permissions for --aws-verify-target-group,
# which makes the controller confirm a weight change actually landed in AWS before
# it advances to the next canary step.
ROLLOUTS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/CFGLabRolloutsELBReadPolicy"
if ! aws iam get-policy --policy-arn "${ROLLOUTS_POLICY_ARN}" >/dev/null 2>&1; then
  cat >/tmp/rollouts-elb-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTags"
    ],
    "Resource": "*"
  }]
}
JSON
  aws iam create-policy --policy-name CFGLabRolloutsELBReadPolicy \
    --policy-document file:///tmp/rollouts-elb-policy.json >/dev/null
fi
ensure_role CFGLabRolloutsRole "${ROLLOUTS_POLICY_ARN}"
ensure_association argo-rollouts argo-rollouts CFGLabRolloutsRole

# ------------------------------------------------------------------------------
say "Helm repositories"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# ------------------------------------------------------------------------------
say "AWS Load Balancer Controller (chart ${LBC_CHART}, app v${LBC_APP})"

# Managed nodegroups ship with an IMDS hop limit of 1, so a pod on the pod
# network cannot reach instance metadata. Left to discover its own VPC the
# controller crashloops with:
#
#   unable to initialize AWS cloud ... failed to fetch VPC ID from instance
#   metadata ... context deadline exceeded
#
# Passing region and vpcId explicitly removes the IMDS dependency entirely.
# Raising the nodegroup hop limit to 2 also works, but this is the smaller change.
VPC_ID="${VPC_ID:-$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)}"
echo "vpcId=${VPC_ID}"

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${LBC_CHART}" \
  --set clusterName="${CLUSTER}" \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m

# ------------------------------------------------------------------------------
say "Argo Rollouts (chart ${ROLLOUTS_CHART}, app v1.9.1)"
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts --create-namespace \
  --version "${ROLLOUTS_CHART}" \
  --set dashboard.enabled=true \
  --set controller.awsVerifyTargetGroup=true \
  --wait --timeout 5m

# ------------------------------------------------------------------------------
say "Argo CD (chart ${ARGOCD_CHART}, app v3.5.0)"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "${ARGOCD_CHART}" \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 8m

# ------------------------------------------------------------------------------
say "kube-prometheus-stack (chart ${KPS_CHART})"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version "${KPS_CHART}" \
  -f "$(dirname "$0")/kube-prometheus-stack.values.yaml" \
  --wait --timeout 10m

# ------------------------------------------------------------------------------
say "Namespaces, image pull secret, load-test script"
for ns in demo demo-control loadtest; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

if [ -n "${GHCR_TOKEN:-}" ]; then
  for ns in demo demo-control; do
    kubectl create secret docker-registry ghcr \
      --docker-server=ghcr.io \
      --docker-username="${GHCR_USER:-c4geeks}" \
      --docker-password="${GHCR_TOKEN}" \
      --namespace "${ns}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
else
  echo "GHCR_TOKEN not set; skipping pull secret (fine if the package is public)"
fi

kubectl create configmap k6-script \
  --from-file="$(dirname "$0")/../loadtest/script.js" \
  --namespace loadtest --dry-run=client -o yaml | kubectl apply -f - >/dev/null

say "Platform ready"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded || true
