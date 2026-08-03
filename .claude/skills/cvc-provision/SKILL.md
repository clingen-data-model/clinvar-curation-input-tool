---
name: cvc-provision
description: >-
  Provision or repair a ClinVar CvC (clinvar-cvc/) Firebase/GCP environment
  (dev or prod): create the project, deploy Firestore rules + allowlist, install
  the Firestore→BigQuery extension, and grant the IAM the extension needs. Use
  when standing up a new environment (e.g. clingen-cvc-dev), when Firestore
  writes succeed but nothing reaches BigQuery, or when events start 403'ing after
  an extension reinstall/reconfigure ("run.invoker" / "Receiving end" / "Not
  found: Dataset"). Mixes a script, console-only OAuth steps, and easy-to-forget
  IAM grants that repeatedly caused breakage.
---

# Provision / repair a CvC Firebase+BigQuery environment

Everything runs from `clinvar-cvc/`. Prod project = `clingen-cvc`; dev = `clingen-cvc-dev`.
Firestore is the `(default)` DB in **`nam5`**; BigQuery dataset `clinvar_cvc_ext` in
`us-central1`; collection `clinvar_cvc_ext_annotations`.

## Prereqs
- `gcloud` (authed: `gcloud auth login`), `firebase-tools` (`firebase login`), `jq`.
- The GCP project must live where an **External + In-production** OAuth consent
  screen is allowed (a hard org-policy prerequisite for external users). Under
  `broadinstitute.org` this happened to be allowed; verify before relying on it.

## A. Provision a new environment
1. **Scripted parts** — from `clinvar-cvc/`, run (dev shown):
   ```bash
   CVC_PROJECT=clingen-cvc-dev ./setup-clingen-cvc.sh
   ```
   Creates the project, links billing, enables APIs, creates Firestore `(default)`
   in `nam5`, deploys `firestore.rules`, seeds the allowlist with `MY_EMAIL`,
   creates a Web app (writing the apiKey into `env.js` for the dev block), grants
   the compute SA build roles, and grants the extension runtime SA its roles
   (`bigquery.dataEditor/jobUser`, `cloudtasks.enqueuer`, `eventarc.publisher`)
   plus `run.invoker`. It also *attempts* a CLI extension deploy — but see step 3.
2. **Console-only OAuth** (cannot be scripted), in the target project:
   - Google Auth Platform ▸ **Audience** → User type **External** → **Publish (In production)**.
   - Firebase ▸ Authentication ▸ Sign-in method ▸ enable **Google**; under
     **"Whitelist client IDs from external projects"** add the extension's OAuth
     client id (the same one in `manifest.json` — shared across dev/prod).
3. **Install the Firestore→BigQuery extension via the FIREBASE CONSOLE** — NOT the
   CLI. `firebase deploy --only extensions` does **not** run the extension's
   BigQuery setup lifecycle on a fresh project (no dataset/table/view created).
   Console install params: **Firestore Database region `nam5`** (NOT us-central1),
   Collection `clinvar_cvc_ext_annotations`, Dataset `clinvar_cvc_ext`, Table
   `annotations`, Dataset location `us-central1`, view type = regular view, time
   partitioning = NONE.
4. **After the extension is installed, grant Cloud Run Invoker** (see section C —
   the console install can leave this unbound, and any reinstall drops it).
5. **Create the flattened view**: run `bigquery/annotations_view.sql` in the
   BigQuery console (or `bq query --use_legacy_sql=false < bigquery/annotations_view.sql`),
   substituting the project id in the SQL for the target project.
6. **Verify** (section D).

## B. Point the extension at this environment
- In `firebase-config.js` set `const ACTIVE_ENV = 'dev'` (or `'prod'`). Confirm
  `env.js` has the correct `apiKey` for that env (step A1 fills dev).
- Reload the unpacked extension; a red **DEV** banner shows when not prod.
- **Reload the ClinVar tab** — static content scripts only inject on page load.

## C. Repair: events 403 / no data in BigQuery (the recurring one)
Symptoms: Firestore docs exist but the BQ `annotations_raw_changelog` stays empty;
function logs show `run.routes.invoke` / "not authenticated", or "Not found:
Dataset/Table". **Any extension reinstall/reconfigure recreates the Cloud Run
service and DROPS the run.invoker binding.** Re-grant (adjust project + the nam5
trigger region if prod differs):
```bash
PROJ=clingen-cvc-dev
TRIG_SA=$(gcloud eventarc triggers list --location=nam5 --project=$PROJ --format="value(serviceAccount)" | head -1)
EXT_SA="ext-firestore-bigquery-export@${PROJ}.iam.gserviceaccount.com"
for SA in "$TRIG_SA" "$EXT_SA"; do
  gcloud run services add-iam-policy-binding ext-firestore-bigquery-export-fsexportbigquery \
    --region=us-central1 --project=$PROJ --member="serviceAccount:${SA}" --role=roles/run.invoker --quiet
done
# runtime SA also needs (usually already granted by setup script):
for r in roles/bigquery.dataEditor roles/bigquery.jobUser roles/cloudtasks.enqueuer roles/eventarc.publisher; do
  gcloud projects add-iam-policy-binding $PROJ --member="serviceAccount:${EXT_SA}" --role="$r" --condition=None --quiet
done
```
If the dataset/table were never created (CLI-installed extension), **reinstall the
extension via the console** (step A3) so its setup lifecycle runs, then re-grant
run.invoker (above). Pub/Sub retries queued events, so previously-failed writes
usually backfill within a couple of minutes.

**ALWAYS grant run.invoker BEFORE a bulk migration/import — and verify it's flowing.**
Hit on the **prod** history load (2026-08-03): the trigger SA (`<projnum>-compute@developer`)
lacked run.invoker even though prod had streamed fine for small tests, so ALL 30,784
bulk events were rejected (logged as **WARNING** `run.routes.invoke`, not ERROR — so
an `severity>=ERROR` log filter shows "0 errors" and hides it; check `>=WARNING`).
Critically, a bulk load during a broken binding **does not fully self-heal**: Pub/Sub
retries with backoff and only ~73% (22.5k/30.8k) backfilled after the re-grant — the
rest **exhausted their retry window and were permanently dropped from the stream**
(Firestore still had all 30,784; only BQ was short). Fix once dropped: after
re-granting run.invoker, **re-run the clean-slate `wipe-collection` + paced `migrate`**
so every doc re-emits a fresh event through the now-working stream (create-only
re-runs alone won't help — no write, no event). Note the trigger SA is the project's
**compute** SA and the Eventarc trigger lives in **nam5** while the Cloud Run service
is in **us-central1**.

## D. Verify (dev-safe, seeds via owner token which bypasses rules)
```bash
PROJ=clingen-cvc-dev
TOKEN=$(gcloud auth print-access-token)
curl -s -X PATCH "https://firestore.googleapis.com/v1/projects/$PROJ/databases/(default)/documents/clinvar_cvc_ext_annotations/provision-check" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"fields":{"user_email":{"stringValue":"you@example.com"},"scv":{"stringValue":"SCV-CHECK"},"action":{"stringValue":"No Change"},"created_at":{"timestampValue":"2026-01-01T00:00:00Z"}}}' >/dev/null
sleep 90
bq --location=us-central1 --project_id=$PROJ query --use_legacy_sql=false \
  'SELECT document_id, operation FROM `'"$PROJ"'.clinvar_cvc_ext.annotations_raw_changelog` ORDER BY timestamp DESC LIMIT 5'
# prod isolation check (run against clingen-cvc): the dev doc must NOT appear
```
Also confirm no prod leak: query prod's changelog for the dev doc id → expect 0.

## Gotchas (full detail in clinvar-cvc/README.md Troubleshooting)
- Firestore must be **Standard edition / Native mode** (NOT Enterprise/MongoDB,
  which has SCRAM/OIDC + no Rules tab). Use the `(default)` DB (a named DB has no
  Rules tab — deploy rules via the Firebase CLI).
- The extension's **Firestore Database region param must equal the DB location (`nam5`)**.
- Grant a specific SA (never `allUsers`) for run.invoker; org policy blocks public.
- The flattened view is created by RUNNING the SQL, per project — it is not part
  of the extension.
