import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { getMatch } = require('../../scvc/content.js');

describe('getMatch', () => {
  it('returns the requested capture group', () => {
    expect(getMatch('Accession: VCV000012345.1', /Accession:\s*(VCV\d+\.\d+)/, 1))
      .toBe('VCV000012345.1');
  });
  it('returns empty string on no match', () => {
    expect(getMatch('nothing here', /(SCV\d+)/, 1)).toBe('');
  });
});
