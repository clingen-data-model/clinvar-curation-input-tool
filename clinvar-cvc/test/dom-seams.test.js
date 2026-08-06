import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { inspectSeams, seamDefs } = require('../dom-seams.js');
const { extractClinVarData } = require('../scrape.js');
const here = dirname(fileURLToPath(import.meta.url));
const htmlGermline = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');
const html73058 = readFileSync(join(here, 'fixtures/clinvar-variation-73058.html'), 'utf8');

const bySeam = (report) => Object.fromEntries(report.seams.map((s) => [s.key, s]));

describe('dom-seams.inspectSeams — healthy pages', () => {
  it('germline-only page (variation 590935): all required seams resolve; somatic absent-but-ok', () => {
    document.documentElement.innerHTML = htmlGermline;
    const report = inspectSeams(document);
    const s = bySeam(report);
    expect(report.ok).toBe(true);
    // every header seam resolved
    ['variant-details-box', 'vcv-accession', 'vcv-variation-id', 'variant-name',
     'vcv-classification', 'vcv-review-status', 'timeline'].forEach((k) => {
      expect(s[k].ok, `${k}: ${s[k].detail}`).toBe(true);
    });
    // germline present with rows; somatic sections legitimately absent (still ok)
    expect(s['scv:germline'].present).toBe(true);
    expect(s['scv:germline'].count).toBe(3);
    expect(s['scv:somatic-clinical-impact'].present).toBe(false);
    expect(s['scv:somatic-clinical-impact'].ok).toBe(true); // optional + absent = healthy
    expect(s['scv:somatic-oncogenicity'].ok).toBe(true);
  });

  it('multi-section page (variation 73058): all three SCV sections present + shape-ok', () => {
    document.documentElement.innerHTML = html73058;
    const report = inspectSeams(document);
    const s = bySeam(report);
    expect(report.ok).toBe(true);
    expect(s['scv:germline']).toMatchObject({ present: true, count: 9, ok: true });
    expect(s['scv:somatic-clinical-impact']).toMatchObject({ present: true, count: 7, ok: true });
    expect(s['scv:somatic-oncogenicity']).toMatchObject({ present: true, count: 1, ok: true });
  });
});

describe('dom-seams.inspectSeams — drift pinpointing', () => {
  it('a renamed variant-details box flags exactly the box-dependent seams, not the rest', () => {
    // Simulate ClinVar drift: the #new-variant-details container id changes.
    document.documentElement.innerHTML =
      htmlGermline.replace(/id="new-variant-details"/g, 'id="new-variant-details-RENAMED"');
    const report = inspectSeams(document);
    const s = bySeam(report);
    expect(report.ok).toBe(false); // overall unhealthy
    // the box and the two fields parsed out of it break…
    expect(s['variant-details-box'].ok).toBe(false);
    expect(s['vcv-accession'].ok).toBe(false);
    expect(s['vcv-variation-id'].ok).toBe(false);
    // …while seams that don't depend on that box stay healthy (precise blame)
    expect(s['variant-name'].ok).toBe(true);
    expect(s['vcv-classification'].ok).toBe(true);
    expect(s['vcv-review-status'].ok).toBe(true);
    expect(s['scv:germline'].ok).toBe(true);
  });

  it('a germline table stripped of its rows flags scv:germline (required)', () => {
    document.documentElement.innerHTML =
      htmlGermline.replace(/germline-sub-col/g, 'germline-sub-col-RENAMED');
    const report = inspectSeams(document);
    const s = bySeam(report);
    expect(report.ok).toBe(false);
    expect(s['scv:germline']).toMatchObject({ present: false, ok: false });
  });
});

describe('dom-seams — registry & scraper consistency', () => {
  it('seamDefs covers all three SCV sections (reuses scv-sections.js)', () => {
    const keys = seamDefs().map((d) => d.key);
    expect(keys).toEqual(expect.arrayContaining([
      'scv:germline', 'scv:somatic-clinical-impact', 'scv:somatic-oncogenicity'
    ]));
  });

  // Ties the inspector to reality: whenever the real scraper yields a value, the
  // matching seam must report healthy — so the mirror can't silently drift from
  // scrape.js without a test failing.
  it.each([
    ['germline page', htmlGermline],
    ['73058 page', html73058]
  ])('%s: populated scrape fields ⇒ healthy seams, and row count matches', (_label, html) => {
    document.documentElement.innerHTML = html;
    const data = extractClinVarData(document);
    const s = bySeam(inspectSeams(document));
    const link = {
      vcv: 'vcv-accession', variation_id: 'vcv-variation-id', name: 'variant-name',
      vcv_interp: 'vcv-classification', vcv_review: 'vcv-review-status'
    };
    Object.entries(link).forEach(([field, seam]) => {
      if (data[field]) expect(s[seam].ok, `${field} populated but ${seam} unhealthy`).toBe(true);
    });
    const seamRowTotal = ['scv:germline', 'scv:somatic-clinical-impact', 'scv:somatic-oncogenicity']
      .reduce((n, k) => n + (s[k].count || 0), 0);
    expect(seamRowTotal).toBe(data.row.length);
  });
});
