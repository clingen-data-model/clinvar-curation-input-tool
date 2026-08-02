import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { scvOptionLabel, reasonOptionGroups, isScrapeable } = require('../popup-view.js');

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
