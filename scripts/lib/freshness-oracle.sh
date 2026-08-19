#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# freshness-oracle.sh — oracles fraîcheur artifacts deploy (E2E2 / ADR-018)
#
# Lib SOURCEABLE uniquement : PAS d'exécution top-level, PAS de `set -e` global
# (le caller — step GHA ou witness — gère sa propre discipline fail-fast).
# Messages stdout préfixés `[freshness]`.
#
# Contrat return codes (convention 0=PASS / 1=FAIL / 2=WARN) :
#   freshness_check_checkout  <repo_dir> <expected_ref>        → 0 | 1 | 2
#   freshness_check_tag_drift <env_config_file> <expected_tag> → 0 | 1 | 2
#   freshness_file_sha256     <file>                           → 0 (+ sha hex stdout) | 1
#
# Pattern caller correct (AP-1 bash-ops-specialist — JAMAIS `if ! cmd; then rc=$?`,
# la négation capture toujours 0) :
#   rc=0
#   freshness_check_checkout "$dir" "$ref" || rc=$?
#   case "$rc" in 0) ... ;; 1) ... ;; 2) ... ;; esac
#
# Dépendances : coreutils (sha256sum, grep) + git. Rien d'autre.
# Consommé par : .github/workflows/deploy-app.yml (O1/O3/O4) +
#   rollback-app.yml (O1) + freshness-witness.yml (fixtures locales).
# ─────────────────────────────────────────────────────────────────────────────

# freshness_check_checkout <repo_dir> <expected_ref>
# Oracle O1 — le checkout du caller repo correspond-il au ref demandé (app_ref) ?
#   0 = PASS : HEAD == expected_ref résolu.
#   1 = FAIL : mismatch (checkout stale/divergent) OU ref non résolvable OU
#       repo_dir invalide.
#   2 = WARN : expected_ref vide '' — cas S5 (invoker n'a pas fourni app_ref,
#       fallback github.sha natif actions/checkout — non évaluable).
freshness_check_checkout() {
  local repo_dir="$1"
  local expected_ref="$2"
  local head_sha=""
  local resolved=""

  if [ -z "${expected_ref}" ]; then
    echo "[freshness] O1 WARN : expected_ref vide — checkout non évaluable (app_ref '' — cf. DEPLOY-APP-INVOKER-GUIDE § app_ref)"
    return 2
  fi

  if ! git -C "${repo_dir}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[freshness] O1 FAIL : repo_dir invalide (pas un repo git) : ${repo_dir}"
    return 1
  fi

  head_sha="$(git -C "${repo_dir}" rev-parse HEAD 2>/dev/null)" || {
    echo "[freshness] O1 FAIL : HEAD non résolvable dans ${repo_dir}"
    return 1
  }

  if printf '%s' "${expected_ref}" | grep -qE '^[0-9a-f]{40}$'; then
    # SHA 40 hex → comparaison stricte à HEAD (un SHA inexistant → mismatch → FAIL).
    resolved="${expected_ref}"
  else
    resolved="$(git -C "${repo_dir}" rev-parse --verify "${expected_ref}^{commit}" 2>/dev/null)" || {
      echo "[freshness] O1 FAIL : expected_ref non résolvable en commit dans ${repo_dir} : ${expected_ref}"
      return 1
    }
  fi

  if [ "${head_sha}" = "${resolved}" ]; then
    echo "[freshness] O1 PASS : HEAD == expected_ref (${head_sha})"
    return 0
  fi

  echo "[freshness] O1 FAIL : HEAD ${head_sha} != expected_ref ${resolved} (${expected_ref}) — checkout stale/divergent"
  return 1
}

# freshness_check_tag_drift <env_config_file> <expected_tag>
# Oracle O4 — sémantique DA6 : PASS si AU MOINS UNE clé `*_VERSION` du fichier
# vaut expected_tag (évite les faux positifs structurels type POSTGRES_VERSION
# qui ne matchera jamais le tag app).
#   0 = PASS : ≥1 clé *_VERSION == expected_tag.
#   2 = WARN : aucune clé ne matche OU aucune clé *_VERSION présente
#       (liste clés/valeurs trouvées dans le message).
#   1 = FAIL : fichier absent/illisible.
freshness_check_tag_drift() {
  local cfg_file="$1"
  local expected_tag="$2"
  local line=""
  local key=""
  local value=""
  local found_keys=""
  local match_key=""

  if [ ! -f "${cfg_file}" ] || [ ! -r "${cfg_file}" ]; then
    echo "[freshness] O4 FAIL : fichier env config absent/illisible : ${cfg_file}"
    return 1
  fi

  while IFS= read -r line || [ -n "${line}" ]; do
    # Normalisation défensive de la ligne AVANT parse (F4 R1 — anti faux WARN) :
    #  - BOM UTF-8 en tête (fichier édité Notepad Windows) ;
    #  - CR traînants, TOUS (CRLF simple + \r\r\n double CR) — sinon la valeur embarque
    #    un \r invisible et la comparaison stricte au tag échoue en faux WARN ;
    #  - whitespace de tête (clé indentée).
    # Limite documentée (guide invoker § Oracles fraîcheur) : fichier à séparateurs CR
    # isolés old-Mac (\r seul, sans \n) NON supporté — read ne découpe que sur \n.
    line="${line#$'\xef\xbb\xbf'}"
    while [ "${line%$'\r'}" != "${line}" ]; do
      line="${line%$'\r'}"
    done
    line="${line#"${line%%[![:space:]]*}"}"
    # Ignorer commentaires + lignes vides ; ne retenir que `<KEY>_VERSION=<value>`.
    case "${line}" in
      \#* | '') continue ;;
    esac
    if ! printf '%s' "${line}" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*_VERSION='; then
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    # Strip quotes simples/doubles éventuelles (uniquement si paire englobante).
    case "${value}" in
      \"*\")
        value="${value#\"}"
        value="${value%\"}"
        ;;
      \'*\')
        value="${value#\'}"
        value="${value%\'}"
        ;;
    esac
    found_keys="${found_keys}${found_keys:+, }${key}=${value}"
    if [ "${value}" = "${expected_tag}" ]; then
      match_key="${key}"
    fi
  done < "${cfg_file}"

  if [ -n "${match_key}" ]; then
    echo "[freshness] O4 PASS : ${match_key} == expected tag (${expected_tag})"
    return 0
  fi

  if [ -z "${found_keys}" ]; then
    echo "[freshness] O4 WARN : aucune clé *_VERSION dans ${cfg_file} — drift non évaluable (expected tag ${expected_tag})"
    return 2
  fi

  echo "[freshness] O4 WARN : aucune clé *_VERSION ne matche le tag ${expected_tag} — clés trouvées : ${found_keys}"
  return 2
}

# freshness_file_sha256 <file>
# Oracle O3 (côté runner) — empreinte sha256 du fichier local, pour comparaison
# `sha256sum -c` côté VPS (fichier posé).
#   0 = OK : sha256 hex (64 chars) sur stdout.
#   1 = fichier absent/illisible (message sur stderr — stdout réservé au sha).
freshness_file_sha256() {
  local file="$1"
  local sum_output=""

  if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
    echo "[freshness] sha256 FAIL : fichier absent/illisible : ${file}" >&2
    return 1
  fi

  sum_output="$(sha256sum "${file}")" || {
    echo "[freshness] sha256 FAIL : sha256sum erreur sur ${file}" >&2
    return 1
  }

  printf '%s\n' "${sum_output%% *}"
  return 0
}
