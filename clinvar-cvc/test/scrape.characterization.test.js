import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const { extractClinVarData } = require('../../scvc/content.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');

describe('extractClinVarData (characterization of scvc scraper)', () => {
  beforeEach(() => { document.documentElement.innerHTML = html; });

  it('extracts VCV identity + a non-empty SCV list', () => {
    const data = extractClinVarData();
    expect(data.vcv).toMatch(/^VCV\d+/);
    expect(data.variation_id).toMatch(/^\d+$/);
    expect(Array.isArray(data.row)).toBe(true);
    expect(data.row.length).toBeGreaterThan(0);
    expect(data).toMatchSnapshot();
  });
});
