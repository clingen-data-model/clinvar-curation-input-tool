import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { handleInitializePopup, applyHighlights } = require('../content.js');
const { extractClinVarData } = require('../scrape.js');
const { SCV_SECTIONS, ANNOTATABLE_SCV_SECTIONS } = require('../scv-sections.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');
const html73058 = readFileSync(join(here, 'fixtures/clinvar-variation-73058.html'), 'utf8');

describe('content.handleInitializePopup', () => {
  beforeEach(() => { document.documentElement.innerHTML = html; });
  it('returns scraped data for an initializePopup message', () => {
    const data = handleInitializePopup({ from: 'popup', subject: 'initializePopup' }, document);
    expect(data).not.toBeNull();
    expect(data.vcv).toBe('VCV000590935.4');
    expect(data.row.length).toBe(3);
  });
  it('returns null for unrelated messages', () => {
    expect(handleInitializePopup({ from: 'popup', subject: 'other' }, document)).toBeNull();
  });
});

describe('content.applyHighlights', () => {
  beforeEach(() => {
    document.documentElement.innerHTML = html;
    window.extractClinVarData = extractClinVarData; // scrape.js sets this global in the browser
  });
  // Regression: a variation with NO prior CvC annotations must still get a
  // "+ Annotate" button on every SCV row (the empty-history case that used to
  // be suppressed by initHighlights' `!resp.rows.length` guard).
  it('adds a + Annotate button to EVERY SCV row even with no prior history', () => {
    applyHighlights(document, {}); // {} = empty history summary
    expect(document.querySelectorAll('.cvc-annotate-btn').length).toBe(3); // fixture has 3 rows
    expect(document.querySelectorAll('.cvc-hl-badge').length).toBe(0);     // no history → no CvC-N badges
  });
  it('is idempotent — repeated calls do not stack buttons', () => {
    applyHighlights(document, {});
    applyHighlights(document, {});
    expect(document.querySelectorAll('.cvc-annotate-btn').length).toBe(3);
  });
});

describe('content.applyHighlights — all three SCV sections (variation 73058)', () => {
  const byKey = Object.fromEntries(SCV_SECTIONS.map((s) => [s.key, s]));
  const DEFAULT_CONFIG = ANNOTATABLE_SCV_SECTIONS.slice();
  // count of + Annotate buttons injected into a given section's rows
  const btnCount = (key) =>
    document.querySelectorAll(byKey[key].rowSelector + ' .cvc-annotate-btn').length;
  const setConfig = (keys) => {
    ANNOTATABLE_SCV_SECTIONS.length = 0;
    keys.forEach((k) => ANNOTATABLE_SCV_SECTIONS.push(k));
  };

  beforeEach(() => {
    document.documentElement.innerHTML = html73058;
    window.extractClinVarData = extractClinVarData;
    setConfig(DEFAULT_CONFIG);
  });
  afterEach(() => { setConfig(DEFAULT_CONFIG); });

  it('adds + Annotate to rows in ALL three sections when all are configured', () => {
    setConfig(['germline', 'somatic-clinical-impact', 'somatic-oncogenicity']);
    applyHighlights(document, {});
    expect(btnCount('germline')).toBe(9);
    expect(btnCount('somatic-clinical-impact')).toBe(7);
    expect(btnCount('somatic-oncogenicity')).toBe(1);
    expect(document.querySelectorAll('.cvc-annotate-btn').length).toBe(17);
  });

  it('trimming ANNOTATABLE_SCV_SECTIONS to [germline] suppresses somatic badges', () => {
    setConfig(['germline']);
    applyHighlights(document, {});
    expect(btnCount('germline')).toBe(9);
    expect(btnCount('somatic-clinical-impact')).toBe(0);
    expect(btnCount('somatic-oncogenicity')).toBe(0);
    // no badge of ANY kind in either somatic table
    expect(document.querySelectorAll('.submissions-somatic-list .cvc-annotate-btn').length).toBe(0);
    expect(document.querySelectorAll('.submissions-somatic-list .cvc-hl-badge').length).toBe(0);
  });

  it('is idempotent across sections — repeated calls do not stack', () => {
    setConfig(['germline', 'somatic-clinical-impact', 'somatic-oncogenicity']);
    applyHighlights(document, {});
    applyHighlights(document, {});
    expect(document.querySelectorAll('.cvc-annotate-btn').length).toBe(17);
  });
});
