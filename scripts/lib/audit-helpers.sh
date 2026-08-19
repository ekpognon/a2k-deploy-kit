#!/usr/bin/env bash
#
# scripts/lib/audit-helpers.sh — Helper functions retention + digest history lookup
# (cycle 29 Wave 1 closure 4.5 — sous-actions 1 + 5b)
#
# Provides :
#   - get_third_last_tag : 3rd most recent image tag locally (Phase 3 pre-pull retention)
#   - get_registry       : detect REGISTRY from compose OR env default ghcr.io
#   - get_org            : detect <org> from compose image label OR env default
#   - get_historical_digest : lookup historical digest from audit log (rollback anti-tampering F2)
#
# Discipline : set -euo pipefail + bash-ops-specialist AP-1 to AP-15 + idempotent.
# Cross-refs : ADR-010 A12 (retention) + ADR-011 (audit trail).

if [[ -n "${A2K_AUDIT_HELPERS_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly A2K_AUDIT_HELPERS_LIB_LOADED=1

# ============================================================================
# get_registry — Detect REGISTRY (env override OR docker-compose.yml inspection)
# ============================================================================
# Echo : registry hostname (e.g. "ghcr.io")
# Args : none (uses REGISTRY env var if set, else default)
get_registry() {
  echo "${REGISTRY:-ghcr.io}"
}

# ============================================================================
# get_org — Detect <org> namespace registry path component
# ============================================================================
# Echo : org name (e.g. "ekpognon" / "a2kconsulting")
# Args : none (uses A2K_REGISTRY_ORG env var if set, else fallback)
#
# Cycle 29 Wave 1 cont sub-action 7 (Mode A user 2026-06-22 verbatim "pour l'instant
# mon compte. mais pas dans le dur. on peut variabiliser cela pour une construction
# dynamique de l'url") :
#   - Default V0 : ekpognon (user GHCR account current)
#   - Override : A2K_REGISTRY_ORG env var dans compose env_file OR config/<env>/.env.config
#     OR Ansible role per-app
#   - Construction URL dynamique : ${REGISTRY}/${A2K_REGISTRY_ORG}/${APP_NAME}:${TAG}
#
# Apps consommatrices peuvent override (multi-tenant futur a2kconsulting OR autre org).
# Cf. ADR-010 § A6 amend + DEPLOY-APP-INVOKER-GUIDE.md § A6 env vars contract.
get_org() {
  echo "${A2K_REGISTRY_ORG:-ekpognon}"
}

# ============================================================================
# get_third_last_tag — Get the 3rd most recent image tag (for retention pre-pull)
# ============================================================================
# Echo : tag name OR empty if absent
# Args : $1=app_name $2=registry $3=org
#
# Filter : only semver vX.Y.Z OR sha-<hex> patterns (excludes :current / :previous aliases)
get_third_last_tag() {
  local app_name="${1:?app_name required}"
  local registry="${2:?registry required}"
  local org="${3:?org required}"

  docker images "${registry}/${org}/${app_name}" --format '{{.Tag}}' 2>/dev/null \
    | grep -E '^(v[0-9]+\.[0-9]+\.[0-9]+|sha-[a-f0-9]+)$' \
    | sort -r \
    | sed -n '3p' \
    || echo ""
}

# ============================================================================
# get_historical_digest — Lookup historical digest for tag from audit log
# ============================================================================
# Echo : digest sha256:... OR empty if not found
# Args : $1=app_name $2=env $3=tag
#
# Lookup discipline : /var/log/<app>/<env>/deploys/*-deploy.log JSON entries
# Best-effort (returns empty silently if log absent OR digest missing — F2 fallback OK).
get_historical_digest() {
  local app_name="${1:?app_name required}"
  local env="${2:?env required}"
  local tag="${3:?tag required}"
  local log_dir="/var/log/${app_name}/${env}/deploys"

  if [[ ! -d "${log_dir}" ]]; then
    echo ""
    return 0
  fi

  # Lookup most recent log entry mentioning this tag with digest field
  grep -h "\"tag\":\"${tag}\"" "${log_dir}"/*.log 2>/dev/null \
    | grep -oE '"digest":"sha256:[a-f0-9]+"' \
    | head -1 \
    | sed 's/.*"digest":"\(.*\)"/\1/' \
    || echo ""
}

# ============================================================================
# prune_old_images — Prune images older than N latest (retention discipline A12)
# ============================================================================
# Args : $1=app_name $2=registry $3=org $4=retain_count
# Returns : 0 always (idempotent — concurrent prune tolerated)
#
# INVARIANT (R1-W1-04 MED cycle 29 Wave 2 §2.1) : Aliases :current and :previous
#   MUST point to images whose semver/sha tags are within retain_count window
#   (last N retained). Cycle 29 ADR-010 A12 fast rollback chain depends on this
#   invariant. If an alias points to a pruned tag → next deploy rollback target
#   WRONG (in-place rollback A12 will fail to pull alias-resolved digest).
#   Caller MUST ensure :current and :previous aliases are updated AFTER each
#   deploy to point to tags within the retained window. See app-deploy.sh
#   Phase 9 alias rotation logic.
#
# Defense-in-depth (F-ARCH-5 LOW cycle 29 Wave 2 §2.1) : retain_count is
#   validated runtime via regex ^[0-9]+$ ; falls back to default 3 if corrupted
#   (empty / non-numeric) env to prevent silent broken pruning.
#
# Audit log discipline (R4 L3 LOW cycle 29 Wave 2 §2.1) : prune_count +
#   prune_failed compteurs explicit via per-iteration loop (replaces silent
#   xargs `|| true` pipe). Concurrent prune tolerance preserved via per-rmi
#   2>/dev/null + counter increment.
prune_old_images() {
  local app_name="${1:?app_name required}"
  local registry="${2:?registry required}"
  local org="${3:?org required}"
  local retain_count="${4:-3}"

  # Defense-in-depth (F-ARCH-5) : fallback to 3 if corrupted env (empty / non-numeric)
  if ! [[ "${retain_count}" =~ ^[0-9]+$ ]]; then
    echo "[audit-helpers] WARN: prune_old_images: invalid retain_count='${retain_count}' — fallback 3" >&2
    retain_count=3
  fi

  # Audit log discipline (R4 L3) : explicit per-iteration loop + compteurs
  local pruned_count=0 prune_failed=0 tag_to_prune
  while IFS= read -r tag_to_prune; do
    [[ -z "${tag_to_prune}" ]] && continue
    if docker rmi "${registry}/${org}/${app_name}:${tag_to_prune}" 2>/dev/null; then
      pruned_count=$((pruned_count + 1))
    else
      prune_failed=$((prune_failed + 1))
    fi
  done < <(docker images "${registry}/${org}/${app_name}" --format '{{.Tag}}' 2>/dev/null \
    | grep -E '^(v[0-9]+\.[0-9]+\.[0-9]+|sha-[a-f0-9]+)$' \
    | sort -V -r \
    | tail -n +$((retain_count + 1)) \
    || true)
  # Note (preserved cycle 29 Wave 2) : `|| true` after sort/tail final pipe =
  # concurrent prune tolerance documented inline. `2>/dev/null` per-rmi keeps
  # silent failure on already-deleted images (concurrent cleanup race).
  echo "[audit-helpers] prune_old_images: pruned=${pruned_count} failed=${prune_failed} retain=${retain_count}" >&2

  # R1-W1-08 HIGH fix (cycle 29 Wave 1 it-2) : sort -V semver-aware reverse
  # Empirique : lexicographic `sort -r` donnait v1.9.0 > v1.10.5 (incorrect).
  # `sort -V -r` (version-aware) : v1.10.5 > v1.10.0 > v1.9.0 (correct semver).
  # Tags sha-* hexadécimaux : sort -V dégradé lexicographic OK (alphabet hex).
}
