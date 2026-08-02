import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { scvOptionLabel, reasonOptionGroups, isScrapeable, historyView } = require('../popup-view.js');

describe('popup-view', () => {
  it('formats an SCV option label (scv, interp, truncated submitter)', () => {
    const label = scvOptionLabel({ scv: 'SCV1.1', interp: 'Pathogenic',
      submitter: 'A very long submitter organization name' });
    expect(label).toContain('SCV1.1');
    expect(label).toContain('Pathogenic');
    expect(label).toMatch(/\.\.\.$/);
  });
  it('builds grouped reason options for an action', () => {
    const groups = reasonOptionGroups('Flagging Candidate');
    expect(groups.find(g => g.label === 'Submission errors')).toBeTruthy();
    expect(groups.some(g => g.options.includes('Other'))).toBe(true);
  });
  it('builds the flat ("" label) group for Remove Flagged Submission', () => {
    const groups = reasonOptionGroups('Remove Flagged Submission');
    expect(groups.length).toBe(1);
    expect(groups[0].label).toBe('');
    expect(groups[0].options).toContain('Curation error');
  });
  it('returns no groups for No Change', () => {
    expect(reasonOptionGroups('No Change')).toEqual([]);
  });
});

describe('isScrapeable', () => {
  it('true for data with a vcv and >=1 row', () => {
    expect(isScrapeable({ vcv: 'VCV1', row: [{ scv: 'SCV1.1' }] })).toBe(true);
  });
  it('false for null / no vcv / no rows', () => {
    expect(isScrapeable(null)).toBe(false);
    expect(isScrapeable({ row: [{}] })).toBe(false);
    expect(isScrapeable({ vcv: 'VCV1', row: [] })).toBe(false);
    expect(isScrapeable({ vcv: 'VCV1' })).toBe(false);
  });
});

describe('historyView', () => {
  const rows = [
    { scv: 'SCV000020162.8', submitter: 'OMIM', action: 'Flagging Candidate', reason: 'Outlier claim',
      notes: '', user_email: 'jratliff@broadinstitute.org', created_at: '2023-11-14T20:25:27Z' },
    { scv: 'SCV000111.1', submitter: 'LabX', action: 'No Change', reason: '',
      notes: 'looks fine', user_email: 'hrehm@broadinstitute.org', created_at: '2023-10-07T15:41:55Z' }
  ];

  it('returns one display row per annotation, newest-first order preserved', () => {
    const v = historyView(rows, 'SCV000111.1');
    expect(v).toHaveLength(2);
    expect(v[0].scv).toBe('SCV000020162.8');
  });

  it('formats a human date (YYYY-MM-DD) and marks the row matching currentScv', () => {
    const v = historyView(rows, 'SCV000111.1');
    expect(v[0].when).toBe('2023-11-14');
    expect(v[0].isCurrent).toBe(false);
    expect(v[1].isCurrent).toBe(true);
  });

  it('summarizes action + reason, and who', () => {
    const v = historyView(rows, '');
    expect(v[1].summary).toBe('No Change');            // no reason → action only
    expect(v[0].summary).toBe('Flagging Candidate — Outlier claim');
    expect(v[0].who).toBe('jratliff@broadinstitute.org');
  });

  it('is empty for no rows', () => {
    expect(historyView([], 'x')).toEqual([]);
  });
});
