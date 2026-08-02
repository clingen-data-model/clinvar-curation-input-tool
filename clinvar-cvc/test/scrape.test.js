import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { extractClinVarData } = require('../scrape.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');

describe('scrape.extractClinVarData', () => {
  beforeEach(() => { document.documentElement.innerHTML = html; });

  it('extracts VCV identity', () => {
    const d = extractClinVarData(document);
    expect(d.vcv).toBe('VCV000590935.4');
    expect(d.variation_id).toBe('590935');
    expect(d.vcv_interp).toBeTruthy();
    expect(d.vcv_review).toBeTruthy();
  });
  it('extracts one row per SCV with core fields', () => {
    const d = extractClinVarData(document);
    expect(d.row.length).toBe(3);
    for (const r of d.row) {
      expect(r.scv).toMatch(/^SCV\d+\.\d+$/);
      expect(typeof r.submitter).toBe('string');
      expect(typeof r.interp).toBe('string');
    }
  });
  it('does NOT emit the dead Sheets-only fields', () => {
    const d = extractClinVarData(document);
    expect(d.spreadsheet).toBeUndefined();
    expect(d.scv_range).toBeUndefined();
    expect(d.vcv_range).toBeUndefined();
  });
  it('matches the pinned scraped-content shape (no regression)', () => {
    expect(extractClinVarData(document)).toMatchSnapshot();
  });
});
