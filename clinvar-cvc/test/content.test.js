import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { handleInitializePopup, applyHighlights } = require('../content.js');
const { extractClinVarData } = require('../scrape.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');

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
