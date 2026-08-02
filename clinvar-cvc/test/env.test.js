import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveConfig } = require('../env.js');

describe('resolveConfig', () => {
  it('defaults to prod', () => {
    expect(resolveConfig().projectId).toBe('clingen-cvc');
    expect(resolveConfig().env).toBe('prod');
  });
  it('resolves dev', () => {
    const c = resolveConfig('dev');
    expect(c.projectId).toBe('clingen-cvc-dev');
    expect(c.collection).toBe('clinvar_cvc_ext_annotations');
    expect(c.databaseId).toBe('(default)');
  });
  it('throws on unknown env', () => {
    expect(() => resolveConfig('staging')).toThrow(/unknown env/i);
  });
});
