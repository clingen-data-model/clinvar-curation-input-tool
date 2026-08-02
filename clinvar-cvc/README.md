# ClinVar CvC Extension — Firestore → BigQuery (external-user capable)

A minimal, standalone Chrome extension that captures **5 fields** and persists
them to **Firestore**, with a Firebase Extension streaming every write into
**BigQuery**. It exercises the full path we plan to use for the real ClinVar
Curator save flow:

```text
Chrome extension  ──POST (Firestore REST API)──▶  Firestore collection
                                                        │
                          "Stream Firestore to BigQuery" Firebase Extension
                                                        ▼
                                  BigQuery: <table>_raw_changelog (+ _raw_latest view)
                                                        │
                                    annotations_view.sql (flattened, typed columns)
                                                        ▼
                                           BigQuery: clinvar_cvc_ext.annotations
```

The 5 captured fields: **Variation ID, SCV ID, Action, Reason, Notes**. Two more
are added automatically: the submitter's **verified Google account email**
(`user_email`) and a `created_at` timestamp.

## Architecture decisions

- **Dedicated GCP project `clingen-cvc`.** Everything — Firestore, BigQuery,
  Firebase Auth, and the OAuth client — lives here. A dedicated project lets us
  publish an **External** OAuth audience (any Google account, inside or outside
  the institution), which org policy blocks in `clingen-dev`.
- **`(default)` Firestore database** (Native mode). Because the project is
  dedicated, there's nothing to isolate from, so we skip the named database and
  avoid its Rules-tab / extension "Database ID" gotchas.
- **Firestore REST API, no Firebase SDK.** MV3's CSP blocks CDN scripts and the
  modular SDK needs a build step; REST keeps this build-free with no vendored
  files.
- **Google sign-in (`authMode: 'google'`).** The Firebase ID token carries a
  verified email, so a rule can enforce `user_email == request.auth.token.email`.
- **Controlled access via an `allowed_curators` allowlist.** Anyone can *sign in*
  (External audience), but only accounts whose verified email has a document in
  the `allowed_curators` collection may *submit*. Enforced in security rules
  (can't be bypassed client-side); admins manage the list in the console.

## Files

| File | Purpose |
|------|---------|
| `manifest.json` | MV3 config; popup action, icons, permissions, `oauth2` client, ClinVar content script |
| `env.js` | `resolveConfig(env)` — per-environment (prod/dev) public config |
| `firebase-config.js` | **Flip `ACTIVE_ENV` here** (`'prod'`/`'dev'`) — thin selector over `env.js` |
| `scrape.js` | `extractClinVarData(doc)` — refactored ClinVar page scraper (from `scvc/`) |
| `vocab.js` | `ACTIONS` + `reasonsForAction()` — action/reason vocabulary |
| `annotation.js` | `buildAnnotation`→v4 doc, `validateAnnotation`, `annotationDocId` (dedup hash) |
| `content.js` | Content script — returns scraped data to the popup on `initializePopup` |
| `popup.html` / `popup.js` / `popup-view.js` | Rich SCV-picker/action-reason-notes form; scrape→picker→save (create-only, non-ClinVar guard, close-on-save, duplicate detection) |
| `firestore.rules` + `firebase.json` | Security rules incl. `allowed_curators` allowlist (deploy via Firebase CLI) |
| `bigquery/annotations_view.sql` | Flattened BigQuery view (v4 typed columns; run per-project) |
| `test/` + `package.json` + `vitest.config.js` | Vitest+jsdom unit tests — `npm install && npm test` |
| `setup-clingen-cvc.sh` | Scripts the automatable setup (project/APIs/Firestore/rules/allowlist/webapp); pauses for the console-only OAuth steps |
| `add-curator.sh` / `remove-curator.sh` / `list-curators.sh` | Admin helpers to manage the `allowed_curators` allowlist |
| `icons/` | Extension icons (16/48/128) |

---

## ⚠️ Prerequisite for external users

Enabling external users requires publishing an **External** OAuth consent screen.
A project **inherits its org's policies**, and `broadinstitute.org` almost
certainly forbids this. So create `clingen-cvc` **with no org** (a standalone
project on a permissive billing account) or **under an org that allows External +
In-production consent screens**. If it lands under `broadinstitute.org`, external
sign-in will still be blocked.

---

## Setup (all in the new `clingen-cvc` project)

### 1. Create the project
Firebase console ▸ **Add project** ▸ name it `clingen-cvc` (note the org
caveat above). Skip Google Analytics.

### 2. Create the Firestore database
**Build ▸ Firestore Database ▸ Create database.** Keep the database id as
**`(default)`**. Pick **Standard edition / Native mode** (NOT Enterprise/MongoDB,
NOT Datastore). Location: a US region (e.g. `nam5`). Start in **test mode** (we
tighten rules in step 8). Or from a terminal:

```bash
gcloud firestore databases create \
  --database='(default)' --location=nam5 \
  --type=firestore-native --project=clingen-cvc
```

### 3. Enable billing (Blaze)
The Firestore→BigQuery extension (step 10) deploys a Cloud Function, which needs
the **Blaze** plan. Firebase console ▸ upgrade the project to Blaze and attach a
billing account. (Firestore + auth alone work on the free plan, but the extension
does not.)

### 4. Enable Google sign-in + set an External audience
1. **Build ▸ Authentication ▸ Get started ▸ Sign-in method ▸ Add new provider ▸
   Google ▸** Enable, set a support email, **Save.**
2. **Google Auth Platform ▸ Audience** (a.k.a. OAuth consent screen):
   - **User type = External.**
   - **Publish app ▸ In production.** The app requests only non-sensitive scopes
     (`openid`, `email`, `profile`), so publishing is **immediate — no Google
     verification, no user cap, no "unverified app" warning.** Any Google account
     can now sign in.
   - (Staying in **Testing** instead limits sign-in to the individual emails in
     the **Test users** list — max 100; a Google Group can't be a test user.)

### 5. Get the Web API key
Project settings ▸ General ▸ Your apps ▸ add a **Web** app (`clinvar-cvc-ext`, no
Hosting) if none exists ▸ copy **`apiKey`** into [`firebase-config.js`](firebase-config.js).
(`projectId`, `databaseId`, `collection`, `authMode` are already set.)

### 6. Create the OAuth client for the extension
1. Load the extension once (step 9.1) and copy its **extension id** from
   `chrome://extensions/`.
2. Cloud console ▸ **APIs & Services ▸ Credentials ▸ Create credentials ▸ OAuth
   client ID** ▸ type **Chrome extension** ▸ paste the extension id ▸ **Create**
   ▸ copy the client id.
3. Paste it into [`manifest.json`](manifest.json) → `oauth2.client_id`, then
   reload the extension.

### 7. Let Firebase trust that client
Firebase console ▸ Authentication ▸ Sign-in method ▸ **Google** ▸ *"Whitelist
client IDs from external projects"* ▸ add the extension's OAuth client id. (A
Chrome-extension client is always "external" to Firebase's own web client.)

### 8. Deploy the security rules
With `(default)` you can edit rules in the console's **Rules** tab, or deploy the
version-controlled [`firestore.rules`](firestore.rules) via CLI:

```bash
npm install -g firebase-tools
firebase login
firebase deploy --only firestore:rules --project clingen-cvc   # run from clinvar-cvc/
```

The rule requires the caller to be an **allowlisted curator** (see step 8a) whose
verified token email equals the `user_email` being written, and makes documents
immutable (create-only).

### 8a. Seed the curator allowlist (add yourself)
Access is controlled by the `allowed_curators` collection: **document id = an
authorized email.** Add yourself first, or your own test write in step 9 is denied.

Firebase console ▸ Firestore Database ▸ (default) ▸ **Data** ▸ **Start collection**
▸ collection id `allowed_curators` ▸ **Add document** ▸ set the **Document ID** to
your Google email (e.g. `you@example.com`) ▸ add an optional field like
`added_by` (string) ▸ **Save.** (Field contents don't matter — only the doc's
existence does.)

To authorize others later, add one document per email the same way; to revoke,
delete their document. See "Who can use the extension" below.

### 9. Load and test
1. `chrome://extensions/` ▸ enable **Developer mode** ▸ **Load unpacked** ▸ select
   `clinvar-cvc/`.
2. Click the icon, fill the form, **Save to Firestore.** Chrome prompts for Google
   consent the first time. Success shows a Firestore document id.
3. Confirm in Firestore Database ▸ Data ▸ `clinvar_cvc_ext_annotations`, with
   `user_email` = your verified Google email.

### 10. Stream Firestore → BigQuery
Install the Firebase Extension **"Stream Firestore to BigQuery"**
(`firestore-bigquery-export`). Console install works, but via CLI it's two steps
(this tripped us up — `ext:install` only records to the local manifest):

```bash
firebase ext:install firebase/firestore-bigquery-export --project clingen-cvc  # records params
firebase deploy --only extensions --project clingen-cvc --force                # ACTUALLY deploys
```

Parameter values:
- **Collection path**: `clinvar_cvc_ext_annotations`
- **Dataset ID**: `clinvar_cvc_ext`  **Table ID**: `annotations`
- **Firestore Database region**: ⚠️ must be your database's **location**, i.e.
  **`nam5`** (the US multi-region), **not** `us-central1`. The install default is
  wrong for a multi-region DB and the deploy fails with *"Database '(default)'
  does not exist in region 'us-central1'."*
- **BigQuery dataset location**: `us-central1` (as configured here) — remember to
  pass `--location=us-central1` on CLI queries.
- View type: regular view; time partitioning: NONE.

Fresh-project IAM (the deploy fails without these):
```bash
# the compute SA needs build permissions (gen1 helper functions build via Cloud Build)
SA="$(gcloud projects describe clingen-cvc --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
for r in roles/storage.objectViewer roles/logging.logWriter roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding clingen-cvc --member="serviceAccount:${SA}" --role="$r" --condition=None
done
```

After deploy, grant the Eventarc trigger's SA **Cloud Run Invoker** on the
function's Cloud Run service (otherwise events 403 and nothing streams — see
Troubleshooting):
```bash
TRIG_SA=$(gcloud eventarc triggers list --project=clingen-cvc --location=nam5 \
  --format="value(serviceAccount)" | head -1)
[ -z "$TRIG_SA" ] && TRIG_SA="${SA}"
gcloud run services add-iam-policy-binding ext-firestore-bigquery-export-fsexportbigquery \
  --region=us-central1 --project=clingen-cvc --member="serviceAccount:${TRIG_SA}" --role=roles/run.invoker
```

The dataset/table are created on the **first write after deploy** (earlier writes
don't backfill). Verify:
```bash
bq --location=us-central1 --project_id=clingen-cvc query --use_legacy_sql=false \
  'SELECT COUNT(*) FROM `clingen-cvc.clinvar_cvc_ext.annotations_raw_changelog`'
```

### 11. Flattened BigQuery table
Create the typed view (one column per field, mirroring the Firestore doc) from
[`bigquery/annotations_view.sql`](bigquery/annotations_view.sql). Pipe it via
stdin — `bq` crashes if a query that starts with `--` comments is passed as an
argument:
```bash
bq --location=us-central1 --project_id=clingen-cvc query --use_legacy_sql=false \
  < bigquery/annotations_view.sql
```
This builds **`clingen-cvc.clinvar_cvc_ext.annotations`** over
`annotations_raw_latest`. Note: the extension serializes Firestore timestamps as
`{_seconds,_nanoseconds}`, so the view extracts `created_at` via
`TIMESTAMP_SECONDS(... '$.created_at._seconds')`. Swap `VIEW`→`TABLE` (or a
scheduled query) for a physical table.

### Adjusting the extension log level (`LOG_LEVEL`)
The extension is deployed with `LOG_LEVEL=debug` (verbose — handy while setting
up). To quiet it down (less log noise/cost) or turn it back up to diagnose an
issue, toggle it either way:

**CLI (edit the manifest, redeploy):**
1. Edit `extensions/firestore-bigquery-export.env` → set `LOG_LEVEL=warn`
   (valid: `debug`, `info`, `warn`, `error`, `silent`).
2. `firebase deploy --only extensions --project clingen-cvc --force`

**Console:** Extensions ▸ *Stream Firestore to BigQuery* ▸ **Reconfigure
extension** ▸ set **Log level** ▸ Save.

⚠️ **Either path re-creates the Eventarc trigger**, which drops the Cloud Run
Invoker binding — so **re-run the `run.invoker` grant from step 10** afterward, or
streaming silently 403s (see Troubleshooting). Suggested: `warn` for normal
operation, `debug` only while investigating.

---

## Who can use the extension

Access has **two independent gates**:

1. **Authentication (audience)** — the OAuth consent screen of `clingen-cvc`. Set
   to **External + In production** (step 4), so *any* Google account (inside or
   outside the institution) can sign in.
2. **Authorization (allowlist)** — the `allowed_curators` collection. Only an
   account whose verified email has a document there can actually **submit**;
   the security rules enforce this and can't be bypassed from the extension.

So signing in is open, but submitting is restricted to the allowlist. A signed-in
account that isn't listed gets a "not authorized — contact an administrator"
message (the write returns `PERMISSION_DENIED`).

### Managing the allowlist (admin)
Easiest — the helper scripts (need gcloud authed as a project owner/editor):
```bash
./add-curator.sh    jane@example.com   # authorize
./remove-curator.sh jane@example.com   # revoke
./list-curators.sh                     # show all authorized emails
```
(They write to `allowed_curators` via the Firestore REST API with your owner
token, which bypasses the client-write rule. Override the project with
`CVC_PROJECT=... ./add-curator.sh ...`.)

Or by hand in the console:
- **Add a curator**: Firestore ▸ Data ▸ `allowed_curators` ▸ **Add document** ▸
  Document ID = their Google email. (An optional `added_by`/`note` field is just
  for your bookkeeping.)
- **Remove a curator**: delete their document. Effective on their next submit
  (their in-flight token doesn't grant a bypass — every write re-checks the rule).
- Clients can't modify `allowed_curators` (rules forbid it); manage it only via
  the console, these scripts, or the Admin SDK.

> Want Google-Group-based management later? Keep this same collection as the
> enforcement point and add a scheduled job that syncs the group's membership
> into `allowed_curators` (Cloud Identity API). The rules don't change.

## Security (before this is more than a POC)

With `authMode: 'google'` the persisted `user_email` is verified, the rule
enforces `user_email == request.auth.token.email`, and only allowlisted curators
can write. Remaining hardening:

- **App Check** so only your extension (not anyone with the API key) can write.
- **Field/shape validation** in the rules (types, required fields, allowed
  `action`/`reason` values).

---

## Troubleshooting (things that actually bit us)

**External users can't sign in.** The OAuth consent screen is **Internal**, or
**External + Testing** without the user in the Test users list. Set it to
**External + In production** on the project that owns the `client_id` (step 4).

**A legitimate curator signs in but gets "not authorized" / `PERMISSION_DENIED`.**
The `allowed_curators` document id must **exactly match** their verified email
(it's case-sensitive — `Jane@x.com` ≠ `jane@x.com`), and they must be using
Google sign-in (`authMode: 'google'`) so the token carries a verified email.
Confirm the doc exists under the correct database/collection and re-try.

**`getAuthToken` fails with a bad-client-id / OAuth error.** The `oauth2.client_id`
in the manifest must be a **Chrome extension** OAuth client whose id matches this
extension's id, and it must be **whitelisted** in Firebase's Google provider
(step 7). Note: an unpacked extension's id is stable per machine/profile — if it
changes, re-create the OAuth client (or pin the id with a manifest `key`).

**`firebase ext:install` ran but no extension/functions exist.** In current
firebase-tools, `ext:install` only records the extension to the local
`firebase.json` manifest — it does **not** deploy. Run
`firebase deploy --only extensions --project clingen-cvc --force` to actually
install it.

**Extension deploy fails: "Database '(default)' does not exist in region
'us-central1'. Did you mean 'nam5'?"** The recorded **Firestore Database region**
is wrong. Set it to your database's location — `nam5` for the US multi-region —
in `extensions/firestore-bigquery-export.env` (`DATABASE_REGION=nam5`) and
redeploy. (The Cloud Function can stay in `us-central1`; only the trigger region
must match the DB.)

**Extension deploy fails: "Access to bucket gcf-sources-… denied … grant Storage
Object Viewer to …-compute@developer.gserviceaccount.com."** A fresh project's
compute service account lacks build permissions. Grant them, then redeploy:
```bash
SA="$(gcloud projects describe clingen-cvc --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
for r in roles/storage.objectViewer roles/logging.logWriter roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding clingen-cvc --member="serviceAccount:${SA}" --role="$r" --condition=None
done
```

**Firestore writes succeed but nothing reaches BigQuery / no dataset appears.**
Confirm the extension's **Collection path** (`clinvar_cvc_ext_annotations`) and
that it was actually deployed (above). The dataset/table are created on the first
write *after* deploy; earlier writes don't backfill.

**Dataset + tables exist but stay empty even after new saves.** Check the function
logs (Extensions ▸ your extension ▸ Logs). If you see `HTTP 403` pushes to the
function's `*.run.app` URL (`__GCP_CloudEventsMode=CE_PUBSUB_BINDING`), the
Eventarc trigger fired but its delivery identity can't invoke the Cloud Run
service. Grant it **Cloud Run Invoker** (this commonly breaks after reconfiguring
or toggling `LOG_LEVEL`). Note the trigger lives in **`nam5`** (the DB region):

```bash
TRIG_SA=$(gcloud eventarc triggers list --location=nam5 --project=clingen-cvc \
  --format="value(serviceAccount)" | head -1)
gcloud run services add-iam-policy-binding ext-firestore-bigquery-export-fsexportbigquery \
  --region=us-central1 --project=clingen-cvc \
  --member="serviceAccount:${TRIG_SA}" --role=roles/run.invoker
```

Pub/Sub retries failed pushes, so previously-403'd events usually backfill within
a couple of minutes once the binding lands.

**`SELECT` returns rows but the Preview tab looks empty.** Freshly streamed rows
sit in BigQuery's streaming buffer, which the Preview tab doesn't show. Verify
with a query, not Preview.

**Extension deployed via CLI, function runs, but the BQ dataset/table are never
created ("Not found: Dataset/Table").** The `firestore-bigquery-export` extension
installed via `firebase deploy --only extensions` (manifest mode) does NOT reliably
run its BigQuery **setup lifecycle** (the step that creates the dataset, changelog
table, and latest view) on a fresh project — and it also does NOT auto-grant the
runtime SA its declared roles. Granting the roles (bigquery.dataEditor/jobUser,
cloudtasks.enqueuer, eventarc.publisher, run.invoker) makes the function run
cleanly, but it still only *writes* — it never *creates* the schema. **Fix: install
this extension via the Firebase console** (Extensions ▸ install), which runs the
setup and grants roles automatically — this is how the prod (`clingen-cvc`) instance
was installed and works. Reserve the CLI/manifest path for *config* changes to an
already-console-installed instance.
