/**
 * Firebase / Firestore configuration for the ClinVar POC extension.
 *
 * This file is now a thin selector over env.js's per-environment config
 * (dev vs prod GCP projects). See env.js for the actual project details
 * (projectId, apiKey, databaseId, collection) for each environment.
 *
 * The OAuth client_id is NOT selected here — it stays fixed in manifest.json,
 * shared and whitelisted in both projects' Firebase Google providers, so
 * flipping ACTIVE_ENV only changes which Firestore project data is written to.
 *
 * How the extension authenticates to Firestore before writing
 * (FIREBASE_CONFIG.authMode):
 *   'google'    — Google sign-in via chrome.identity + Identity Toolkit. The
 *                 Firebase ID token carries a VERIFIED email, so rules enforce
 *                 user_email == request.auth.token.email. Requires the Google
 *                 provider enabled + an OAuth client id in manifest.json.
 *   'anonymous' — Firebase Anonymous Auth (email captured but NOT verified).
 *   'none'      — no auth; only works with open (test-mode) rules.
 *
 * NOTE: these are non-module top-level `const`s, so they are visible to
 * popup.js as long as this file is loaded (after env.js) first in popup.html.
 */
// Active environment: 'prod' (default) or 'dev'. Flip to 'dev' (or load the
// dev-pointed unpacked copy) to trial changes against clingen-cvc-dev.
const ACTIVE_ENV = 'prod';
const FIREBASE_CONFIG = { ...resolveConfig(ACTIVE_ENV), authMode: 'google' };
