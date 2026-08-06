import { describe, it, expect, afterEach } from 'vitest';
import { fileURLToPath } from 'url';
import { dirname } from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const mod = require('../scv-sections.js');
const { SCV_SECTIONS, ANNOTATABLE_SCV_SECTIONS, annotatableSections } = mod;

// Snapshot the default config so trimming in one test can't leak into others.
const DEFAULT_CONFIG = ANNOTATABLE_SCV_SECTIONS.slice();
afterEach(() => {
  ANNOTATABLE_SCV_SECTIONS.length = 0;
  DEFAULT_CONFIG.forEach((k) => ANNOTATABLE_SCV_SECTIONS.push(k));
});

describe('scv-sections registry', () => {
  it('registers the three SCV sections in order with a clean discriminator + inject cell', () => {
    expect(SCV_SECTIONS.map((s) => s.key)).toEqual([
      'germline',
      'somatic-clinical-impact',
      'somatic-oncogenicity'
    ]);
    for (const s of SCV_SECTIONS) {
      expect(typeof s.rowSelector).toBe('string');
      expect(s.rowSelector.length).toBeGreaterThan(0);
      expect(s.injectCell).toBe(3);
    }
  });

  it('uses the table-id discriminator for the somatic sections', () => {
    const byKey = Object.fromEntries(SCV_SECTIONS.map((s) => [s.key, s]));
    expect(byKey['germline'].rowSelector).toBe('.submissions-germline-list tbody tr.germline-sub-col');
    expect(byKey['somatic-clinical-impact'].rowSelector)
      .toBe('#submissions-somatic-list-clinical-impact-tbody tr.somatic-sub-col');
    expect(byKey['somatic-oncogenicity'].rowSelector)
      .toBe('#submissions-somatic-list-oncogenicity-tbody tr.somatic-sub-col');
  });

  it('defaults to germline only (somatic sections supported but off by default)', () => {
    expect(ANNOTATABLE_SCV_SECTIONS).toEqual(['germline']);
    expect(annotatableSections().map((s) => s.key)).toEqual(['germline']);
  });

  it('annotatableSections() honors a trimmed config (in registry order)', () => {
    ANNOTATABLE_SCV_SECTIONS.length = 0;
    ANNOTATABLE_SCV_SECTIONS.push('somatic-oncogenicity', 'germline');
    // preserves REGISTRY order, not config order
    expect(annotatableSections().map((s) => s.key)).toEqual([
      'germline',
      'somatic-oncogenicity'
    ]);
  });

  it('annotatableSections() returns registry entries (not copies) so callers get selectors', () => {
    ANNOTATABLE_SCV_SECTIONS.length = 0;
    ANNOTATABLE_SCV_SECTIONS.push('germline');
    const got = annotatableSections();
    expect(got.length).toBe(1);
    expect(got[0]).toBe(SCV_SECTIONS[0]);
  });
});
