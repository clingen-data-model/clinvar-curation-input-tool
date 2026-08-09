import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildWarningsSql, buildFinalizeSql, buildRefreshSpSql, makeFinalizeHandler } = require('../finalize.js');
const DS = 'clinvar_curator_v4_dev';

describe('buildFinalizeSql', () => {
  const { sql, params } = buildFinalizeSql({ dataset: DS, batchId: '136' });
  it('is one BQ transaction', () => {
    expect(sql.startsWith('BEGIN TRANSACTION;')).toBe(true);
    expect(sql.trimEnd().endsWith('COMMIT TRANSACTION;')).toBe(true);
  });
  it('promotes reviews (OK/Fixed/Archive, NOT-IN idempotent)', () => {
    expect(sql).toContain("rs.review_status IN ('OK','Fixed','Archive')");
    expect(sql).toContain('NOT IN (SELECT annotation_id FROM `clingen-dev.clinvar_curator_v4_dev.cvc_clinvar_reviews`)');
  });
  it('promotes submissions for THIS batch (NOT-IN idempotent, carries scv_id/scv_ver)', () => {
    expect(sql).toContain('INSERT INTO `clingen-dev.clinvar_curator_v4_dev.cvc_clinvar_submissions` (annotation_id, scv_id, scv_ver, batch_id)');
    expect(sql).toContain('WHERE rs.batch_id = @batch');
  });
  it('derives the batches row (6 cols incl submission STRUCT via clinvar_ingest)', () => {
    expect(sql).toContain('(batch_id, finalized_datetime, batch_release_date, batch_start_date, batch_end_date, submission)');
    expect(sql).toContain('`clinvar_ingest.determineMonthBasedOnRange`');
    expect(sql).toContain('`clinvar_ingest.release_on`');
  });
  it('bumps next_batch_id ONLY while it still equals this batch (retry-safe)', () => {
    expect(sql).toContain('SET next_batch_id = CAST(@batchInt + 1 AS STRING)');
    expect(sql).toContain('last_finalized_file = @finalfile'); // records the protected finalized file
    expect(sql).toContain('WHERE next_batch_id = @batch');
    expect(params).toMatchObject({ batch: '136', batchInt: 136 });
  });
  it('rejects a non-numeric batch + is dataset-guarded', () => {
    expect(() => buildFinalizeSql({ dataset: DS, batchId: 'x' })).toThrow(/numeric/);
    expect(() => buildFinalizeSql({ dataset: 'clinvar_curator', batchId: '1' })).toThrow(/not an allowed v4/);
  });
});

describe('buildWarningsSql / buildRefreshSpSql', () => {
  it('warnings counts unreviewed/Question', () => {
    expect(buildWarningsSql({ dataset: DS })).toContain("review_status IS NULL OR review_status = 'Question'");
  });
  it('refresh SP targets the v4 dataset', () => {
    expect(buildRefreshSpSql({ dataset: DS })).toBe('CALL `clingen-dev.clinvar_curator_v4_dev.refresh_cvc_impact_analysis`()');
  });
});

describe('makeFinalizeHandler — orchestration', () => {
  const mk = (genCount) => {
    const log = [];
    return {
      log,
      h: makeFinalizeHandler({
        generate: async ({ batchId }) => { log.push('generate'); return genCount ? { count: genCount, filename: 'f.json', link: 'L', mailto: 'M' } : { count: 0 }; },
        runQuery: async () => { log.push('warnings'); return [{ needs_review: 3, total: 10 }]; },
        runDml: async () => { log.push('promote'); return 7; },
        startSpRefresh: () => { log.push('sp'); return 'JOB1'; },
        config: { dataset: DS }
      })
    };
  };
  it('warns then generates then promotes then kicks the SP (async), in order', async () => {
    const { h, log } = mk(5);
    const out = await h({ batchId: '136', date: '20260807', finalizedDatetime: '2026-08-07 09:00:00' });
    expect(log).toEqual(['warnings', 'generate', 'promote', 'sp']);
    expect(out).toMatchObject({ count: 5, finalized: true, nextBatchId: '137', spRefreshJob: 'JOB1' });
    expect(out.warnings.needsReview).toBe(3);
    expect(out.promotedDmlRows).toBe(7);
  });
  it('empty batch → no promote, no SP, finalized:false (still returns warnings)', async () => {
    const { h, log } = mk(0);
    const out = await h({ batchId: '136', date: '20260807', finalizedDatetime: '2026-08-07 09:00:00' });
    expect(out).toMatchObject({ count: 0, finalized: false });
    expect(log).toEqual(['warnings', 'generate']); // no promote / sp
    expect(out.warnings.needsReview).toBe(3);
  });
});
