#!/usr/bin/env bash
#
# scripts/lib/backup-lib.sh — Library backup shared V0 (backup-v0 T1 — design 2026-06-30)
#
# Factorized backup primitives consumed by scripts/app-backup.sh (orchestrateur) and,
# on negotiated terms only (guide T3), by per-app hooks (e.g. pre-deploy.sh D-Backup-A).
#
# Scope V0 (modèle verrouillé Mode A user — design 2026-06-30-shared-backup-script-DESIGN-OPTIONS.md
# (document de travail NON versionné ce repo — cf. ADR-015 §Context)
# + validation indépendante 3 blockers / 5 ajustements) :
#   - pg_dump -F c par base postgres (mode docker : exec DANS le conteneur — version pg_dump =
#     serveur, auth locale conteneur trust/peer : AUCUN secret Zone 4 requis pour le dump —
#     propriété PG-ONLY, cf. bullet mysql ci-dessous)
#   - pg_dumpall --globals-only (rôles/GRANTs — critique Soiroke dual-user : restore sans globals échoue)
#   - mysqldump par base mysql (multi-moteurs 2026-07-11 — ADR-015 amend, Option B dispatch
#     per-engine) : credential IN-CONTAINER via `sh -c 'exec mysqldump … -p"$<password_env>"'`
#     (pattern image officielle Docker Hub) — le secret est déjà dans l'env du conteneur
#     (compose env_file ← Zone 4), JAMAIS sourcé host-side, JAMAIS dans le manifest (NOM de
#     var uniquement). Primitives : dump_mysql_docker / dump_mysql_network (stub V0) /
#     dump_mysql_users (users+GRANTs par container — équivalent fonctionnel des globals PG)
#   - retention locale compteurs explicit (mirror prune_old_images audit-helpers.sh)
#   - offsite S3 V1 CÂBLÉ (backup-v1 É1) : cascade override per-app / socle per-env (set PARTIEL
#     = ERREUR bruyante, opt-out total = skip propre), chiffrement GPG per-file AVANT rclone
#     copyto <env>/<app>/<instance>/ (jamais d'offsite en clair). Rétention remote OFF par défaut
#     (ADR-016 : clé serveur write/list-only sans DeleteObject — ménage 30j = lifecycle bucket OU admin)
#   - sentinelle last-success (ajustement F — monitoring RPO V1)
#   - access=network RÉSERVÉ V0 (stub fail-fast explicite, PAS de silent success)
#
# Ajustement D (write-once local) : chmod 0440 post-écriture de chaque dump — mitige
# ADR-008 amend cycle 31 "deploy compromis (CI key leak) peut détruire les backups" :
# le fichier devient read-only même pour l'owner (rm reste possible via perms dir 02770,
# mais l'écrasement/corruption silencieuse est bloquée — defense-in-depth V0).
#
# Discipline :
#   - Lib sourcée : PAS de `set -euo pipefail` ici (hérité de l'appelant — cohérent
#     env-vars.sh / audit-helpers.sh qui ne le posent pas).
#   - AP-1 bash-ops-specialist : exit code capture `cmd || rc=$?` — JAMAIS de négation
#     en condition `if` pour capturer un rc (piège : capture 0, pas le vrai exit code).
#     Cf. hooks-runner.sh:272 pattern canonique.
#   - JAMAIS de secret loggé (pas d'echo des vars rclone/DB — noms de vars OK, valeurs JAMAIS).
#   - DRY_RUN guard sur toute action à effet de bord (print la commande, ne l'exécute pas).
#
# Cross-refs : ADR-011 D-Backup-A (pg_dump -F c + retention 7j) + ADR-008 amend cycle 31
# + ops_discipline.md §11 backup strategy RPO/RTO + filesystem_layout.md Zone 2 backups.

# Idempotent guard — prevent double-sourcing (mirror env-vars.sh:30-33).
if [[ -n "${A2K_BACKUP_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly A2K_BACKUP_LIB_LOADED=1

# umask 027 ré-affirmé (mirror hooks-runner.sh:30) — compagnon setgid Zone 2 backups 02770 :
# fichiers créés 0640 avant le chmod 0440 write-once. Protège si un futur appelant source
# ce lib sans umask restrictif.
umask 027

# ============================================================================
# Logging fallbacks — used only if the caller did not define log helpers
# (app-backup.sh defines colored log_info/log_ok/log_warn/log_error before sourcing).
# ============================================================================
_backup_lib_have_log_helpers=0
declare -F log_info >/dev/null 2>&1 && _backup_lib_have_log_helpers=1
if [[ "${_backup_lib_have_log_helpers}" -eq 0 ]]; then
  log_info()  { echo "[INFO] $*"; }
  log_ok()    { echo "[OK] $*"; }
  log_warn()  { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
fi
unset _backup_lib_have_log_helpers

# ============================================================================
# backup_lib_is_dry_run — DRY_RUN detection (A2K_DRY_RUN contract first, raw DRY_RUN fallback
# for hook callers that source this lib outside app-backup.sh)
# ============================================================================
backup_lib_is_dry_run() {
  [[ "${A2K_DRY_RUN:-${DRY_RUN:-0}}" == "1" ]]
}

# ============================================================================
# dump_postgres_docker — pg_dump -F c d'une base via docker exec (mode access=docker)
# ============================================================================
# Args : $1=container $2=db_user $3=db_name $4=out_file
# Contract :
#   - Pré-validation fail-fast : le container DOIT exister (pas de nom deviné).
#   - pg_dump exécuté DANS le conteneur → version pg_dump = version serveur (jamais de
#     mismatch client/serveur) + auth locale conteneur (trust/peer socket) : aucun secret
#     Zone 4 nécessaire pour le dump en mode docker — propriété PG-ONLY (l'image officielle
#     mysql n'a PAS d'auth socket sans mot de passe : cf. dump_mysql_docker credential
#     in-container).
#   - Fail-fast dump vide/corrompu ([[ -s ]]) + cleanup du fichier partiel.
#   - chmod 0440 post-écriture (ajustement D write-once — cf. header).
dump_postgres_docker() {
  local container="${1:?container required}"
  local db_user="${2:?db_user required}"
  local db_name="${3:?db_name required}"
  local out_file="${4:?out_file required}"

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] docker exec ${container} pg_dump -U ${db_user} -F c ${db_name} > ${out_file}"
    echo "[DRY_RUN] chmod 0440 ${out_file}"
    return 0
  fi

  # Pré-validation fail-fast : container existant (docker inspect) — pas de nom deviné.
  docker inspect "${container}" >/dev/null 2>&1 || {
    log_error "dump_postgres_docker: container '${container}' introuvable (docker inspect fail) — vérifier manifest vs compose app"
    return 1
  }

  # Pré-check anti-écrasement (M1) : un fichier pré-existant (write-once 0440) ferait échouer
  # le redirect ET le rm -f post-échec détruirait un dump VALIDE — refuser AVANT, sans rm.
  if [[ -e "${out_file}" ]]; then
    log_error "dump_postgres_docker: refuse d'écraser ${out_file} pré-existant (write-once 0440 — collision filename, cf. validation manifest)"
    return 1
  fi

  # AP-1 exit code capture (jamais `if !` — cf. hooks-runner.sh:272).
  local rc=0
  docker exec "${container}" pg_dump -U "${db_user}" -F c "${db_name}" > "${out_file}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "dump_postgres_docker: pg_dump failed (rc=${rc}) container=${container} db=${db_name}"
    rm -f "${out_file}"
    return 1
  fi

  # Fail-fast dump vide/corrompu.
  [[ -s "${out_file}" ]] || {
    log_error "dump_postgres_docker: dump vide/corrompu — ${out_file} (supprimé)"
    rm -f "${out_file}"
    return 1
  }

  # Ajustement D — write-once local (cf. header lib).
  chmod 0440 "${out_file}"
  log_ok "dump_postgres_docker: ${out_file} ($(du -h "${out_file}" 2>/dev/null | cut -f1 || echo '?'))"
  return 0
}

# ============================================================================
# dump_postgres_network — RÉSERVÉ V0 (stub fail-fast explicite, PAS de silent success)
# ============================================================================
# Args réservés : $1=host $2=port $3=sslmode $4=db_user $5=db_name $6=out_file
# V0 : manifest access=network → validation schéma app-backup.sh exit 1 AVANT d'arriver ici.
# Ce stub = double filet si un appelant hook invoque directement la lib.
dump_postgres_network() {
  log_error "dump_postgres_network: network access non implémenté V0 — cf. manifest access=network réservé (backup-manifest.TEMPLATE.yml)"
  return 1
}

# ============================================================================
# dumpall_globals — pg_dumpall --globals-only (rôles/GRANTs cluster-wide)
# ============================================================================
# Args : $1=container $2=db_user $3=out_file
# Critique Soiroke dual-user (POSTGRES_USER soiroke_admin + POSTGRES_APP_USER soiroke_app) :
# un restore sans les globals (rôles + GRANTs) échoue — les objets référencent des rôles absents.
dumpall_globals() {
  local container="${1:?container required}"
  local db_user="${2:?db_user required}"
  local out_file="${3:?out_file required}"

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] docker exec ${container} pg_dumpall -U ${db_user} --globals-only > ${out_file}"
    echo "[DRY_RUN] chmod 0440 ${out_file}"
    return 0
  fi

  docker inspect "${container}" >/dev/null 2>&1 || {
    log_error "dumpall_globals: container '${container}' introuvable (docker inspect fail)"
    return 1
  }

  # Pré-check anti-écrasement (M1) : refuser AVANT le redirect, sans rm — un rm -f post-échec
  # sur fichier pré-existant 0440 détruirait un dump globals VALIDE.
  if [[ -e "${out_file}" ]]; then
    log_error "dumpall_globals: refuse d'écraser ${out_file} pré-existant (write-once 0440 — collision filename, cf. validation manifest)"
    return 1
  fi

  # AP-1 exit code capture.
  local rc=0
  docker exec "${container}" pg_dumpall -U "${db_user}" --globals-only > "${out_file}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "dumpall_globals: pg_dumpall failed (rc=${rc}) container=${container}"
    rm -f "${out_file}"
    return 1
  fi

  [[ -s "${out_file}" ]] || {
    log_error "dumpall_globals: dump globals vide/corrompu — ${out_file} (supprimé)"
    rm -f "${out_file}"
    return 1
  }

  chmod 0440 "${out_file}"
  log_ok "dumpall_globals: ${out_file}"
  return 0
}

# ============================================================================
# dump_mysql_docker — mysqldump d'une base via docker exec (mode access=docker)
# ============================================================================
# Args : $1=container $2=db_user $3=db_name $4=out_file $5=password_env
# Contract (multi-moteurs 2026-07-11 — ADR-015 amend, arbitrages Mode A user + D1/D2/D3) :
#   - Credential IN-CONTAINER : la commande est une STRING `sh -c` contenant le littéral
#     `-p"$<password_env>"` NON expansé host-side — le shell qui expanse est le `sh` DANS
#     le conteneur (le secret y est déjà : compose env_file ← Zone 4). Zéro transit
#     host-side, zéro leak DRY_RUN (la valeur n'existe pas côté hôte). ❌ INTERDIT :
#     `docker exec -e MYSQL_PWD=…` (déprécié doc MySQL 8.x + transit host-side).
#   - password_env = NOM de var d'env in-container (validé phase 2 app-backup.sh :
#     whitelist générique PUIS forme stricte ^[A-Z][A-Z0-9_]{0,63}$ — defense-in-depth,
#     la valeur est interpolée dans la string sh -c). Défaut manifest : MYSQL_ROOT_PASSWORD.
#   - Flags canoniques (D3) : --single-transaction --skip-lock-tables --quick (snapshot
#     MVCC cohérent InnoDB sans lock) + --routines --events (per-DB, défaut OFF — sans eux
#     le restore perd procédures/events) + --databases <db> (émet CREATE DATABASE IF NOT
#     EXISTS + USE → couvre la perte totale sans createdb manuel). NE PAS passer
#     --skip-comments/--skip-dump-date : l'assert troncature dépend de `-- Dump completed`.
#   - Check InnoDB défensif = WARN non bloquant (D3) : tables non-InnoDB listées (cohérence
#     snapshot non garantie hors InnoDB) — un ERROR bloquant sur une table marginale MyISAM
#     transformerait un backup utilisable en zéro backup (sémantique continue + agrégat M2).
#   - Assert troncature (D3) : dernière ligne DOIT matcher `-- Dump completed` — un dump SQL
#     text coupé mid-stream passe le [[ -s ]] (contrairement au -F c PG).
#   - Mêmes gardes que dump_postgres_docker : docker inspect fail-fast + pré-check
#     anti-écrasement write-once + cleanup fichier partiel + chmod 0440.
dump_mysql_docker() {
  local container="${1:?container required}"
  local db_user="${2:?db_user required}"
  local db_name="${3:?db_name required}"
  local out_file="${4:?out_file required}"
  local password_env="${5:?password_env required}"

  # Strings in-container : `\$${password_env}` produit le littéral `$MYSQL_ROOT_PASSWORD`
  # (NON expansé host-side). db_name/db_user/password_env whitelist-validés phase 2.
  local in_dump_cmd in_innodb_check_cmd
  in_dump_cmd="exec mysqldump --single-transaction --skip-lock-tables --quick --routines --events --databases ${db_name} -u${db_user} -p\"\$${password_env}\""
  in_innodb_check_cmd="exec mysql -N -B -u${db_user} -p\"\$${password_env}\" -e \"SELECT table_name FROM information_schema.tables WHERE table_schema='${db_name}' AND engine <> 'InnoDB'\""

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] docker exec ${container} sh -c '${in_innodb_check_cmd}' (check InnoDB — WARN non bloquant)"
    echo "[DRY_RUN] docker exec ${container} sh -c '${in_dump_cmd}' > ${out_file}"
    echo "[DRY_RUN] tail -n 1 ${out_file} | grep -- '-- Dump completed' (assert troncature)"
    echo "[DRY_RUN] chmod 0440 ${out_file}"
    return 0
  fi

  # Pré-validation fail-fast : container existant (docker inspect) — pas de nom deviné.
  docker inspect "${container}" >/dev/null 2>&1 || {
    log_error "dump_mysql_docker: container '${container}' introuvable (docker inspect fail) — vérifier manifest vs compose app"
    return 1
  }

  # Pré-check anti-écrasement (M1) : refuser AVANT le redirect, sans rm — un rm -f post-échec
  # sur fichier pré-existant 0440 détruirait un dump VALIDE (miroir dump_postgres_docker).
  if [[ -e "${out_file}" ]]; then
    log_error "dump_mysql_docker: refuse d'écraser ${out_file} pré-existant (write-once 0440 — collision filename, cf. validation manifest)"
    return 1
  fi

  # Check InnoDB défensif — WARN non bloquant (D3). AP-1 capture rc.
  local rc=0 non_innodb=""
  non_innodb="$(docker exec "${container}" sh -c "${in_innodb_check_cmd}" 2>/dev/null)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_warn "dump_mysql_docker: check InnoDB impossible (rc=${rc}) container=${container} db=${db_name} — poursuite (non bloquant)"
  elif [[ -n "${non_innodb}" ]]; then
    log_warn "dump_mysql_docker: tables non-InnoDB dans ${db_name} (cohérence snapshot --single-transaction NON garantie) : $(echo "${non_innodb}" | tr '\n' ' ')"
  fi

  # AP-1 exit code capture (jamais `if !` — cf. hooks-runner.sh:272).
  rc=0
  docker exec "${container}" sh -c "${in_dump_cmd}" > "${out_file}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "dump_mysql_docker: mysqldump failed (rc=${rc}) container=${container} db=${db_name}"
    rm -f "${out_file}"
    return 1
  fi

  # Fail-fast dump vide/corrompu.
  [[ -s "${out_file}" ]] || {
    log_error "dump_mysql_docker: dump vide/corrompu — ${out_file} (supprimé)"
    rm -f "${out_file}"
    return 1
  }

  # Assert troncature (D3) : mysqldump termine par `-- Dump completed on <date>` — un dump
  # SQL text coupé mid-stream (connexion tombée) passe le [[ -s ]], PAS cet assert.
  rc=0
  tail -n 1 "${out_file}" | grep -q -- "-- Dump completed" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "dump_mysql_docker: dump tronqué (dernière ligne ≠ '-- Dump completed') — ${out_file} (supprimé)"
    rm -f "${out_file}"
    return 1
  fi

  # Ajustement D — write-once local (cf. header lib).
  chmod 0440 "${out_file}"
  log_ok "dump_mysql_docker: ${out_file} ($(du -h "${out_file}" 2>/dev/null | cut -f1 || echo '?'))"
  return 0
}

# ============================================================================
# dump_mysql_network — RÉSERVÉ V0 (stub fail-fast explicite, PAS de silent success)
# ============================================================================
# Miroir dump_postgres_network : manifest access=network → validation schéma app-backup.sh
# exit 1 AVANT d'arriver ici. Ce stub = double filet si un appelant hook invoque directement la lib.
dump_mysql_network() {
  log_error "dump_mysql_network: network access non implémenté V0 — cf. manifest access=network réservé (backup-manifest.TEMPLATE.yml)"
  return 1
}

# ============================================================================
# dump_mysql_users — users + GRANTs MySQL par container (équivalent globals PG)
# ============================================================================
# Args : $1=container $2=db_user $3=out_file $4=password_env
# Équivalent fonctionnel de pg_dumpall --globals-only côté MySQL (LTS 8.0/8.4 : PAS de
# `mysqldump --users` — MySQL ≥9.3 uniquement) : boucle SHOW CREATE USER + SHOW GRANTS
# scriptée (pattern industrie standard), fichier SQL rejouable terminé par FLUSH PRIVILEGES;.
# Exclusions (D3) : comptes système mysql.infoschema / mysql.session / mysql.sys + root —
# root est géré par l'image via env au bootstrap : rejouer son CREATE USER au restore
# écraserait le hash courant avec l'ancien.
# ⚠ Le fichier contient des password hashes — même discipline de non-exfiltration que les
# globals PG (jamais persisté/copié hors VPS en clair — cf. restore-db.md § Sécurité).
# Enjeu restore plus faible que PG (pas d'OWNER par rôle MySQL — seuls les GRANTs
# applicatifs manquent si absent) mais nécessaire pour la perte totale du conteneur.
dump_mysql_users() {
  local container="${1:?container required}"
  local db_user="${2:?db_user required}"
  local out_file="${3:?out_file required}"
  local password_env="${4:?password_env required}"

  # Littéral `$<password_env>` NON expansé host-side (cf. dump_mysql_docker contract).
  local in_list_cmd
  in_list_cmd="exec mysql -N -B -u${db_user} -p\"\$${password_env}\" -e \"SELECT user, host FROM mysql.user WHERE user NOT IN ('mysql.infoschema','mysql.session','mysql.sys','root')\""

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] docker exec ${container} sh -c '${in_list_cmd}' (liste comptes hors système + root)"
    echo "[DRY_RUN] par compte : docker exec ${container} sh -c 'exec mysql -N -B -u${db_user} -p\"\$${password_env}\" -e \"SET print_identified_with_as_hex = ON; SHOW CREATE USER ...; SHOW GRANTS FOR ...;\"' >> ${out_file} (hashes en hex rejouables — statements suffixés ';')"
    echo "[DRY_RUN] echo 'FLUSH PRIVILEGES;' >> ${out_file}"
    echo "[DRY_RUN] chmod 0440 ${out_file}"
    return 0
  fi

  docker inspect "${container}" >/dev/null 2>&1 || {
    log_error "dump_mysql_users: container '${container}' introuvable (docker inspect fail)"
    return 1
  }

  # Pré-check anti-écrasement (M1) : refuser AVANT, sans rm (miroir dumpall_globals).
  if [[ -e "${out_file}" ]]; then
    log_error "dump_mysql_users: refuse d'écraser ${out_file} pré-existant (write-once 0440 — collision filename, cf. validation manifest)"
    return 1
  fi

  # Liste des comptes (batch -N -B : user<TAB>host, 1 par ligne). AP-1 capture rc.
  local rc=0 accounts=""
  accounts="$(docker exec "${container}" sh -c "${in_list_cmd}")" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "dump_mysql_users: listing comptes failed (rc=${rc}) container=${container}"
    return 1
  fi
  if [[ -z "${accounts}" ]]; then
    log_error "dump_mysql_users: aucun compte hors système/root — inattendu (le user applicatif du manifest devrait exister) container=${container}"
    return 1
  fi

  # En-tête du fichier rejouable (rappel discipline hashes — cf. header fonction).
  {
    echo "-- dump_mysql_users: users + GRANTs (container=${container}) — contient des password hashes"
    echo "-- Rejouable : mysql < ce fichier (cf. restore-db.md § Restore MySQL, Step 1-MySQL)"
  } > "${out_file}" || {
    log_error "dump_mysql_users: écriture ${out_file} impossible"
    rm -f "${out_file}"
    return 1
  }

  # Boucle SHOW CREATE USER + SHOW GRANTS par compte, statements suffixés ';'.
  # Garde anti-injection défensive : user/host proviennent de mysql.user (semi-trusted) —
  # un compte hors whitelist (quotes, backticks, …) est SKIPPÉ avec WARN visible plutôt
  # qu'interpolé dans une string SQL (discipline lib anti-injection).
  # Hashes rejouables (F2 review R1) : `SET print_identified_with_as_hex = ON` (portée
  # session — préfixé au même `-e` que les SHOW, chaque docker exec = session neuve) rend
  # les hashes binaires en hex (0x…). Sans lui, le salt binaire caching_sha2_password
  # (~15 %/compte contient `\` ou `'`) traverse 2 couches d'échappement (littéral SQL
  # serveur PUIS batch -B) → rejeu cassé ou hash corrompu silencieux. Doc MySQL : « should
  # be enabled when the intent is to capture statements that can be replayed ». Requiert
  # MySQL ≥ 8.0.17 (variable inconnue = SET fail → rc≠0 fail-fast visible, jamais silencieux).
  # Validation round-trip EMPIRIQUE au 1er DR-drill STG (restore-db.md § DR-drill).
  local u h
  while IFS=$'\t' read -r u h; do
    [[ -n "${u}" ]] || continue
    if [[ ! "${u}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || [[ ! "${h}" =~ ^[A-Za-z0-9._%-]{1,128}$ ]]; then
      log_warn "dump_mysql_users: compte '${u}'@'${h}' hors whitelist — SKIP (à dumper manuellement si légitime)"
      continue
    fi
    rc=0
    docker exec "${container}" sh -c "exec mysql -N -B -u${db_user} -p\"\$${password_env}\" -e \"SET print_identified_with_as_hex = ON; SHOW CREATE USER '${u}'@'${h}'; SHOW GRANTS FOR '${u}'@'${h}';\"" \
      | sed 's/$/;/' >> "${out_file}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      log_error "dump_mysql_users: SHOW CREATE USER/GRANTS failed (rc=${rc}) compte '${u}'@'${h}' — ${out_file} (supprimé)"
      rm -f "${out_file}"
      return 1
    fi
  done <<< "${accounts}"

  # Garde écriture (flag booléen — pas de capture $? sur echo, SC2320) : un échec (disk full)
  # laisserait un fichier rejouable INCOMPLET que le [[ -s ]] seul ne détecte pas (l'en-tête
  # suffit à le rendre non-vide).
  local flush_write_ok=1
  echo "FLUSH PRIVILEGES;" >> "${out_file}" || flush_write_ok=0
  if [[ "${flush_write_ok}" -ne 1 ]]; then
    log_error "dump_mysql_users: écriture FLUSH PRIVILEGES; failed — ${out_file} (supprimé)"
    rm -f "${out_file}"
    return 1
  fi

  [[ -s "${out_file}" ]] || {
    log_error "dump_mysql_users: dump users vide/corrompu — ${out_file} (supprimé)"
    rm -f "${out_file}"
    return 1
  }

  chmod 0440 "${out_file}"
  log_ok "dump_mysql_users: ${out_file}"
  return 0
}

# ============================================================================
# apply_retention — Purge des fichiers backup plus vieux que <days> jours
# ============================================================================
# Args : $1=dir $2=days $3=pattern (glob find -name)
# Mirror prune_old_images (audit-helpers.sh:118-153) : loop explicit + compteurs
# deleted_count/delete_failed — PAS de `find -delete` masquant ni `|| true` avalant.
# Retourne 0 même si delete_failed > 0 (retention best-effort loggée — le dump du run
# courant a réussi ; un échec de purge ne doit pas faire échouer le backup).
apply_retention() {
  local dir="${1:?dir required}"
  local days="${2:-7}"
  local pattern="${3:?pattern required}"

  # Defense-in-depth (mirror audit-helpers.sh:125-128) : fallback 7 si days corrompu.
  [[ "${days}" =~ ^[0-9]+$ ]] || {
    log_warn "apply_retention: days='${days}' invalide (^[0-9]+$) — fallback 7"
    days=7
  }

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] apply_retention: cibles (dir=${dir} pattern='${pattern}' mtime +${days}) :"
    # Dir potentiellement absent en audit local — toléré DRY_RUN only (documenté).
    find "${dir}" -maxdepth 1 -type f -name "${pattern}" -mtime +"${days}" -print 2>/dev/null || true
    return 0
  fi

  [[ -d "${dir}" ]] || {
    log_warn "apply_retention: dir '${dir}' absent — skip"
    return 0
  }

  # -maxdepth 1 : ne purge QUE le niveau backups/ (pas de récursion sur d'éventuels
  # sous-dirs V1+ type archives/). -mtime +N = strictement plus vieux que N jours (find semantics).
  local deleted_count=0 delete_failed=0 f
  while IFS= read -r -d '' f; do
    if rm -f "${f}" 2>/dev/null; then
      deleted_count=$((deleted_count + 1))
    else
      delete_failed=$((delete_failed + 1))
    fi
  done < <(find "${dir}" -maxdepth 1 -type f -name "${pattern}" -mtime +"${days}" -print0)

  log_info "apply_retention: deleted=${deleted_count} failed=${delete_failed} (dir=${dir} pattern='${pattern}' days=${days})"
  if [[ "${delete_failed}" -gt 0 ]]; then
    log_warn "apply_retention: ${delete_failed} suppression(s) en échec — vérifier perms Zone 2 backups (02770 deploy:<app>-backup)"
  fi
  return 0
}

# ============================================================================
# resolve_backup_remote — Cascade offsite override per-app / socle per-env (backup-v1 É1)
# ============================================================================
# Aucun arg. Sorties (globals) :
#   BACKUP_OFFSITE_MODE        override | socle | off
#   EFFECTIVE_BUCKET           bucket effectif (override: BACKUP_BUCKET / socle: A2K_BACKUP_S3_BUCKET)
#   EFFECTIVE_GPG_FINGERPRINT  recipient GPG effectif (clé PUBLIQUE — donnée non-secrète)
# + si mode=socle : export mapping RCLONE_CONFIG_S3BACKUP_*="${A2K_BACKUP_S3_*}" dans le scope
#   du run (AUCUN rclone.conf disque) — post-résolution le code parle UN dialecte : `s3backup:`.
#
# Résolution (SSOT ticket T1' — verrouillé Mode A user) :
#   1. ≥1 var du set OVERRIDE présente → EXIGER les 8 → OVERRIDE TOTAL. Set partiel → ERROR rc=1.
#   2. Sinon ≥1 var du set SOCLE présente → EXIGER les 8 → SOCLE. Set partiel → ERROR rc=1.
#   3. Sinon → mode off, skip propre rc=0 (opt-out légitime — comportement V0).
# Durcissement vs V0 : set PARTIEL = ERREUR bruyante (un skip silencieux sur typo de var = RPO
# offsite menti). GPG fingerprint manquant d'un set sinon complet = set partiel = ERROR (remplace
# le WARN+skip V0 — jamais d'offsite en clair, désormais BLOQUANT).
# Diagnostic partiel : NOMS des vars manquantes uniquement (valeurs JAMAIS loggées).
# Réentrant : idempotent par process (flag `_A2K_BACKUP_REMOTE_RESOLVED`) — 2e appel = no-op
# return 0, l'état résolu du 1er appel est préservé.
resolve_backup_remote() {
  # Guard réentrance (FIX M2) : le mapping socle exporte 6 RCLONE_CONFIG_S3BACKUP_* (set OVERRIDE)
  # → un 2e appel même process verrait OVERRIDE PARTIEL 6/8 = ERROR mensongère + état résolu détruit.
  if [[ "${_A2K_BACKUP_REMOTE_RESOLVED:-0}" -eq 1 ]]; then
    return 0
  fi

  BACKUP_OFFSITE_MODE="off"
  EFFECTIVE_BUCKET=""
  EFFECTIVE_GPG_FINGERPRINT=""

  # Sets COMPLETS (8 vars chacun) — voyagent EN BLOC par couche, jamais de mixage.
  local override_vars=(
    RCLONE_CONFIG_S3BACKUP_TYPE
    RCLONE_CONFIG_S3BACKUP_PROVIDER
    RCLONE_CONFIG_S3BACKUP_ENDPOINT
    RCLONE_CONFIG_S3BACKUP_REGION
    RCLONE_CONFIG_S3BACKUP_ACCESS_KEY_ID
    RCLONE_CONFIG_S3BACKUP_SECRET_ACCESS_KEY
    BACKUP_BUCKET
    BACKUP_GPG_FINGERPRINT
  )
  local socle_vars=(
    A2K_BACKUP_S3_TYPE
    A2K_BACKUP_S3_PROVIDER
    A2K_BACKUP_S3_ENDPOINT
    A2K_BACKUP_S3_REGION
    A2K_BACKUP_S3_ACCESS_KEY_ID
    A2K_BACKUP_S3_SECRET_ACCESS_KEY
    A2K_BACKUP_S3_BUCKET
    A2K_BACKUP_GPG_FINGERPRINT
  )

  local v present_override=0 present_socle=0 missing_vars=()
  for v in "${override_vars[@]}"; do
    [[ -n "${!v:-}" ]] && present_override=$((present_override + 1))
  done
  for v in "${socle_vars[@]}"; do
    [[ -n "${!v:-}" ]] && present_socle=$((present_socle + 1))
  done

  if [[ "${present_override}" -gt 0 ]]; then
    # Couche 1 — OVERRIDE per-app PRIME (dès 1 var présente, les 8 sont EXIGÉES).
    for v in "${override_vars[@]}"; do
      [[ -n "${!v:-}" ]] || missing_vars+=("${v}")
    done
    if [[ "${#missing_vars[@]}" -gt 0 ]]; then
      log_error "resolve_backup_remote: set OVERRIDE per-app PARTIEL (${present_override}/8) — vars manquantes : ${missing_vars[*]}"
      log_error "resolve_backup_remote: compléter le set (8 vars EN BLOC) OU le purger entièrement (opt-out) — RPO offsite menti sinon"
      return 1
    fi
    BACKUP_OFFSITE_MODE="override"
    EFFECTIVE_BUCKET="${BACKUP_BUCKET}"
    EFFECTIVE_GPG_FINGERPRINT="${BACKUP_GPG_FINGERPRINT}"
  elif [[ "${present_socle}" -gt 0 ]]; then
    # Couche 2 — SOCLE commun per-env.
    for v in "${socle_vars[@]}"; do
      [[ -n "${!v:-}" ]] || missing_vars+=("${v}")
    done
    if [[ "${#missing_vars[@]}" -gt 0 ]]; then
      log_error "resolve_backup_remote: set SOCLE per-env PARTIEL (${present_socle}/8) — vars manquantes : ${missing_vars[*]}"
      log_error "resolve_backup_remote: compléter le set (8 vars EN BLOC) OU le purger entièrement (opt-out) — RPO offsite menti sinon"
      return 1
    fi
    BACKUP_OFFSITE_MODE="socle"
    # Mapping runtime socle → dialecte rclone s3backup: (scope du run, AUCUN rclone.conf disque).
    export RCLONE_CONFIG_S3BACKUP_TYPE="${A2K_BACKUP_S3_TYPE}"
    export RCLONE_CONFIG_S3BACKUP_PROVIDER="${A2K_BACKUP_S3_PROVIDER}"
    export RCLONE_CONFIG_S3BACKUP_ENDPOINT="${A2K_BACKUP_S3_ENDPOINT}"
    export RCLONE_CONFIG_S3BACKUP_REGION="${A2K_BACKUP_S3_REGION}"
    export RCLONE_CONFIG_S3BACKUP_ACCESS_KEY_ID="${A2K_BACKUP_S3_ACCESS_KEY_ID}"
    export RCLONE_CONFIG_S3BACKUP_SECRET_ACCESS_KEY="${A2K_BACKUP_S3_SECRET_ACCESS_KEY}"
    EFFECTIVE_BUCKET="${A2K_BACKUP_S3_BUCKET}"
    EFFECTIVE_GPG_FINGERPRINT="${A2K_BACKUP_GPG_FINGERPRINT}"
  else
    # Couche 3 — opt-out total : skip propre (comportement V0 conservé).
    log_info "resolve_backup_remote: offsite non configuré (aucune var override/socle) — skip propre (opt-out)"
    _A2K_BACKUP_REMOTE_RESOLVED=1
    return 0
  fi

  # Vérifs binaires (mode≠off) — offsite = attente dès qu'une config existe (durci vs WARN V0).
  # DRY_RUN : audit local dev host sans gpg/rclone toléré (print du check, pas de fail).
  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] command -v gpg + command -v rclone (check binaires SKIP en audit local)"
  else
    command -v gpg >/dev/null 2>&1 || {
      log_error "resolve_backup_remote: gpg absent — offsite configuré (mode=${BACKUP_OFFSITE_MODE}) mais chiffrement impossible (installer gpg VPS-side)"
      return 1
    }
    command -v rclone >/dev/null 2>&1 || {
      log_error "resolve_backup_remote: rclone absent — offsite configuré (mode=${BACKUP_OFFSITE_MODE}) mais upload impossible (installer rclone VPS-side)"
      return 1
    }
  fi

  log_ok "resolve_backup_remote: mode=${BACKUP_OFFSITE_MODE} bucket=${EFFECTIVE_BUCKET}"
  _A2K_BACKUP_REMOTE_RESOLVED=1
  return 0
}

# ============================================================================
# encrypt_and_upload_file — Chiffrement GPG per-file + upload rclone copyto (backup-v1 É1)
# ============================================================================
# Args : $1=file $2=instance $3=env $4=app
# Pré-requis : resolve_backup_remote OK (EFFECTIVE_BUCKET + EFFECTIVE_GPG_FINGERPRINT posés).
# Flux (SSOT ticket T1' — mécanisme GPG karaoke capitalisé, --trust-model always) :
#   dump local clair 0440 (inchangé V0)
#     → gpg --batch --yes --encrypt --recipient FPR --trust-model always --output f.gpg f
#       (temp 0640 umask 027 — PAS chmod 0440, PAS conservé)
#     → sidecar sha256 basename-only (É2 vérifie l'intégrité depuis n'importe quel cwd)
#     → rclone copyto f.gpg.sha256 s3backup:<bucket>/<env>/<app>/<instance>/basename.gpg.sha256
#     → rclone copyto f.gpg        s3backup:<bucket>/<env>/<app>/<instance>/basename.gpg
#       (sidecar d'abord — .gpg = commit marker de la paire)
#     → rm -f des 2 temps (le local reste CLAIR — RTO ≤1h sans clé privée, Zone 2 perms)
# Échec gpg OU copyto (l'un des 2 fichiers) → rm des temps + return 1 (offsite = attente).
encrypt_and_upload_file() {
  local f="${1:?file required}"
  local instance="${2:?instance required}"
  local env="${3:?env required}"
  local app="${4:?app required}"

  local base gpg_file sha_file file_dir remote_prefix
  base="$(basename "${f}")"
  file_dir="$(dirname "${f}")"
  gpg_file="${f}.gpg"
  sha_file="${f}.gpg.sha256"
  remote_prefix="s3backup:${EFFECTIVE_BUCKET}/${env}/${app}/${instance}"

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] gpg --batch --yes --encrypt --recipient ${EFFECTIVE_GPG_FINGERPRINT} --trust-model always --output ${gpg_file} ${f}"
    echo "[DRY_RUN] (cd ${file_dir} && sha256sum ${base}.gpg > ${base}.gpg.sha256)"
    echo "[DRY_RUN] rclone copyto ${sha_file} ${remote_prefix}/${base}.gpg.sha256"
    echo "[DRY_RUN] rclone copyto ${gpg_file} ${remote_prefix}/${base}.gpg"
    return 0
  fi

  # AP-1 exit code capture par étape ; TOUT chemin d'échec purge les 2 temps (dérivables).
  local rc=0
  gpg --batch --yes --encrypt --recipient "${EFFECTIVE_GPG_FINGERPRINT}" --trust-model always \
      --output "${gpg_file}" "${f}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "encrypt_and_upload_file: gpg encrypt failed (rc=${rc}) — ${base} (temps purgés, local clair intact)"
    rm -f "${gpg_file}" "${sha_file}"
    return 1
  fi

  # Sidecar sha256 basename-only (subshell cd — le fichier référencé dans le .sha256 est relatif).
  rc=0
  (cd "${file_dir}" && sha256sum "${base}.gpg" > "${base}.gpg.sha256") || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "encrypt_and_upload_file: sha256 sidecar failed (rc=${rc}) — ${base} (temps purgés)"
    rm -f "${gpg_file}" "${sha_file}"
    return 1
  fi

  # Sidecar .sha256 uploadé D'ABORD, .gpg en DERNIER (FIX M1 — .gpg = commit marker de la paire) :
  # la présence du .gpg au listing remote (critère catch-up) GARANTIT la paire complète ; un
  # sidecar orphelin (sidecar OK puis .gpg KO) est inoffensif — catch-up re-tente la paire,
  # le copyto sidecar ré-écrase.
  rc=0
  rclone copyto "${sha_file}" "${remote_prefix}/${base}.gpg.sha256" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "encrypt_and_upload_file: rclone copyto .sha256 failed (rc=${rc}) — ${base} (temps purgés — catch-up retentera la paire)"
    rm -f "${gpg_file}" "${sha_file}"
    return 1
  fi

  rc=0
  rclone copyto "${gpg_file}" "${remote_prefix}/${base}.gpg" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_error "encrypt_and_upload_file: rclone copyto .gpg failed (rc=${rc}) — ${base} (temps purgés, dump local intact — le .gpg est le commit marker : catch-up retentera la paire)"
    rm -f "${gpg_file}" "${sha_file}"
    return 1
  fi

  rm -f "${gpg_file}" "${sha_file}"
  log_ok "encrypt_and_upload_file: ${remote_prefix}/${base}.gpg (+ sidecar sha256)"
  return 0
}

# ============================================================================
# remote_list_instance — Listing remote d'une instance (consommé par le catch-up)
# ============================================================================
# Args : $1=instance $2=env $3=app
# stdout = basenames du préfixe remote <env>/<app>/<instance>/ (1 par ligne — rclone lsf).
# DRY_RUN : print de la commande sur STDERR (stdout DOIT rester vide — il est capturé
# par le caller en $(...) comme listing).
remote_list_instance() {
  local instance="${1:?instance required}"
  local env="${2:?env required}"
  local app="${3:?app required}"

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] rclone lsf s3backup:${EFFECTIVE_BUCKET}/${env}/${app}/${instance}/" >&2
    return 0
  fi

  # AP-1 : rc propagé au caller (échec listing → le catch-up de l'instance ne peut pas conclure).
  local rc=0
  rclone lsf "s3backup:${EFFECTIVE_BUCKET}/${env}/${app}/${instance}/" || rc=$?
  return "${rc}"
}

# ============================================================================
# apply_remote_retention — Rétention remote scoped préfixe — OFF PAR DÉFAUT (backup-v1 É1 amendé)
# ============================================================================
# Args : $1=env $2=app $3=days (default 0 = OFF)
# ⚠ DÉSACTIVÉE PAR DÉFAUT (décision Mode A user 2026-07-03, ADR-016) — modèle rétention
# remote HORS serveur : la clé S3 socle détenue par le VPS = dépôt+listing SEULEMENT
# (PutObject+ListBucket, JAMAIS DeleteObject — anti-purge : un deploy/CI compromis ne peut
# PAS détruire l'offsite). Le ménage 30j = lifecycle bucket-side Contabo OU tâche admin
# depuis poste ops (clé delete DISTINCTE) — PAS la clé du serveur.
# Fonction CONSERVÉE pour un usage admin explicite (days>0 via A2K_BACKUP_REMOTE_RETENTION_DAYS,
# nécessite une clé avec DeleteObject — override délibéré, jamais le défaut).
# ⚠ Scope STRICT au préfixe ${env}/${app}/ — JAMAIS la racine bucket (socle partagé multi-apps).
# Best-effort (mirror apply_retention locale) : échec delete → WARN, return 0 (le backup
# et l'upload du run courant ont réussi — une purge ratée ne doit pas les faire échouer).
apply_remote_retention() {
  local env="${1:?env required}"
  local app="${2:?app required}"
  local days="${3:-0}"

  # Defense-in-depth : fallback 0 (OFF — safe default) si days corrompu.
  [[ "${days}" =~ ^[0-9]+$ ]] || {
    log_warn "apply_remote_retention: days='${days}' invalide (^[0-9]+$) — fallback 0 (OFF)"
    days=0
  }

  # OFF par défaut (days=0) — rétention remote = responsabilité EXTERNE (cf. header).
  if [[ "${days}" -eq 0 ]]; then
    log_info "apply_remote_retention: OFF (days=0 défaut ADR-016) — ménage remote = lifecycle bucket Contabo OU tâche admin poste ops (clé serveur = write/list-only, sans DeleteObject)"
    return 0
  fi

  # Commande UNIQUE (array) — le scope préfixe ${env}/${app}/ est structurel, pas répété.
  local delete_cmd=(rclone delete --min-age "${days}d" "s3backup:${EFFECTIVE_BUCKET}/${env}/${app}/")

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] ${delete_cmd[*]}"
    return 0
  fi

  local rc=0
  "${delete_cmd[@]}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log_warn "apply_remote_retention: delete remote failed (rc=${rc}) — best-effort, backup/upload non impactés (préfixe ${env}/${app}/, days=${days})"
    return 0
  fi

  log_ok "apply_remote_retention: préfixe ${env}/${app}/ purgé (--min-age ${days}d)"
  return 0
}

# ============================================================================
# write_last_success_sentinel — Sentinelle horodatée fin de succès (ajustement F)
# ============================================================================
# Args : $1=dir
# Écrit ${dir}/last-success (ISO UTC). Monitoring RPO V1 : alerte si last-success > seuil
# (ops_discipline.md §11). PAS de chmod 0440 ici — la sentinelle DOIT rester réécrivable
# à chaque run (umask 027 → 0640).
write_last_success_sentinel() {
  local dir="${1:?dir required}"

  if backup_lib_is_dry_run; then
    echo "[DRY_RUN] date -u +%Y-%m-%dT%H:%M:%SZ > ${dir}/last-success"
    return 0
  fi

  # Best-effort (L1) : la sentinelle = monitoring V1, ne doit JAMAIS faire échouer un backup
  # réussi (appelée top-level sous set -e côté app-backup.sh) — warn + return 0.
  date -u +%Y-%m-%dT%H:%M:%SZ > "${dir}/last-success" || {
    log_warn "write_last_success_sentinel: écriture ${dir}/last-success impossible (best-effort — backup non impacté)"
    return 0
  }
  log_ok "write_last_success_sentinel: ${dir}/last-success"
  return 0
}
