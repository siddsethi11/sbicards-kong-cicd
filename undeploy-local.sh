#!/usr/bin/env bash
# SBI Cards - Kong Enterprise CI/CD demo teardown script
#
# Purpose:
#   Remove only the SBI Cards demo deployment from Kong Enterprise so you can
#   re-run the live demo from a clean state.
#
# Usage:
#   export KONG_ADMIN_URL="http://localhost:8001"   # default
#   export KONG_ADMIN_TOKEN="<rbac-token>"          # only if RBAC is enabled
#   export KONG_WORKSPACE="default"                 # default
#
#   ./undeploy-local.sh                 # prompts for confirmation
#   ./undeploy-local.sh --yes           # non-interactive delete
#   ./undeploy-local.sh --dry-run       # print what would be deleted
#   ./undeploy-local.sh --service NAME  # override service name
#
# Notes:
#   - Some Kong setups enforce FK constraints and require routes to be deleted
#     before deleting a service.
#   - Script attempts to remove Dev Portal document objects and the uploaded spec
#     file at specs/sbi-cards-rewards.yaml.

set -euo pipefail

RESET='\033[0m'; BOLD='\033[1m'; RED='\033[31m'; GREEN='\033[32m'
YELLOW='\033[33m'; CYAN='\033[36m'

step() { echo -e "\n${BOLD}${CYAN}==> $*${RESET}"; }
ok()   { echo -e "${GREEN}OK  $*${RESET}"; }
warn() { echo -e "${YELLOW}WARN $*${RESET}"; }
fail() { echo -e "${RED}ERR $*${RESET}" >&2; exit 1; }

[[ -f "openapi/sbi-cards-rewards-openapi.yaml" ]] || fail "Run from the SBICards repo root."

KONG_ADMIN_URL="${KONG_ADMIN_URL:-http://localhost:8001}"
KONG_WORKSPACE="${KONG_WORKSPACE:-default}"
SPEC_PATH="specs/sbi-cards-rewards.yaml"

DRY_RUN=false
ASSUME_YES=false
SERVICE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --service)
      [[ $# -ge 2 ]] || fail "--service requires a value"
      SERVICE_NAME="$2"
      shift 2
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

CURL_AUTH=()
if [[ -n "${KONG_ADMIN_TOKEN:-}" ]]; then
  CURL_AUTH=(-H "Kong-Admin-Token: ${KONG_ADMIN_TOKEN}")
fi

command -v curl >/dev/null || fail "curl not found"
command -v jq >/dev/null || fail "jq not found - brew install jq"

if [[ -z "$SERVICE_NAME" ]]; then
  if [[ -f "kong/kong-generated.yaml" ]]; then
    SERVICE_NAME=$(grep "^  name:" kong/kong-generated.yaml | head -1 | awk '{print $2}')
  fi
fi

SERVICE_NAME="${SERVICE_NAME:-sbi-cards-reward-points-api}"

step "Target details"
echo "Admin API : ${KONG_ADMIN_URL}"
echo "Workspace : ${KONG_WORKSPACE}"
echo "Service   : ${SERVICE_NAME}"
echo "Spec file : ${SPEC_PATH}"
$DRY_RUN && warn "Dry-run mode enabled; no delete requests will be sent"

if [[ "$ASSUME_YES" != "true" && "$DRY_RUN" != "true" ]]; then
  read -r -p "Proceed with undeploy? (yes/no): " answer
  [[ "$answer" == "yes" ]] || fail "Cancelled by user"
fi

api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] ${method} ${KONG_ADMIN_URL}/${KONG_WORKSPACE}/${path}"
    return 0
  fi

  local code
  if [[ -n "$data" ]]; then
    code=$(curl -sS -o /tmp/sbi_undeploy_body.$$ -w "%{http_code}" \
      -X "$method" "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/${path}" \
      -H "Content-Type: application/json" \
      "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
      -d "$data")
  else
    code=$(curl -sS -o /tmp/sbi_undeploy_body.$$ -w "%{http_code}" \
      -X "$method" "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/${path}" \
      "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}")
  fi

  if [[ "$code" =~ ^2[0-9][0-9]$ || "$code" == "404" ]]; then
    return 0
  fi

  echo "HTTP ${code} from ${method} ${path}" >&2
  cat /tmp/sbi_undeploy_body.$$ >&2 || true
  rm -f /tmp/sbi_undeploy_body.$$ || true
  return 1
}

step "Resolve service"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] GET ${KONG_ADMIN_URL}/${KONG_WORKSPACE}/services/${SERVICE_NAME}"
  SERVICE_ID=""
else
  SERVICE_JSON=$(curl -sS \
    "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/services/${SERVICE_NAME}") || fail "Unable to query service"
  SERVICE_ID=$(jq -r '.id // empty' <<< "$SERVICE_JSON")
fi

if [[ "$DRY_RUN" == "true" ]]; then
  warn "Dry-run: service lookup skipped; delete shown by service name path"
  step "Delete service (cascades routes/plugins on service)"
  api DELETE "services/${SERVICE_NAME}" || fail "Failed deleting service"
  ok "Service delete request simulated"
elif [[ -z "$SERVICE_ID" || "$SERVICE_ID" == "null" ]]; then
  warn "Service '${SERVICE_NAME}' not found; continuing with Dev Portal cleanup"
else
  ok "Found service id: ${SERVICE_ID}"

  step "Delete routes attached to service"
  ROUTES_JSON=$(curl -sS \
    "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/services/${SERVICE_ID}/routes") || fail "Unable to list routes for service"
  ROUTE_IDS=()
  while IFS= read -r rid; do
    [[ -n "$rid" ]] && ROUTE_IDS+=("$rid")
  done < <(jq -r '.data[]?.id' <<< "$ROUTES_JSON")

  if [[ ${#ROUTE_IDS[@]} -eq 0 ]]; then
    warn "No routes found under service ${SERVICE_ID}"
  else
    for rid in "${ROUTE_IDS[@]}"; do
      api DELETE "routes/${rid}" || fail "Failed deleting route ${rid}"
      ok "Deleted route ${rid}"
    done
  fi

  step "Delete service (cascades routes/plugins on service)"
  api DELETE "services/${SERVICE_ID}" || fail "Failed deleting service"
  ok "Service delete request completed"
fi

step "Delete matching document_objects"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] GET ${KONG_ADMIN_URL}/${KONG_WORKSPACE}/document_objects"
else
  DOCS_JSON=$(curl -sS \
    "${CURL_AUTH[@]+"${CURL_AUTH[@]}"}" \
    "${KONG_ADMIN_URL}/${KONG_WORKSPACE}/document_objects") || DOCS_JSON='{"data":[]}'

  DOC_IDS=()
  while IFS= read -r did; do
    [[ -n "$did" ]] && DOC_IDS+=("$did")
  done < <(jq -r --arg p "$SPEC_PATH" '.data[]? | select(.path == $p) | .id' <<< "$DOCS_JSON")

  if [[ ${#DOC_IDS[@]} -eq 0 ]]; then
    warn "No document_objects found for path ${SPEC_PATH}"
  else
    for id in "${DOC_IDS[@]}"; do
      if api DELETE "document_objects/${id}"; then
        ok "Deleted document_object ${id}"
      else
        warn "Could not delete document_object ${id}; continuing"
      fi
    done
  fi
fi

step "Delete Dev Portal file"
if api DELETE "files/${SPEC_PATH}"; then
  ok "File delete request completed"
else
  warn "Could not delete file ${SPEC_PATH}; continuing"
fi

echo ""
echo -e "${BOLD}${GREEN}Teardown complete. Demo resources removed (or already absent).${RESET}"
