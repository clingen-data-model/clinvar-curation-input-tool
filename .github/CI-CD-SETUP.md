# CI/CD setup — review-app

## Status

- **`ci.yml` — ACTIVE.** Runs on every PR/push touching `review-app/**`: the
  functions Vitest suite + a `web` type-check/build. No secrets, no deploy.
- **`deploy-dev.yml` / `deploy-prod.yml` — DORMANT DRAFTS.** `workflow_dispatch`
  only, so they never run (or fail) until the deploy credential below is
  configured. Prod is additionally gated by a protected `production` environment.

## To enable deploys (repo owner / GCP admin)

Deploys authenticate to GCP with **Workload Identity Federation** (no long-lived
keys). One-time setup per Firebase project (`clingen-cvc-dev`, later `clingen-cvc`):

1. **CI deploy service account** with roles: `roles/firebasehosting.admin`,
   `roles/cloudfunctions.admin`, `roles/run.admin`, `roles/iam.serviceAccountUser`,
   `roles/artifactregistry.writer`, `roles/cloudbuild.builds.editor`, plus
   `roles/serviceusage.serviceUsageConsumer`. (Cloud Functions gen2 deploys build
   via Cloud Build + push to Artifact Registry.)
2. **Workload Identity Federation**: a pool + provider bound to this GitHub repo
   (`google-github-actions/auth` docs), and grant the CI SA
   `roles/iam.workloadIdentityUser` for the repo's OIDC subject.
3. **Repo Actions variables** (Settings → Secrets and variables → Actions →
   Variables): `GCP_WIF_PROVIDER`, `CI_DEPLOY_SA_DEV`, `RUNTIME_SA_DEV` (and the
   `_PROD` equivalents). No secrets needed with WIF.
4. **Enable auto-deploy on merge**: change `deploy-dev.yml`'s trigger from
   `workflow_dispatch` to `push: { branches: [main], paths: ['review-app/**'] }`.
5. **Prod**: create a `production` GitHub environment with a required reviewer;
   run `deploy-prod.yml` manually (type `deploy-prod` to confirm).

## Notes

- The `Re-grant runtime IAM` step re-asserts the gen2 `run.invoker`/`actAs`
  bindings (see `review-app/scripts/grant-iam.sh`) that a service-recreating
  deploy can drop.
- Deploying serves whatever `review-app/firebase.json` points `hosting.public`
  at — `web/dist` after the React cutover.
- Alternative to WIF: a service-account JSON key in a `GCP_SA_KEY` secret +
  `google-github-actions/auth@v2` with `credentials_json`. WIF is preferred.
