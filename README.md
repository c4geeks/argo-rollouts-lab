# Argo Rollouts progressive-delivery lab

Companion repo for **[Argo Rollouts canary deployments on Kubernetes](https://computingforgeeks.com/argo-rollouts-canary-progressive-delivery/)**
on ComputingForGeeks.

Most Argo Rollouts walkthroughs stop at `kubectl argo rollouts promote`. This one
puts a sustained load test through three releases on a real EKS cluster behind a
real ALB and measures what actually happened:

- how long an ALB takes to serve a weight change after Argo Rollouts writes it
- how many requests a bad release serves before the analysis aborts it
- how many requests that same bad release serves with a plain `Deployment`

Everything here is what was run to produce the numbers in the article.

## What is in the box

| Path | What it is |
|---|---|
| `app/` | The demo service. Renders its version as a colour tile, exports Prometheus metrics, and takes `ERROR_RATE` / `LATENCY_MS` so a "bad build" is reproducible |
| `manifests/base/` | **Way 1** — the Rollout as plain Kustomize |
| `charts/rollouts-demo/` | **Way 2** — the same Rollout as a Helm chart, canary shape driven from `values.yaml` |
| `manifests/control/` | The control group: identical app, plain `Deployment`, no analysis |
| `manifests/analysis/` | The Prometheus success-rate gate |
| `gitops/` | Argo CD `Application` for each delivery path |
| `platform/` | One idempotent script that installs the whole platform |
| `loadtest/` | k6 script and Job. Counts responses per version from the client side |
| `scripts/` | The measurement harness and the summariser |
| `dashboards/` | Grafana dashboard used for the article screenshots |
| `infra/` | The exact Terragrunt config used to create the cluster |

## Versions this was run against

| Component | Version |
|---|---|
| EKS / Kubernetes | 1.36 |
| Argo Rollouts | v1.9.1 (chart 2.41.1) |
| Argo CD | v3.5.0 (chart 10.3.0) |
| AWS Load Balancer Controller | v3.5.0 (chart 3.5.0) |
| kube-prometheus-stack | chart 88.1.5 |
| k6 | 2.1.0 |

## Run it

```bash
# 1. Cluster (EKS 1.36, 3x t3.large, eu-west-1)
make cluster

# 2. Platform: LB controller, Argo Rollouts, Argo CD, Prometheus, Grafana
make platform

# 3. The application, both delivery paths
make deploy            # Way 1, Kustomize
make deploy-control    # the control group
make dashboards

# 4. Experiments
make e1    # healthy canary v1 -> v2
make e2    # bad canary v2 -> v3, expect an automatic rollback
make e3    # same bad image, plain Deployment, nothing stops it

# 5. The tables
make results
```

Then tear it down. An idle cluster with a NAT gateway and an ALB still bills:

```bash
make destroy
```

## The image

`ghcr.io/c4geeks/rollouts-demo` is built for `linux/amd64` with the version,
colour and fault settings baked in at build time, so "v3 is broken" is a property
of the image rather than something the manifest toggles:

| Tag | Colour | Injected error rate |
|---|---|---|
| `v1` | blue | 0% |
| `v2` | green | 0% |
| `v3` | red | 10% |

Rebuild them yourself with `make -C app push`.

## Licence

MIT.
