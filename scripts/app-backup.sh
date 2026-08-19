#!/usr/bin/env bash
#
# scripts/app-backup.sh — Shared backup core V0 (backup-v0 T1 — design 2026-06-30)
#
# Architecture push-and-forget VPS-orchestrator (cohérent app-deploy.sh / app-rollback.sh) :
#   - Transport : scripts/ scp'd vers /opt/<env>/<app>/ par les workflows GHA (cycle 12)
#   - VPS = orchestrator local autonome (this script runs LOCALLY on VPS)
#   - Déclencheur V0 : systemd timer (T2) OU exécution manuelle admin ops
#
# Scope V0 (modèle verrouillé Mode A user + extension multi-moteurs BK2 2026-07-11 ADR-015 amend) :
#   - Dump par base déclarée dans le manifest app-owned backup/manifest.<env>.yml — dispatch
#     per-engine par convention dump_${engine}_${access} (Option B) : postgres = pg_dump -F c
#     (auth locale trust/peer, PG-only) / mysql = mysqldump via sh -c credential in-container
#     (littéral -p"$<password_env>" jamais expansé host-side — cf. backup-lib.sh)
#   - Artefacts per-container : postgres = pg_dumpall --globals-only (rôles/GRANTs — Soiroke
#     dual-user) / mysql = users+GRANTs boucle SHOW CREATE USER + SHOW GRANTS (dump_mysql_users)
#   - Retention locale 7j (ADR-011 D-Backup-A)
#   - Offsite S3 V1 CÂBLÉ (backup-v1 É1) : cascade override per-app / socle per-env, chiffrement
#     GPG per-file AVANT rclone copyto <env>/<app>/<instance>/ (jamais d'offsite en clair),
#     catch-up idempotent <7j. Rétention remote OFF par défaut (ADR-016 : clé serveur
#     write/list-only sans DeleteObject — ménage 30j = lifecycle bucket Contabo OU tâche admin)
#   - Sentinelle last-success (monitoring RPO V1) — inclut désormais le succès upload offsite
#   - Volumes / secrets / configs HORS V0
#
# Workflow strict (8 phases) :
#   1. Pré-flight (PROJECT_DIR + Zone 4 secrets + docker + Zone 2 backups writable + manifest présent)
#   2. Validation schéma manifest (fail-fast clair — format plat contraint, cf. backup-manifest.TEMPLATE.yml)
#   3. Source Zone 4 secrets (set -a / set +a — vars rclone/BACKUP_* pour phase 6)
#   4. Dump par cible manifest (dispatch dump_${engine}_${access}) + artefacts per-container
#      per-engine (globals PG dumpall_globals / users MySQL dump_mysql_users — dédupliqués)
#      Sémantique « continue + agrégat » (M2) : un échec de cible n'aborte PAS le run — les cibles
#      suivantes sont tentées ; compteurs TARGETS_OK/TARGETS_FAILED/GLOBALS_FAILED/USERS_FAILED → FINAL_RC.
#   5. Retention locale (apply_retention — dumps + globals) — exécutée même si FINAL_RC=1
#   6. Offsite S3 (resolve_backup_remote + encrypt_and_upload_file par fichier + catch-up
#      idempotent + apply_remote_retention) — exécuté même si FINAL_RC=1 (dumps réussis offsite) ;
#      set config PARTIEL ou échec upload → FINAL_RC=1
#   7. Sentinelle (write_last_success_sentinel) — GATED FINAL_RC=0 (last-success = succès COMPLET,
#      upload offsite INCLUS, sinon RPO menti)
#   8. Audit log JSON : émis par le trap EXIT backup_cleanup (rc réel + duration, même sur échec/interruption)
#   Fin : exit FINAL_RC (0 = toutes cibles OK ; 1 = ≥1 dump/globals FAILED)
#
# Usage VPS :
#   bash scripts/app-backup.sh <env> <app_name>
#   bash scripts/app-backup.sh stg soiroke
#
# Usage local audit (aucune exécution docker/rclone) :
#   DRY_RUN=1 bash scripts/app-backup.sh stg soiroke
#   A2K_BACKUP_MANIFEST=/tmp/manifest.stg.yml DRY_RUN=1 bash scripts/app-backup.sh stg soiroke
#
# Env vars (optional) :
#   DRY_RUN=1                            Audit mode (print commandes, aucune exécution)
#   LOG_LEVEL=DEBUG|INFO                 Log level (default INFO)
#   A2K_BACKUP_MANIFEST=<path>           Override path manifest (default /opt/<env>/<app>/backup/manifest.<env>.yml)
#   A2K_BACKUP_RETENTION_DAYS=N          Override retention locale (default 7 — ADR-011 D-Backup-A)
#   A2K_BACKUP_REMOTE_RETENTION_DAYS=N   Retention remote script-side (default 0 = OFF — ADR-016 :
#                                        ménage externe bucket-side ; N>0 = usage admin explicite,
#                                        clé avec DeleteObject requise — jamais la clé du VPS)
#
# Discipline : KISS + named constants + BASH-CALLS-SEPARATED v2 + bash-ops-specialist AP-1 à AP-15.
# Cross-refs : ADR-011 D-Backup-A (pg_dump -F c + retention 7j) + ADR-008 amend cycle 31
# (write-once 0440) + ops_discipline.md §11 backup strategy RPO/RTO + docs/contracts/backup-manifest.TEMPLATE.yml.

set -euo pipefail

# Cycle 37 (ADR-008 amend / ADR-013) — umask 027 : compagnon obligatoire du bit setgid des zones
# FHS (Zone 2 backups 02770 deploy:<app>-backup). Force fichiers 0640 (avant chmod 0440 write-once
# par la lib) / dirs 2750. Placé après set -euo pipefail, AVANT tout mkdir (cf. app-deploy.sh:40-47).
umask 027

# ============================================================================
# Constants
# ============================================================================
# SC2155 : declare + assign séparés (le rc du $() n'est pas masqué par readonly).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LIB_DIR="${SCRIPT_DIR}/lib"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

readonly DRY_RUN="${DRY_RUN:-0}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Retention locale — default 7j (ADR-011 D-Backup-A). Corruption env → fallback 7 dans apply_retention.
readonly RETENTION_DAYS="${A2K_BACKUP_RETENTION_DAYS:-7}"

BACKUP_PHASE="init"
START_TS="$(date +%s)"

# ============================================================================
# Colors (terminal compatible — fallback no-color, mirror app-deploy.sh:72-84)
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
# Logging helpers (mirror app-deploy.sh:89-93)
# ============================================================================
log_info()  { echo "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { echo "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()  { echo "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error() { echo "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_phase() { echo ""; echo "${C_BLUE}━━━ Phase: $* ━━━${C_RESET}"; }

# ============================================================================
# Trap cleanup diagnostic (simplifié app-deploy.sh:98-110 — 1 trap, pas de rollback :
# le backup est read-only côté DB, aucune action compensatoire nécessaire)
# ============================================================================
# shellcheck disable=SC2317,SC2329  # invoquée indirectement via trap EXIT INT TERM ci-dessous.
# SC2317 requis pour shellcheck 0.9.0 (CI apt ubuntu-latest) : avant 0.11.0, le corps d'une
# fonction jugée « never invoked » est flaggé SC2317 ligne par ligne (SC2329 n'existe qu'à
# partir de 0.11.0 — CHANGELOG officiel). Wiki SC2317 : « ShellCheck may incorrectly believe
# that code is unreachable if it's invoked by variable name or in a trap » → disable directive
# placée avant la fonction = couvre toute la fonction (faux positif documenté, rien de masqué).
backup_cleanup() {
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "Backup interrupted/failed (rc=${rc}) at phase: ${BACKUP_PHASE}"
    log_warn "Dumps partiels éventuels : les fonctions lib suppriment leurs fichiers en échec ; vérifier ${BACKUPS_DIR:-/var/lib/<app>/<env>/backups}"
    log_warn "Diagnostic: docker ps -a + ls -la Zone 2 backups + journalctl --since '10 minutes ago'"
  fi
  # M2 — audit log JSON émis ICI (trap EXIT) : loggé avec le rc RÉEL + duration réelle, MÊME
  # sur échec/interruption (l'appel phase 8 top-level n'était jamais atteint sous set -e).
  # Guard A2K_APP_NAME : le trap est posé AVANT le sourcing libs + export_a2k_backup_env_vars —
  # A2K_APP_NAME non-vide garantit libs sourcées (log_hook_audit défini) + env A2K_* exportées.
  # log_hook_audit est déjà best-effort (WARN + return 0 si log dir absent — cf. phase 8).
  if [[ -n "${A2K_APP_NAME:-}" ]]; then
    local end_ts duration_s
    end_ts="$(date +%s)"
    duration_s=$((end_ts - START_TS))
    log_hook_audit "backup" "${rc}" "${duration_s}" "N/A"
  fi
  return "${rc}"
}
trap backup_cleanup EXIT INT TERM

# ============================================================================
# Usage / Argument validation
# ============================================================================
usage() {
  cat >&2 <<EOF
${SCRIPT_NAME} — Shared backup core V0 (backup-v0 T1)

Usage:
  bash ${SCRIPT_NAME} <env> <app_name>

Args:
  env           Environment target : stg | prd
  app_name      App name : topxpress | soiroke | etc.

Env vars (optional):
  DRY_RUN=1                            Audit mode (aucune exécution docker/gpg/rclone)
  A2K_BACKUP_MANIFEST=<path>           Override path manifest (default /opt/<env>/<app>/backup/manifest.<env>.yml)
  A2K_BACKUP_RETENTION_DAYS=N          Override retention locale (default 7 — ADR-011 D-Backup-A)
  A2K_BACKUP_REMOTE_RETENTION_DAYS=N   Retention remote script-side (default 0 = OFF — ADR-016 ménage externe)

Examples:
  bash ${SCRIPT_NAME} stg soiroke
  DRY_RUN=1 bash ${SCRIPT_NAME} stg soiroke

Cf. docs/contracts/backup-manifest.TEMPLATE.yml (schéma manifest app-owned)
EOF
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

readonly ENV="$1"
readonly APP_NAME="$2"

# Validate env whitelist (mirror app-deploy.sh:170-176)
case "${ENV}" in
  stg|prd) ;;
  *)
    log_error "env='${ENV}' invalid (expected: stg|prd)"
    exit 1
    ;;
esac

# Validate app_name (DNS-safe + filesystem-safe — mirror app-deploy.sh:179, inversé || pour AP-1)
printf '%s' "${APP_NAME}" | grep -qE '^[a-z][a-z0-9_-]{0,63}$' || {
  log_error "app_name='${APP_NAME}' invalid (whitelist ^[a-z][a-z0-9_-]{0,63}$)"
  exit 1
}

# ============================================================================
# Source libraries (lib/env-vars.sh + lib/hooks-runner.sh + lib/backup-lib.sh)
# ============================================================================
for _lib in env-vars.sh hooks-runner.sh backup-lib.sh; do
  if [[ ! -f "${LIB_DIR}/${_lib}" ]]; then
    log_error "Library missing: ${LIB_DIR}/${_lib}"
    exit 1
  fi
done
unset _lib
# shellcheck source=lib/env-vars.sh disable=SC1091
. "${LIB_DIR}/env-vars.sh"
# shellcheck source=lib/hooks-runner.sh disable=SC1091
. "${LIB_DIR}/hooks-runner.sh"
# shellcheck source=lib/backup-lib.sh disable=SC1091
. "${LIB_DIR}/backup-lib.sh"

# ============================================================================
# Export A2K_* env vars variante backup (L1.3 — PAS d'image_tag bidon)
# ============================================================================
export_a2k_backup_env_vars "${APP_NAME}" "${ENV}"

readonly PROJECT_DIR="${A2K_PROJECT_DIR}"
readonly BACKUPS_DIR="/var/lib/${APP_NAME}/${ENV}/backups"
# Manifest app-owned (repo app, transporté VPS avec le deploy). Override A2K_BACKUP_MANIFEST
# pour audit local DRY_RUN + tests (T3).
readonly MANIFEST_FILE="${A2K_BACKUP_MANIFEST:-${PROJECT_DIR}/backup/manifest.${ENV}.yml}"

# ============================================================================
# Print header
# ============================================================================
echo ""
echo "${C_BLUE}========================================================================${C_RESET}"
echo "${C_BLUE}  app-backup.sh — backup shared V0 (design 2026-06-30 / ADR-011 D-Backup-A)${C_RESET}"
echo "${C_BLUE}========================================================================${C_RESET}"
log_info "Env          : ${ENV}"
log_info "App          : ${APP_NAME}"
log_info "Project dir  : ${PROJECT_DIR}"
log_info "Backups dir  : ${BACKUPS_DIR}"
log_info "Manifest     : ${MANIFEST_FILE}"
log_info "Retention    : ${RETENTION_DAYS}j"
log_info "DRY_RUN      : ${DRY_RUN}"
log_info "Timestamp    : ${A2K_DEPLOY_TIMESTAMP}"
echo ""

# ============================================================================
# Phase 1 — Pré-flight validation
# ============================================================================
BACKUP_PHASE="preflight"
log_phase "1. Pré-flight validation"

MANIFEST_PRESENT=1

# Project dir (mirror app-deploy.sh:279-287)
if [[ -d "${PROJECT_DIR}" ]]; then
  log_ok "PROJECT_DIR present: ${PROJECT_DIR}"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] PROJECT_DIR ${PROJECT_DIR} absent (expected on VPS post-scp)"
  else
    log_error "PROJECT_DIR ${PROJECT_DIR} absent"
    exit 1
  fi
fi

# Zone 4 secrets (mirror app-deploy.sh:302-312)
if [[ -f "${A2K_SECRETS_FILE}" ]]; then
  log_ok "Zone 4 secrets present: ${A2K_SECRETS_FILE}"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] Zone 4 secrets absent (expected on VPS — provision via provision-app.yml)"
  else
    log_error "Zone 4 secrets absent: ${A2K_SECRETS_FILE}"
    exit 1
  fi
fi

# docker CLI (les dumps passent par docker exec)
if command -v docker >/dev/null 2>&1; then
  log_ok "docker CLI present"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] docker CLI absent (expected on dev host)"
  else
    log_error "docker CLI absent"
    exit 1
  fi
fi

# Zone 2 backups writable (02770 deploy:<app>-backup setgid — app-soiroke/defaults/main.yml:43-54)
if [[ -d "${BACKUPS_DIR}" ]] && [[ -w "${BACKUPS_DIR}" ]]; then
  log_ok "Zone 2 backups writable: ${BACKUPS_DIR}"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_warn "[DRY_RUN] Zone 2 backups ${BACKUPS_DIR} absent/non-writable (expected on VPS — provisionné Ansible)"
  else
    log_error "Zone 2 backups ${BACKUPS_DIR} absent OR non-writable (attendu 02770 deploy:${APP_NAME}-backup — provision Ansible)"
    exit 1
  fi
fi

# Manifest présent (app-owned — transporté avec le deploy)
if [[ -f "${MANIFEST_FILE}" ]]; then
  log_ok "Manifest present: ${MANIFEST_FILE}"
else
  if [[ "${DRY_RUN}" == "1" ]]; then
    # Audit local : manifest absent toléré (warn) — phases dump simulées sans cible.
    # Pour simuler le parsing complet : A2K_BACKUP_MANIFEST=<path test> DRY_RUN=1 bash ...
    log_warn "[DRY_RUN] Manifest absent: ${MANIFEST_FILE} (expected on VPS — phases dump simulées sans cible)"
    MANIFEST_PRESENT=0
  else
    log_error "Manifest absent: ${MANIFEST_FILE}"
    log_error "Le manifest est app-owned (repo app, backup/manifest.${ENV}.yml, transporté VPS avec le deploy)"
    log_error "Cf. docs/contracts/backup-manifest.TEMPLATE.yml"
    exit 1
  fi
fi

# ============================================================================
# Phase 2 — Validation schéma manifest (fail-fast clair)
# ============================================================================
BACKUP_PHASE="manifest-validation"
log_phase "2. Validation schéma manifest"

# Parsing KISS V0 — format PLAT CONTRAINT (cf. docs/contracts/backup-manifest.TEMPLATE.yml).
# Choix retenu : parser pur bash ligne-à-ligne, AUCUNE dépendance yq (non garanti VPS,
# un seul code path testable). Le schéma contraint le format pour rendre le parsing fiable
# (pas de YAML arbitraire) : liste `targets:` + items `- engine: ...` + paires `key: value`
# une par ligne, valeurs whitelist ^[A-Za-z0-9._-]{1,128}$ (anti-injection defense-in-depth).
#
# Arrays remplis par parse_backup_manifest (index = cible) :
declare -a T_ENGINE=() T_ACCESS=() T_CONTAINER=() T_DB_USER=() T_DB_NAME=() T_PASSWORD_ENV=()
TARGET_COUNT=0

# Table de validation per-engine (Option B — BK2 2026-07-11) : enum engine = clés de la table
# (message d'erreur dynamique), valeur = clés REQUISES access=docker. Engine N+1 = 1 ligne ici
# + 1 primitive dump_${engine}_${access} dans backup-lib.sh (dispatch par convention phase 4).
declare -A ENGINE_REQUIRED_KEYS=(
  [postgres]="container db_user db_name"
  [mysql]="container db_user db_name"
)

# Valeur d'une clé de cible par nom (helper table validation per-engine).
target_key_value() {
  local idx="$1" key="$2"
  case "${key}" in
    container)    printf '%s' "${T_CONTAINER[idx]}" ;;
    db_user)      printf '%s' "${T_DB_USER[idx]}" ;;
    db_name)      printf '%s' "${T_DB_NAME[idx]}" ;;
    password_env) printf '%s' "${T_PASSWORD_ENV[idx]}" ;;
    *)            printf '' ;;
  esac
}

manifest_fail() {
  log_error "manifest.${ENV}.yml invalide : $*"
  log_error "Path: ${MANIFEST_FILE} — schéma : docs/contracts/backup-manifest.TEMPLATE.yml"
  exit 1
}

# Whitelist valeur manifest (anti-injection — les valeurs partent en args docker exec)
validate_manifest_value() {
  local key="$1" value="$2"
  [[ "${value}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || manifest_fail "valeur '${key}: ${value}' hors whitelist ^[A-Za-z0-9._-]{1,128}$"
}

parse_backup_manifest() {
  local file="$1"
  local raw line key value idx=-1 in_targets=0

  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    # Strip comments + trim whitespace (pure bash)
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue

    if [[ "${line}" == "targets:" ]]; then
      in_targets=1
      continue
    fi

    [[ "${in_targets}" -eq 1 ]] || manifest_fail "contenu avant 'targets:' non supporté (ligne: '${line}')"

    # Nouvelle cible — DOIT commencer par '- engine:' (format plat contraint)
    if [[ "${line}" == -* ]]; then
      [[ "${line}" == "- engine:"* ]] || manifest_fail "chaque cible DOIT commencer par '- engine:' (ligne: '${line}')"
      idx=$((idx + 1))
      T_ENGINE[idx]=""; T_ACCESS[idx]=""; T_CONTAINER[idx]=""; T_DB_USER[idx]=""; T_DB_NAME[idx]=""; T_PASSWORD_ENV[idx]=""
      line="${line#- }"
    fi

    [[ "${idx}" -ge 0 ]] || manifest_fail "paire key:value hors cible (ligne: '${line}')"
    [[ "${line}" == *:* ]] || manifest_fail "ligne non key:value (ligne: '${line}')"

    key="${line%%:*}"
    value="${line#*:}"
    # trim value
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ -n "${value}" ]] || manifest_fail "clé '${key}' sans valeur"

    case "${key}" in
      engine)    validate_manifest_value "${key}" "${value}"; T_ENGINE[idx]="${value}" ;;
      access)    validate_manifest_value "${key}" "${value}"; T_ACCESS[idx]="${value}" ;;
      container) validate_manifest_value "${key}" "${value}"; T_CONTAINER[idx]="${value}" ;;
      db_user)   validate_manifest_value "${key}" "${value}"; T_DB_USER[idx]="${value}" ;;
      db_name)   validate_manifest_value "${key}" "${value}"; T_DB_NAME[idx]="${value}" ;;
      password_env)
        # NOM de var d'env in-container (engine=mysql UNIQUEMENT — validé per-engine ci-dessous),
        # JAMAIS une valeur. Whitelist générique ICI puis forme env-var stricte (D2 defense-in-depth).
        validate_manifest_value "${key}" "${value}"; T_PASSWORD_ENV[idx]="${value}" ;;
      host|port|sslmode|credentials_ref)
        # Clés RÉSERVÉES access=network V0 — tolérées au parsing, la validation
        # access=network fail-fast ci-dessous rend l'erreur plus claire que 'clé inconnue'.
        ;;
      *) manifest_fail "clé inconnue '${key}' (autorisées: engine|access|container|db_user|db_name|password_env + réservées network)" ;;
    esac
  done < "${file}"

  TARGET_COUNT=$((idx + 1))
}

if [[ "${MANIFEST_PRESENT}" -eq 1 ]]; then
  parse_backup_manifest "${MANIFEST_FILE}"

  [[ "${TARGET_COUNT}" -ge 1 ]] || manifest_fail "aucune cible (targets: vide)"

  # M1 RELAXÉE per-engine (BK2 D1) — clé de dédup engine:db_name : les extensions per-engine
  # (.dump PG / .mysql.sql MySQL) rendent les filenames disjoints cross-engine → même db_name
  # sur 2 engines distincts = AUTORISÉ (cas réel TopXpress) ; duplicata MÊME engine = collision
  # filename write-once (fail-fast). Pattern string-contains cohérent GLOBALS_DUMPED_CONTAINERS.
  SEEN_DB_NAMES=" "
  PG_TARGET_COUNT=0
  MYSQL_TARGET_COUNT=0
  for ((i = 0; i < TARGET_COUNT; i++)); do
    # Enum engine = clés de la table per-engine (Option B — message dynamique).
    [[ -n "${ENGINE_REQUIRED_KEYS[${T_ENGINE[i]}]:-}" ]] \
      || manifest_fail "cible #$((i + 1)) : engine='${T_ENGINE[i]}' non supporté (enum: ${!ENGINE_REQUIRED_KEYS[*]})"
    case "${T_ACCESS[i]}" in
      docker)
        # Clés REQUISES per-engine (table ENGINE_REQUIRED_KEYS — access=docker).
        # read -ra : split explicite de la liste espace-séparée (pas d'expansion non quotée).
        IFS=' ' read -r -a REQUIRED_KEYS_ARR <<< "${ENGINE_REQUIRED_KEYS[${T_ENGINE[i]}]}"
        for req_key in "${REQUIRED_KEYS_ARR[@]}"; do
          [[ -n "$(target_key_value "${i}" "${req_key}")" ]] \
            || manifest_fail "cible #$((i + 1)) : '${req_key}' REQUIS (engine=${T_ENGINE[i]}, access=docker)"
        done
        ;;
      network)
        log_error "cible #$((i + 1)) : access=network non implémenté V0 (RÉSERVÉ — cf. backup-manifest.TEMPLATE.yml)"
        exit 1
        ;;
      *) manifest_fail "cible #$((i + 1)) : access='${T_ACCESS[i]}' invalide (enum: docker|network)" ;;
    esac

    # password_env — engine=mysql UNIQUEMENT (D2) : défaut MYSQL_ROOT_PASSWORD (convention
    # image officielle) + forme env-var stricte (defense-in-depth — la valeur, un NOM de var,
    # est interpolée dans la string sh -c in-container). Présent sur engine≠mysql = erreur.
    if [[ "${T_ENGINE[i]}" == "mysql" ]]; then
      if [[ -z "${T_PASSWORD_ENV[i]}" ]]; then
        T_PASSWORD_ENV[i]="MYSQL_ROOT_PASSWORD"
      fi
      [[ "${T_PASSWORD_ENV[i]}" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] \
        || manifest_fail "cible #$((i + 1)) : password_env='${T_PASSWORD_ENV[i]}' hors forme env-var stricte ^[A-Z][A-Z0-9_]{0,63}$"
    else
      [[ -z "${T_PASSWORD_ENV[i]}" ]] \
        || manifest_fail "cible #$((i + 1)) : 'password_env' réservé engine=mysql (engine=${T_ENGINE[i]} — PG = auth locale trust/peer sans credential)"
    fi

    # Noms réservés db_name (D1) — tous engines : un db 'users'/'globals' mimerait les
    # artefacts users-/globals- (ambiguïté parsing catch-up phase 6).
    case "${T_DB_NAME[i]}" in
      globals|users)
        manifest_fail "cible #$((i + 1)) : db_name='${T_DB_NAME[i]}' RÉSERVÉ (collision naming artefacts globals-/users- — renommer la base ou la cible)"
        ;;
    esac

    # Préfixe réservé 'users-' — engine=mysql UNIQUEMENT (F3 review R1) : un db_name mysql
    # 'users-<x>' avec container '<x>' produit un basename data IDENTIQUE à l'artefact users
    # per-container (<app>-<env>-users-<x>-<ts>.mysql.sql) → refus write-once systématique
    # (USERS_FAILED) + catch-up phase 6 routé branche users (instance erronée). Fail-fast
    # miroir des réservés exacts ci-dessus. PG non affecté (extensions .dump/.sql disjointes).
    if [[ "${T_ENGINE[i]}" == "mysql" && "${T_DB_NAME[i]}" == users-* ]]; then
      manifest_fail "cible #$((i + 1)) : db_name='${T_DB_NAME[i]}' préfixe 'users-' RÉSERVÉ pour engine=mysql (collision basename avec l'artefact users-<container> — renommer la base ou la cible)"
    fi

    # M1 per-engine — fail-fast duplicata engine:db_name (cross-engine AUTORISÉ, extensions disjointes D1).
    if [[ "${SEEN_DB_NAMES}" == *" ${T_ENGINE[i]}:${T_DB_NAME[i]} "* ]]; then
      manifest_fail "cible #$((i + 1)) : db_name='${T_DB_NAME[i]}' dupliqué pour engine=${T_ENGINE[i]} (filenames dumps collisionnent — unicité per-engine ; cross-engine = autorisé)"
    fi
    SEEN_DB_NAMES="${SEEN_DB_NAMES}${T_ENGINE[i]}:${T_DB_NAME[i]} "

    # Compteurs récap per-engine
    case "${T_ENGINE[i]}" in
      postgres) PG_TARGET_COUNT=$((PG_TARGET_COUNT + 1)) ;;
      mysql)    MYSQL_TARGET_COUNT=$((MYSQL_TARGET_COUNT + 1)) ;;
    esac
  done

  log_ok "Manifest valide : ${TARGET_COUNT} cible(s) access=docker — ${PG_TARGET_COUNT} postgres / ${MYSQL_TARGET_COUNT} mysql"
else
  log_warn "[DRY_RUN] Validation manifest SKIP (manifest absent)"
fi

# ============================================================================
# Phase 3 — Source Zone 4 secrets
# ============================================================================
BACKUP_PHASE="source-secrets"
log_phase "3. Source Zone 4 secrets"

# Le sourcing Zone 4 alimente UNIQUEMENT la phase 6 S3 (vars RCLONE_CONFIG_S3BACKUP_* +
# BACKUP_BUCKET + BACKUP_GPG_FINGERPRINT). Les dumps docker exec n'en ont pas besoin :
#   - postgres : auth locale conteneur trust/peer socket (aucun credential — PG-only) ;
#   - mysql : le credential est DÉJÀ dans l'env du conteneur (compose env_file ← Zone 4) et
#     y est expansé par le `sh -c` in-container — JAMAIS sourcé host-side par ce script (BK1 Q1 #13).
# Pattern idiomatique autorisé set -a && . && set +a (actions_governance.md § Hygiène Bash v2).
if [[ "${DRY_RUN}" == "1" ]]; then
  log_warn "[DRY_RUN] Source ${A2K_SECRETS_FILE} SKIP (aucun secret chargé en audit local)"
else
  set -a
  # shellcheck disable=SC1090
  . "${A2K_SECRETS_FILE}"
  set +a
  log_ok "Zone 4 secrets sourcés (valeurs jamais loggées)"
fi

# ============================================================================
# Phase 4 — Dumps par cible manifest + globals par container
# ============================================================================
BACKUP_PHASE="dump"
log_phase "4. Dumps par cible (dispatch per-engine) + globals PG / users MySQL (par container)"

# M2 — sémantique « continue + agrégat » : capture AP-1 par cible (jamais `if !`), les cibles
# suivantes sont TOUJOURS tentées ; FINAL_RC agrégé (1 si ≥1 échec) porté jusqu'à l'exit final.
TARGETS_OK=0
TARGETS_FAILED=0
GLOBALS_FAILED=0
USERS_FAILED=0
FINAL_RC=0

# Tracking fichier→instance (backup-v1 É1) : arrays PARALLÈLES des fichiers produits AVEC
# succès ce run — consommés phase 6 (encrypt_and_upload_file par fichier, routage <instance>).
declare -a UPLOAD_FILES=() UPLOAD_INSTANCES=()

if [[ "${MANIFEST_PRESENT}" -eq 1 ]]; then
  GLOBALS_DUMPED_CONTAINERS=" "        # globals PG (pg_dumpall) — dédupliqués par container
  MYSQL_USERS_DUMPED_CONTAINERS=" "    # users/GRANTs MySQL — dédupliqués par container (miroir)
  for ((i = 0; i < TARGET_COUNT; i++)); do
    # Extension + args per-engine (D1 — extensions disjointes structurellement : rétention
    # phase 5 + catch-up phase 6 routent par pattern). postgres : 4 args inchangés ;
    # mysql : + password_env (NOM de var in-container — validé phase 2).
    case "${T_ENGINE[i]}" in
      mysql)
        out_dump="${BACKUPS_DIR}/${APP_NAME}-${ENV}-${T_DB_NAME[i]}-${A2K_DEPLOY_TIMESTAMP}.mysql.sql"
        dump_args=("${T_CONTAINER[i]}" "${T_DB_USER[i]}" "${T_DB_NAME[i]}" "${out_dump}" "${T_PASSWORD_ENV[i]}")
        ;;
      *)  # postgres (enum garanti par la validation phase 2)
        out_dump="${BACKUPS_DIR}/${APP_NAME}-${ENV}-${T_DB_NAME[i]}-${A2K_DEPLOY_TIMESTAMP}.dump"
        dump_args=("${T_CONTAINER[i]}" "${T_DB_USER[i]}" "${T_DB_NAME[i]}" "${out_dump}")
        ;;
    esac
    log_info "Cible #$((i + 1)) : engine=${T_ENGINE[i]} container=${T_CONTAINER[i]} db=${T_DB_NAME[i]} (user=${T_DB_USER[i]})"

    # Dispatch par convention dump_${engine}_${access} (Option B) — garde défensive declare -F :
    # primitive absente (engine N+1 déclaré table phase 2 sans primitive lib) = cible FAILED
    # loggée + compteur, PAS de crash (sémantique continue + agrégat M2 préservée).
    dump_fn="dump_${T_ENGINE[i]}_${T_ACCESS[i]}"
    rc=0
    if declare -F "${dump_fn}" >/dev/null 2>&1; then
      "${dump_fn}" "${dump_args[@]}" || rc=$?
    else
      log_error "Cible #$((i + 1)) : primitive '${dump_fn}' absente de backup-lib.sh (engine=${T_ENGINE[i]} access=${T_ACCESS[i]}) — cible FAILED sans crash"
      rc=1
    fi
    if [[ "${rc}" -ne 0 ]]; then
      TARGETS_FAILED=$((TARGETS_FAILED + 1))
      log_error "Cible #$((i + 1)) : dump FAILED (rc=${rc}) — poursuite des cibles suivantes (continue + agrégat)"
    else
      TARGETS_OK=$((TARGETS_OK + 1))
      UPLOAD_FILES+=("${out_dump}")
      UPLOAD_INSTANCES+=("${T_CONTAINER[i]}")
    fi

    # Artefacts per-container per-engine — dédupliqués par container + filename PAR CONTAINER (H1) :
    # 2 containers distincts = 2 fichiers distincts (sans le container dans le filename, le 2e
    # dump refusait le fichier 0440 du 1er → destruction du fichier VALIDE via rm -f post-échec).
    case "${T_ENGINE[i]}" in
      postgres)
        # Globals PG (rôles/GRANTs cluster-wide — critique Soiroke dual-user) : déclenchés
        # UNIQUEMENT par les cibles postgres (conditionnel engine — BK2).
        if [[ "${GLOBALS_DUMPED_CONTAINERS}" == *" ${T_CONTAINER[i]} "* ]]; then
          log_info "Globals PG container=${T_CONTAINER[i]} déjà dumpés ce run — skip"
        else
          out_globals="${BACKUPS_DIR}/${APP_NAME}-${ENV}-globals-${T_CONTAINER[i]}-${A2K_DEPLOY_TIMESTAMP}.sql"
          rc=0
          dumpall_globals "${T_CONTAINER[i]}" "${T_DB_USER[i]}" "${out_globals}" || rc=$?
          if [[ "${rc}" -ne 0 ]]; then
            GLOBALS_FAILED=$((GLOBALS_FAILED + 1))
            log_error "Globals PG container=${T_CONTAINER[i]} FAILED (rc=${rc}) — poursuite (continue + agrégat)"
          else
            GLOBALS_DUMPED_CONTAINERS="${GLOBALS_DUMPED_CONTAINERS}${T_CONTAINER[i]} "
            UPLOAD_FILES+=("${out_globals}")
            UPLOAD_INSTANCES+=("${T_CONTAINER[i]}")
          fi
        fi
        ;;
      mysql)
        # Users/GRANTs MySQL (équivalent fonctionnel globals PG — arbitrage user : ON par
        # container, miroir exact du bloc globals). Naming D1 : users-<container>-<ts>.mysql.sql.
        if [[ "${MYSQL_USERS_DUMPED_CONTAINERS}" == *" ${T_CONTAINER[i]} "* ]]; then
          log_info "Users MySQL container=${T_CONTAINER[i]} déjà dumpés ce run — skip"
        else
          out_users="${BACKUPS_DIR}/${APP_NAME}-${ENV}-users-${T_CONTAINER[i]}-${A2K_DEPLOY_TIMESTAMP}.mysql.sql"
          rc=0
          dump_mysql_users "${T_CONTAINER[i]}" "${T_DB_USER[i]}" "${out_users}" "${T_PASSWORD_ENV[i]}" || rc=$?
          if [[ "${rc}" -ne 0 ]]; then
            USERS_FAILED=$((USERS_FAILED + 1))
            log_error "Users MySQL container=${T_CONTAINER[i]} FAILED (rc=${rc}) — poursuite (continue + agrégat)"
          else
            MYSQL_USERS_DUMPED_CONTAINERS="${MYSQL_USERS_DUMPED_CONTAINERS}${T_CONTAINER[i]} "
            UPLOAD_FILES+=("${out_users}")
            UPLOAD_INSTANCES+=("${T_CONTAINER[i]}")
          fi
        fi
        ;;
    esac
  done

  if [[ "${TARGETS_FAILED}" -gt 0 ]] || [[ "${GLOBALS_FAILED}" -gt 0 ]] || [[ "${USERS_FAILED}" -gt 0 ]]; then
    FINAL_RC=1
    log_error "Phase 4 récap : dumps OK=${TARGETS_OK} FAILED=${TARGETS_FAILED} / globals PG FAILED=${GLOBALS_FAILED} / users MySQL FAILED=${USERS_FAILED} → FINAL_RC=1 (retention + S3 exécutées quand même ; sentinelle SKIP)"
  fi
else
  log_warn "[DRY_RUN] Dumps SKIP (aucune cible — manifest absent)"
fi

# ============================================================================
# Phase 5 — Retention locale
# ============================================================================
BACKUP_PHASE="retention"
log_phase "5. Retention locale (${RETENTION_DAYS}j — ADR-011 D-Backup-A)"

apply_retention "${BACKUPS_DIR}" "${RETENTION_DAYS}" "${APP_NAME}-${ENV}-*.dump"
apply_retention "${BACKUPS_DIR}" "${RETENTION_DAYS}" "${APP_NAME}-${ENV}-globals-*.sql"
# 1 SEUL pattern mysql (D1) : couvre data (<db>-<ts>.mysql.sql) ET users (users-<container>-<ts>.mysql.sql)
# — ajouté ATOMIQUEMENT avec les primitives S1 (piège BK1 Q1 #8 : artefact non matché = jamais purgé).
apply_retention "${BACKUPS_DIR}" "${RETENTION_DAYS}" "${APP_NAME}-${ENV}-*.mysql.sql"

# ============================================================================
# Phase 6 — Offsite S3 (backup-v1 É1 : cascade + GPG per-file + catch-up + rétention remote)
# ============================================================================
BACKUP_PHASE="s3-offsite"
log_phase "6. Offsite S3 (cascade override/socle + GPG + rclone copyto par fichier)"

rc=0
resolve_backup_remote || rc=$?
if [[ "${rc}" -ne 0 ]]; then
  # Set config PARTIEL ou binaire manquant : ERREUR bruyante (durci vs skip V0 — RPO offsite menti sinon).
  FINAL_RC=1
  log_error "Phase 6 : résolution offsite FAILED (rc=${rc}) → FINAL_RC=1 (dumps locaux intacts, offsite NON synchronisé)"
elif [[ "${BACKUP_OFFSITE_MODE}" == "off" ]]; then
  log_info "Phase 6 : offsite non configuré — skip propre (opt-out, comportement V0)"
else
  # --- 6a. Sweep orphelins temps (.gpg/.gpg.sha256 dérivables — run précédent interrompu) ---
  if [[ "${DRY_RUN}" == "1" ]]; then
    log_info "[DRY_RUN] sweep orphelins : rm -f ${BACKUPS_DIR}/*.gpg ${BACKUPS_DIR}/*.gpg.sha256"
  else
    rc=0
    rm -f "${BACKUPS_DIR}"/*.gpg "${BACKUPS_DIR}"/*.gpg.sha256 || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      log_warn "Sweep orphelins .gpg partiel (rc=${rc}) — best-effort, poursuite"
    fi
  fi

  # --- 6b. Upload des fichiers produits ce run (tracking phase 4 — continue + agrégat M2) ---
  UPLOADED_BASENAMES=" "
  for ((i = 0; i < ${#UPLOAD_FILES[@]}; i++)); do
    rc=0
    encrypt_and_upload_file "${UPLOAD_FILES[i]}" "${UPLOAD_INSTANCES[i]}" "${ENV}" "${APP_NAME}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      FINAL_RC=1
      log_error "Upload offsite FAILED (rc=${rc}) — $(basename "${UPLOAD_FILES[i]}") : poursuite des suivants (continue + agrégat)"
    fi
    # Marqué « traité ce run » même en échec : le catch-up de CE run ne double-tente pas
    # (conditions identiques) — le run SUIVANT le rattrapera (absent du listing remote).
    UPLOADED_BASENAMES="${UPLOADED_BASENAMES}$(basename "${UPLOAD_FILES[i]}") "
  done

  # --- 6c. Catch-up idempotent (self-healing trou d'upload <7j — dumps locaux retenus) ---
  # 1 listing remote par instance (caché) ; re-encrypt+upload des basenames .gpg absents.
  # Présence du .gpg remote = paire complète garantie (sidecar uploadé AVANT — commit
  # marker, cf. encrypt_and_upload_file).
  # Routage instance : globals PG / users MySQL = container dans le filename ; dumps db =
  # lookup db_name → container via arrays manifest du run, FILTRÉ PAR ENGINE (OBLIGATOIRE
  # post-M1-relaxée D1 : même db_name possible cross-engine — le filtre engine désambiguïse).
  # Routage EXTENSION-FIRST (D1) : suffixe .mysql.sql testé AVANT le préfixe globals- (un db
  # mysql nommé 'globals-x' matcherait le glob globals PG — l'extension tranche).
  declare -A CATCHUP_LIST_STATE=()   # instance → OK|FAIL (listing tenté)
  declare -A CATCHUP_LIST_FILES=()   # instance → basenames remote (newline-joined)
  CATCHUP_SEEN_BASENAMES=" "         # dédup globs chevauchants (*.mysql.sql vs globals-*.sql)
  for CU_FILE in "${BACKUPS_DIR}/${APP_NAME}-${ENV}-"*.dump "${BACKUPS_DIR}/${APP_NAME}-${ENV}-"*.mysql.sql "${BACKUPS_DIR}/${APP_NAME}-${ENV}-globals-"*.sql; do
    if [[ ! -e "${CU_FILE}" ]]; then
      continue   # glob non-matché (nullglob non posé — pattern littéral)
    fi
    CU_BASE="$(basename "${CU_FILE}")"
    if [[ "${CATCHUP_SEEN_BASENAMES}" == *" ${CU_BASE} "* ]]; then
      continue   # déjà traité cette boucle (globs chevauchants — e.g. db 'globals-x' mysql)
    fi
    CATCHUP_SEEN_BASENAMES="${CATCHUP_SEEN_BASENAMES}${CU_BASE} "
    if [[ "${UPLOADED_BASENAMES}" == *" ${CU_BASE} "* ]]; then
      continue   # fichier du run courant — déjà traité en 6b
    fi

    CU_CONTAINER=""
    if [[ "${CU_BASE}" == *.mysql.sql ]]; then
      # Extension-first (D1) — artefacts MySQL
      CU_TMP="${CU_BASE%.mysql.sql}"
      if [[ "${CU_BASE}" == "${APP_NAME}-${ENV}-users-"* ]]; then
        # <app>-<env>-users-<container>-<ts>.mysql.sql → container (ts %Y%m%dT%H%M%SZ sans hyphen)
        CU_TMP="${CU_TMP#"${APP_NAME}-${ENV}-users-"}"
        CU_CONTAINER="${CU_TMP%-*}"
      else
        # <app>-<env>-<db>-<ts>.mysql.sql → db → container (lookup FILTRÉ engine=mysql)
        CU_TMP="${CU_TMP#"${APP_NAME}-${ENV}-"}"
        CU_DB="${CU_TMP%-*}"
        for ((j = 0; j < TARGET_COUNT; j++)); do
          if [[ "${T_ENGINE[j]}" == "mysql" ]] && [[ "${T_DB_NAME[j]}" == "${CU_DB}" ]]; then
            CU_CONTAINER="${T_CONTAINER[j]}"
            break
          fi
        done
        if [[ -z "${CU_CONTAINER}" ]]; then
          log_warn "Catch-up : db mysql '${CU_DB}' absente du manifest courant — skip ${CU_BASE} (fenêtre 7j marginale)"
          continue
        fi
      fi
    elif [[ "${CU_BASE}" == "${APP_NAME}-${ENV}-globals-"*.sql ]]; then
      # <app>-<env>-globals-<container>-<ts>.sql → container (ts %Y%m%dT%H%M%SZ sans hyphen)
      CU_TMP="${CU_BASE#"${APP_NAME}-${ENV}-globals-"}"
      CU_TMP="${CU_TMP%.sql}"
      CU_CONTAINER="${CU_TMP%-*}"
    else
      # <app>-<env>-<db>-<ts>.dump → db → container (lookup FILTRÉ engine=postgres —
      # OBLIGATOIRE post-M1-relaxée : un db_name partagé cross-engine routerait sinon
      # le .dump PG vers le container mysql homonyme)
      CU_TMP="${CU_BASE#"${APP_NAME}-${ENV}-"}"
      CU_TMP="${CU_TMP%.dump}"
      CU_DB="${CU_TMP%-*}"
      for ((j = 0; j < TARGET_COUNT; j++)); do
        if [[ "${T_ENGINE[j]}" == "postgres" ]] && [[ "${T_DB_NAME[j]}" == "${CU_DB}" ]]; then
          CU_CONTAINER="${T_CONTAINER[j]}"
          break
        fi
      done
      if [[ -z "${CU_CONTAINER}" ]]; then
        log_warn "Catch-up : db postgres '${CU_DB}' absente du manifest courant — skip ${CU_BASE} (fenêtre 7j marginale)"
        continue
      fi
    fi

    # Listing remote par instance — 1 seule fois par run (cache).
    if [[ -z "${CATCHUP_LIST_STATE[${CU_CONTAINER}]:-}" ]]; then
      rc=0
      CU_LISTING="$(remote_list_instance "${CU_CONTAINER}" "${ENV}" "${APP_NAME}")" || rc=$?
      if [[ "${rc}" -ne 0 ]]; then
        FINAL_RC=1
        log_error "Catch-up : listing remote instance=${CU_CONTAINER} FAILED (rc=${rc}) — catch-up instance SKIP (offsite non vérifiable)"
        CATCHUP_LIST_STATE[${CU_CONTAINER}]="FAIL"
        CATCHUP_LIST_FILES[${CU_CONTAINER}]=""
      else
        CATCHUP_LIST_STATE[${CU_CONTAINER}]="OK"
        CATCHUP_LIST_FILES[${CU_CONTAINER}]="${CU_LISTING}"
      fi
    fi
    if [[ "${CATCHUP_LIST_STATE[${CU_CONTAINER}]}" == "FAIL" ]]; then
      continue
    fi

    if [[ $'\n'"${CATCHUP_LIST_FILES[${CU_CONTAINER}]}"$'\n' == *$'\n'"${CU_BASE}.gpg"$'\n'* ]]; then
      continue   # déjà offsite — idempotent
    fi

    log_info "Catch-up : ${CU_BASE} absent du remote (instance=${CU_CONTAINER}) — re-encrypt+upload"
    rc=0
    encrypt_and_upload_file "${CU_FILE}" "${CU_CONTAINER}" "${ENV}" "${APP_NAME}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      FINAL_RC=1
      log_error "Catch-up : upload FAILED (rc=${rc}) — ${CU_BASE} (poursuite)"
    fi
  done

  # --- 6d. Rétention remote — OFF PAR DÉFAUT (ADR-016 : clé serveur write/list-only sans
  # DeleteObject ; ménage 30j = lifecycle bucket Contabo OU tâche admin poste ops).
  # N>0 = usage admin explicite uniquement (clé delete distincte — jamais celle du VPS).
  apply_remote_retention "${ENV}" "${APP_NAME}" "${A2K_BACKUP_REMOTE_RETENTION_DAYS:-0}"
fi

# ============================================================================
# Phase 7 — Sentinelle last-success
# ============================================================================
BACKUP_PHASE="sentinel"
log_phase "7. Sentinelle last-success (monitoring RPO V1)"

# M2 — GATED : last-success = succès COMPLET uniquement (toutes cibles + globals OK
# + upload offsite OK quand configuré — backup-v1 É1, décision verrouillée : FINAL_RC
# porte désormais AUSSI le succès upload/résolution phase 6), sinon le monitoring RPO V1
# lirait un succès menti sur un backup partiel OU non-offsité.
if [[ "${FINAL_RC}" -eq 0 ]]; then
  write_last_success_sentinel "${BACKUPS_DIR}"
else
  log_warn "Sentinelle SKIP — backup INCOMPLET (FINAL_RC=${FINAL_RC}) : last-success réservé aux runs 100% OK"
fi

# ============================================================================
# Phase 8 — Audit log JSON (M2 : log_hook_audit déplacé dans le trap EXIT backup_cleanup —
# loggé avec le rc RÉEL + duration réelle, même sur échec/interruption)
# ============================================================================
BACKUP_PHASE="audit-log"
log_phase "8. Audit log (émis par le trap EXIT avec le rc réel)"

# Piège hérité hooks-runner.sh ensure_audit_log_dir ligne 126 (`sudo mkdir … 2>/dev/null ||
# mkdir … 2>/dev/null || warn`) : NON ré-implémenté ici (restriction ticket). Le backup
# PRÉSUPPOSE le log dir /var/log/<app>/<env>/deploys déjà provisionné (Ansible Zone 3 setgid —
# T2 le garantit). Si le dir existe → aucun appel sudo. Si le dir manque → log_hook_audit
# WARN + return 0 sans faire échouer le backup (audit best-effort — le dump lui-même a réussi).
END_TS="$(date +%s)"
DURATION_S=$((END_TS - START_TS))

echo ""
if [[ "${FINAL_RC}" -eq 0 ]]; then
  log_ok "Backup ${APP_NAME}/${ENV} terminé (duration=${DURATION_S}s, DRY_RUN=${DRY_RUN})"
else
  log_error "Backup ${APP_NAME}/${ENV} INCOMPLET (dumps OK=${TARGETS_OK} FAILED=${TARGETS_FAILED} / globals PG FAILED=${GLOBALS_FAILED} / users MySQL FAILED=${USERS_FAILED} — duration=${DURATION_S}s)"
fi
exit "${FINAL_RC}"
