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
  it('returns config + release freshness (base vs current release)', async () => {
    const runQuery = async () => [{ next_batch_id: '136', reviewers: ['a@x.org'], submission_recipients: ['to@x.org'], submission_cc: [], last_finalized_file: 'f.json', base_release_date: { value: '2026-08-04' }, current_release: { value: '2026-08-04' } }];
    const out = await makeConfigHandler({ runQuery, dataset: 'clinvar_curator_v4_dev' })();
    expect(out).toMatchObject({ nextBatchId: '136', lastFinalizedFile: 'f.json', baseReleaseDate: '2026-08-04', currentRelease: '2026-08-04', releaseStale: false });
  });
  it('flags releaseStale when a newer release than the base exists', async () => {
    const runQuery = async () => [{ next_batch_id: '136', base_release_date: { value: '2026-07-01' }, current_release: { value: '2026-08-04' } }];
    const out = await makeConfigHandler({ runQuery, dataset: 'clinvar_curator_v4_dev' })();
    expect(out.releaseStale).toBe(true);
  });
  it('is stale when base has never been stamped but a release exists', async () => {
    const runQuery = async () => [{ next_batch_id: '136', base_release_date: null, current_release: { value: '2026-08-04' } }];
    expect((await makeConfigHandler({ runQuery, dataset: 'clinvar_curator_v4_dev' })()).releaseStale).toBe(true);
  });
  it('defaults gracefully when config is empty', async () => {
    const out = await makeConfigHandler({ runQuery: async () => [], dataset: 'clinvar_curator_v4_dev' })();
    expect(out).toMatchObject({ nextBatchId: null, reviewers: [], lastFinalizedFile: null, baseReleaseDate: null, currentRelease: null, releaseStale: false });
  });
});
