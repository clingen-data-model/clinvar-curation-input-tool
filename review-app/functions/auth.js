// auth.js — pure, dependency-injected authorization for the Review & Submit
// web-app backend. Reuses the CvC v4 identity model (Google sign-in + the
// `allowed_curators` allowlist), but shares NO code with the extension's
// chrome.* auth — a web app verifies a Firebase ID token and re-checks the
// allowlist server-side (never trust the client).
//
// Everything here is pure + injectable (token verifier + allowlist lookup are
// passed in) so it unit-tests with no live Firebase/GCP. CommonJS (Node/Functions).

class AuthError extends Error {
  // code: 'unauthenticated' (401) | 'notAuthorized' (403)
  constructor(code, message) { super(message); this.name = 'AuthError'; this.code = code; }
}

// Resolve + authorize an email against the allowlist. `isAllowlisted` is an
// injected async (email)=>bool. Returns the normalized (trimmed, lowercased)
// email; throws AuthError otherwise.
async function assertAllowlisted(email, isAllowlisted) {
  const e = String(email || '').trim().toLowerCase();
  if (!e) throw new AuthError('unauthenticated', 'no verified email on the request');
  const ok = await isAllowlisted(e);
  if (!ok) throw new AuthError('notAuthorized', `${e} is not an authorized curator`);
  return e;
}

// Build an auth guard for HTTP handlers. Injected deps:
//   verifyIdToken(rawToken) -> decoded { email, email_verified } (throws if invalid)
//   isAllowlisted(email)    -> Promise<bool>
// Returns async (req) -> { email }; throws AuthError on any failure.
function makeAuthGuard({ verifyIdToken, isAllowlisted }) {
  return async function authenticate(req) {
    const header = (req && req.headers && (req.headers.authorization || req.headers.Authorization)) || '';
    const m = /^Bearer\s+(.+)$/i.exec(String(header));
    if (!m) throw new AuthError('unauthenticated', 'missing Bearer token');
    let decoded;
    try {
      decoded = await verifyIdToken(m[1]);
    } catch (e) {
      throw new AuthError('unauthenticated', 'invalid ID token');
    }
    if (!decoded || decoded.email_verified === false) {
      throw new AuthError('unauthenticated', 'email not verified');
    }
    const email = await assertAllowlisted(decoded.email, isAllowlisted);
    return { email };
  };
}

// Map an AuthError to an HTTP status (anything else is a 500).
function authErrorStatus(err) {
  if (err && err.code === 'notAuthorized') return 403;
  if (err && err.code === 'unauthenticated') return 401;
  return 500;
}

// Firestore-backed allowlist lookup: allowed_curators/<email> doc existence
// (doc ids are verified emails — see clinvar-cvc/list-curators.sh). `db` is a
// Firestore instance (injected so this stays testable with a fake).
function makeFirestoreAllowlistLookup(db) {
  return async function isAllowlisted(email) {
    const snap = await db.collection('allowed_curators').doc(email).get();
    return !!(snap && snap.exists);
  };
}

module.exports = {
  AuthError, assertAllowlisted, makeAuthGuard, authErrorStatus, makeFirestoreAllowlistLookup
};
