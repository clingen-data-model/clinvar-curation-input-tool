import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { submissionFilename, buildSubmissionEmail, mailtoUrl } = require('../submission.js');

describe('submissionFilename', () => {
  it('dev builds a v4-/DEV-prefixed name so it can never collide with the live pipeline', () => {
    expect(submissionFilename({ batchId: '145', date: '20260807', env: 'dev' }))
      .toBe('v4-DEV-clinvar-annotation-submission-145-20260807.json');
  });
  it('prod (cutover) uses the legacy name exactly (no prefix)', () => {
    expect(submissionFilename({ batchId: '145', date: '20260807', env: 'prod' }))
      .toBe('clinvar-annotation-submission-145-20260807.json');
  });
});

describe('buildSubmissionEmail (mirrors Generate.js createDraftEmail text)', () => {
  const base = { count: 42, batchId: '145', generatedDatetime: '2026-08-07 09:15:00',
                 recipients: ['a@x.org', 'b@x.org'], cc: ['c@x.org'] };
  it('subject + body match the legacy wording', () => {
    const e = buildSubmissionEmail(base);
    expect(e.subject).toBe("ClinGen's Clinvar annotation submission #145");
    expect(e.body).toContain('next batch of 42 ClinGen ClinVar Annotations');
    expect(e.body).toContain('finalized for submission on 2026-08-07 09:15:00');
    expect(e.to).toEqual(['a@x.org', 'b@x.org']);
    expect(e.cc).toEqual(['c@x.org']);
  });
  it('appends an attach-the-file reminder (mailto cannot attach)', () => {
    const e = buildSubmissionEmail({ ...base, fileName: 'v4-DEV-...-145-20260807.json' });
    expect(e.body).toMatch(/attach .*v4-DEV-.*145-20260807\.json/i);
  });
});

describe('mailtoUrl', () => {
  it('encodes to/cc/subject/body into a mailto: link', () => {
    const url = mailtoUrl({ to: ['a@x.org', 'b@x.org'], cc: ['c@x.org'],
                            subject: 'Subj #145', body: 'line1\nline2 & more' });
    expect(url.startsWith('mailto:a@x.org,b@x.org?')).toBe(true);
    expect(url).toContain('cc=c%40x.org');
    expect(url).toContain('subject=Subj%20%23145');
    expect(url).toContain('body=line1%0Aline2%20%26%20more');
  });
  it('omits cc when none', () => {
    const url = mailtoUrl({ to: ['a@x.org'], cc: [], subject: 'S', body: 'B' });
    expect(url).not.toContain('cc=');
  });
});
