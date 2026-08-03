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
    { scv: 'SCV1', action: 'Flagging Candidate', reason: 'Outlier claim',
      notes: 'n1', user_email: 'a@x.org', created_at: '2024-01-02T00:00:00Z' },
    { scv: 'SCV1', action: 'No Change', reason: '',
      notes: '', user_email: 'b@x.org', created_at: '2024-03-01T00:00:00Z' },
    { scv: 'SCV2', action: 'No Change', reason: '',
      notes: '', user_email: 'c@x.org', created_at: '2023-05-01T00:00:00Z' }
  ];

  it('returns only the selected SCV, newest-first', () => {
    const v = historyView(rows, 'SCV1');
    expect(v).toHaveLength(2);
    expect(v[0].when).toBe('2024-03-01');   // newest first
    expect(v[0].who).toBe('b@x.org');
    expect(v[1].when).toBe('2024-01-02');
  });

  it('exposes action / reason / notes separately', () => {
    const v = historyView(rows, 'SCV1');
    expect(v[0]).toMatchObject({ action: 'No Change', reason: '', notes: '' });
    expect(v[1]).toMatchObject({ action: 'Flagging Candidate', reason: 'Outlier claim', notes: 'n1' });
  });

  it('is empty when no SCV is selected', () => {
    expect(historyView(rows, '')).toEqual([]);
    expect(historyView(rows, null)).toEqual([]);
  });

  it('is empty when the selected SCV has no history', () => {
    expect(historyView(rows, 'SCVX')).toEqual([]);
    expect(historyView([], 'SCV1')).toEqual([]);
  });
});
