#!/usr/bin/env bash
# SBI Cards – Kong Enterprise CI/CD demo script
#
# Usage:
#   export KONG_ADMIN_URL="http://localhost:8001"   # default
#   export KONG_ADMIN_TOKEN="<rbac-token>"          # only if RBAC is enabled
#   export KONG_WORKSPACE="default"                 # default
#   export KONG_PROXY_URL="http://localhost:8000"   # required for --test-only / full
#
#   ./test-local.sh                # full 5-step run
#   ./test-local.sh --lint-only    # step 1 only
#   ./test-local.sh --deploy-only  # steps 2-4 (includes Dev Portal publish)
#   ./test-local.sh --test-only    # step 5 only
#   ./test-local.sh --skip-deploy  # steps 1-3 local build/validate, no Admin API

set -euo pipefail

RESET='\033[0m'; BOLD='\033[1m'; RED='\033[31m'; GREEN='\033[32m'
YELLOW='\033[33m'; CYAN='\033[36m'

step() { echo -e "\n${BOLD}${CYAN}▶  $*${RESET}"; }
ok()   { echo -e "${GREEN}✔  $*${RESET}"; }
fail() { echo -e "${RED}✘  $*${RESET}" >&2; exit 1; }
warn() { echo -e "${YELLOW}⚠  $*${RESET}"; }

MODE="full"; SKIP_DEPLOY=false
for arg in "$@"; do
  case "$arg" in
    --lint-only)   MODE="lint-only"   ;;
    --deploy-only) MODE="deploy-only" ;;
    --test-only)   MODE="test-only"   ;;
    --skip-deploy) SKIP_DEPLOY=true   ;;
    *) fail "Unknown argument: $arg"  ;;
  esac
done

[[ -f "openapi/sbi-cards-rewards-openapi.yaml" ]] || fail "Run from the SBICards repo root."

KONG_ADMIN_URL="${KONG_ADMIN_URL:-http://localhost:8001}"
KONG_WORKSPACE="${KONG_WORKSPACE:-default}"

DECK_FLAGS=(--kong-addr "${KONG_ADMIN_URL}")
CURL_AUTH=()
if [[ -n "${KONG_ADMIN_TOKEN:-}" ]]; then
  DECK_FLAGS+=(--headers "Kong-Admin-Token:${KONG_ADMIN_TOKEN}")
  CURL_AUTH=(-H "Kong-Admin-Token: ${KONG_ADMIN_TOKEN}")
fi

# ── pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight: checking required tools"

if [[ "$MODE" != "deploy-only" ]]; then
  command -v inso >/dev/null || fail "inso not found – brew install insomnia-inso"
  ok "inso  $(inso --version 2>&1 | head -1)"
fi

if [[ "$MODE" != "lint-only" && "$MODE" != "test-only" ]]; then
  command -v deck >/dev/null || fail "deck not found – brew install deck"
  ok "deck  $(deck version 2>&1 | head -1)"
  command -v jq   >/dev/null || fail "jq not found – brew install jq"
  ok "jq    $(jq --version)"
fi

if [[ "$MODE" == "full" || "$MODE" == "test-only" ]]; then
  [[ -n "${KONG_PROXY_URL:-}" ]] || fail "KONG_PROXY_URL is not set (e.g. http://localhost:8000)."
fi

echo ""
echo -e "${BOLD}================================================${RESET}"
echo -e "${BOLD} SBI Cards – Kong Enterprise CI/CD Demo${RESET}"
echo -e "${BOLD} Admin API : ${KONG_ADMIN_URL}${RESET}"
echo -e "${BOLD} Workspace : ${KONG_WORKSPACE}${RESET}"
echo -e "${BOLD}================================================${RESET}"
[[ "$SKIP_DEPLOY" == "true" ]] && warn "--skip-deploy: build/validate only, no Admin API calls"

lint_step() {
  step "STEP 1/5 – inso lint spec"
  inso lint spec openapi/sbi-cards-rewards-openapi.yaml --ci
  ok "OAS is valid"
}

deploy_step() {
  step "STEP 2/5 – deck file openapi2kong"
  deck file openapi2kong \
    -s openapi/sbi-cards-rewards-openapi.yaml \
    -o kong/kong-generated.yaml
  ok "kong/kong-generated.yaml written"
  head -20 kong/kong-generated.yaml

  step "STEP 3/5 – deck file add-plugins (mocking + cors)"
  deck file add-plugins \
    --state kong/kong-generated.yaml \
    --overwrite \
    --output-file kong/sandbox.yaml \
    kong/plugins.yaml
  ok "kong/sandbox.yaml written"

  step "STEP 3/5 – deck file validate"
  deck file validate kong/sandbox.yaml
  ok "Config is valid"

  if [[ "$SKIP_DEPLOY" == "true" ]]; then
    warn "Skipping gateway apply and portal publish (--skip-deploy)"
    return 0
  fi

  step "STEP 3/5 – deck gateway ping"
  deck gateway ping "${DECK_FLAGS[@]}"
  ok "Connected to Kong Enterprise at ${KONG_ADMIN_URL}"

  step "STEP 3/5 – deck gateway diff"
  deck gateway diff kong/sandbox.yaml "${DECK_FLAGS[@]}"

  step "STEP 3/5 – deck gateway apply"
  deck gateway apply kong/sandbox.yaml "${DECK_FLAGS[@]}"
  ok "Sandbox deployed to Kong Enterprise"

  portal_publish_step
}

portal_publish_step() {
  local spec_file="openapi/sbi-cards-rewards-openapi.yaml"
  local spec_path="specs/sbi-cards-rewards.yaml"
  local files_url="${KONG_ADMIN_URL}/${KONG_WORKSPACE}/files"

  local service_name
  service_name=$(grep "^  name:" kong/kong-generated.yaml | head -1 | awk '{print $2}')

  local service_uuid
  service_uuid=$(curl -sS \
    "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/services/${service_name}" \
    | jq -r '.id')
  [[ "$service_uuid" == "null" || -z "$service_uuid" ]] \
    && fail "Could not resolve UUID for service '${service_name}' – is it deployed?"

  local payload
  payload=$(jq -n --arg path "$spec_path" --rawfile contents "$spec_file" \
    '{path: $path, contents: $contents}')

  step "STEP 4/5 – Upload OAS to Dev Portal /files"
  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "${files_url}" \
    -H "Content-Type: application/json" \
    "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    -d "$payload")

  if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
    ok "Spec uploaded (HTTP ${http_code})"
  elif [[ "$http_code" == "409" ]]; then
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -X PUT "${files_url}/${spec_path}" \
      -H "Content-Type: application/json" \
      "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
      -d "$payload")
    [[ "$http_code" == "200" ]] \
      && ok "Spec updated (HTTP 200)" \
      || fail "Dev Portal file update failed – HTTP ${http_code}"
  else
    fail "Dev Portal file upload failed – HTTP ${http_code}"
  fi

  step "STEP 4/5 – Link spec to service '${service_name}'"
  local docobj_url="${KONG_ADMIN_URL}/${KONG_WORKSPACE}/services/${service_uuid}/document_objects"
  local doc_payload
  doc_payload=$(jq -n --arg path "$spec_path" '{path: $path}')

  local doc_response doc_body
  doc_response=$(curl -sS -w "\n%{http_code}" \
    -X POST "${docobj_url}" \
    -H "Content-Type: application/json" \
    "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    -d "$doc_payload")
  http_code=$(tail -1 <<< "$doc_response")
  doc_body=$(sed '$d' <<< "$doc_response")

  if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
    ok "Spec linked to service '${service_name}' (HTTP ${http_code})"
  elif [[ "$http_code" == "409" ]]; then
    local doc_id
    doc_id=$(curl -sS \
      "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
      "${docobj_url}" \
      | jq -r --arg p "$spec_path" '.data[] | select(.path == $p) | .id')
    [[ -z "$doc_id" || "$doc_id" == "null" ]] \
      && fail "Document object exists but ID could not be resolved"
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -X PATCH "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/document_objects/${doc_id}" \
      -H "Content-Type: application/json" \
      "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
      -d "$doc_payload")
    [[ "$http_code" == "200" ]] \
      && ok "Document object updated (HTTP 200)" \
      || fail "Document object update failed – HTTP ${http_code}"
  else
    fail "Service document link failed – HTTP ${http_code}: ${doc_body}"
  fi
}

test_step() {
  local env_file="insomnia/.insomnia/Environment/env_sbi_kong_ee.yml"
  step "STEP 5/5 – Inject ${KONG_PROXY_URL} into Insomnia env"
  sed -i.bak "s|^  base_url:.*|  base_url: ${KONG_PROXY_URL}|" "${env_file}"
  rm -f "${env_file}.bak"

  step "STEP 5/5 – Waiting 8s for Kong to propagate config…"
  sleep 8

  step "STEP 5/5 – inso run test"
  inso run test uts_sbi_suite \
    --env env_sbi_kong_ee \
    --workingDir insomnia \
    --ci
  ok "All API tests passed"
}

case "$MODE" in
  lint-only)   lint_step ;;
  deploy-only) deploy_step ;;
  test-only)   test_step ;;
  full)
    lint_step
    deploy_step
    [[ "$SKIP_DEPLOY" == "false" ]] && test_step
    ;;
esac

echo ""
echo -e "${BOLD}${GREEN}================================================${RESET}"
echo -e "${BOLD}${GREEN} All steps passed. Ready to push to GitHub!${RESET}"
echo -e "${BOLD}${GREEN}================================================${RESET}"
