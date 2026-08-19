#!/usr/bin/env bash
#
# scripts/lib/env-vars.sh — Library export 11 vars A2K_* contract (cycle 29 A6 amend Wave 1 cont)
#
# Exports the 11 standardized A2K_* env vars consumed by per-app hooks via file convention
# discovery (cycle 29 ADR-010, decision A6 + amend Wave 1 cont sub-action 7 2026-06-22).
#
# Contract (11 vars — amend cycle 29 Wave 1 cont sub-action 7 ADD A2K_REGISTRY_ORG) :
#   1. A2K_APP_NAME              — e.g. "topxpress" / "soiroke"
#   2. A2K_ENV                   — e.g. "stg" / "prd"
#   3. A2K_IMAGE_TAG             — target image tag (semver v1.2.3 OR sha-* 40 chars)
#   4. A2K_PREVIOUS_TAG          — previous deployed tag (empty for first deploy)
#   5. A2K_PROJECT_DIR           — absolute path /opt/<env>/<app>
#   6. A2K_SECRETS_FILE          — Zone 4 path /etc/<app>/<env>/.env.secrets
#   7. A2K_ACTION                — "deploy" | "rollback" | "backup"
#   8. A2K_DEPLOY_TIMESTAMP      — ISO UTC YYYYMMDDTHHMMSSZ
#   9. A2K_DRY_RUN               — "0" | "1"
#  10. A2K_LOG_LEVEL             — "DEBUG" | "INFO" | "WARN" | "ERROR"
#  11. A2K_REGISTRY_ORG          — registry org namespace (default "ekpognon", override compose
#                                  env_file OR config/<env>/.env.config OR Ansible role per-app)
#                                  → construction URL dynamique : ${REGISTRY}/${A2K_REGISTRY_ORG}/${APP_NAME}:${TAG}
#
# Whitelist regex anti-injection : ^[a-z][a-z0-9_-]{0,63}$ (DNS-safe + filesystem-safe).
# Defense-in-depth : validation runtime au boot via grep -qE pattern.
#
# Discipline : set -euo pipefail + named constants + AP-1 to AP-15 bash-ops-specialist.
# Cross-refs : ADR-010 A6 amend + DEPLOY-APP-INVOKER-GUIDE.md § Env vars A2K_* contract.

# Idempotent guard — prevent double-sourcing.
if [[ -n "${A2K_ENV_VARS_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly A2K_ENV_VARS_LIB_LOADED=1

# ============================================================================
# a2k_validate_and_export_registry_org — Helper interne (DRY backup-v0 T1 L1.3)
# ============================================================================
# Cycle 29 Wave 1 cont sub-action 7 (Mode A user 2026-06-22) :
# A2K_REGISTRY_ORG = 11e var A6 amend. Default "ekpognon" canonical user GHCR account.
# Override possible via config/<env>/.env.config OR compose env_file OR Ansible role per-app.
# Whitelist regex anti-injection (DNS-safe + filesystem-safe) AVANT export.
# Factorisé (backup-v0 T1) : consommé par export_a2k_env_vars + export_a2k_backup_env_vars.
a2k_validate_and_export_registry_org() {
  local registry_org="${A2K_REGISTRY_ORG:-ekpognon}"
  if ! printf '%s' "${registry_org}" | grep -qE '^[a-z][a-z0-9_-]{0,63}$'; then
    echo "[ERROR] a2k_validate_and_export_registry_org: A2K_REGISTRY_ORG='${registry_org}' invalid (whitelist ^[a-z][a-z0-9_-]{0,63}$)" >&2
    return 1
  fi
  export A2K_REGISTRY_ORG="${registry_org}"
}

# ============================================================================
# export_a2k_env_vars — Export 11 A2K_* contract env vars (A6 amend Wave 1 cont — incl. A2K_REGISTRY_ORG validation runtime)
# ============================================================================
# Args : $1=app_name $2=env $3=image_tag $4=previous_tag $5=action
# Auto-detected : project_dir, secrets_file, timestamp, dry_run, log_level
export_a2k_env_vars() {
  local app_name="${1:?app_name required}"
  local env="${2:?env required}"
  local image_tag="${3:?image_tag required}"
  local previous_tag="${4:-}"
  local action="${5:?action required (deploy|rollback|backup)}"

  # Validate action whitelist (backup-v0 T1 L1.3 : enum étendu deploy|rollback|backup —
  # propreté sémantique pour futur appelant générique ; app-backup.sh utilise la variante
  # dédiée export_a2k_backup_env_vars ci-dessous, PAS cette fonction avec image_tag bidon)
  case "${action}" in
    deploy|rollback|backup) ;;
    *)
      echo "[ERROR] export_a2k_env_vars: action='${action}' invalid (deploy|rollback|backup)" >&2
      return 1
      ;;
  esac

  export A2K_APP_NAME="${app_name}"
  export A2K_ENV="${env}"
  export A2K_IMAGE_TAG="${image_tag}"
  export A2K_PREVIOUS_TAG="${previous_tag}"
  export A2K_PROJECT_DIR="/opt/${env}/${app_name}"
  export A2K_SECRETS_FILE="/etc/${app_name}/${env}/.env.secrets"
  export A2K_ACTION="${action}"
  export A2K_DEPLOY_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  export A2K_DRY_RUN="${DRY_RUN:-0}"
  export A2K_LOG_LEVEL="${LOG_LEVEL:-INFO}"

  # A2K_REGISTRY_ORG (11e var A6 amend) — validation + export via helper factorisé
  # (cf. a2k_validate_and_export_registry_org ci-dessus).
  a2k_validate_and_export_registry_org
}

# ============================================================================
# export_a2k_backup_env_vars — Variante backup du contract A2K_* (backup-v0 T1 L1.3)
# ============================================================================
# Args : $1=app_name $2=env
# Variante DÉDIÉE consommée par scripts/app-backup.sh — PAS de placeholder image_tag bidon
# dans export_a2k_env_vars (dont ${3:?} exige un image_tag que le backup n'a pas).
# A2K_IMAGE_TAG / A2K_PREVIOUS_TAG exportés vides (contrat 11 vars préservé pour les
# consommateurs génériques type log_hook_audit qui lisent A2K_ACTION/A2K_DEPLOY_TIMESTAMP).
export_a2k_backup_env_vars() {
  local app_name="${1:?app_name required}"
  local env="${2:?env required}"

  export A2K_APP_NAME="${app_name}"
  export A2K_ENV="${env}"
  export A2K_IMAGE_TAG=""
  export A2K_PREVIOUS_TAG=""
  export A2K_PROJECT_DIR="/opt/${env}/${app_name}"
  export A2K_SECRETS_FILE="/etc/${app_name}/${env}/.env.secrets"
  export A2K_ACTION="backup"
  export A2K_DEPLOY_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  export A2K_DRY_RUN="${DRY_RUN:-0}"
  export A2K_LOG_LEVEL="${LOG_LEVEL:-INFO}"

  # A2K_REGISTRY_ORG — même whitelist regex que deploy/rollback (helper factorisé).
  a2k_validate_and_export_registry_org
}

# ============================================================================
# print_a2k_env_vars — Debug helper, print exported vars
# ============================================================================
print_a2k_env_vars() {
  echo "[A2K env vars] APP=${A2K_APP_NAME:-?} ENV=${A2K_ENV:-?} IMAGE_TAG=${A2K_IMAGE_TAG:-?}"
  echo "[A2K env vars] PREVIOUS_TAG=${A2K_PREVIOUS_TAG:-(none)} ACTION=${A2K_ACTION:-?}"
  echo "[A2K env vars] PROJECT_DIR=${A2K_PROJECT_DIR:-?} SECRETS_FILE=${A2K_SECRETS_FILE:-?}"
  echo "[A2K env vars] TIMESTAMP=${A2K_DEPLOY_TIMESTAMP:-?} DRY_RUN=${A2K_DRY_RUN:-?} LOG_LEVEL=${A2K_LOG_LEVEL:-?}"
  echo "[A2K env vars] REGISTRY_ORG=${A2K_REGISTRY_ORG:-?} (cycle 29 Wave 1 cont sub-action 7 — 11e var A6 amend)"
}
