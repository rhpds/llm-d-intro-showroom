# llm-d Showroom Environment Validator

A bash script that validates whether a cluster is properly deployed for the llm-d intro showroom. Designed for Ops teams to run before a showroom session to confirm the environment is ready for students.

## Prerequisites

- `oc` CLI installed and available in your PATH
- `jq` installed
- `curl` installed
- Network access to the target OpenShift cluster API

## What It Checks

| # | Check | Details |
|---|-------|---------|
| 1 | Cluster authentication | Logs in and verifies the admin user |
| 2 | ArgoCD applications | All apps are Synced and Healthy |
| 3 | Namespace | `llm-d-project` exists |
| 4 | GPU nodes & NVIDIA config | GPU nodes present, capacity/allocatable counts, available (free) GPUs |
| 5 | NVIDIA GPU Operator | Operator CSV installed, device plugin running, driver daemonset, validator, NFD, GPU model & memory |
| 6 | ServingRuntime | `rhaiis-cuda` vLLM runtime exists |
| 7 | PVC & data | `benchmark-data` PVC is Bound, `prompts.csv` is present |
| 8 | llama-vllm-single | InferenceService is Ready with running pods |
| 9 | llama-vllm-scaled | InferenceService is Ready with 4 running pods |
| 10 | llama-llm-d | LLMInferenceService is Ready with 4 running pods |
| 11 | Load balancer | `llama-vllm-scaled-lb` ClusterIP service exists |
| 12 | Gateway infra | GatewayClass, Gateway, and gateway service exist |
| 13 | Grafana | Namespace, route, and UI accessibility |
| 14 | Model endpoints | Curl tests against `/v1/models` and `/v1/completions` — only runs if models are deployed |
| 15 | Benchmark jobs | `guidellm-*` jobs completed successfully |
| 16 | OpenShift AI | `redhat-ods-applications` namespace exists |

## Usage

```bash
cd solver-script

# Run with default cluster credentials
./validate-environment.sh

# Override cluster and credentials
API_SERVER=https://api.mycluster.example.com:6443 \
ADMIN_USER=admin \
ADMIN_PASS=mypassword \
./validate-environment.sh

# Override the target namespace
NAMESPACE=my-llm-project ./validate-environment.sh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_SERVER` | `https://api.cluster-f5bq9.f5bq9.sandbox5220.opentlc.com:6443` | OpenShift API server URL |
| `ADMIN_USER` | `admin` | Cluster admin username |
| `ADMIN_PASS` | `MTI0NzQz` | Cluster admin password |
| `NAMESPACE` | `llm-d-project` | Primary lab namespace |
| `GRAFANA_NS` | `grafana` | Grafana namespace |
| `INGRESS_NS` | `openshift-ingress` | Ingress namespace |

## Output

The script prints color-coded results for each check:

- **PASS** (green) — check succeeded
- **FAIL** (red) — something is missing or broken
- **WARN** (yellow) — resource not found but may be created during the lab

A summary at the end shows total pass/fail/warn counts. Exit codes:

| Code | Meaning |
|------|---------|
| 0 | All checks passed |
| 1 | Minor issues (1-3 failures) |
| 2 | Significant issues (4+ failures) |

## Cleanup

The script is **non-destructive**. Any temporary resources it creates (port-forwards, data-check pods) are automatically cleaned up on exit, whether the script completes normally or is interrupted with Ctrl+C.
