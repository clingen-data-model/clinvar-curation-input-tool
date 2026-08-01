/**
 * Firebase / Firestore configuration for the ClinVar POC extension.
 *
 * Everything for this POC now lives in its OWN GCP project, `clingen-cvc`,
 * so it can be published to an EXTERNAL OAuth audience (any Google account,
 * inside or outside the institution) without the org policies that block that
 * in clingen-dev. See README.md.
 *
 * Fill in from the Firebase console for `clingen-cvc`:
 *   Project settings > General > Your apps (Web app)
 *     - apiKey : the Web API key
 * (projectId is already set below.)
 *
 * `collection` is the Firestore collection the POC writes to. It MUST match
 * the "Collection path" you configure in the Firestore -> BigQuery extension.
 *
 * NOTE: these are non-module top-level `const`s, so they are visible to
 * popup.js as long as this file is loaded first in popup.html.
 */
const FIREBASE_CONFIG = {
  projectId: 'clingen-cvc',
  apiKey: 'PASTE_FIREBASE_WEB_API_KEY_HERE',

  // Dedicated project => use the default database (no named-database Rules-tab
  // or extension "Database ID" gotchas). Leave as '(default)'.
  databaseId: '(default)',

  collection: 'clinvar_cvc_ext_annotations',

  // How the extension authenticates to Firestore before writing:
  //   'google'    — Google sign-in via chrome.identity + Identity Toolkit. The
  //                 Firebase ID token carries a VERIFIED email, so rules enforce
  //                 user_email == request.auth.token.email. Requires the Google
  //                 provider enabled + an OAuth client id in manifest.json.
  //   'anonymous' — Firebase Anonymous Auth (email captured but NOT verified).
  //   'none'      — no auth; only works with open (test-mode) rules.
  authMode: 'google'
};
