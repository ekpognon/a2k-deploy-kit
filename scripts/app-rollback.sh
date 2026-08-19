#!/usr/bin/env bash
#
# scripts/app-rollback.sh — Shared rollback core (cycle 29 ADR-010 A12 in-place + pre-pull last 3)
#
# Architecture push-and-forget VPS-orchestrator (cohérent app-deploy.sh) :
#   - GHA = transport-only (rollback-app.yml workflow → scp scripts/ + ssh exec)
#   - VPS = orchestrator local autonome (this script runs LOCALLY on VPS)
#
# Cycle 29 decisions Mode A user (A12 + A5 hooks) :
#   - A12 Rollback in-place + pre-pull last 3 images VPS (~5s fast rollback sans re-download network)
#   - A5 2 hooks rollback : pre-rollback + post-rollback (timeout 60s, fail=WARNING)
#   - A6 11 env vars A2K_* contract (A6 amend Wave 1 cont — A2K_ACTION=rollback + A2K_PREVIOUS_TAG=target rollback + A2K_REGISTRY_ORG)
#   - A11 Audit log VPS append JSON structured
#   - A14 Runbook deep-rollback-from-git-tag.md (rebuild from git tag immuable si image absente registry)
#
# Workflow strict (8 steps) :
#   1. Pré-flight validation (env + app + previous-tag arg + image pre-pulled VPS)
#   2. Discovery hooks <compose_path>/hooks/*.sh
#   3. Export A2K_* + A2K_ACTION=rollback + A2K_PREVIOUS_TAG=target
#   4. pre-rollback.sh hook (timeout 60s, fail=WARNING_CONTINUE)
#   5. docker compose pull <previous-tag> (skip si déjà local) + up -d --force-recreate
#   6. healthcheck.sh hook validation rollback
#   7. post-rollback.sh hook (timeout 60s, fail=WARNING_OK)
#   8. Audit log VPS + alias mobile <app>:current ← previous-tag
#
# Usage VPS :
#   bash scripts/app-rollback.sh <env> <app_name> <previous_tag>
#   bash scripts/app-rollback.sh stg topxpress v1.2.2
#
# Usage local audit :
#   DRY_RUN=1 bash scripts/app-rollback.sh stg topxpress v1.2.2
#
# Discipline : KISS + named constants + BASH-CALLS-SEPARATED v2 + bash-ops-specialist AP-1 to AP-15.

set -euo pipefail

# Cycle 37 (ADR-008 amend / ADR-013) — umask 027 : compagnon du bit setgid (cf. app-deploy.sh).
# Force dir 2750 / fichiers 0640 (other=---) sur le FAIL_LOG et les sous-dirs créés ici + hooks
# pre/post-rollback sourcés via lib/hooks-runner.sh. Placé après set -euo pipefail, AVANT tout mkdir.
umask 027

# ============================================================================
# Constants
# ============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

readonly DRY_RUN="${DRY_RUN:-0}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

ROLLBACK_PHASE="init"

# Colors
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  readonly C_RED=$'\033[0;31m'
  readonly C_GREEN=$'\033[0;32m'
  readonly C_YELLOW=$'\033[0;33m'
  readonly C_BLUE=$'\033[0;34m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_RED=""
  readonly C_GREEN=""
  readonly C_YELLOW=""
  readonly C_BLUE=""
  readonly C_RESET=""
fi

log_info()  { echo "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { echo "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()  { echo "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error() { echo "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_phase() { echo ""; echo "${C_BLUE}━━━ Phase: $* ━━━${C_RESET}"; }

rollback_cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "Rollback interrupted/failed (rc=${rc}) at phase: ${ROLLBACK_PHASE}"
    log_error "Manual intervention required — verify state: docker ps -a + docker compose logs"
  fi
  return "${rc}"
}
trap rollback_cleanup EXIT INT TERM

# ============================================================================
# Usage
# ============================================================================
usage() {
  cat >&2 <<EOF
${SCRIPT_NAME} — Shared rollback core (cycle 29 ADR-010 A12)

Usage:
  bash ${SCRIPT_NAME} <env> <app_name> <previous_tag>

Args:
  env             Environment : stg | prd
  app_name        App name : topxpress | soiroke | etc.
  previous_tag    Rollback target tag (must be pre-pulled VPS A12)

Env vars:
  DRY_RUN=1       Audit mode (no container execution)
  LOG_LEVEL       DEBUG | INFO | WARN | ERROR

Examples:
  bash ${SCRIPT_NAME} stg topxpress v1.2.2
  DRY_RUN=1 bash ${SCRIPT_NAME} prd soiroke v3.0.5

Cf. docs/runbooks/deep-rollback-from-git-tag.md (A14) si image absente registry.
EOF
  exit 1
}

if [[ $# -lt 3 ]]; then
  usage
fi

readonly ENV="$1"
readonly APP_NAME="$2"
readonly PREVIOUS_TAG="$3"

# Validation
case "${ENV}" in
  stg|prd) ;;
  *) log_error "env='${ENV}' invalid (expected: stg|prd)"; exit 1 ;;
esac

if ! printf '%s' "${APP_NAME}" | grep -qE '^[a-z][a-z0-9_-]{0,63}$'; then
  log_error "app_name='${APP_NAME}' invalid"
  exit 1
fi

if ! printf '%s' "${PREVIOUS_TAG}" | grep -qE '^[a-zA-Z0-9._-]{1,128}$'; then
  log_error "previous_tag='${PREVIOUS_TAG}' invalid"
  exit 1
fi

# ============================================================================
# Source libraries
# ============================================================================
# shellcheck source=lib/env-vars.sh
. "${LIB_DIR}/env-vars.sh"
# shellcheck source=lib/hooks-runner.sh
. "${LIB_DIR}/hooks-runner.sh"
# shellcheck source=lib/audit-helpers.sh
if [[ -f "${LIB_DIR}/audit-helpers.sh" ]]; then
  . "${LIB_DIR}/audit-helpers.sh"
fi

readonly PROJECT_DIR="/opt/${ENV}/${APP_NAME}"
readonly HOOKS_DIR="${PROJECT_DIR}/hooks"
readonly COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

# Detect current tag (will be displaced by rollback target)
CURRENT_TAG=""
if [[ "${DRY_RUN}" == "0" ]] && command -v docker >/dev/null 2>&1; then
  if CURRENT_TAG=$(docker image inspect "${APP_NAME}:current" --format '{{index .RepoTags 0}}' 2>/dev/null); then
    CURRENT_TAG="${CURRENT_TAG##*:}"
  fi
fi

# Export A2K_* contract with A2K_ACTION=rollback
# Note: A2K_IMAGE_TAG = previous_tag (rollback target becomes new active image)
#       A2K_PREVIOUS_TAG = current_tag (what was active, now being displaced)
export_a2k_env_vars "${APP_NAME}" "${ENV}" "${PREVIOUS_TAG}" "${CURRENT_TAG}" "rollback"

echo ""
echo "${C_YELLOW}========================================================================${C_RESET}"
echo "${C_YELLOW}  app-rollback.sh — cycle 29 ADR-010 A12 in-place rollback${C_RESET}"
echo "${C_YELLOW}========================================================================${C_RESET}"
log_info "Env             : ${ENV}"
log_info "App             : ${APP_NAME}"
log_info "Rollback target : ${PREVIOUS_TAG}"
log_info "Current (active): ${CURRENT_TAG:-(unknown)}"
log_info "Project dir     : ${PROJECT_DIR}"
log_info "DRY_RUN         : ${DRY_RUN}"
echo ""

# ============================================================================
# Phase 1 — Pré-flight validation
# ============================================================================
ROLLBACK_PHASE="preflight"
log_phase "1. Pré-flight validation"

# Project dir
if [[ ! -d "${PROJECT_DIR}" ]] && [[ "${DRY_RUN}" == "0" ]]; then
  log_error "PROJECT_DIR ${PROJECT_DIR} absent"
  exit 1
fi

# Compose file
if [[ ! -f "${COMPOSE_FILE}" ]] && [[ "${DRY_RUN}" == "0" ]]; then
  log_error "docker-compose.yml absent: ${COMPOSE_FILE}"
  exit 1
fi

# Verify previous_tag image pre-pulled VPS (A12 — fast rollback sans re-download)
if [[ "${DRY_RUN}" == "0" ]] && command -v docker >/dev/null 2>&1; then
  # Image format: ghcr.io/<org>/<app>:<tag> OR <app>:<tag> — check both
  if ! docker image inspect "${APP_NAME}:${PREVIOUS_TAG}" >/dev/null 2>&1 \
    && ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q ":${PREVIOUS_TAG}$"; then
    log_error "previous_tag '${PREVIOUS_TAG}' NOT pre-pulled VPS"
    log_error "A12 fast rollback IMPOSSIBLE — image absent from local registry"
    log_error ""
    log_error "Options :"
    log_error "  1. Try docker pull (slow path, registry-dependent) :"
    log_error "     docker pull ghcr.io/<org>/${APP_NAME}:${PREVIOUS_TAG}"
    log_error "  2. Deep rollback from git tag (A14 — if image absent registry post-cleanup) :"
    log_error "     Cf. docs/runbooks/deep-rollback-from-git-tag.md"
    exit 1
  fi
  log_ok "previous_tag image pre-pulled VPS — fast rollback OK"
fi

# ============================================================================
# Phase 2 — Discovery hooks
# ============================================================================
ROLLBACK_PHASE="discover-hooks"
log_phase "2. Discovery rollback hooks"

if [[ -d "${HOOKS_DIR}" ]]; then
  HOOKS_FOUND="$(discover_hooks "${HOOKS_DIR}")"
  log_info "Hooks found: ${HOOKS_FOUND:-(none)}"
else
  log_warn "Hooks dir absent: ${HOOKS_DIR}"
fi

# ============================================================================
# Phase 3 — pre-rollback hook (fail=WARNING_CONTINUE)
# ============================================================================
ROLLBACK_PHASE="pre-rollback"
log_phase "3. Hook pre-rollback.sh (fail=WARNING_CONTINUE, timeout=$(get_hook_timeout pre-rollback)s)"

PRE_ROLLBACK_RC=0
run_hook "pre-rollback" "${HOOKS_DIR}" || PRE_ROLLBACK_RC=$?

if [[ "${PRE_ROLLBACK_RC}" -ne 0 ]] && [[ "${PRE_ROLLBACK_RC}" -ne 1 ]]; then
  log_warn "pre-rollback hook returned rc=${PRE_ROLLBACK_RC} (non-fatal per fail_behavior)"
fi

# ============================================================================
# Phase 4 — docker compose pull <previous-tag> + up -d --force-recreate
# ============================================================================
ROLLBACK_PHASE="swap"
log_phase "4. docker compose pull ${PREVIOUS_TAG} + up -d --force-recreate"

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "[DRY_RUN] Would set image tag to ${PREVIOUS_TAG} in compose"
  log_info "[DRY_RUN] Would execute: docker compose pull (skip if local)"
  log_info "[DRY_RUN] Would execute: docker compose up -d --force-recreate"
else
  # R1-W1-07 LOW fix (cycle 29 Wave 2 §2.3) : cd subshell guard
  # Defense-in-depth bash AP-12 : isolate cd to subshell to prevent directory state
  # leak if script ever sourced. cd failure exit 1 explicit (fail-fast).
  (
    cd "${PROJECT_DIR}" || { log_error "cd ${PROJECT_DIR} FAILED"; exit 1; }

    # The convention here is that docker-compose.yml uses ${A2K_IMAGE_TAG} or similar var.
    # If app uses static tag, deploy.sh must pass image tag via env_file rewrite.
    # For V0, we export TARGET_TAG that compose can substitute.
    export TARGET_TAG="${PREVIOUS_TAG}"
    export IMAGE_TAG="${PREVIOUS_TAG}"

    log_info "Pulling target image (skip if local)..."

    # Sub-action 5b Finding E F2 (cycle 29 Wave 1 closure 4.5) + R4 M1 MED Wave 2 §2.3 :
    # validate local image digest AVANT fallback cache (anti-tampering rollback)
    # Env-aware Wave 2 : PRD strict exit 1 + STG/local warning-only continue forensic.
    #
    # TODO V1+ (R1-W1-01 MED §2.3) : digest write-side incomplet.
    # get_historical_digest grep "digest":"sha256:..." dans audit logs MAIS
    # log_hook_audit ne writes pas digest field actuellement (audit-helpers.sh).
    # Options V1+ : (a) write-side complete docker image inspect post-pull deploy,
    #              (b) supprimer read-side dead path. Defer V1+ scope dédié.
    # Read-side preserved as defense-in-depth scaffolding pour write-side V1+.
    REGISTRY_HOST="$(get_registry 2>/dev/null || echo 'ghcr.io')"
    REGISTRY_ORG="$(get_org 2>/dev/null || echo 'ekpognon')"  # cycle 29 Wave 1 cont sub-action 7 — default canonical Mode A user 2026-06-22
    if docker image inspect "${REGISTRY_HOST}/${REGISTRY_ORG}/${APP_NAME}:${PREVIOUS_TAG}" >/dev/null 2>&1; then
      LOCAL_DIGEST=$(docker image inspect "${REGISTRY_HOST}/${REGISTRY_ORG}/${APP_NAME}:${PREVIOUS_TAG}" --format '{{.Id}}' 2>/dev/null || echo "")
      EXPECTED_DIGEST=""
      if declare -F get_historical_digest >/dev/null 2>&1; then
        EXPECTED_DIGEST=$(get_historical_digest "${APP_NAME}" "${ENV}" "${PREVIOUS_TAG}" 2>/dev/null || echo "")
      fi
      if [[ -n "${EXPECTED_DIGEST}" && -n "${LOCAL_DIGEST}" && "${LOCAL_DIGEST}" != "${EXPECTED_DIGEST}" ]]; then
        log_error "ROLLBACK CRITICAL: local image digest MISMATCH (anti-tampering F2)"
        log_error "  Expected digest : ${EXPECTED_DIGEST:0:20}..."
        log_error "  Local digest    : ${LOCAL_DIGEST:0:20}..."
        log_error "  Tag             : ${PREVIOUS_TAG}"
        log_error "  Possible image tampering OR digest history stale"
        # R4 M1 MED Wave 2 §2.3 — env-aware fail_behavior in audit log
        if [[ "${ENV}" == "prd" ]]; then
          log_hook_audit "rollback-digest-mismatch" 1 0 "abort" || true
          log_error "  PRD strict anti-tampering: ABORTING rollback. Manual forensic investigation required."
          log_error "  Cf. ops_discipline.md §9 strict prd + ADR-010 § A11 audit log forensic"
          exit 1
        else
          log_hook_audit "rollback-digest-mismatch" 1 0 "warn" || true
          log_warn "  STG/local env: continuing rollback with warning (forensic trail in audit log)"
        fi
      fi
    fi

    docker compose pull || log_warn "docker compose pull failed — using local image cache (digest validated above F2)"

    log_info "Bringing up services with rollback target (--force-recreate)..."
    docker compose up -d --force-recreate
    log_ok "docker compose up to rollback target OK"
  )
fi

# ============================================================================
# Phase 5 — healthcheck post-rollback validation
# ============================================================================
ROLLBACK_PHASE="healthcheck"
log_phase "5. Hook healthcheck.sh (rollback validation, timeout=$(get_hook_timeout healthcheck)s)"

HEALTHCHECK_RC=0
run_hook "healthcheck" "${HOOKS_DIR}" || HEALTHCHECK_RC=$?

if [[ "${HEALTHCHECK_RC}" -ne 0 ]]; then
  # Sub-action 5b Finding E F1 (cycle 29 Wave 1 closure 4.5) :
  # capture diagnostic AVANT exit 1 (observability rollback fail CATASTROPHIC)
  TIMESTAMP_FAIL="$(date +%Y%m%d-%H%M%S)"
  FAIL_LOG="/var/log/${APP_NAME}/${ENV}/deploys/${TIMESTAMP_FAIL}-rollback-fail.log"
  mkdir -p "$(dirname "${FAIL_LOG}")" 2>/dev/null || true
  {
    echo "=== Diagnostic post-rollback FAIL ==="
    echo "Timestamp : ${TIMESTAMP_FAIL}"
    echo "App       : ${APP_NAME}"
    echo "Env       : ${ENV}"
    echo "Target    : ${PREVIOUS_TAG}"
    echo "Was       : ${CURRENT_TAG:-unknown}"
    echo ""
    echo "=== docker ps -a ==="
    docker ps -a --filter "name=${APP_NAME}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null || true
    echo ""
    echo "=== docker compose logs (tail 50) ==="
    docker compose logs --tail=50 2>/dev/null || true
  } >> "${FAIL_LOG}" 2>&1 || true

  log_error "Rollback healthcheck FAILED — manual intervention required"
  log_error "Both current AND rollback target appear unhealthy"
  log_error "Diagnostic saved: ${FAIL_LOG}"
  log_error "CATASTROPHIC FAILURE — manual intervention REQUIRED immediately"

  # Audit log CRITICAL entry
  log_hook_audit "rollback-catastrophic" 1 0 "CATASTROPHIC_FAIL" || true
  exit 1
fi

# ============================================================================
# Phase 6 — post-rollback hook (fail=WARNING_OK — rollback completed)
# ============================================================================
ROLLBACK_PHASE="post-rollback"
log_phase "6. Hook post-rollback.sh (fail=WARNING_OK, timeout=$(get_hook_timeout post-rollback)s)"

POST_ROLLBACK_RC=0
run_hook "post-rollback" "${HOOKS_DIR}" || POST_ROLLBACK_RC=$?

if [[ "${POST_ROLLBACK_RC}" -ne 0 ]]; then
  log_warn "post-rollback hook rc=${POST_ROLLBACK_RC} (non-fatal — rollback already complete)"
fi

# ============================================================================
# Phase 7 — Audit log finalize
# ============================================================================
ROLLBACK_PHASE="finalize"
log_phase "7. Audit log finalize"

log_hook_audit "rollback-complete" 0 0 "SUCCESS"
log_ok "Rollback complete — app=${APP_NAME} env=${ENV} target=${PREVIOUS_TAG} (was=${CURRENT_TAG:-unknown})"

if [[ "${DRY_RUN}" == "0" ]]; then
  log_info "Audit log: /var/log/${APP_NAME}/${ENV}/deploys/${A2K_DEPLOY_TIMESTAMP}.log"
fi

ROLLBACK_PHASE="success"
trap - EXIT INT TERM

echo ""
echo "${C_GREEN}========================================================================${C_RESET}"
echo "${C_GREEN}  ✓ ROLLBACK SUCCESS — ${APP_NAME} ${ENV} → ${PREVIOUS_TAG}${C_RESET}"
echo "${C_GREEN}========================================================================${C_RESET}"

exit 0
