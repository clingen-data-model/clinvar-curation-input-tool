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
| `manifest.json` | MV3 config; popup action, icons, permissions, `oauth2` client |
| `popup.html` | The 5-field form |
| `popup.js` | Validates input, Google sign-in, writes a Firestore document via REST |
| `firebase-config.js` | **You edit this** — `apiKey` (project/db/collection/authMode preset) |
| `firestore.rules` + `firebase.json` | Security rules (deploy via Firebase CLI) |
| `bigquery/annotations_view.sql` | Flattened BigQuery view mirroring the Firestore doc shape |
| `setup-clingen-cvc.sh` | Scripts the automatable setup (project/APIs/Firestore/rules/allowlist/webapp); pauses for the console-only OAuth steps |
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
(`firestore-bigquery-export`):
- **Firestore Database ID**: `(default)` (the extension's default — correct here).
- **Collection path**: `clinvar_cvc_ext_annotations`
- **Dataset ID**: `clinvar_cvc_ext`  **Table ID**: `annotations`
- **BigQuery dataset location**: `us` (matches a US Firestore location).

The extension creates the dataset/table on the first write after install (it only
streams writes made *after* install). Then verify:

```sql
SELECT COUNT(*) FROM `clingen-cvc.clinvar_cvc_ext.annotations_raw_changelog`;
```

### 11. Flattened BigQuery table
Run [`bigquery/annotations_view.sql`](bigquery/annotations_view.sql) once in the
BigQuery console. It creates the view **`clingen-cvc.clinvar_cvc_ext.annotations`**
with one typed column per field (mirroring the Firestore document) over
`annotations_raw_latest`. Swap `VIEW`→`TABLE` (or use a scheduled query) for a
physical table.

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
- **Add a curator**: Firestore ▸ Data ▸ `allowed_curators` ▸ **Add document** ▸
  Document ID = their Google email. (An optional `added_by`/`note` field is just
  for your bookkeeping.)
- **Remove a curator**: delete their document. Effective on their next submit
  (their in-flight token doesn't grant a bypass — every write re-checks the rule).
- Clients can't modify `allowed_curators` (rules forbid it); manage it only via
  the console or the Admin SDK.

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

**Firestore writes succeed but nothing reaches BigQuery / no dataset appears.**
Check the extension's **Firestore Database ID** param — with `(default)` it should
be `(default)` (the default). Also confirm the Collection path.

**Dataset + tables exist but stay empty even after new saves.** Check the function
logs (Extensions ▸ your extension ▸ Logs). If you see `HTTP 403` pushes to the
function's `*.run.app` URL (`__GCP_CloudEventsMode=CE_PUBSUB_BINDING`), the
Eventarc trigger fired but its delivery identity can't invoke the Cloud Run
service. Grant it **Cloud Run Invoker** (this commonly breaks after reconfiguring):

```bash
gcloud eventarc triggers list --location=us-central1 --project=clingen-cvc
gcloud eventarc triggers describe TRIGGER_NAME \
  --location=us-central1 --project=clingen-cvc \
  --format="value(serviceAccount)"
gcloud run services add-iam-policy-binding ext-firestore-bigquery-export-fsexportbigquery \
  --region=us-central1 --project=clingen-cvc \
  --member="serviceAccount:TRIGGER_SA" --role=roles/run.invoker
```

Pub/Sub retries failed pushes, so previously-403'd events usually backfill within
a couple of minutes once the binding lands.

**`SELECT` returns rows but the Preview tab looks empty.** Freshly streamed rows
sit in BigQuery's streaming buffer, which the Preview tab doesn't show. Verify
with a query, not Preview.
