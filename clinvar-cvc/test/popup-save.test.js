import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { classifyWriteError } = require('../firestore-write.js');
describe('classifyWriteError', () => {
  it('detects ALREADY_EXISTS (409)', () => {
    expect(classifyWriteError(409, { error: { status: 'ALREADY_EXISTS' } })).toBe('alreadyExists');
  });
  it('detects not-authorized (403 / PERMISSION_DENIED)', () => {
    expect(classifyWriteError(403, {})).toBe('notAuthorized');
    expect(classifyWriteError(400, { error: { message: 'Missing or insufficient permissions' } })).toBe('notAuthorized');
  });
  it('returns null otherwise', () => {
    expect(classifyWriteError(500, { error: { message: 'server' } })).toBeNull();
  });
});
