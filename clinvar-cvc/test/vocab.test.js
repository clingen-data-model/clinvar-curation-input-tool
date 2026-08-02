import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { ACTIONS, reasonsForAction } = require('../vocab.js');

describe('vocab', () => {
  it('exposes the three actions', () => {
    expect(ACTIONS).toEqual(['No Change', 'Flagging Candidate', 'Remove Flagged Submission']);
  });
  it('gives grouped reasons for Flagging Candidate', () => {
    const r = reasonsForAction('Flagging Candidate');
    expect(Object.keys(r)).toContain('Submission errors');
    expect(r['Miscellaneous']).toContain('Other');
  });
  it('gives flat reasons for Remove Flagged Submission', () => {
    const r = reasonsForAction('Remove Flagged Submission');
    expect(r['']).toContain('Curation error');
  });
  it('gives no reasons for No Change', () => {
    expect(reasonsForAction('No Change')).toEqual({});
  });
});
