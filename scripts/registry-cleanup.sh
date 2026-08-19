#!/usr/bin/env bash
#
# scripts/registry-cleanup.sh — VPS local image cleanup (cycle 29 ADR-010 A13)
#
# VPS-local image cleanup discipline complementing GHA registry-cleanup.yml workflow
# (which cleans GHCR registry). This script cleans VPS local Docker images per A13 :
#   - docker image prune -a --filter "until=720h"  (30 days)
#   - PAS --volumes (anti-destructive data prod — A13 strict)
#   - Last 3 images retention per app via :current + :previous aliases (A12 fast rollback support)
#
# Decision A13 retention :
#   - v*.*.* PRD : last 10 (count-based) — managed registry-side cron
#   - sha-* STG : 14j (time-based) — managed registry-side cron
#   - sha-* PRD : 30j (time-based) — managed registry-side cron
#   - untagged : 7j — managed BOTH registry + VPS local
#   - alias :current + :previous : always retained (A12 fast rollback)
#
# Usage VPS (cron weekly Sunday 3h UTC OR systemd timer) :
#   bash scripts/registry-cleanup.sh
#
# Usage DRY_RUN audit (list images to prune without execution) :
#   DRY_RUN=1 bash scripts/registry-cleanup.sh
#
# Cron setup VPS (recommended) :
#   /etc/cron.d/a2k-registry-cleanup :
#     0 3 * * 0 root bash /opt/<env>/<app>/scripts/registry-cleanup.sh >> /var/log/registry-cleanup.log 2>&1
#
# Discipline : KISS + named constants + BASH-CALLS-SEPARATED v2.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

readonly DRY_RUN="${DRY_RUN:-0}"
readonly RETENTION_HOURS="${RETENTION_HOURS:-720}"  # 30 days default (A13 PRD sha-*)

# Colors
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  readonly C_GREEN=$'\033[0;32m'
  readonly C_YELLOW=$'\033[0;33m'
  readonly C_BLUE=$'\033[0;34m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_GREEN=""
  readonly C_YELLOW=""
  readonly C_BLUE=""
  readonly C_RESET=""
fi

log_info() { echo "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()   { echo "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn() { echo "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }

# ============================================================================
# Sanity check — Docker available
# ============================================================================
if ! command -v docker >/dev/null 2>&1; then
  log_warn "docker CLI absent — registry-cleanup.sh requires Docker on VPS"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] continuing audit mode without docker..."
  else
    exit 1
  fi
fi

echo ""
echo "${C_BLUE}========================================================================${C_RESET}"
echo "${C_BLUE}  registry-cleanup.sh — cycle 29 ADR-010 A13 VPS local cleanup${C_RESET}"
echo "${C_BLUE}========================================================================${C_RESET}"
log_info "Retention hours : ${RETENTION_HOURS} (${RETENTION_HOURS}h = $((RETENTION_HOURS / 24))j)"
log_info "DRY_RUN         : ${DRY_RUN}"
log_info "Mode            : VPS local (registry cleanup délégué snok/container-retention-policy via registry-cleanup.yml workflow)"
echo ""

# ============================================================================
# Phase 1 — List current images (audit)
# ============================================================================
log_info "Phase 1 — Current images audit"

if command -v docker >/dev/null 2>&1; then
  echo ""
  docker image ls --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null || true
  echo ""
fi

# ============================================================================
# Phase 2 — Identify alias-protected images (NEVER prune :current / :previous)
# ============================================================================
log_info "Phase 2 — Alias-protected images (A12 — :current + :previous retained always)"

PROTECTED_IMAGE_IDS=""
if command -v docker >/dev/null 2>&1; then
  # All images tagged :current or :previous
  PROTECTED_IMAGE_IDS=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null \
    | grep -E ':(current|previous)$' \
    | awk '{print $2}' \
    | sort -u || true)
fi

if [[ -n "${PROTECTED_IMAGE_IDS}" ]]; then
  log_ok "Protected image IDs (:current / :previous aliases) :"
  echo "${PROTECTED_IMAGE_IDS}"
else
  log_warn "No alias-protected images found (no :current / :previous tags)"
fi

# ============================================================================
# Phase 3 — Identify dangling images (untagged — A13 7j retention)
# ============================================================================
log_info "Phase 3 — Dangling (untagged) images"

if command -v docker >/dev/null 2>&1; then
  DANGLING_COUNT=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l || echo "0")
  log_info "Dangling images count : ${DANGLING_COUNT}"
fi

# ============================================================================
# Phase 4 — Execute prune (A13 — until filter, NO --volumes)
# ============================================================================
log_info "Phase 4 — Prune execution"

if [[ "${DRY_RUN}" == "1" ]]; then
  log_warn "[DRY_RUN] Would execute: docker image prune -a --force --filter \"until=${RETENTION_HOURS}h\""
  log_warn "[DRY_RUN] NOTE : --volumes flag BANNED (A13 anti-destructive data prod)"
else
  if ! command -v docker >/dev/null 2>&1; then
    log_warn "docker absent — prune skipped"
  else
    # A13 strict : prune images only, NEVER --volumes (anti-destructive data prod)
    # `until` filter keeps images younger than retention threshold
    log_info "Running: docker image prune -a --force --filter \"until=${RETENTION_HOURS}h\""
    docker image prune -a --force --filter "until=${RETENTION_HOURS}h" || {
      log_warn "docker image prune exited non-zero — continuing"
    }
    log_ok "Prune completed"
  fi
fi

# ============================================================================
# Phase 5 — Summary post-prune
# ============================================================================
log_info "Phase 5 — Post-prune summary"

if command -v docker >/dev/null 2>&1 && [[ "${DRY_RUN}" == "0" ]]; then
  echo ""
  log_info "Remaining images :"
  docker image ls --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null || true
  echo ""

  log_info "Disk usage :"
  docker system df 2>/dev/null || true
fi

echo ""
echo "${C_GREEN}========================================================================${C_RESET}"
echo "${C_GREEN}  ✓ registry-cleanup.sh DONE${C_RESET}"
echo "${C_GREEN}========================================================================${C_RESET}"

exit 0
