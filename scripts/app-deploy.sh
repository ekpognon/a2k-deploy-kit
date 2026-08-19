#!/usr/bin/env bash
#
# scripts/app-deploy.sh — Shared deploy core (cycle 29 ADR-010 Famille 1 GHA-native B+C hybride)
#
# Architecture push-and-forget VPS-orchestrator (ADR-004 cycle 12 cohérent) :
#   - GHA = transport-only (scp scripts/ + compose + config → /opt/<env>/<app>/)
#   - VPS = orchestrator local autonome (this script runs LOCALLY on VPS post-scp)
#   - Workflow `bash app-deploy.sh <env> <app_name> <image_tag>` invoked by deploy-app.yml step
#
# Cycle 29 decisions Mode A user 2026-06-22 (ADR-010 A1-A15) :
#   - A2 Famille 1 GHA-native B+C hybride (workflow_call + composite actions)
#   - A5 6 hooks contract : pre-deploy + healthcheck + post-deploy + smoke-test + pre-rollback + post-rollback
#   - A6 11 env vars A2K_* contract (A6 amend Wave 1 cont — cf. lib/env-vars.sh, incl. A2K_REGISTRY_ORG)
#   - A7 File convention discovery <compose_path>/hooks/*.sh executable bash
#   - A8 smoke-test absent → ERROR + abort (discipline qualité enforce V0)
#   - A9 Timeouts per-hook overridable via A2K_HOOK_TIMEOUT_<HOOK>
#   - A10 Fail semantics : 5 NON-overridable + 1 overridable (post-deploy)
#   - A11 Audit log /var/log/<app>/<env>/deploys/<timestamp>.log JSON structured
#   - A12 Rollback strategy in-place + pre-pull last 3 images VPS (~5s rollback fast)
#
# Strict workflow (7 steps) :
#   1. Pré-flight validation (env + compose + Zone 4 secrets + Docker Compose v2 + proxy_net + shared Traefik)
#   2. Discovery hooks <compose_path>/hooks/*.sh (file convention A7)
#   3. Export 11 A2K_* env vars (A6 contract — A6 amend Wave 1 cont incl. A2K_REGISTRY_ORG)
#   4. Pre-pull TARGET_TAG + retain last 3 images backup (A12 fast rollback)
#   5. Sequential hooks invocation : pre-deploy → docker compose pull/up → healthcheck → post-deploy → smoke-test
#   6. Audit log VPS append
#   7. Alias mobile `<app>:current` updated (A12)
#
# Usage VPS (post-scp scripts/) :
#   bash scripts/app-deploy.sh <env> <app_name> <image_tag>
#   bash scripts/app-deploy.sh stg topxpress v1.2.3
#   bash scripts/app-deploy.sh prd soiroke sha-abc123def456
#
# Usage local audit (no execution containers) :
#   DRY_RUN=1 bash scripts/app-deploy.sh stg topxpress sha-test
#
# Discipline : KISS + DRY + named constants + early returns + BASH-CALLS-SEPARATED v2 + bash-ops-specialist AP-1 to AP-15.

set -euo pipefail

# Cycle 37 (ADR-008 amend / ADR-013) — umask 027 : compagnon obligatoire du bit setgid des zones FHS.
# Le setgid propage le GROUPE aux sous-dirs créés par deploy, mais PAS le mode → sans umask un dir
# sortirait 2755 (world-readable). umask 027 force dir 2750 / fichiers 0640 (other=---), enforçant
# least-privilege (ops_discipline §5). Attribut de process hérité par fork/exec → couvre les hooks
# per-app cross-repo sourcés via lib/hooks-runner.sh. Placé après set -euo pipefail, AVANT tout mkdir.
umask 027

# ============================================================================
# Constants
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Image retention discipline (A12) — keep last 3 images backup VPS for fast in-place rollback
readonly RETAIN_IMAGES_COUNT=3

# Mode flags
readonly DRY_RUN="${DRY_RUN:-0}"
readonly VERBOSE="${VERBOSE:-0}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Cycle 12 push-and-forget — phase tracking for trap cleanup + rollback automatic if phase >= swap
DEPLOY_PHASE="init"
ROLLBACK_TRIGGERED=0

# ============================================================================
# Colors (terminal compatible — fallback no-color)
# ============================================================================
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

# ============================================================================
# Logging helpers
# ============================================================================
log_info()  { echo "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { echo "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()  { echo "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error() { echo "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_phase() { echo ""; echo "${C_BLUE}━━━ Phase: $* ━━━${C_RESET}"; }

# ============================================================================
# Trap cleanup (anti-stall + rollback auto if phase >= swap)
# ============================================================================
deploy_cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "Deploy interrupted/failed (rc=${rc}) at phase: ${DEPLOY_PHASE}"
    if [[ "${ROLLBACK_TRIGGERED}" -eq 1 ]]; then
      log_warn "Rollback was triggered — verify state via: docker ps -a | grep ${A2K_APP_NAME:-app}"
    elif [[ "${DEPLOY_PHASE}" == "swap" || "${DEPLOY_PHASE}" == "healthcheck" || "${DEPLOY_PHASE}" == "post-deploy" || "${DEPLOY_PHASE}" == "smoke-test" ]]; then
      log_warn "Phase ${DEPLOY_PHASE} interrupted post-swap — consider rollback: bash ${SCRIPT_DIR}/app-rollback.sh ${A2K_ENV:-?} ${A2K_APP_NAME:-?} ${A2K_PREVIOUS_TAG:-?}"
    fi
    log_warn "Diagnostic: docker ps -a + journalctl -u docker --since '5 minutes ago'"
  fi
  return "${rc}"
}

# R1-W1-11 MED fix (cycle 29 Wave 2 §2.2 — defense-in-depth split trap) :
# Lines 145-219 (validation / regex / source library / docker image inspect previous tag)
# n'étaient pas couvertes par trap (installé ligne ~225 post-export). Window 1-219L pré-export
# unmonitored (R4 L1 accepté V0 set -e direct fail fast, mais split trap renforce diagnostic).
# Pattern : early minimal trap (preflight/validation) → replace with enriched post-export.
deploy_cleanup_early() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "Deploy failed early (rc=${rc}) at phase=${DEPLOY_PHASE} — before A2K_* env vars exported (preflight/validation/library-loading)"
    log_warn "Diagnostic: check args validation OR library presence OR env var format"
  fi
  return "${rc}"
}
# Install MINIMAL early trap (validation/preflight diagnostic).
# Replaced post-export ligne ~225 with enriched deploy_cleanup (references A2K_*).
trap deploy_cleanup_early EXIT INT TERM

# ============================================================================
# Usage / Argument validation
# ============================================================================
usage() {
  cat >&2 <<EOF
${SCRIPT_NAME} — Shared deploy core (cycle 29 ADR-010)

Usage:
  bash ${SCRIPT_NAME} <env> <app_name> <image_tag>

Args:
  env           Environment target : stg | prd
  app_name      App name : topxpress | soiroke | etc.
  image_tag     Container image tag (semver v1.2.3 OR sha-* 40 chars)

Env vars (optional):
  DRY_RUN=1               Audit mode (no container execution)
  VERBOSE=1               Verbose logging
  LOG_LEVEL=DEBUG|INFO    Log level (default INFO)
  A2K_HOOK_TIMEOUT_<HOOK> Override hook timeout (e.g. A2K_HOOK_TIMEOUT_PRE_DEPLOY=900)
  A2K_HOOK_FAIL_BEHAVIOR_POST_DEPLOY=rollback   Override post-deploy fail behavior

Examples:
  bash ${SCRIPT_NAME} stg topxpress v1.2.3
  bash ${SCRIPT_NAME} prd soiroke sha-abc123def456
  DRY_RUN=1 bash ${SCRIPT_NAME} stg topxpress sha-test

Cf. docs/contracts/DEPLOY-APP-INVOKER-GUIDE.md
EOF
  exit 1
}

if [[ $# -lt 3 ]]; then
  usage
fi

readonly ENV="$1"
readonly APP_NAME="$2"
readonly TARGET_TAG="$3"

# Validate env whitelist
case "${ENV}" in
  stg|prd) ;;
  *)
    log_error "env='${ENV}' invalid (expected: stg|prd)"
    exit 1
    ;;
esac

# Validate app_name (DNS-safe + filesystem-safe)
if ! printf '%s' "${APP_NAME}" | grep -qE '^[a-z][a-z0-9_-]{0,63}$'; then
  log_error "app_name='${APP_NAME}' invalid (whitelist ^[a-z][a-z0-9_-]{0,63}$)"
  exit 1
fi

# Validate image_tag (semver / sha / alphanum)
if ! printf '%s' "${TARGET_TAG}" | grep -qE '^[a-zA-Z0-9._-]{1,128}$'; then
  log_error "image_tag='${TARGET_TAG}' invalid (whitelist [a-zA-Z0-9._-]{1,128})"
  exit 1
fi

# Anti :latest discipline (ops_discipline §2 pinned versions exactes)
if [[ "${TARGET_TAG}" == "latest" ]]; then
  log_error "image_tag='latest' BANNED (ops_discipline §2 pinned versions exactes)"
  exit 1
fi

# ============================================================================
# Source libraries (lib/env-vars.sh + lib/hooks-runner.sh)
# ============================================================================
if [[ ! -f "${LIB_DIR}/env-vars.sh" ]]; then
  log_error "Library missing: ${LIB_DIR}/env-vars.sh"
  exit 1
fi
if [[ ! -f "${LIB_DIR}/hooks-runner.sh" ]]; then
  log_error "Library missing: ${LIB_DIR}/hooks-runner.sh"
  exit 1
fi
# shellcheck source=lib/env-vars.sh
. "${LIB_DIR}/env-vars.sh"
# shellcheck source=lib/hooks-runner.sh
. "${LIB_DIR}/hooks-runner.sh"
# shellcheck source=lib/audit-helpers.sh
if [[ -f "${LIB_DIR}/audit-helpers.sh" ]]; then
  . "${LIB_DIR}/audit-helpers.sh"
fi

# ============================================================================
# Discover previous tag for A2K_PREVIOUS_TAG (for hooks + rollback fallback)
# ============================================================================
# Project dir convention /opt/<env>/<app>/
readonly PROJECT_DIR="/opt/${ENV}/${APP_NAME}"
readonly HOOKS_DIR="${PROJECT_DIR}/hooks"
readonly COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

PREVIOUS_TAG=""
if [[ "${DRY_RUN}" == "0" ]] && command -v docker >/dev/null 2>&1; then
  # Convention alias mobile <app>:current points to currently deployed tag
  if PREVIOUS_TAG=$(docker image inspect "${APP_NAME}:current" --format '{{index .RepoTags 0}}' 2>/dev/null); then
    # Strip "<app>:" prefix to keep tag only
    PREVIOUS_TAG="${PREVIOUS_TAG##*:}"
    # If alias points to "current" itself, no previous detected
    if [[ "${PREVIOUS_TAG}" == "current" ]]; then
      PREVIOUS_TAG=""
    fi
  else
    PREVIOUS_TAG=""
  fi
fi

# Export A2K_* contract env vars (A6 — 11 vars, A6 amend Wave 1 cont incl. A2K_REGISTRY_ORG)
export_a2k_env_vars "${APP_NAME}" "${ENV}" "${TARGET_TAG}" "${PREVIOUS_TAG}" "deploy"

# Sub-action 5a Finding G R1F2 (cycle 29 Wave 1 closure 4.5) + R1-W1-11 MED Wave 2 §2.2 :
# trap installed AFTER A2K_* env vars exported so deploy_cleanup diagnostic can reference
# A2K_ENV + A2K_APP_NAME + A2K_PREVIOUS_TAG effectively. Disarm early trap then arm enriched.
#
# Trap installation strategy recap (cycle 29 Wave 2 split — §2.9 residual ACCEPTÉ V0) :
# - Lines 1-78 (init/constants/colors/logging) : set -e direct fail fast (no side-effects
#   pre-export — R4 L1 acceptable V0 — diagnostic minimal trap installed line ~118 below)
# - Line ~118 : early trap deploy_cleanup_early (validation/preflight diagnostic — R1-W1-11)
# - Line ~225 (here) : enriched trap deploy_cleanup post-export A2K_* references
# Cf. R4 L1 §2.9 acceptable V0 + R1-W1-11 MED fix Wave 2 §2.2 defense-in-depth split.
trap - EXIT INT TERM
trap deploy_cleanup EXIT INT TERM

# ============================================================================
# Print header
# ============================================================================
echo ""
echo "${C_BLUE}========================================================================${C_RESET}"
echo "${C_BLUE}  app-deploy.sh — cycle 29 ADR-010 shared deploy core${C_RESET}"
echo "${C_BLUE}========================================================================${C_RESET}"
log_info "Env          : ${ENV}"
log_info "App          : ${APP_NAME}"
log_info "Target tag   : ${TARGET_TAG}"
log_info "Previous tag : ${PREVIOUS_TAG:-(none — first deploy)}"
log_info "Project dir  : ${PROJECT_DIR}"
log_info "Hooks dir    : ${HOOKS_DIR}"
log_info "DRY_RUN      : ${DRY_RUN}"
log_info "Timestamp    : ${A2K_DEPLOY_TIMESTAMP}"
echo ""

# ============================================================================
# Phase 1 — Pré-flight validation
# ============================================================================
DEPLOY_PHASE="preflight"
log_phase "1. Pré-flight validation"

# Project dir
if [[ ! -d "${PROJECT_DIR}" ]]; then
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] PROJECT_DIR ${PROJECT_DIR} absent (expected on VPS post-scp)"
  else
    log_error "PROJECT_DIR ${PROJECT_DIR} absent"
    log_error "Trigger upstream: gh workflow run provision-app.yml env=${ENV} app_name=${APP_NAME} dry_run=false"
    exit 1
  fi
fi

# Compose file
if [[ -f "${COMPOSE_FILE}" ]]; then
  log_ok "docker-compose.yml present: ${COMPOSE_FILE}"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] docker-compose.yml absent (expected post-scp by deploy-app.yml workflow)"
  else
    log_error "docker-compose.yml absent: ${COMPOSE_FILE}"
    exit 1
  fi
fi

# Zone 4 secrets (A2K_SECRETS_FILE)
if [[ -f "${A2K_SECRETS_FILE}" ]]; then
  log_ok "Zone 4 secrets present: ${A2K_SECRETS_FILE}"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] Zone 4 secrets absent (expected on VPS — provision via provision-app.yml)"
  else
    log_error "Zone 4 secrets absent: ${A2K_SECRETS_FILE}"
    log_error "Trigger upstream: gh workflow run provision-app.yml env=${ENV} app_name=${APP_NAME}"
    exit 1
  fi
fi

# Docker Compose v2
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    log_ok "Docker Compose v2 present: $(docker compose version --short 2>/dev/null || echo 'unknown')"
  else
    log_error "Docker Compose v2 plugin missing — install via Ansible role 'docker'"
    [[ "${DRY_RUN}" == "1" ]] || exit 1
  fi
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] docker CLI absent (expected on dev host)"
  else
    log_error "docker CLI absent"
    exit 1
  fi
fi

# proxy_net network (shared Traefik dependency)
if [[ "${DRY_RUN}" == "0" ]] && command -v docker >/dev/null 2>&1; then
  if docker network inspect proxy_net >/dev/null 2>&1; then
    log_ok "proxy_net network present"
  else
    log_error "proxy_net network absent — shared Traefik dependency"
    log_error "Trigger upstream: gh workflow run infra-bootstrap-vps.yml env=${ENV} dry_run=false"
    exit 1
  fi
fi

# shared Traefik container running
if [[ "${DRY_RUN}" == "0" ]] && command -v docker >/dev/null 2>&1; then
  if docker ps --filter "name=traefik-${ENV}" --filter "status=running" --format '{{.Names}}' | grep -q "traefik-${ENV}"; then
    log_ok "traefik-${ENV} container running"
  else
    log_error "traefik-${ENV} container NOT running"
    log_error "Trigger upstream: gh workflow run deploy.yml (a2k-shared-infra) env=${ENV}"
    exit 1
  fi
fi

# ============================================================================
# Phase 2 — Discovery hooks (file convention A7)
# ============================================================================
DEPLOY_PHASE="discover-hooks"
log_phase "2. Discovery hooks (file convention A7)"

HOOKS_FOUND=""
if [[ -d "${HOOKS_DIR}" ]]; then
  HOOKS_FOUND="$(discover_hooks "${HOOKS_DIR}")"
  if [[ -n "${HOOKS_FOUND}" ]]; then
    log_ok "Hooks found: ${HOOKS_FOUND}"
  else
    log_warn "Hooks dir ${HOOKS_DIR} exists but no hooks found"
  fi
else
  log_warn "Hooks dir absent: ${HOOKS_DIR}"
fi

# A8 — smoke-test.sh OBLIGATOIRE V0 (enforce discipline qualité)
if [[ ! -f "${HOOKS_DIR}/smoke-test.sh" ]]; then
  log_error "smoke-test.sh OBLIGATOIRE V0 (decision A8) — ${HOOKS_DIR}/smoke-test.sh absent"
  log_error "Apps DOIVENT fournir smoke-test.sh V0 (discipline qualité enforce)"
  log_error "Cf. docs/contracts/DEPLOY-APP-INVOKER-GUIDE.md § Smoke-test obligatoire V0 (A8)"
  exit 1
fi

# ============================================================================
# Phase 3 — Pre-pull TARGET image + retain last 3 images (A12 fast rollback)
# ============================================================================
DEPLOY_PHASE="pre-pull"
log_phase "3. Pre-pull TARGET image + retain last ${RETAIN_IMAGES_COUNT} images (A12)"

# A12 fast rollback enablement : pre-pull TARGET image + last 2 backup tags (cycle 29 Wave 1 fix Finding A)
REGISTRY_HOST="$(get_registry 2>/dev/null || echo 'ghcr.io')"
REGISTRY_ORG="$(get_org 2>/dev/null || echo 'ekpognon')"  # cycle 29 Wave 1 cont sub-action 7 — default canonical Mode A user 2026-06-22

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "[DRY_RUN] Would pre-pull: ${REGISTRY_HOST}/${REGISTRY_ORG}/${APP_NAME}:${TARGET_TAG} + last 2 backup tags"
  log_info "[DRY_RUN] Retention discipline: ${RETAIN_IMAGES_COUNT} images pre-pulled (A12 fast rollback enabled)"
else
  # Pre-pull TARGET image + retention (A12 fast rollback — empirical Sub-action 1 fix Finding A R1F3+R2H3+R3S3+R4F3 quadruple consensus)
  THIRD_LAST_TAG=""
  if declare -F get_third_last_tag >/dev/null 2>&1; then
    THIRD_LAST_TAG="$(get_third_last_tag "${APP_NAME}" "${REGISTRY_HOST}" "${REGISTRY_ORG}" 2>/dev/null || echo '')"
  fi

  for tag_to_pull in "${TARGET_TAG}" "${PREVIOUS_TAG:-}" "${THIRD_LAST_TAG}"; do
    # Skip empty + skip alias mobile reserved names
    [[ -n "${tag_to_pull}" && "${tag_to_pull}" != "current" && "${tag_to_pull}" != "previous" ]] || continue
    # R1-W1-02 MED fix (cycle 29 Wave 2 §2.2) : preserve stderr diagnostic in log_warn
    # Pattern : capture stderr while suppressing stdout, propagate diagnostic on failure.
    # AP-1 negative `if ! cmd` natif PAS de capture $? après négation — pattern safe.
    PULL_ERR=""
    if ! PULL_ERR="$(docker pull "${REGISTRY_HOST}/${REGISTRY_ORG}/${APP_NAME}:${tag_to_pull}" 2>&1 1>/dev/null)"; then
      log_warn "Pre-pull ${tag_to_pull} failed (best-effort A12 retention): ${PULL_ERR}"
    fi
  done
  log_info "Retention discipline: ${RETAIN_IMAGES_COUNT} images pre-pulled (A12 fast rollback enabled)"
fi

# ============================================================================
# Phase 4 — pre-deploy hook (with Sub-action 5c B1 enforcement runtime)
# ============================================================================
DEPLOY_PHASE="pre-deploy"
log_phase "4. Hook pre-deploy.sh (fail=ABORT, timeout=$(get_hook_timeout pre-deploy)s)"

# Sub-action 5c Finding F R4F4 (cycle 29 Wave 1 closure 4.5) :
# ADR-011 B1 forward-only strict cross-env enforcement runtime (defense-in-depth doc-as-code).
# Anti-pattern banni : migrate:rollback / migrate:reset / migrate:down / liquibase rollback dans pre-deploy.sh
#
# Affinement cycle 29 Wave 2 §2.6 (R3 S-10 MED + R4 M2 MED + R1-W1-06 LOW consolidé) :
# 1. Line-filtered : skip lignes commentaires (^[[:space:]]*#) — élimine false-positive R4 M2 + R1-W1-06
# 2. Élargi colon : `liquibase[[:space:]:]+rollback` catches `mvn liquibase:rollback` R3 S-10
# 3. Élargi pattern explicit : `mvn[[:space:]:]+liquibase[[:space:]:]+rollback`
#
# Trust boundary : pre-deploy.sh = app-controlled hook content (internal dev trust).
# False-negatives résiduels (env indirection $ROLLBACK_CMD / aliases / custom ./db-rollback.sh)
# acceptés V0 best-effort runtime — ADR-011 doc-as-code = PRIMARY defense pipeline qualité reviewers.
if [[ -f "${HOOKS_DIR}/pre-deploy.sh" ]]; then
  # Filter out commented lines BEFORE applying regex pattern (anti false-positive R4 M2 + R1-W1-06)
  if grep -vE '^[[:space:]]*#' "${HOOKS_DIR}/pre-deploy.sh" \
       | grep -qE '(migrate:(rollback|reset|down)|liquibase[[:space:]:]+rollback|mvn[[:space:]:]+liquibase[[:space:]:]+rollback)'; then
    log_error "ADR-011 B1 VIOLATION: forward-only strict cross-env enforcement"
    log_error "  Détecté pattern interdit (non-commented line) dans : ${HOOKS_DIR}/pre-deploy.sh"
    log_error "  Patterns bannis : migrate:(rollback|reset|down) | liquibase[:space:]rollback | mvn liquibase:rollback"
    log_error "  Référence : docs/decisions-architecture.md § ADR-011 § B1 Forward-only strict"
    log_error "  Migration policy : Expand-Contract pattern (forward-only) — pas de rollback DB"
    exit 1
  fi
fi

if ! run_hook "pre-deploy" "${HOOKS_DIR}"; then
  log_error "pre-deploy hook failed (fail_behavior=ABORT)"
  exit 1
fi

# ============================================================================
# Phase 5 — docker compose pull + up -d --force-recreate (the swap)
# ============================================================================
DEPLOY_PHASE="swap"
log_phase "5. docker compose pull + up -d --force-recreate"

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "[DRY_RUN] Would execute: cd ${PROJECT_DIR}"
  log_info "[DRY_RUN] Would execute: docker compose pull"
  log_info "[DRY_RUN] Would execute: docker compose up -d --force-recreate"
else
  # R1-W1-07 LOW fix (cycle 29 Wave 2 §2.2) : cd subshell guard
  # Defense-in-depth bash AP-12 : isolate cd to subshell to prevent directory state
  # leak if script ever sourced. cd failure exit 1 explicit (fail-fast).
  (
    cd "${PROJECT_DIR}" || { log_error "cd ${PROJECT_DIR} FAILED"; exit 1; }
    log_info "Pulling images..."
    docker compose pull
    log_info "Bringing up services (--force-recreate)..."
    docker compose up -d --force-recreate
    log_ok "docker compose up OK"
  )
fi

# ============================================================================
# Phase 6 — healthcheck hook (fail=ROLLBACK)
# ============================================================================
DEPLOY_PHASE="healthcheck"
log_phase "6. Hook healthcheck.sh (fail=ROLLBACK, timeout=$(get_hook_timeout healthcheck)s)"

HEALTHCHECK_RC=0
run_hook "healthcheck" "${HOOKS_DIR}" || HEALTHCHECK_RC=$?

if [[ "${HEALTHCHECK_RC}" -eq 2 ]]; then
  log_error "healthcheck hook failed (fail_behavior=ROLLBACK) — triggering rollback"
  ROLLBACK_TRIGGERED=1
  if [[ -n "${PREVIOUS_TAG}" ]]; then
    log_warn "Triggering rollback to previous tag: ${PREVIOUS_TAG}"
    bash "${SCRIPT_DIR}/app-rollback.sh" "${ENV}" "${APP_NAME}" "${PREVIOUS_TAG}" || true
  else
    log_error "No previous tag available — manual intervention required"
  fi
  exit 1
elif [[ "${HEALTHCHECK_RC}" -ne 0 ]]; then
  log_error "healthcheck hook failed (rc=${HEALTHCHECK_RC})"
  exit "${HEALTHCHECK_RC}"
fi

# ============================================================================
# Phase 7 — post-deploy hook (default WARNING_CONTINUE, overridable to ROLLBACK)
# ============================================================================
DEPLOY_PHASE="post-deploy"
log_phase "7. Hook post-deploy.sh (fail=$(get_hook_fail_behavior post-deploy), timeout=$(get_hook_timeout post-deploy)s)"

POST_DEPLOY_RC=0
run_hook "post-deploy" "${HOOKS_DIR}" || POST_DEPLOY_RC=$?

if [[ "${POST_DEPLOY_RC}" -eq 2 ]]; then
  log_error "post-deploy hook failed (fail_behavior=ROLLBACK via override) — triggering rollback"
  ROLLBACK_TRIGGERED=1
  if [[ -n "${PREVIOUS_TAG}" ]]; then
    bash "${SCRIPT_DIR}/app-rollback.sh" "${ENV}" "${APP_NAME}" "${PREVIOUS_TAG}" || true
  fi
  exit 1
elif [[ "${POST_DEPLOY_RC}" -ne 0 ]]; then
  log_warn "post-deploy hook returned rc=${POST_DEPLOY_RC} (non-fatal per fail_behavior)"
fi

# ============================================================================
# Phase 8 — smoke-test hook (fail=ROLLBACK)
# ============================================================================
DEPLOY_PHASE="smoke-test"
log_phase "8. Hook smoke-test.sh (fail=ROLLBACK, timeout=$(get_hook_timeout smoke-test)s)"

SMOKE_RC=0
run_hook "smoke-test" "${HOOKS_DIR}" || SMOKE_RC=$?

if [[ "${SMOKE_RC}" -eq 2 ]]; then
  log_error "smoke-test hook failed (fail_behavior=ROLLBACK) — triggering rollback"
  ROLLBACK_TRIGGERED=1
  if [[ -n "${PREVIOUS_TAG}" ]]; then
    bash "${SCRIPT_DIR}/app-rollback.sh" "${ENV}" "${APP_NAME}" "${PREVIOUS_TAG}" || true
  fi
  exit 1
elif [[ "${SMOKE_RC}" -ne 0 ]]; then
  log_error "smoke-test hook failed (rc=${SMOKE_RC})"
  exit "${SMOKE_RC}"
fi

# ============================================================================
# Phase 9 — Alias mobile <app>:current + <app>:previous (A12 retention)
# ============================================================================
DEPLOY_PHASE="alias-rotation"
log_phase "9. Alias mobile <app>:current → ${TARGET_TAG} (A12)"

if [[ "${DRY_RUN}" == "1" ]]; then
  log_info "[DRY_RUN] Would rotate aliases: ${APP_NAME}:current → ${TARGET_TAG} + ${APP_NAME}:previous → ${PREVIOUS_TAG:-(none)}"
  log_info "[DRY_RUN] Would prune images older than ${RETAIN_IMAGES_COUNT} latest (keep :current + :previous)"
else
  # A12 effective alias rotation (cycle 29 Wave 1 fix Finding A — Mode A user décision 2026-06-22)
  REGISTRY_HOST="$(get_registry 2>/dev/null || echo 'ghcr.io')"
  REGISTRY_ORG="$(get_org 2>/dev/null || echo 'ekpognon')"  # cycle 29 Wave 1 cont sub-action 7 — default canonical Mode A user 2026-06-22
  ALIAS_SOURCE="${REGISTRY_HOST}/${REGISTRY_ORG}/${APP_NAME}:${TARGET_TAG}"

  # REGDOCK 2026-08-18 (G2) — rotation TOLÉRANTE multi-org/multi-images.
  # La rotation d'alias suppose la convention mono-image <registry>/<org>/<app_name>:<tag>.
  # Apps multi-images (images ≠ <org>/<app_name>, e.g. etatcivil-{backend,web}) : la source
  # du `docker tag` n'existe pas localement → WARN + skip rotation (rc 0). JAMAIS exit 1 ici :
  # à cette phase le deploy est DÉJÀ un succès (Phases 5-8 GREEN) — un échec de rotation
  # d'alias de commodité ne doit pas produire un run rouge + rollback legacy spurieux.
  # Conséquence assumée (documentée DEPLOY-APP-INVOKER-GUIDE § A2K_REGISTRY_ORG) :
  # A2K_PREVIOUS_TAG restera vide pour ces apps (détection alias <app>:current impossible)
  # → rollback multi-images = tag explicite via rollback-app.yml (previous_tag arg).
  if ! docker image inspect "${ALIAS_SOURCE}" >/dev/null 2>&1; then
    log_warn "Alias rotation SKIPPED — source ${ALIAS_SOURCE} absente localement (deploy reste SUCCESS)"
    log_warn "  Cause probable : app multi-images (images ≠ <org>/<app_name>) OU org registry incorrecte"
    log_warn "  Vérifier : var repo caller A2K_REGISTRY_ORG (org résolue : ${REGISTRY_ORG}) — cf. DEPLOY-APP-INVOKER-GUIDE § A2K_REGISTRY_ORG"
    log_warn "  Impact : A2K_PREVIOUS_TAG vide au prochain deploy — rollback = tag explicite (rollback-app.yml)"
    log_hook_audit "alias-rotation-skipped" 0 0 "warn"
  else
    # Rotate alias mobile <app>:previous ← previous TAG (preserve fast rollback target)
    if [[ -n "${PREVIOUS_TAG:-}" ]]; then
      docker tag "${REGISTRY_HOST}/${REGISTRY_ORG}/${APP_NAME}:${PREVIOUS_TAG}" "${APP_NAME}:previous" 2>/dev/null \
        || log_warn "tag ${APP_NAME}:previous failed (PREVIOUS_TAG=${PREVIOUS_TAG}) — non-blocking"
    fi

    # Rotate alias mobile <app>:current ← TARGET_TAG (new active deployment)
    # R1-W1-03 HIGH fix (cycle 29 Wave 1 it-2) : escalate failure :current = fail-fast
    # Empirique : `|| log_warn` swallowed failure → script continue success malgré rotation cassée
    # → prochain deploy lit :current obsolète → PREVIOUS_TAG detection wrong → rollback target WRONG.
    # :current = source vérité rollback (A12) — failure NON tolérée.
    # :previous reste warning-only (degradation gracieuse — rollback CLI fallback PREVIOUS_TAG explicit arg).
    # REGDOCK : exit 1 PRÉSERVÉ ici — la source EXISTE (guard ci-dessus) donc un échec de
    # `docker tag` = vraie panne docker sur une app mono-image (invariant R1-W1-03 intact).
    if ! docker tag "${ALIAS_SOURCE}" "${APP_NAME}:current" 2>/dev/null; then
      log_error "tag ${APP_NAME}:current FAILED (TARGET_TAG=${TARGET_TAG}) — A12 rollback CASSÉ"
      log_error "Prochain deploy lira alias :current obsolète → rollback target WRONG"
      log_error "Cf. ADR-010 § A12 — alias :current = source vérité rollback PREVIOUS_TAG detection"
      log_error "  Context: TARGET_TAG=${TARGET_TAG} REGISTRY=${REGISTRY_HOST}/${REGISTRY_ORG}/${APP_NAME}"
      # F-NEW-2 MED-obs fix (cycle 29 Wave 2 §2.2) : 4e arg = fail_behavior sémantique
      # ("abort" / "warn" / "rollback") — PAS contexte TARGET_TAG. Contexte → log_error dédié ci-dessus.
      log_hook_audit "alias-rotation-current-fail" 1 0 "abort"
      exit 1
    fi
    log_info "Alias rotated: ${APP_NAME}:current → ${TARGET_TAG} + ${APP_NAME}:previous → ${PREVIOUS_TAG:-(none)}"

    # Retention pruning : keep last RETAIN_IMAGES_COUNT + :current + :previous (idempotent)
    if declare -F prune_old_images >/dev/null 2>&1; then
      prune_old_images "${APP_NAME}" "${REGISTRY_HOST}" "${REGISTRY_ORG}" "${RETAIN_IMAGES_COUNT}"
      log_info "Retention pruning OK (kept last ${RETAIN_IMAGES_COUNT} + :current + :previous)"
    fi
  fi
fi

# ============================================================================
# Phase 10 — Final audit log entry
# ============================================================================
DEPLOY_PHASE="finalize"
log_phase "10. Audit log finalize"

log_hook_audit "deploy-complete" 0 0 "SUCCESS"
log_ok "Deploy complete — app=${APP_NAME} env=${ENV} tag=${TARGET_TAG}"

if [[ "${DRY_RUN}" == "0" ]]; then
  log_info "Audit log: /var/log/${APP_NAME}/${ENV}/deploys/${A2K_DEPLOY_TIMESTAMP}.log"
fi

# Disarm trap (successful exit)
DEPLOY_PHASE="success"
trap - EXIT INT TERM

echo ""
echo "${C_GREEN}========================================================================${C_RESET}"
echo "${C_GREEN}  ✓ DEPLOY SUCCESS — ${APP_NAME} ${ENV} ${TARGET_TAG}${C_RESET}"
echo "${C_GREEN}========================================================================${C_RESET}"

exit 0
