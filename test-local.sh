#!/usr/bin/env bash
# =============================================================================
# test-local.sh  –  Local dry-run mirroring the GitHub Actions pipeline
#
# Deploys to Kong Enterprise (on-prem / k8s) via the Admin API.
#
# Steps (match the CI/CD workflow exactly):
#   1  inso lint spec          – lint the OAS
#   2  deck file openapi2kong  – convert OAS → Kong declarative config
#   3  deck file add-plugins   – inject mocking plugin
#      deck file validate       – validate the generated config
#      deck gateway diff        – preview changes against Kong Enterprise
#      deck gateway apply       – deploy to Kong Enterprise Admin API (:8001)
#   4  curl POST/PUT            – upload OAS to Dev Portal /files
#      curl POST                – link spec to service via /document_objects
#   5  inso run test            – run Insomnia test suite against live proxy
#
# Usage:
#   export KONG_ADMIN_URL="http://localhost:8001"  # Kong Enterprise Admin API
#   export KONG_ADMIN_TOKEN="<rbac-token>"         # only if RBAC is enabled
#   export KONG_WORKSPACE="default"                # workspace name (default: default)
#   export KONG_PROXY_URL="http://localhost:8000"  # Kong proxy (for tests)
#
#   ./test-local.sh                # full 5-step run
#   ./test-local.sh --lint-only    # step 1 only
#   ./test-local.sh --deploy-only  # steps 2-4 only (includes portal publish)
#   ./test-local.sh --test-only    # step 5 only
#   ./test-local.sh --skip-deploy  # steps 1-3 build/validate only (no Admin API needed)
# =============================================================================

set -euo pipefail

RESET='\033[0m'; BOLD='\033[1m'; RED='\033[31m'; GREEN='\033[32m'
YELLOW='\033[33m'; CYAN='\033[36m'

step() { echo -e "\n${BOLD}${CYAN}▶  $*${RESET}"; }
ok()   { echo -e "${GREEN}✔  $*${RESET}"; }
fail() { echo -e "${RED}✘  $*${RESET}" >&2; exit 1; }
warn() { echo -e "${YELLOW}⚠  $*${RESET}"; }

MODE="full"
SKIP_DEPLOY=false
for arg in "$@"; do
  case "$arg" in
    --lint-only)   MODE="lint-only" ;;
    --deploy-only) MODE="deploy-only" ;;
    --test-only)   MODE="test-only" ;;
    --skip-deploy) SKIP_DEPLOY=true ;;
    *) fail "Unknown argument: $arg" ;;
  esac
done

[[ -f "openapi/sbi-cards-rewards-openapi.yaml" ]] || fail "Run from the SBICards demo repo root."

KONG_ADMIN_URL="${KONG_ADMIN_URL:-http://localhost:8001}"
KONG_WORKSPACE="${KONG_WORKSPACE:-default}"

# Build deck flags – append admin token header only if RBAC token is set
DECK_KONG_FLAGS="--kong-addr ${KONG_ADMIN_URL}"
if [[ -n "${KONG_ADMIN_TOKEN:-}" ]]; then
  DECK_KONG_FLAGS="${DECK_KONG_FLAGS} --headers Kong-Admin-Token:${KONG_ADMIN_TOKEN}"
fi

# Build curl auth header array (reused for both gateway and portal calls)
ADMIN_AUTH_HEADERS=()
if [[ -n "${KONG_ADMIN_TOKEN:-}" ]]; then
  ADMIN_AUTH_HEADERS=(-H "Kong-Admin-Token: ${KONG_ADMIN_TOKEN}")
fi

# ── pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight: checking required tools"

if [[ "$MODE" == "full" || "$MODE" == "lint-only" || "$MODE" == "test-only" ]]; then
  command -v inso >/dev/null || fail "inso not found.   brew install insomnia-inso"
  ok "inso  $(inso --version 2>&1 | head -1)"
fi

if [[ "$MODE" == "full" || "$MODE" == "deploy-only" || "$SKIP_DEPLOY" == "true" ]]; then
  command -v deck >/dev/null || fail "deck not found.   brew install deck"
  ok "deck  $(deck version 2>&1 | head -1)"
  command -v jq >/dev/null || fail "jq not found.    brew install jq"
  ok "jq    $(jq --version 2>&1)"
fi

if [[ "$MODE" == "full" || "$MODE" == "test-only" ]]; then
  [[ -n "${KONG_PROXY_URL:-}" ]] || fail "KONG_PROXY_URL is not set (e.g. http://localhost:8000)."
fi

echo ""
echo -e "${BOLD}================================================${RESET}"
echo -e "${BOLD} SBI Cards – Kong Enterprise CI/CD Demo${RESET}"
echo -e "${BOLD} Admin API  : ${KONG_ADMIN_URL}${RESET}"
echo -e "${BOLD} Workspace  : ${KONG_WORKSPACE}${RESET}"
echo -e "${BOLD}================================================${RESET}"
[[ "$SKIP_DEPLOY" == "true" ]] && warn "Running in --skip-deploy mode (steps 1-3 local only, no Admin API needed)"

lint_step() {
  step "STEP 1/5 – Lint OAS with inso lint spec"
  inso lint spec openapi/sbi-cards-rewards-openapi.yaml --ci
  ok "Spec is valid – no linting errors"
}

deploy_step() {
  step "STEP 2/5 – deck file openapi2kong → kong/kong-generated.yaml"
  deck file openapi2kong \
    -s openapi/sbi-cards-rewards-openapi.yaml \
    -o kong/kong-generated.yaml
  ok "kong/kong-generated.yaml written"
  echo "── preview ──"
  head -20 kong/kong-generated.yaml

  step "STEP 3/5 – Add Mocking plugin from kong/mock-plugin.yaml"
  deck file add-plugins \
    --state kong/kong-generated.yaml \
    --overwrite \
    --output-file kong/sandbox.yaml \
    kong/mock-plugin.yaml
  ok "kong/sandbox.yaml written"

  step "STEP 3/5 – deck file validate kong/sandbox.yaml"
  deck file validate kong/sandbox.yaml
  ok "Config is valid"

  if [[ "$SKIP_DEPLOY" == "true" ]]; then
    warn "Skipping deck gateway apply and portal publish (--skip-deploy)"
    return 0
  fi

  step "STEP 3/5 – Ping Kong Enterprise Admin API: ${KONG_ADMIN_URL}"
  # shellcheck disable=SC2086
  deck gateway ping $DECK_KONG_FLAGS
  ok "Connected to Kong Enterprise"

  step "STEP 3/5 – deck gateway diff (preview changes)"
  # shellcheck disable=SC2086
  deck gateway diff kong/sandbox.yaml $DECK_KONG_FLAGS

  step "STEP 3/5 – deck gateway apply → sandbox live on Kong Enterprise"
  # shellcheck disable=SC2086
  deck gateway apply kong/sandbox.yaml $DECK_KONG_FLAGS
  ok "Sandbox deployed to Kong Enterprise"

  portal_publish_step
}

portal_publish_step() {
  local spec_file="openapi/sbi-cards-rewards-openapi.yaml"
  local spec_path="specs/sbi-cards-rewards.yaml"
  local files_url="${KONG_ADMIN_URL}/${KONG_WORKSPACE}/files"

  # Derive service name from the already-generated Kong config (avoids hardcoding IDs)
  local service_name
  service_name=$(grep "^  name:" kong/kong-generated.yaml | head -1 | awk '{print $2}')

  # Resolve service UUID – the /documents sub-resource requires UUID, not name
  local service_uuid
  service_uuid=$(curl -sS \
    "${ADMIN_AUTH_HEADERS[@]+"${ADMIN_AUTH_HEADERS[@]}"}" \
    "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/services/${service_name}" \
    | jq -r '.id')
  [[ "$service_uuid" == "null" || -z "$service_uuid" ]] \
    && fail "Could not resolve UUID for service '${service_name}' – is it deployed?"
  ok "Resolved service UUID: ${service_uuid}"

  # ── 1. Upload spec to portal /files (source of truth) ────────────────────
  step "STEP 4/5 – Upload OAS to Dev Portal files: ${files_url}"

  local payload
  payload=$(jq -n \
    --arg path "$spec_path" \
    --rawfile contents "$spec_file" \
    '{path: $path, contents: $contents}')

  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "${files_url}" \
    -H "Content-Type: application/json" \
    "${ADMIN_AUTH_HEADERS[@]+"${ADMIN_AUTH_HEADERS[@]}"}" \
    -d "$payload")

  if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
    ok "Spec uploaded to Dev Portal files (HTTP ${http_code})"
  elif [[ "$http_code" == "409" ]]; then
    # Already exists – replace the contents with PUT
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -X PUT "${files_url}/${spec_path}" \
      -H "Content-Type: application/json" \
      "${ADMIN_AUTH_HEADERS[@]+"${ADMIN_AUTH_HEADERS[@]}"}" \
      -d "$payload")
    [[ "$http_code" == "200" ]] \
      && ok "Dev Portal spec updated (HTTP 200)" \
      || fail "Dev Portal file update failed – HTTP ${http_code} from ${files_url}"
  else
    fail "Dev Portal file upload failed – HTTP ${http_code} from ${files_url}"
  fi

  # ── 2. Link spec to service via /document_objects (path-only payload) ───
  # /document_objects links an already-uploaded /files entry to a service.
  # The endpoint takes only {path}, not {contents}.
  local docobj_url="${KONG_ADMIN_URL}/${KONG_WORKSPACE}/services/${service_uuid}/document_objects"
  step "STEP 4/5 – Link spec to service '${service_name}' (${service_uuid})"

  local doc_payload
  doc_payload=$(jq -n --arg path "$spec_path" '{path: $path}')

  local doc_response
  doc_response=$(curl -sS -w "\n%{http_code}" \
    -X POST "${docobj_url}" \
    -H "Content-Type: application/json" \
    "${ADMIN_AUTH_HEADERS[@]+"${ADMIN_AUTH_HEADERS[@]}"}" \
    -d "$doc_payload")
  http_code=$(tail -1 <<< "$doc_response")
  local doc_body
  doc_body=$(sed '$d' <<< "$doc_response")

  if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
    ok "Spec linked to service '${service_name}' in Dev Portal (HTTP ${http_code})"
  elif [[ "$http_code" == "409" ]]; then
    # Already linked – find the existing document object ID and PATCH its path
    local doc_id
    doc_id=$(curl -sS \
      "${ADMIN_AUTH_HEADERS[@]+"${ADMIN_AUTH_HEADERS[@]}"}" \
      "${docobj_url}" \
      | jq -r --arg p "$spec_path" '.data[] | select(.path == $p) | .id')
    [[ -z "$doc_id" || "$doc_id" == "null" ]] \
      && fail "Document object already exists but ID could not be resolved"
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
      -X PATCH "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/document_objects/${doc_id}" \
      -H "Content-Type: application/json" \
      "${ADMIN_AUTH_HEADERS[@]+"${ADMIN_AUTH_HEADERS[@]}"}" \
      -d "$doc_payload")
    [[ "$http_code" == "200" ]] \
      && ok "Spec document object updated (HTTP 200)" \
      || fail "Document object update failed – HTTP ${http_code}"
  else
    fail "Service document link failed – HTTP ${http_code}: ${doc_body}"
  fi
}

test_step() {
  ENV_FILE="insomnia/.insomnia/Environment/env_sbi_kong_ee.yml"
  step "STEP 5/5 – Inject ${KONG_PROXY_URL} into Insomnia env"
  sed -i.bak "s|^  base_url:.*|  base_url: ${KONG_PROXY_URL}|" "${ENV_FILE}"
  rm -f "${ENV_FILE}.bak"
  echo "Set base_url → ${KONG_PROXY_URL}"

  step "STEP 5/5 – Waiting 8s for Kong to propagate config…"
  sleep 8

  step "STEP 5/5 – inso run test uts_sbi_suite"
  inso run test uts_sbi_suite \
    --env env_sbi_kong_ee \
    --workingDir insomnia \
    --ci
  ok "All API tests passed"
}

case "$MODE" in
  lint-only)
    lint_step
    ;;
  deploy-only)
    deploy_step
    ;;
  test-only)
    test_step
    ;;
  full)
    lint_step
    deploy_step
    if [[ "$SKIP_DEPLOY" == "false" ]]; then
      test_step
    fi
    ;;
esac

echo ""
echo -e "${BOLD}${GREEN}================================================${RESET}"
echo -e "${BOLD}${GREEN} All steps passed. Ready to push to GitHub!${RESET}"
echo -e "${BOLD}${GREEN}================================================${RESET}"
