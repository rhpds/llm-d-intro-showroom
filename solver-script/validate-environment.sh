#!/usr/bin/env bash
#
# llm-d Showroom Environment Validator
# Validates that the cluster is properly deployed for showroom instructions.
# NON-DESTRUCTIVE: all temporary resources are cleaned up on exit.
#

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
API_SERVER="${API_SERVER:-https://api.cluster-f5bq9.f5bq9.sandbox5220.opentlc.com:6443}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-MTI0NzQz}"
NAMESPACE="${NAMESPACE:-llm-d-project}"
GRAFANA_NS="${GRAFANA_NS:-grafana}"
INGRESS_NS="${INGRESS_NS:-openshift-ingress}"
MODEL_NAME="llama-3-1-8b-instruct-fp8"

PASS=0
FAIL=0
WARN=0
CLEANUP_PIDS=()
CLEANUP_PODS=()

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo -e "${BLUE}[CLEANUP]${NC} Reversing temporary changes..."

    for pid in "${CLEANUP_PIDS[@]+"${CLEANUP_PIDS[@]}"}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            echo -e "  Killed port-forward (PID $pid)"
        fi
    done

    for pod in "${CLEANUP_PODS[@]+"${CLEANUP_PODS[@]}"}"; do
        if oc get pod "$pod" -n "$NAMESPACE" &>/dev/null; then
            oc delete pod "$pod" -n "$NAMESPACE" --grace-period=0 --force &>/dev/null || true
            echo -e "  Deleted temp pod $pod"
        fi
    done

    echo -e "${BLUE}[CLEANUP]${NC} Done. No residual resources left."
}
trap cleanup EXIT

# ─── Helpers ─────────────────────────────────────────────────────────────────
pass() { ((PASS++)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗ FAIL${NC}: $1"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}⚠ WARN${NC}: $1"; }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }

wait_for_port() {
    local port=$1 retries=10
    for ((i=0; i<retries; i++)); do
        if curl -s --connect-timeout 1 "http://localhost:$port" &>/dev/null || \
           curl -s --connect-timeout 1 "http://localhost:$port/v1/models" &>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ─── Login ───────────────────────────────────────────────────────────────────
section "1. Cluster Authentication"

if oc login "$API_SERVER" -u "$ADMIN_USER" -p "$ADMIN_PASS" --insecure-skip-tls-verify=true &>/dev/null; then
    pass "Logged in to cluster as $ADMIN_USER"
else
    fail "Cannot log in to cluster at $API_SERVER"
    echo -e "${RED}Cannot proceed without cluster access. Exiting.${NC}"
    exit 1
fi

WHOAMI=$(oc whoami 2>/dev/null || echo "unknown")
if [[ "$WHOAMI" == "$ADMIN_USER" ]]; then
    pass "Authenticated user is $ADMIN_USER"
else
    fail "Expected user $ADMIN_USER but got $WHOAMI"
fi

# ─── ArgoCD Application Sync ────────────────────────────────────────────────
section "2. ArgoCD Applications"

if oc get crd applications.argoproj.io &>/dev/null; then
    pass "ArgoCD CRD exists on the cluster"
else
    fail "ArgoCD CRD not found — ArgoCD may not be installed"
fi

ARGOCD_NS=$(oc get applications.argoproj.io --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
if [[ -z "$ARGOCD_NS" ]]; then
    ARGOCD_NS="openshift-gitops"
fi

ARGO_APPS=$(oc get applications.argoproj.io -n "$ARGOCD_NS" -o json 2>/dev/null || echo '{"items":[]}')
APP_COUNT=$(echo "$ARGO_APPS" | jq '.items | length')

if [[ "$APP_COUNT" -gt 0 ]]; then
    pass "Found $APP_COUNT ArgoCD application(s) in namespace $ARGOCD_NS"
else
    warn "No ArgoCD applications found in $ARGOCD_NS — checking all namespaces"
    ARGO_APPS=$(oc get applications.argoproj.io --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
    APP_COUNT=$(echo "$ARGO_APPS" | jq '.items | length')
    if [[ "$APP_COUNT" -gt 0 ]]; then
        pass "Found $APP_COUNT ArgoCD application(s) across all namespaces"
    else
        fail "No ArgoCD applications found on cluster"
    fi
fi

while IFS='|' read -r name sync health; do
    if [[ "$name" == "openshift-ai" ]]; then
        # openshift-ai has known drift: Subscription shows UpgradePending (3.3.0
        # pending approval while 3.2.0 is pinned) and Notebook env vars are
        # injected by the controller. Validate the actual deployed state instead.
        RHODS_CSV_PHASE=$(oc get csv rhods-operator.3.2.0 -n redhat-ods-operator -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [[ "$RHODS_CSV_PHASE" == "Succeeded" ]]; then
            pass "ArgoCD app '$name' — rhods-operator.3.2.0 CSV is Succeeded (sync=$sync ignored, known drift)"
        else
            fail "ArgoCD app '$name' — rhods-operator.3.2.0 CSV phase: $RHODS_CSV_PHASE (expected Succeeded)"
        fi

        NB_READY=$(oc get notebook benchmark-analysis -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "$NB_READY" -ge 1 ]]; then
            pass "ArgoCD app '$name' — Notebook 'benchmark-analysis' is running (OutOfSync ignored, controller-injected env vars)"
        else
            fail "ArgoCD app '$name' — Notebook 'benchmark-analysis' is not ready (readyReplicas=$NB_READY)"
        fi
    elif [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
        pass "ArgoCD app '$name' — Synced & Healthy"
    elif [[ "$sync" == "Synced" ]]; then
        warn "ArgoCD app '$name' — Synced but health=$health"
    else
        fail "ArgoCD app '$name' — sync=$sync, health=$health"
    fi
done < <(echo "$ARGO_APPS" | jq -r '.items[] | "\(.metadata.name)|\(.status.sync.status // "Unknown")|\(.status.health.status // "Unknown")"' 2>/dev/null)

# ─── Namespace ───────────────────────────────────────────────────────────────
section "3. Namespace & Project"

if oc get namespace "$NAMESPACE" &>/dev/null; then
    pass "Namespace '$NAMESPACE' exists"
else
    fail "Namespace '$NAMESPACE' does not exist"
fi

oc project "$NAMESPACE" &>/dev/null 2>&1 || true

# ─── GPU Nodes & NVIDIA Stack ────────────────────────────────────────────────
section "4. GPU Nodes & NVIDIA Configuration"

GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | wc -l | tr -d ' ')
if [[ "$GPU_NODES" -gt 0 ]]; then
    pass "Found $GPU_NODES GPU node(s) with nvidia.com/gpu.present=true"
else
    fail "No GPU nodes found with label nvidia.com/gpu.present=true"
fi

REQUIRED_GPUS=4
TOTAL_GPU_CAPACITY=0
TOTAL_GPU_ALLOCATABLE=0

while IFS='|' read -r node_name capacity allocatable; do
    [[ -z "$node_name" ]] && continue
    TOTAL_GPU_CAPACITY=$((TOTAL_GPU_CAPACITY + capacity))
    TOTAL_GPU_ALLOCATABLE=$((TOTAL_GPU_ALLOCATABLE + allocatable))
    if [[ "$allocatable" -ge 1 ]]; then
        pass "Node '$node_name' — $allocatable GPU(s) allocatable, $capacity capacity"
    else
        fail "Node '$node_name' — 0 GPUs allocatable ($capacity capacity)"
    fi
done < <(oc get nodes -l nvidia.com/gpu.present=true -o json 2>/dev/null | \
    jq -r '.items[] | "\(.metadata.name)|\(.status.capacity["nvidia.com/gpu"] // 0)|\(.status.allocatable["nvidia.com/gpu"] // 0)"' 2>/dev/null)

if [[ "$TOTAL_GPU_CAPACITY" -ge "$REQUIRED_GPUS" ]]; then
    pass "Total GPU capacity: $TOTAL_GPU_CAPACITY (need $REQUIRED_GPUS for full lab)"
else
    fail "Total GPU capacity: $TOTAL_GPU_CAPACITY — need at least $REQUIRED_GPUS for full lab (Module 3 & 4 use 4 replicas)"
fi

if [[ "$TOTAL_GPU_ALLOCATABLE" -ge 1 ]]; then
    pass "Total allocatable GPUs: $TOTAL_GPU_ALLOCATABLE"
else
    fail "No allocatable GPUs — models cannot be scheduled"
fi

GPU_REQUESTS=$(oc get pods --all-namespaces -o json 2>/dev/null | \
    jq '[.items[] | select(.status.phase=="Running") | .spec.containers[]?.resources.requests["nvidia.com/gpu"] // empty | tonumber] | add // 0' 2>/dev/null || echo "0")
GPU_FREE=$((TOTAL_GPU_ALLOCATABLE - GPU_REQUESTS))
if [[ "$GPU_FREE" -ge 1 ]]; then
    pass "Available GPUs: $GPU_FREE free ($GPU_REQUESTS in use)"
else
    warn "All $TOTAL_GPU_ALLOCATABLE GPUs are in use ($GPU_REQUESTS requested) — new deployments will queue"
fi

# ─── NVIDIA GPU Operator ────────────────────────────────────────────────────
section "5. NVIDIA GPU Operator"

NVIDIA_NS=$(oc get pods --all-namespaces -o json 2>/dev/null | \
    jq -r '[.items[] | select(.metadata.name | test("nvidia")) | .metadata.namespace] | unique[]' 2>/dev/null | head -1 || echo "")

if [[ -z "$NVIDIA_NS" ]]; then
    NVIDIA_NS="nvidia-gpu-operator"
fi

NVIDIA_CSV=$(oc get csv --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.name | test("nvidia|gpu-operator")) | "\(.metadata.name)|\(.status.phase // "Unknown")"' 2>/dev/null | head -1 || echo "")

if [[ -n "$NVIDIA_CSV" ]]; then
    CSV_NAME=$(echo "$NVIDIA_CSV" | cut -d'|' -f1)
    CSV_PHASE=$(echo "$NVIDIA_CSV" | cut -d'|' -f2)
    if [[ "$CSV_PHASE" == "Succeeded" ]]; then
        pass "NVIDIA GPU Operator installed: $CSV_NAME (Succeeded)"
    else
        fail "NVIDIA GPU Operator '$CSV_NAME' phase: $CSV_PHASE (expected Succeeded)"
    fi
else
    warn "NVIDIA GPU Operator CSV not found — GPUs may be configured differently"
fi

DEVICE_PLUGIN_PODS=$(oc get pods --all-namespaces -l app=nvidia-device-plugin-daemonset -o json 2>/dev/null || echo '{"items":[]}')
DP_RUNNING=$(echo "$DEVICE_PLUGIN_PODS" | jq '[.items[] | select(.status.phase=="Running")] | length')
if [[ "$DP_RUNNING" -ge 1 ]]; then
    pass "NVIDIA device plugin daemonset: $DP_RUNNING pod(s) running"
else
    DEVICE_PLUGIN_PODS=$(oc get pods --all-namespaces -o json 2>/dev/null | \
        jq '[.items[] | select(.metadata.name | test("nvidia-device-plugin")) | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
    if [[ "$DEVICE_PLUGIN_PODS" -ge 1 ]]; then
        pass "NVIDIA device plugin: $DEVICE_PLUGIN_PODS pod(s) running"
    else
        fail "NVIDIA device plugin pods not running — GPUs won't be visible to workloads"
    fi
fi

DRIVER_PODS=$(oc get pods --all-namespaces -o json 2>/dev/null | \
    jq '[.items[] | select(.metadata.name | test("nvidia-driver")) | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
if [[ "$DRIVER_PODS" -ge 1 ]]; then
    pass "NVIDIA driver daemonset: $DRIVER_PODS pod(s) running"
else
    warn "NVIDIA driver pods not found — may use pre-installed host drivers"
fi

VALIDATOR_PODS=$(oc get pods --all-namespaces -o json 2>/dev/null | \
    jq '[.items[] | select(.metadata.name | test("nvidia-operator-validator")) | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
if [[ "$VALIDATOR_PODS" -ge 1 ]]; then
    pass "NVIDIA operator validator: $VALIDATOR_PODS pod(s) running"
else
    warn "NVIDIA operator validator pods not found"
fi

NFD_PODS=$(oc get pods --all-namespaces -o json 2>/dev/null | \
    jq '[.items[] | select(.metadata.name | test("node-feature-discovery|nfd")) | select(.status.phase=="Running")] | length' 2>/dev/null || echo "0")
if [[ "$NFD_PODS" -ge 1 ]]; then
    pass "Node Feature Discovery: $NFD_PODS pod(s) running"
else
    warn "Node Feature Discovery pods not found — GPU labels may not auto-populate"
fi

GPU_PRODUCT=$(oc get nodes -l nvidia.com/gpu.present=true -o json 2>/dev/null | \
    jq -r '.items[0].metadata.labels["nvidia.com/gpu.product"] // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$GPU_PRODUCT" != "unknown" && -n "$GPU_PRODUCT" ]]; then
    pass "GPU model detected: $GPU_PRODUCT"
else
    warn "Could not detect GPU product label (nvidia.com/gpu.product)"
fi

GPU_MEMORY=$(oc get nodes -l nvidia.com/gpu.present=true -o json 2>/dev/null | \
    jq -r '.items[0].metadata.labels["nvidia.com/gpu.memory"] // "unknown"' 2>/dev/null || echo "unknown")
if [[ "$GPU_MEMORY" != "unknown" && -n "$GPU_MEMORY" ]]; then
    pass "GPU memory: ${GPU_MEMORY} MB"
else
    warn "Could not detect GPU memory label (nvidia.com/gpu.memory)"
fi

# ─── ServingRuntime ──────────────────────────────────────────────────────────
section "6. ServingRuntime"

if oc get servingruntime rhaiis-cuda -n "$NAMESPACE" &>/dev/null; then
    pass "ServingRuntime 'rhaiis-cuda' exists in $NAMESPACE"
else
    warn "ServingRuntime 'rhaiis-cuda' not found — may be created during lab"
fi

# ─── PVC & Benchmark Data ───────────────────────────────────────────────────
section "7. PVC & Benchmark Data"

if oc get pvc benchmark-data -n "$NAMESPACE" &>/dev/null; then
    PVC_STATUS=$(oc get pvc benchmark-data -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [[ "$PVC_STATUS" == "Bound" ]]; then
        pass "PVC 'benchmark-data' is Bound"
    else
        fail "PVC 'benchmark-data' exists but status is $PVC_STATUS"
    fi
else
    fail "PVC 'benchmark-data' not found in $NAMESPACE"
fi

TEMP_POD="validate-data-check-$$"
CLEANUP_PODS+=("$TEMP_POD")
oc run "$TEMP_POD" -n "$NAMESPACE" \
    --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
    --restart=Never \
    --overrides='{
        "spec": {
            "containers": [{
                "name": "check",
                "image": "registry.access.redhat.com/ubi9/ubi-minimal:latest",
                "command": ["sh", "-c", "ls -la /data/prompts.csv 2>/dev/null && echo EXISTS || echo MISSING"],
                "volumeMounts": [{"name": "data", "mountPath": "/data"}]
            }],
            "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "benchmark-data"}}]
        }
    }' &>/dev/null 2>&1 || true

if oc wait --for=condition=Ready pod/"$TEMP_POD" -n "$NAMESPACE" --timeout=30s &>/dev/null 2>&1; then
    sleep 2
fi
DATA_CHECK=$(oc logs "$TEMP_POD" -n "$NAMESPACE" 2>/dev/null || echo "UNKNOWN")
if echo "$DATA_CHECK" | grep -q "EXISTS"; then
    pass "prompts.csv exists in benchmark-data PVC"
elif echo "$DATA_CHECK" | grep -q "MISSING"; then
    fail "prompts.csv NOT found in benchmark-data PVC"
else
    warn "Could not verify prompts.csv (temp pod may not have started)"
fi

# ─── InferenceService: llama-vllm-single ─────────────────────────────────────
section "8. InferenceService — llama-vllm-single"

if oc get inferenceservice llama-vllm-single -n "$NAMESPACE" &>/dev/null; then
    ISVC_READY=$(oc get inferenceservice llama-vllm-single -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$ISVC_READY" == "True" ]]; then
        pass "InferenceService 'llama-vllm-single' is Ready"
    else
        warn "InferenceService 'llama-vllm-single' exists but Ready=$ISVC_READY (may still be starting)"
    fi

    SINGLE_PODS=$(oc get pods -l serving.kserve.io/inferenceservice=llama-vllm-single -n "$NAMESPACE" -o json 2>/dev/null)
    RUNNING=$(echo "$SINGLE_PODS" | jq '[.items[] | select(.status.phase=="Running")] | length')
    if [[ "$RUNNING" -ge 1 ]]; then
        pass "llama-vllm-single has $RUNNING running pod(s)"
    else
        fail "llama-vllm-single has no running pods"
    fi
else
    warn "InferenceService 'llama-vllm-single' not found — may be created during Module 1"
fi

# ─── InferenceService: llama-vllm-scaled ─────────────────────────────────────
section "9. InferenceService — llama-vllm-scaled"

if oc get inferenceservice llama-vllm-scaled -n "$NAMESPACE" &>/dev/null; then
    ISVC_READY=$(oc get inferenceservice llama-vllm-scaled -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$ISVC_READY" == "True" ]]; then
        pass "InferenceService 'llama-vllm-scaled' is Ready"
    else
        warn "InferenceService 'llama-vllm-scaled' exists but Ready=$ISVC_READY"
    fi

    SCALED_PODS=$(oc get pods -l serving.kserve.io/inferenceservice=llama-vllm-scaled -n "$NAMESPACE" -o json 2>/dev/null)
    RUNNING=$(echo "$SCALED_PODS" | jq '[.items[] | select(.status.phase=="Running")] | length')
    if [[ "$RUNNING" -ge 4 ]]; then
        pass "llama-vllm-scaled has $RUNNING running pods (expected 4)"
    elif [[ "$RUNNING" -ge 1 ]]; then
        warn "llama-vllm-scaled has $RUNNING running pods (expected 4)"
    else
        fail "llama-vllm-scaled has no running pods"
    fi
else
    warn "InferenceService 'llama-vllm-scaled' not found — created in Module 3"
fi

# ─── LLMInferenceService: llama-llm-d ────────────────────────────────────────
section "10. LLMInferenceService — llama-llm-d"

if oc get llminferenceservice llama-llm-d -n "$NAMESPACE" &>/dev/null; then
    LLMD_READY=$(oc get llminferenceservice llama-llm-d -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$LLMD_READY" == "True" ]]; then
        pass "LLMInferenceService 'llama-llm-d' is Ready"
    else
        warn "LLMInferenceService 'llama-llm-d' exists but Ready=$LLMD_READY"
    fi

    LLMD_PODS=$(oc get pods -l serving.kserve.io/inferenceservice=llama-llm-d -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')
    RUNNING=$(echo "$LLMD_PODS" | jq '[.items[] | select(.status.phase=="Running")] | length')
    if [[ "$RUNNING" -ge 4 ]]; then
        pass "llama-llm-d has $RUNNING running pods (expected 4)"
    elif [[ "$RUNNING" -ge 1 ]]; then
        warn "llama-llm-d has $RUNNING running pods (expected 4)"
    else
        fail "llama-llm-d has no running pods"
    fi
else
    warn "LLMInferenceService 'llama-llm-d' not found — created in Module 4"
fi

# ─── Load Balancer Service ───────────────────────────────────────────────────
section "11. Load Balancer Service"

if oc get svc llama-vllm-scaled-lb -n "$NAMESPACE" &>/dev/null; then
    pass "Service 'llama-vllm-scaled-lb' exists"
else
    warn "Service 'llama-vllm-scaled-lb' not found — created in Module 3"
fi

# ─── Gateway Infrastructure ─────────────────────────────────────────────────
section "12. Gateway Infrastructure"

if oc get gatewayclass openshift-default &>/dev/null; then
    pass "GatewayClass 'openshift-default' exists"
else
    warn "GatewayClass 'openshift-default' not found"
fi

if oc get gateway openshift-ai-inference -n "$INGRESS_NS" &>/dev/null; then
    pass "Gateway 'openshift-ai-inference' exists in $INGRESS_NS"
else
    warn "Gateway 'openshift-ai-inference' not found in $INGRESS_NS — may be created during Module 4"
fi

GW_SVC="openshift-ai-inference-openshift-default"
if oc get svc "$GW_SVC" -n "$INGRESS_NS" &>/dev/null; then
    pass "Gateway service '$GW_SVC' exists in $INGRESS_NS"
else
    warn "Gateway service '$GW_SVC' not found — created with Gateway"
fi

# ─── Grafana ─────────────────────────────────────────────────────────────────
section "13. Grafana Monitoring"

if oc get namespace "$GRAFANA_NS" &>/dev/null; then
    pass "Grafana namespace '$GRAFANA_NS' exists"
else
    warn "Grafana namespace '$GRAFANA_NS' not found"
fi

GRAFANA_ROUTE=$(oc get route grafana-route -n "$GRAFANA_NS" -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || echo "")
if [[ -n "$GRAFANA_ROUTE" ]]; then
    pass "Grafana route: $GRAFANA_ROUTE"
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://$GRAFANA_ROUTE" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 400 ]]; then
        pass "Grafana UI is accessible (HTTP $HTTP_CODE)"
    else
        warn "Grafana UI returned HTTP $HTTP_CODE"
    fi
else
    warn "Grafana route not found"
fi

# ─── Model Endpoint Test (only if deployed) ─────────────────────────────────
section "14. Model Endpoint Curl Tests (deployed models only)"

TESTED_ENDPOINT=false

test_endpoint_via_portforward() {
    local label=$1 target=$2 local_port=$3 display_name=$4

    oc port-forward "$target" "$local_port:8000" -n "$NAMESPACE" &>/dev/null &
    local pf_pid=$!
    CLEANUP_PIDS+=("$pf_pid")

    if wait_for_port "$local_port"; then
        MODELS=$(curl -s --connect-timeout 5 "http://localhost:$local_port/v1/models" 2>/dev/null || echo "")
        if echo "$MODELS" | jq -e '.data[0].id' &>/dev/null; then
            MODEL_ID=$(echo "$MODELS" | jq -r '.data[0].id')
            pass "$display_name /v1/models responds — model: $MODEL_ID"
        else
            fail "$display_name /v1/models did not return valid model data"
        fi

        COMPLETION=$(curl -s --connect-timeout 10 --max-time 30 \
            "http://localhost:$local_port/v1/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL_NAME\",
                \"prompt\": \"San Francisco is a\",
                \"max_tokens\": 20,
                \"temperature\": 0.7
            }" 2>/dev/null || echo "")
        if echo "$COMPLETION" | jq -e '.choices[0].text' &>/dev/null; then
            REPLY_TEXT=$(echo "$COMPLETION" | jq -r '.choices[0].text' | head -c 80)
            pass "$display_name /v1/completions works — reply: \"$REPLY_TEXT...\""
        else
            fail "$display_name /v1/completions did not return a valid completion"
        fi

        TESTED_ENDPOINT=true
    else
        fail "Could not establish port-forward to $display_name"
    fi

    kill "$pf_pid" 2>/dev/null || true
}

SINGLE_DEPLOY=$(oc get deploy -l serving.kserve.io/inferenceservice=llama-vllm-single -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$SINGLE_DEPLOY" ]]; then
    test_endpoint_via_portforward "llama-vllm-single" "deployment/$SINGLE_DEPLOY" 18000 "llama-vllm-single"
fi

if oc get svc llama-vllm-scaled-lb -n "$NAMESPACE" &>/dev/null; then
    test_endpoint_via_portforward "llama-vllm-scaled" "svc/llama-vllm-scaled-lb" 18001 "llama-vllm-scaled-lb"
fi

if oc get svc "$GW_SVC" -n "$INGRESS_NS" &>/dev/null; then
    oc port-forward "svc/$GW_SVC" "18002:80" -n "$INGRESS_NS" &>/dev/null &
    GW_PF_PID=$!
    CLEANUP_PIDS+=("$GW_PF_PID")

    if wait_for_port 18002; then
        COMPLETION=$(curl -s --connect-timeout 10 --max-time 30 \
            "http://localhost:18002/$NAMESPACE/llama-llm-d/v1/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL_NAME\",
                \"prompt\": \"Kubernetes is\",
                \"max_tokens\": 20,
                \"temperature\": 0.7
            }" 2>/dev/null || echo "")
        if echo "$COMPLETION" | jq -e '.choices[0].text' &>/dev/null; then
            pass "llm-d gateway /v1/completions works via prefix-cache-aware routing"
        else
            fail "llm-d gateway /v1/completions failed"
        fi
        TESTED_ENDPOINT=true
    else
        fail "Could not port-forward to llm-d gateway"
    fi

    kill "$GW_PF_PID" 2>/dev/null || true
fi

if [[ "$TESTED_ENDPOINT" == "false" ]]; then
    warn "No model endpoints deployed yet — endpoint tests skipped (models are created during lab modules)"
fi

# ─── Benchmark Jobs ──────────────────────────────────────────────────────────
section "15. Benchmark Jobs"

for JOB_NAME in guidellm-vllm-single guidellm-vllm-scaled guidellm-llm-d; do
    if oc get job "$JOB_NAME" -n "$NAMESPACE" &>/dev/null; then
        SUCCEEDED=$(oc get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
        FAILED=$(oc get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
        if [[ "$SUCCEEDED" -ge 1 ]]; then
            pass "Job '$JOB_NAME' completed successfully"
        elif [[ "${FAILED:-0}" -ge 1 ]]; then
            fail "Job '$JOB_NAME' has failed"
        else
            warn "Job '$JOB_NAME' exists but hasn't completed yet"
        fi
    else
        warn "Job '$JOB_NAME' not found — runs during lab modules"
    fi
done

# ─── OpenShift AI Hardware Profiles ──────────────────────────────────────────
section "16. OpenShift AI"

if oc get namespace redhat-ods-applications &>/dev/null; then
    pass "OpenShift AI namespace 'redhat-ods-applications' exists"
else
    warn "OpenShift AI namespace not found"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
section "VALIDATION SUMMARY"
echo ""
echo -e "  ${GREEN}Passed${NC}: $PASS"
echo -e "  ${RED}Failed${NC}: $FAIL"
echo -e "  ${YELLOW}Warnings${NC}: $WARN"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}Environment is ready for showroom instructions.${NC}"
    exit 0
elif [[ "$FAIL" -le 3 ]]; then
    echo -e "${YELLOW}Environment has minor issues — review failures above.${NC}"
    exit 1
else
    echo -e "${RED}Environment has significant issues — deployment may not be complete.${NC}"
    exit 2
fi
