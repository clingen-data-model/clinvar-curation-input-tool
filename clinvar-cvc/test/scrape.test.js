import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { extractClinVarData } = require('../scrape.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');
const html73058 = readFileSync(join(here, 'fixtures/clinvar-variation-73058.html'), 'utf8');

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
  it('tags every germline row with section: "germline"', () => {
    const d = extractClinVarData(document);
    expect(d.row.map((r) => r.section)).toEqual(['germline', 'germline', 'germline']);
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

describe('scrape.extractClinVarData — all three SCV sections (variation 73058)', () => {
  beforeEach(() => { document.documentElement.innerHTML = html73058; });

  const bySection = (rows, key) => rows.filter((r) => r.section === key);

  it('still extracts the germline rows (each tagged section: "germline")', () => {
    const d = extractClinVarData(document);
    const germline = bySection(d.row, 'germline');
    expect(germline.length).toBe(9); // fixture has 9 germline-sub-col rows
    for (const r of germline) {
      expect(r.scv).toMatch(/^SCV\d+\.\d+$/);
      // germline review still carries a standard review-status phrase
      expect(typeof r.review).toBe('string');
    }
  });

  it('extracts the 7 somatic clinical-impact rows tagged + parsed', () => {
    const d = extractClinVarData(document);
    const ci = bySection(d.row, 'somatic-clinical-impact');
    expect(ci.length).toBe(7);
    const first = ci[0];
    expect(first.scv).toBe('SCV007104961.1');
    expect(first.submitter_id).toBe('196472');
    // full classification phrase preserved; trailing "(date)" stripped into eval_date
    expect(first.interp).toBe('Tier I (Strong) - Diagnostic - supports diagnosis');
    expect(first.eval_date).toBe('Jul 11, 2023');
    // relaxed review extractor (no "Method:" in somatic cell[1])
    expect(first.review).toBe('criteria provided, single submitter');
    expect(first.subm_date).toBe('Nov 22, 2025');
  });

  it('extracts the 1 somatic oncogenicity row tagged + parsed', () => {
    const d = extractClinVarData(document);
    const onc = bySection(d.row, 'somatic-oncogenicity');
    expect(onc.length).toBe(1);
    expect(onc[0].scv).toBe('SCV005094176.2');
    expect(onc[0].interp).toBe('Oncogenic');
    expect(onc[0].eval_date).toBe('Mar 04, 2025');
    expect(onc[0].review).toBe('criteria provided, single submitter');
  });

  it('orders row[] germline, then clinical-impact, then oncogenicity', () => {
    const d = extractClinVarData(document);
    expect(d.row.length).toBe(9 + 7 + 1);
    const sections = d.row.map((r) => r.section);
    expect(sections.slice(0, 9).every((s) => s === 'germline')).toBe(true);
    expect(sections.slice(9, 16).every((s) => s === 'somatic-clinical-impact')).toBe(true);
    expect(sections[16]).toBe('somatic-oncogenicity');
  });

  it('matches the pinned multi-section scraped-content shape', () => {
    expect(extractClinVarData(document)).toMatchSnapshot();
  });
});
