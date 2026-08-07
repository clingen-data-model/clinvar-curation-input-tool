import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { autoReview } = require('../autoReview.js');

// A "clean" latest annotation with a valid action, no flags.
const base = {
  action: 'flagging candidate', clinvarReviewStatus: 'criteria provided, single submitter',
  curator: 'someone@x.org', isDeletedScv: false, isLatestAnnotation: true,
  isOutdatedScv: false, classificationChanged: false
};
const REVIEWERS = ['lead@x.org', 'reviewer@x.org'];

describe('autoReview — each rule, in precedence order', () => {
  it('1. deleted SCV → Archive (auto)', () => {
    const r = autoReview({ ...base, isDeletedScv: true }, REVIEWERS);
    expect(r).toMatchObject({ status: 'Archive', auto: true });
    expect(r.note).toMatch(/deleted by submitter/);
  });
  it('2. not the latest annotation → manual, superseded note', () => {
    const r = autoReview({ ...base, isLatestAnnotation: false }, REVIEWERS);
    expect(r).toMatchObject({ status: '', auto: false });
    expect(r.note).toMatch(/newer annotation .* takes precedence/);
  });
  it('3. outdated + classification changed → manual, re-curation note', () => {
    const r = autoReview({ ...base, isOutdatedScv: true, classificationChanged: true }, REVIEWERS);
    expect(r.status).toBe('');
    expect(r.note).toMatch(/classification has been updated/);
  });
  it('4. "no change" → auto-OK for anyone', () => {
    const r = autoReview({ ...base, action: 'no change', curator: 'nobody@x.org' }, REVIEWERS);
    expect(r).toMatchObject({ status: 'OK', auto: true });
    expect(r.note).toMatch(/auto reviewed for all curators/);
  });
  it('5. flagging candidate on an already-flagged SCV → manual', () => {
    const r = autoReview({ ...base, action: 'flagging candidate', clinvarReviewStatus: 'flagged submission' }, REVIEWERS);
    expect(r.status).toBe('');
    expect(r.note).toMatch(/already a 'flagged submission'/);
  });
  it('6. remove flagged submission on a NOT-flagged SCV → manual', () => {
    const r = autoReview({ ...base, action: 'remove flagged submission', clinvarReviewStatus: 'criteria provided' }, REVIEWERS);
    expect(r.status).toBe('');
    expect(r.note).toMatch(/NOT a 'flagged submission'/);
  });
  it('remove flagged submission on a flagged SCV → falls through (reviewer/manual), not the #6 note', () => {
    const nonReviewer = autoReview({ ...base, action: 'remove flagged submission', clinvarReviewStatus: 'flagged submission', curator: 'nobody@x.org' }, REVIEWERS);
    expect(nonReviewer).toMatchObject({ status: '' });
    expect(nonReviewer.note).toMatch(/requires manual review/);
  });
  it('7. invalid/missing action → manual, error note', () => {
    expect(autoReview({ ...base, action: 'bogus' }, REVIEWERS).note).toMatch(/Invalid or missing action/);
    expect(autoReview({ ...base, action: '' }, REVIEWERS).note).toMatch(/Invalid or missing action/);
  });
  it('8. outdated (no classification change), non-no-change action → manual, re-curation note', () => {
    const r = autoReview({ ...base, action: 'flagging candidate', isOutdatedScv: true, classificationChanged: false }, REVIEWERS);
    expect(r.status).toBe('');
    expect(r.note).toMatch(/no classification change/);
  });
  it('9. reviewer curator → auto-OK', () => {
    const r = autoReview({ ...base, curator: 'reviewer@x.org' }, REVIEWERS);
    expect(r).toMatchObject({ status: 'OK', auto: true });
    expect(r.note).toMatch(/does not require manual review/);
  });
  it('10. non-reviewer, clean flag → manual', () => {
    const r = autoReview({ ...base, curator: 'nobody@x.org' }, REVIEWERS);
    expect(r).toMatchObject({ status: '', auto: false });
    expect(r.note).toMatch(/requires manual review/);
  });
});

describe('autoReview — precedence + normalization', () => {
  it('deleted takes priority over a would-be auto-OK "no change"', () => {
    expect(autoReview({ ...base, action: 'no change', isDeletedScv: true }, REVIEWERS).status).toBe('Archive');
  });
  it('normalizes action/review-status case + whitespace', () => {
    const r = autoReview({ ...base, action: '  No Change  ' }, REVIEWERS);
    expect(r.status).toBe('OK');
  });
  it('handles a missing reviewers list without throwing', () => {
    expect(() => autoReview({ ...base, curator: 'x@x.org' })).not.toThrow();
  });
});
