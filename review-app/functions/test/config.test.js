import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildConfigSql, makeConfigHandler } = require('../config.js');

describe('buildConfigSql', () => {
  it('reads the single cvc_review_config row from the v4 dataset', () => {
    const sql = buildConfigSql({ dataset: 'clinvar_curator_v4_dev' });
    expect(sql).toContain('`clingen-dev.clinvar_curator_v4_dev.cvc_review_config`');
    expect(sql).toContain('next_batch_id');
  });
  it('is dataset-guarded', () => {
    expect(() => buildConfigSql({ dataset: 'clinvar_curator' })).toThrow(/not an allowed v4/);
  });
});

describe('makeConfigHandler', () => {
  it('returns nextBatchId + reviewers + recipients + lastFinalizedFile', async () => {
    const runQuery = async () => [{ next_batch_id: '136', reviewers: ['a@x.org'], submission_recipients: ['to@x.org'], submission_cc: [], last_finalized_file: 'v4-DEV-clinvar-annotation-submission-135-20260807.json' }];
    const out = await makeConfigHandler({ runQuery, dataset: 'clinvar_curator_v4_dev' })();
    expect(out).toEqual({ nextBatchId: '136', reviewers: ['a@x.org'], submissionRecipients: ['to@x.org'], submissionCc: [], lastFinalizedFile: 'v4-DEV-clinvar-annotation-submission-135-20260807.json' });
  });
  it('defaults gracefully when config is empty', async () => {
    const out = await makeConfigHandler({ runQuery: async () => [], dataset: 'clinvar_curator_v4_dev' })();
    expect(out).toEqual({ nextBatchId: null, reviewers: [], submissionRecipients: [], submissionCc: [], lastFinalizedFile: null });
  });
});
