import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const {
  AuthError, assertAllowlisted, makeAuthGuard, authErrorStatus,
  makeFirestoreAllowlistLookup
} = require('../auth.js');

// A trivial injected allowlist: a Set of allowed emails.
const allowOf = (...emails) => {
  const s = new Set(emails.map((e) => e.toLowerCase()));
  return async (email) => s.has(email);
};

describe('assertAllowlisted', () => {
  it('returns the normalized email for an allow-listed curator', async () => {
    const e = await assertAllowlisted('  LBabb@Broadinstitute.org ', allowOf('lbabb@broadinstitute.org'));
    expect(e).toBe('lbabb@broadinstitute.org');
  });
  it('throws notAuthorized for a non-allow-listed email', async () => {
    await expect(assertAllowlisted('nope@x.org', allowOf('lbabb@broadinstitute.org')))
      .rejects.toMatchObject({ code: 'notAuthorized' });
  });
  it('throws unauthenticated for an empty/missing email', async () => {
    await expect(assertAllowlisted('', allowOf('a@b.org'))).rejects.toMatchObject({ code: 'unauthenticated' });
    await expect(assertAllowlisted(null, allowOf('a@b.org'))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
});

describe('makeAuthGuard', () => {
  const verifyOk = async (tok) => {
    if (tok === 'good') return { email: 'lbabb@broadinstitute.org', email_verified: true };
    if (tok === 'unverified') return { email: 'lbabb@broadinstitute.org', email_verified: false };
    if (tok === 'stranger') return { email: 'stranger@x.org', email_verified: true };
    throw new Error('bad token');
  };
  const guard = makeAuthGuard({ verifyIdToken: verifyOk, isAllowlisted: allowOf('lbabb@broadinstitute.org') });
  const req = (auth) => ({ headers: auth ? { authorization: auth } : {} });

  it('authenticates an allow-listed user with a valid Bearer token', async () => {
    await expect(guard(req('Bearer good'))).resolves.toEqual({ email: 'lbabb@broadinstitute.org' });
  });
  it('rejects a missing/mal-formed Authorization header (unauthenticated)', async () => {
    await expect(guard(req(null))).rejects.toMatchObject({ code: 'unauthenticated' });
    await expect(guard(req('Basic xyz'))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  it('rejects an invalid ID token (unauthenticated)', async () => {
    await expect(guard(req('Bearer bad'))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  it('rejects an unverified email (unauthenticated)', async () => {
    await expect(guard(req('Bearer unverified'))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  it('rejects a valid but non-allow-listed user (notAuthorized)', async () => {
    await expect(guard(req('Bearer stranger'))).rejects.toMatchObject({ code: 'notAuthorized' });
  });
});

describe('authErrorStatus', () => {
  it('maps auth error codes to HTTP status', () => {
    expect(authErrorStatus(new AuthError('unauthenticated', ''))).toBe(401);
    expect(authErrorStatus(new AuthError('notAuthorized', ''))).toBe(403);
    expect(authErrorStatus(new Error('other'))).toBe(500);
  });
});

describe('makeFirestoreAllowlistLookup', () => {
  // Fake Firestore: allowed_curators/<email> doc existence.
  const fakeDb = (present) => ({
    collection: (name) => ({
      doc: (id) => ({
        get: async () => ({ exists: name === 'allowed_curators' && present.includes(id) })
      })
    })
  });
  it('is true only when the allowed_curators doc for the email exists', async () => {
    const lookup = makeFirestoreAllowlistLookup(fakeDb(['lbabb@broadinstitute.org']));
    expect(await lookup('lbabb@broadinstitute.org')).toBe(true);
    expect(await lookup('nope@x.org')).toBe(false);
  });
});
