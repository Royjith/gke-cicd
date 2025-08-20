#!/usr/bin/env bash
set -euo pipefail

# Configuration via environment variables (with sensible defaults)
PROJECT_ID="${PROJECT_ID:-vpc-satyajith}"
CLUSTER="${CLUSTER:-gke-cluster-01}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
NAMESPACE="${NAMESPACE:-default}"
# Comma-separated list of name:port for services to scan
SERVICES="${SERVICES:-my-service:8080,flask-service:8081}"
# Display name for the scan config
DISPLAY_NAME="${SCAN_DISPLAY_NAME:-gke-cicd-scan-${SHORT_SHA:-$(date +%s)}}"
# Severity threshold to fail the build: ANY, HIGH, MEDIUM, LOW, or NONE to never fail
FAIL_ON_SEVERITY="${SCAN_FAIL_ON_SEVERITY:-NONE}"
# Max time to wait for service readiness and scan completion (seconds)
SERVICE_READY_TIMEOUT_SECS="${SERVICE_READY_TIMEOUT_SECS:-600}"
SCAN_TIMEOUT_SECS="${SCAN_TIMEOUT_SECS:-3600}"
DELIVERY_PIPELINE="${DELIVERY_PIPELINE:-gke-cicd-pipeline}"
DEPLOY_REGION="${DEPLOY_REGION:-us-central1}"
WAIT_CLOUD_DEPLOY="${WAIT_CLOUD_DEPLOY:-false}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is not set and could not be inferred from gcloud config." >&2
  exit 1
fi

echo "Using project: ${PROJECT_ID}"
echo "Cluster: ${CLUSTER} (region=${REGION}, zone=${ZONE})"
echo "Namespace: ${NAMESPACE}"
echo "Services: ${SERVICES}"
echo "Scan display name: ${DISPLAY_NAME}"
echo "Fail on severity: ${FAIL_ON_SEVERITY}"
echo "Delivery pipeline: ${DELIVERY_PIPELINE} (region=${DEPLOY_REGION}), wait for rollout: ${WAIT_CLOUD_DEPLOY}"

# Ensure needed tools are present
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  apt-get update -y >/dev/null && apt-get install -y jq >/dev/null
fi

# Enable required Google APIs (idempotent)
APIS_TO_ENABLE="${APIS_TO_ENABLE:-serviceusage.googleapis.com,container.googleapis.com,clouddeploy.googleapis.com,websecurityscanner.googleapis.com}"
IFS=',' read -r -a apis_array <<< "${APIS_TO_ENABLE}"
echo "Ensuring required APIs are enabled: ${APIS_TO_ENABLE}"
for api in "${apis_array[@]}"; do
  echo "Enabling API: ${api}"
  if ! gcloud services enable "${api}" --project "${PROJECT_ID}" --quiet; then
    echo "WARNING: Failed to enable ${api}. Ensure it is enabled and that the Cloud Build service account has permissions (roles/serviceusage.serviceUsageAdmin)." >&2
  fi
done

# Authenticate kubectl against the cluster (read-only)
if [[ -n "${ZONE}" ]]; then
  gcloud container clusters get-credentials "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}"
else
  gcloud container clusters get-credentials "${CLUSTER}" --region "${REGION}" --project "${PROJECT_ID}"
fi

# Resolve service external endpoints and wait until reachable
declare -a STARTING_URLS
IFS=',' read -r -a service_array <<< "${SERVICES}"

wait_for_service_object() {
  local svc_name="$1"
  local deadline=$(( $(date +%s) + SERVICE_READY_TIMEOUT_SECS ))
  echo "Waiting for Service/${svc_name} in namespace ${NAMESPACE} to exist..."
  until kubectl -n "${NAMESPACE}" get svc "${svc_name}" >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
      echo "Timed out waiting for Service/${svc_name} to be created." >&2
      return 1
    fi
    sleep 5
  done
  echo "Service/${svc_name} exists."
}

wait_for_loadbalancer_ingress() {
  local svc_name="$1"
  local deadline=$(( $(date +%s) + SERVICE_READY_TIMEOUT_SECS ))
  echo "Waiting for LoadBalancer ingress for Service/${svc_name}..."
  while true; do
    ip=$(kubectl -n "${NAMESPACE}" get svc "${svc_name}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    host=$(kubectl -n "${NAMESPACE}" get svc "${svc_name}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    external_host="${ip:-${host:-}}"
    if [[ -n "${external_host}" ]]; then
      echo "Ingress ready: ${external_host}"
      break
    fi
    if (( $(date +%s) > deadline )); then
      echo "Timed out waiting for LoadBalancer ingress for Service/${svc_name}" >&2
      echo "Service describe:" >&2
      kubectl -n "${NAMESPACE}" describe svc "${svc_name}" >&2 || true
      echo "Service YAML:" >&2
      kubectl -n "${NAMESPACE}" get svc "${svc_name}" -o yaml >&2 || true
      echo "Recent events:" >&2
      kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -n 100 >&2 || true
      return 1
    fi
    sleep 5
  done
  echo -n "${external_host}"
}

wait_for_cloud_deploy_rollout() {
  local release_name="$1"
  local deadline=$(( $(date +%s) + SERVICE_READY_TIMEOUT_SECS ))
  echo "Waiting for Cloud Deploy rollout of release ${release_name} in pipeline ${DELIVERY_PIPELINE} (${DEPLOY_REGION})..."
  while true; do
    # Get the latest rollout and its state
    rollout=$(gcloud deploy rollouts list --release "${release_name}" --delivery-pipeline "${DELIVERY_PIPELINE}" --region "${DEPLOY_REGION}" --format="value(name,state)" | tail -n1 || true)
    rollout_name=$(echo "${rollout}" | awk '{print $1}')
    rollout_state=$(echo "${rollout}" | awk '{print $2}')
    echo "Current rollout: ${rollout_name:-<none>} state=${rollout_state:-<unknown>}"
    if [[ "${rollout_state}" == "SUCCEEDED" ]]; then
      echo "Rollout succeeded."
      break
    fi
    if [[ "${rollout_state}" == "FAILED" || "${rollout_state}" == "CANCELLED" ]]; then
      echo "ERROR: Rollout ended with state ${rollout_state}." >&2
      return 1
    fi
    if (( $(date +%s) > deadline )); then
      echo "ERROR: Timed out waiting for rollout to complete." >&2
      return 1
    fi
    sleep 10
  done
}

if [[ "${WAIT_CLOUD_DEPLOY}" == "true" ]]; then
  # Check if RELEASE_NAME is set from the environment file
  if [[ -f /workspace/env.sh ]]; then
    source /workspace/env.sh
  fi
  
  if [[ -n "${RELEASE_NAME:-}" ]]; then
    echo "Using RELEASE_NAME from environment: ${RELEASE_NAME}"
    wait_for_cloud_deploy_rollout "${RELEASE_NAME}"
  elif [[ -n "${SHORT_SHA:-}" ]]; then
    release_name="app-release-${SHORT_SHA}"
    echo "Using SHORT_SHA-based release name: ${release_name}"
    wait_for_cloud_deploy_rollout "${release_name}"
  else
    echo "Neither RELEASE_NAME nor SHORT_SHA set; skipping Cloud Deploy rollout wait."
  fi
fi

wait_for_http_ok() {
  local url="$1"
  local deadline=$(( $(date +%s) + SERVICE_READY_TIMEOUT_SECS ))
  echo "Waiting for ${url} to become reachable..."
  until curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
      echo "Timed out waiting for ${url}" >&2
      return 1
    fi
    sleep 5
  done
  echo "Reachable: ${url}"
}

for entry in "${service_array[@]}"; do
  svc_name="${entry%%:*}"
  svc_port="${entry##*:}"
  echo "Resolving external endpoint for service ${svc_name}..."
  # Wait for Service existence and LoadBalancer ingress
  wait_for_service_object "${svc_name}"
  external_host=$(wait_for_loadbalancer_ingress "${svc_name}")
  url="http://${external_host}:${svc_port}"
  wait_for_http_ok "${url}"
  STARTING_URLS+=("${url}")
done

echo "Starting URLs: ${STARTING_URLS[*]}"

# Get access token for REST calls
ACCESS_TOKEN=$(gcloud auth print-access-token)
API_ROOT="https://websecurityscanner.googleapis.com/v1"
PARENT="projects/${PROJECT_ID}"

# Build JSON array for startingUrls
urls_json=$(printf '%s\n' "${STARTING_URLS[@]}" | jq -R . | jq -s .)

echo "Creating scan config..."
create_body=$(jq -n \
  --arg dn "${DISPLAY_NAME}" \
  --argjson urls "${urls_json}" \
  '{displayName: $dn, startingUrls: $urls, maxQps: 5}')

create_resp=$(curl -sS -X POST "${API_ROOT}/${PARENT}/scanConfigs" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${create_body}")

scan_config_name=$(echo "${create_resp}" | jq -r '.name // empty')
if [[ -z "${scan_config_name}" ]]; then
  # Attempt to find existing by display name
  list_resp=$(curl -sS -X GET "${API_ROOT}/${PARENT}/scanConfigs" -H "Authorization: Bearer ${ACCESS_TOKEN}")
  scan_config_name=$(echo "${list_resp}" | jq -r --arg dn "${DISPLAY_NAME}" '.scanConfigs[]? | select(.displayName==$dn) | .name' | head -n1)
fi

if [[ -z "${scan_config_name}" ]]; then
  echo "ERROR: Could not create or find scan config. Response: ${create_resp}" >&2
  exit 1
fi

echo "Scan config: ${scan_config_name}"

echo "Starting scan run..."
start_resp=$(curl -sS -X POST "${API_ROOT}/${scan_config_name}:start" -H "Authorization: Bearer ${ACCESS_TOKEN}")
scan_run_name=$(echo "${start_resp}" | jq -r '.name // empty')
if [[ -z "${scan_run_name}" ]]; then
  echo "ERROR: Could not start scan run. Response: ${start_resp}" >&2
  exit 1
fi
echo "Scan run: ${scan_run_name}"

echo "Waiting for scan to complete (timeout: ${SCAN_TIMEOUT_SECS}s)..."
deadline=$(( $(date +%s) + SCAN_TIMEOUT_SECS ))
execution_state=""
result_state=""
while true; do
  run_resp=$(curl -sS -X GET "${API_ROOT}/${scan_run_name}" -H "Authorization: Bearer ${ACCESS_TOKEN}")
  execution_state=$(echo "${run_resp}" | jq -r '.executionState // empty')
  result_state=$(echo "${run_resp}" | jq -r '.resultState // empty')
  echo "Scan status: executionState=${execution_state}, resultState=${result_state}"
  if [[ "${execution_state}" == "FINISHED" ]]; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    echo "ERROR: Timed out waiting for scan completion" >&2
    exit 1
  fi
  sleep 10
done

echo "Fetching findings..."
findings_resp=$(curl -sS -X GET "${API_ROOT}/${scan_run_name}/findings" -H "Authorization: Bearer ${ACCESS_TOKEN}") || findings_resp='{}'
findings_count=$(echo "${findings_resp}" | jq -r '.findings | length // 0')
echo "Total findings: ${findings_count}"

if [[ "${FAIL_ON_SEVERITY}" != "NONE" && "${findings_count}" -gt 0 ]]; then
  # Map severities to numeric order
  # UNKNOWN=0, LOW=1, MEDIUM=2, HIGH=3 per docs
  threshold=0
  case "${FAIL_ON_SEVERITY}" in
    ANY) threshold=0 ;;
    LOW) threshold=1 ;;
    MEDIUM) threshold=2 ;;
    HIGH) threshold=3 ;;
    *) threshold=4 ;;
  esac
  severe_count=$(echo "${findings_resp}" | jq --argjson t "$threshold" '[.findings[]? | .severity as $s | ( $s=="UNKNOWN"?0:( $s=="LOW"?1:( $s=="MEDIUM"?2:( $s=="HIGH"?3:0)))) | select(. >= $t)] | length')
  if [[ "${severe_count}" -gt 0 ]]; then
    echo "ERROR: Web Security Scanner found ${severe_count} findings at or above severity ${FAIL_ON_SEVERITY}." >&2
    # Print a brief table of findings
    echo "Sample findings:" >&2
    echo "${findings_resp}" | jq -r '.findings[]? | "- [\(.severity)] \(.findingType) at \(.httpMethod) \(.fuzzedUrl)"' | head -n 20 >&2
    exit 2
  fi
fi

echo "Web Security Scanner completed with no findings meeting the failure threshold (${FAIL_ON_SEVERITY})."


