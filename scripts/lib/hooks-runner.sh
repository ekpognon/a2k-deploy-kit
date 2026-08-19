#!/usr/bin/env bash
#
# scripts/lib/hooks-runner.sh — Hook invocation framework (cycle 29 A5+A8+A9+A10+A11)
#
# Provides functions to discover, validate, and invoke per-app hooks under file convention
# `<compose_path>/hooks/*.sh` (decision A7). Enforces timeouts (A9), fail semantics (A10),
# audit log JSON structured (A11), and smoke-test absent abort (A8).
#
# Decision A5 — 6 hooks supported (strict order in deploy.sh) :
#   1. pre-deploy.sh       (timeout 600s, fail=ABORT)
#   2. healthcheck.sh      (timeout 180s, fail=ROLLBACK)
#   3. post-deploy.sh      (timeout 120s, fail=WARNING_CONTINUE — overridable via A2K_HOOK_FAIL_BEHAVIOR_POST_DEPLOY=rollback)
#   4. smoke-test.sh       (timeout 60s,  fail=ROLLBACK, ERROR+abort if absent A8)
#   5. pre-rollback.sh     (timeout 60s,  fail=WARNING_CONTINUE)
#   6. post-rollback.sh    (timeout 60s,  fail=WARNING_OK)
#
# Discipline : set -euo pipefail + bash-ops-specialist AP-1 (exit code capture) + JSON log
# audit append-only (A11) + idempotent log dir creation.
# Cross-refs : ADR-010 A5-A11 + DEPLOY-APP-INVOKER-GUIDE.md § Hooks contract.

if [[ -n "${A2K_HOOKS_RUNNER_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly A2K_HOOKS_RUNNER_LIB_LOADED=1

# Cycle 37 (ADR-008 amend / ADR-013) — umask 027 défensif (ceinture+bretelles). Déjà hérité par
# process depuis app-deploy.sh / app-rollback.sh qui sourcent ce lib ; ré-affirmé ici pour protéger
# si un futur appelant source ce lib sans umask restrictif (log dir + hooks per-app). Aligné setgid
# des zones FHS → sous-dirs/fichiers non-world-readable (ops_discipline §5).
umask 027

# ============================================================================
# Default timeouts per hook (decision A9 — overridable via A2K_HOOK_TIMEOUT_<HOOK>)
# ============================================================================
readonly A2K_HOOK_TIMEOUT_PRE_DEPLOY_DEFAULT=600
readonly A2K_HOOK_TIMEOUT_HEALTHCHECK_DEFAULT=180
readonly A2K_HOOK_TIMEOUT_POST_DEPLOY_DEFAULT=120
readonly A2K_HOOK_TIMEOUT_SMOKE_TEST_DEFAULT=60
readonly A2K_HOOK_TIMEOUT_PRE_ROLLBACK_DEFAULT=60
readonly A2K_HOOK_TIMEOUT_POST_ROLLBACK_DEFAULT=60

# ============================================================================
# Default fail behaviors per hook (decision A10 — 5 NON-overridable + 1 overridable)
# ============================================================================
# Values : ABORT | ROLLBACK | WARNING_CONTINUE | WARNING_OK
readonly A2K_HOOK_FAIL_PRE_DEPLOY="ABORT"
readonly A2K_HOOK_FAIL_HEALTHCHECK="ROLLBACK"
readonly A2K_HOOK_FAIL_SMOKE_TEST="ROLLBACK"
readonly A2K_HOOK_FAIL_PRE_ROLLBACK="WARNING_CONTINUE"
readonly A2K_HOOK_FAIL_POST_ROLLBACK="WARNING_OK"
# post-deploy : default WARNING_CONTINUE, overridable via A2K_HOOK_FAIL_BEHAVIOR_POST_DEPLOY=rollback
readonly A2K_HOOK_FAIL_POST_DEPLOY_DEFAULT="WARNING_CONTINUE"

# ============================================================================
# get_hook_timeout — Resolve effective timeout for hook (default OR override)
# ============================================================================
# Args : $1=hook_name (e.g. "pre-deploy", "healthcheck")
# Echo : effective timeout in seconds
get_hook_timeout() {
  local hook_name="${1:?hook_name required}"
  local default_var
  local override_var

  # Convert hook name to uppercase with underscores : pre-deploy → PRE_DEPLOY
  local hook_upper
  hook_upper="$(echo "${hook_name}" | tr 'a-z-' 'A-Z_')"

  default_var="A2K_HOOK_TIMEOUT_${hook_upper}_DEFAULT"
  override_var="A2K_HOOK_TIMEOUT_${hook_upper}"

  # Override takes precedence
  if [[ -n "${!override_var:-}" ]]; then
    echo "${!override_var}"
  else
    echo "${!default_var:-60}"
  fi
}

# ============================================================================
# get_hook_fail_behavior — Resolve effective fail behavior for hook
# ============================================================================
get_hook_fail_behavior() {
  local hook_name="${1:?hook_name required}"

  case "${hook_name}" in
    pre-deploy)    echo "${A2K_HOOK_FAIL_PRE_DEPLOY}" ;;
    healthcheck)   echo "${A2K_HOOK_FAIL_HEALTHCHECK}" ;;
    smoke-test)    echo "${A2K_HOOK_FAIL_SMOKE_TEST}" ;;
    pre-rollback)  echo "${A2K_HOOK_FAIL_PRE_ROLLBACK}" ;;
    post-rollback) echo "${A2K_HOOK_FAIL_POST_ROLLBACK}" ;;
    post-deploy)
      # Overridable via A2K_HOOK_FAIL_BEHAVIOR_POST_DEPLOY=rollback (decision A10)
      local override="${A2K_HOOK_FAIL_BEHAVIOR_POST_DEPLOY:-}"
      if [[ "${override}" == "rollback" ]]; then
        echo "ROLLBACK"
      else
        echo "${A2K_HOOK_FAIL_POST_DEPLOY_DEFAULT}"
      fi
      ;;
    *)
      echo "[ERROR] get_hook_fail_behavior: hook='${hook_name}' unknown" >&2
      echo "WARNING_CONTINUE"  # safe default
      return 1
      ;;
  esac
}

# ============================================================================
# ensure_audit_log_dir — Create audit log dir if absent (idempotent, A11)
# ============================================================================
ensure_audit_log_dir() {
  local app_name="${A2K_APP_NAME:?A2K_APP_NAME not set}"
  local env="${A2K_ENV:?A2K_ENV not set}"
  local log_dir="/var/log/${app_name}/${env}/deploys"

  if [[ "${A2K_DRY_RUN:-0}" == "1" ]]; then
    echo "[DRY_RUN] mkdir -p ${log_dir}"
    return 0
  fi

  # A11 — create with sudo if not writable (audit log dir typically root-owned)
  if [[ ! -d "${log_dir}" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      mkdir -p "${log_dir}"
    else
      sudo mkdir -p "${log_dir}" 2>/dev/null || mkdir -p "${log_dir}" 2>/dev/null || {
        echo "[WARN] ensure_audit_log_dir: cannot create ${log_dir} — audit log skipped" >&2
        return 1
      }
    fi
  fi

  return 0
}

# ============================================================================
# log_hook_audit — Append JSON-structured audit entry (A11)
# ============================================================================
# Args : $1=hook_name $2=exit_code $3=duration_s $4=fail_behavior
log_hook_audit() {
  local hook_name="${1:?hook_name required}"
  local exit_code="${2:?exit_code required}"
  local duration_s="${3:?duration_s required}"
  local fail_behavior="${4:-N/A}"

  local app_name="${A2K_APP_NAME:?A2K_APP_NAME not set}"
  local env="${A2K_ENV:?A2K_ENV not set}"
  local timestamp="${A2K_DEPLOY_TIMESTAMP:?A2K_DEPLOY_TIMESTAMP not set}"
  local action="${A2K_ACTION:-deploy}"
  local log_file="/var/log/${app_name}/${env}/deploys/${timestamp}.log"

  local json_line
  json_line=$(printf '{"timestamp":"%s","action":"%s","hook":"%s","exit_code":%s,"duration_s":%s,"fail_behavior":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${action}" \
    "${hook_name}" \
    "${exit_code}" \
    "${duration_s}" \
    "${fail_behavior}")

  if [[ "${A2K_DRY_RUN:-0}" == "1" ]]; then
    echo "[DRY_RUN] audit log: ${json_line}"
    return 0
  fi

  if ! ensure_audit_log_dir; then
    echo "[WARN] log_hook_audit: audit dir unavailable, skipping" >&2
    return 0
  fi

  echo "${json_line}" >> "${log_file}" 2>/dev/null || {
    echo "[WARN] log_hook_audit: cannot append ${log_file}" >&2
    return 0
  }
}

# ============================================================================
# validate_hook_executable — Check hook file is executable bash script
# ============================================================================
validate_hook_executable() {
  local hook_path="${1:?hook_path required}"

  if [[ ! -f "${hook_path}" ]]; then
    return 1
  fi
  if [[ ! -x "${hook_path}" ]]; then
    echo "[ERROR] validate_hook_executable: ${hook_path} exists but not executable (chmod +x required)" >&2
    return 1
  fi
  return 0
}

# ============================================================================
# discover_hooks — List hooks present in hooks_dir (file convention A7)
# ============================================================================
# Echo : space-separated list of hooks present (e.g. "pre-deploy healthcheck smoke-test")
discover_hooks() {
  local hooks_dir="${1:?hooks_dir required}"
  local found=()
  local hook

  if [[ ! -d "${hooks_dir}" ]]; then
    return 0
  fi

  for hook in pre-deploy healthcheck post-deploy smoke-test pre-rollback post-rollback; do
    if [[ -f "${hooks_dir}/${hook}.sh" ]]; then
      found+=("${hook}")
    fi
  done

  echo "${found[@]:-}"
}

# ============================================================================
# run_hook — Execute hook with timeout, capture exit code, log audit
# ============================================================================
# Args : $1=hook_name $2=hooks_dir
# Returns : 0 if hook OK OR fail_behavior tolerates failure
#           1 if hook fail AND fail_behavior=ABORT
#           2 if hook fail AND fail_behavior=ROLLBACK (caller triggers rollback)
#
# Special : if smoke-test.sh absent → ERROR + return 1 (A8 enforce discipline qualité)
run_hook() {
  local hook_name="${1:?hook_name required}"
  local hooks_dir="${2:?hooks_dir required}"
  local hook_path="${hooks_dir}/${hook_name}.sh"

  local fail_behavior
  fail_behavior="$(get_hook_fail_behavior "${hook_name}")"

  local timeout_s
  timeout_s="$(get_hook_timeout "${hook_name}")"

  # A8 — smoke-test absent enforce ERROR + abort
  if [[ "${hook_name}" == "smoke-test" ]] && [[ ! -f "${hook_path}" ]]; then
    echo "[ERROR] smoke-test.sh OBLIGATOIRE V0 (decision A8) — discipline qualité enforce. Apps DOIVENT fournir." >&2
    echo "       Path attendu: ${hook_path}" >&2
    echo "       Cf. docs/contracts/DEPLOY-APP-INVOKER-GUIDE.md § Smoke-test obligatoire V0 (A8)" >&2
    return 1
  fi

  # Hook absent (sauf smoke-test) — skip silencieusement
  if [[ ! -f "${hook_path}" ]]; then
    echo "[INFO] Hook '${hook_name}' absent (${hook_path}) — skip (optional)"
    return 0
  fi

  # Validate executable bit
  if ! validate_hook_executable "${hook_path}"; then
    echo "[ERROR] Hook '${hook_name}' present but invalid — abort" >&2
    return 1
  fi

  echo ""
  echo "▶ Hook '${hook_name}' (timeout=${timeout_s}s, fail_behavior=${fail_behavior})"
  echo "  Path: ${hook_path}"

  if [[ "${A2K_DRY_RUN:-0}" == "1" ]]; then
    echo "[DRY_RUN] Would execute: timeout ${timeout_s} bash ${hook_path}"
    log_hook_audit "${hook_name}" 0 0 "${fail_behavior}"
    return 0
  fi

  # AP-1 bash-ops-specialist : exit code capture pattern (NOT `if ! cmd; then rc=$?` — that captures 0).
  local start_ts
  local end_ts
  local rc=0
  start_ts="$(date +%s)"

  # `timeout` enforce A9 + propagate exit code correctly
  timeout "${timeout_s}" bash "${hook_path}" || rc=$?

  end_ts="$(date +%s)"
  local duration_s=$((end_ts - start_ts))

  log_hook_audit "${hook_name}" "${rc}" "${duration_s}" "${fail_behavior}"

  if [[ "${rc}" -eq 0 ]]; then
    echo "  ✓ Hook '${hook_name}' OK (duration=${duration_s}s)"
    return 0
  fi

  # `timeout` returns 124 if killed by timeout
  if [[ "${rc}" -eq 124 ]]; then
    echo "  ✗ Hook '${hook_name}' TIMEOUT (>${timeout_s}s, duration=${duration_s}s)" >&2
  else
    echo "  ✗ Hook '${hook_name}' FAILED (exit=${rc}, duration=${duration_s}s)" >&2
  fi

  # Apply fail behavior A10
  case "${fail_behavior}" in
    ABORT)
      echo "  → fail_behavior=ABORT — aborting deploy" >&2
      return 1
      ;;
    ROLLBACK)
      echo "  → fail_behavior=ROLLBACK — caller must trigger rollback" >&2
      return 2
      ;;
    WARNING_CONTINUE)
      echo "  → fail_behavior=WARNING_CONTINUE — deploy continues (non-fatal)" >&2
      return 0
      ;;
    WARNING_OK)
      echo "  → fail_behavior=WARNING_OK — rollback already completed (non-fatal)" >&2
      return 0
      ;;
    *)
      echo "  → fail_behavior='${fail_behavior}' UNKNOWN — treating as ABORT (safe default)" >&2
      return 1
      ;;
  esac
}
