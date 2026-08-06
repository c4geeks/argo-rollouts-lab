# Argo Rollouts progressive-delivery lab
#
#   make cluster        create the EKS cluster (eksctl)
#   make platform       install LB controller, Argo Rollouts, Argo CD, Prometheus
#   make deploy         apply the Kustomize path
#   make deploy-helm    apply the Helm path
#   make e1|e2|e3       run an experiment end to end
#   make load           fire a k6 run at the lab ALB
#   make destroy        delete the cluster
SHELL := /usr/bin/env bash

CLUSTER   ?= cfg-lab-eks
REGION    ?= eu-west-1
IMAGE     ?= ghcr.io/c4geeks/rollouts-demo
K6_VERSION?= 2.1.0
RPS       ?= 50
DURATION  ?= 10m
RESULTS   ?= results

export CLUSTER REGION

.DEFAULT_GOAL := help
.PHONY: help cluster platform deploy deploy-helm deploy-control gitops load \
        e1 e2 e3 watch alb results dashboards destroy

help:  ## Show this help
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z0-9_-]+:.*?## /{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

cluster:  ## Create the VPC and EKS cluster (terragrunt)
	cd infra/live/vpc && terragrunt apply -auto-approve
	cd infra/live/eks && terragrunt apply -auto-approve
	aws eks update-kubeconfig --name $(CLUSTER) --region $(REGION)

platform:  ## Install the platform stack
	./platform/install.sh

deploy:  ## WAY 1 - Kustomize
	kubectl apply -k manifests/base

deploy-helm:  ## WAY 2 - Helm
	helm upgrade --install rollouts-demo charts/rollouts-demo --namespace demo --create-namespace

deploy-control:  ## E3 control group (plain Deployment)
	kubectl apply -k manifests/control

gitops:  ## Hand both paths to Argo CD
	kubectl apply -f gitops/

alb:  ## Print the lab ALB hostname
	@kubectl get ingress -n demo rollouts-demo \
	  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

watch:  ## Follow the rollout
	kubectl argo rollouts get rollout rollouts-demo -n demo --watch

# ------------------------------------------------------------------------------
# Load generation
# ------------------------------------------------------------------------------
load:  ## Run k6. Override HOST=control.example.com for the control group
	@test -n "$$(kubectl get ingress -n demo rollouts-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')" \
	  || { echo "ALB not provisioned yet"; exit 1; }
	@JOB_NAME=$${JOB_NAME:-k6-$$(date +%H%M%S)} \
	 TARGET=http://$$(kubectl get ingress -n demo rollouts-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') \
	 HOST=$${HOST:-demo.example.com} \
	 RPS=$(RPS) DURATION=$(DURATION) K6_VERSION=$(K6_VERSION) \
	 envsubst < loadtest/job.yaml | kubectl apply -f -

# ------------------------------------------------------------------------------
# Experiments
# ------------------------------------------------------------------------------
e1:  ## Healthy canary v1 -> v2 under load
	./scripts/experiment.sh e1

e2:  ## Bad canary v2 -> v3, expect automatic rollback
	./scripts/experiment.sh e2

e3:  ## Control: same bad image via a plain Deployment
	./scripts/experiment.sh e3

results:  ## Summarise captured runs
	@./scripts/summarise.sh

dashboards:  ## Load the Grafana dashboard
	kubectl create configmap rollouts-dashboard \
	  --from-file=dashboards/rollouts.json -n monitoring \
	  --dry-run=client -o yaml | \
	  kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -

destroy:  ## Delete the cluster. Ingresses go first or the ALB outlives the VPC
	kubectl delete ingress --all -A --ignore-not-found --timeout=120s || true
	@echo "waiting for the load balancer controller to release the ALB..."
	sleep 45
	cd infra/live/eks && terragrunt destroy -auto-approve
	cd infra/live/vpc && terragrunt destroy -auto-approve
