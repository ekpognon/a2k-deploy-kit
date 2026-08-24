# a2k-deploy-kit

Kit de déploiement mutualisé A2K — **reusable workflows GitHub Actions + composite actions +
scripts shell** pour déployer, rollbacker et backuper des apps Docker Compose sur VPS
(push-and-forget : GHA = transport + orchestration légère, le VPS exécute localement).

> **Provenance** : extrait de `a2k-shared-infra@91e6a9dd6c22e298acb9e544f2941402f25b94e4`
> (develop local post-REGDOCK, extraction WFPUB 2026-08-19, option B). L'infra privée
> (Ansible, inventaires, Traefik partagé, orchestrateur admin) reste dans `a2k-shared-infra`.
> Motif : les reusable workflows d'un repo **privé** sont inaccessibles cross-org (règle GitHub) —
> ce kit **public** rend la chaîne deploy/rollback consommable par toute app, sans PAT.

## Contenu

| Composant | Rôle |
|---|---|
| `.github/workflows/deploy-app.yml` | Reusable `workflow_call` deploy (transport scripts + compose + config → VPS, exécution `app-deploy.sh` locale, healthcheck, rollback conditionnel, oracles fraîcheur O1/O3/O4) |
| `.github/workflows/rollback-app.yml` | Reusable `workflow_call` rollback in-place (A12 — images pre-pulled last 3) |
| `.github/workflows/freshness-witness.yml` | Témoin CI des oracles fraîcheur (fixtures git locales, 10 cas rc exacts — teste `scripts/lib/freshness-oracle.sh`) |
| `.github/workflows/lint.yml` | CI lint du kit (actionlint + shellcheck sur ses propres fichiers) |
| `.github/actions/{ssh-execute,scp-vps,healthcheck-wait,registry-login}` | Composite actions internes aux workflows (résolues par **self-checkout** `job.workflow_repository`@`job.workflow_sha` — version-lock immuable, zéro skew supply-chain) |
| `scripts/app-deploy.sh` / `app-rollback.sh` / `app-backup.sh` / `registry-cleanup.sh` + `lib/` | Scripts shared core transportés sur le VPS par les workflows puis exécutés localement (VPS orchestrator) |

## Consommation (app repo invoker)

```yaml
jobs:
  deploy:
    permissions:
      contents: read   # checkout du repo app
      issues: write    # alerting freshness (issue dédup dans le repo caller) — comportement à confirmer au premier run réel
    uses: ekpognon/a2k-deploy-kit/.github/workflows/deploy-app.yml@develop
    with:
      env: stg
      app_name: monapp
      container_image_tag: v1.2.3
      app_ref: ${{ github.sha }}
    secrets:
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}  # passation EXPLICITE nommée — JAMAIS `secrets: inherit`
```

> ⚠ **Secrets — passation explicite obligatoire (défaut #5, note etatcivil 2026-08-22)** :
> `secrets: inherit` ne propage RIEN entre deux propriétaires GitHub distincts (doc GitHub :
> même organization/enterprise uniquement) — toute app hors du compte propriétaire du kit
> échoue plan-time (`Secret DEPLOY_SSH_KEY is required, but not provided while calling`).
> La passation explicite fonctionne dans tous les cas et expose moins (seul le secret requis
> transite). Alerting freshness optionnel : ajouter `BREVO_SMTP_USER`/`BREVO_SMTP_KEY` au bloc
> `secrets:` de la même façon. Contrat : `a2k-shared-infra/docs/contracts/DEPLOY-APP-INVOKER-GUIDE.md`
> § Secrets GHA (+ § Contrat de format Zone 4 `.env.secrets` — valeurs single-quotées, zéro doublage `$`)
> — **repo privé A2K : doc transmise aux apps externes par A2K dans le dossier d'onboarding**.

> ⚠ **Note A15 (versions pinned / supply chain)** : `@develop` = **mode itération** (le kit évolue,
> les apps suivent sans re-pin). La **recommandation prd / stabilisé reste le pin SHA**
> (`@<sha40>`) — invariant A15 supply-chain (incidents 2025 tj-actions / Shai Hulud). Une fois le
> kit stabilisé, re-pinner les invokers prd sur un SHA.

Aucun PAT requis : le kit est public, le self-checkout interne
(`repository: ${{ job.workflow_repository }}` + `ref: ${{ job.workflow_sha }}`) embarque
actions + scripts **au même SHA que le workflow appelé** sans token.

## Invariants contractuels (source de vérité : guides `a2k-shared-infra/docs/contracts/` — repo privé A2K, docs transmises aux apps externes par A2K dans le dossier d'onboarding)

- **A6 — 11 env vars `A2K_*`** exportées aux hooks : `APP_NAME`, `ENV`, `IMAGE_TAG`, `PREVIOUS_TAG`,
  `PROJECT_DIR`, `SECRETS_FILE`, `ACTION`, `DEPLOY_TIMESTAMP`, `DRY_RUN`, `LOG_LEVEL`, `REGISTRY_ORG`
  (cf. `scripts/lib/env-vars.sh`).
- **A7 — 6 hooks contract app-side** (file convention `hooks/`) : `pre-deploy.sh`, `healthcheck.sh`,
  `post-deploy.sh`, `smoke-test.sh`, `pre-rollback.sh`, `post-rollback.sh`.
- **A8 — `smoke-test.sh` OBLIGATOIRE V0** : absent → ERROR + abort (discipline qualité enforce).
- Pré-requis VPS (Pattern A fail-fast) : Zone 4 secrets + réseau `proxy_net` + Traefik partagé —
  provisionnés côté `a2k-shared-infra` (Ansible privé), PAS par ce kit.

## Checklist remote-config (user — le remote n'existe pas encore)

1. Créer le repo **public** GitHub `ekpognon/a2k-deploy-kit` puis pousser `develop`
   (`git remote add origin https://github.com/ekpognon/a2k-deploy-kit.git && git push -u origin develop`).
2. **Aucun secret à poser sur le kit lui-même** : les workflows sont `workflow_call`-only — les
   secrets/vars vivent côté repos **invokers** (apps + a2k-shared-infra). Vérifier présents là-bas :
   - secrets : `DEPLOY_SSH_KEY` (+ optionnels `BREVO_SMTP_USER`/`BREVO_SMTP_KEY` alerting freshness) ;
   - vars : `SSH_HOST_FINGERPRINT_STG` / `SSH_HOST_FINGERPRINT_PRD`, `DEPLOY_USER`,
     `DEPLOY_HOST_STG` / `DEPLOY_HOST_PRD` (+ `A2K_REGISTRY_ORG` si org GHCR ≠ défaut) ;
   - environments GitHub `stg` / `prd` sur les repos invokers (gates).
   - `INFRA_SSH_KEY` reste lié à `provision-app.yml` / `infra-bootstrap-vps.yml` côté
     `a2k-shared-infra` (provisioning privé — hors kit).
3. Côté `a2k-shared-infra` (qui embarque ce kit en **submodule** `deploy-kit/`, URL locale en
   attendant le remote) : flipper l'URL dans `.gitmodules` vers
   `https://github.com/ekpognon/a2k-deploy-kit.git` puis `git submodule sync`.
4. Re-pin des apps consommatrices (TopXpress / Soiroke) : anciens pins SHA
   `ekpognon/a2k-shared-infra/...@<sha>` restent fonctionnels (historique git immuable) —
   re-pin vers `ekpognon/a2k-deploy-kit/...@develop` (puis SHA en prd) à leur rythme.

## Développement

- Lint local : `actionlint` + `shellcheck scripts/*.sh scripts/lib/*.sh` (CI : `.github/workflows/lint.yml`).
- Audit sans VPS : `DRY_RUN=1 bash scripts/app-deploy.sh stg monapp v1.2.3`.
- Le nom de dossier runner `shared-infra` dans les workflows est **historique** (origine
  a2k-shared-infra) — conservé volontairement (minimal diff d'extraction).
