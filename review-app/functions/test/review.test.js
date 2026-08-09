import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const {
  buildUpsertReviewSql, buildAssignSql, buildUnassignSql,
  buildBulkUpsertReviewSql, buildBulkAssignSql, buildBulkUnassignSql,
  makeReviewHandler, STATUSES
} = require('../review.js');

const DS = 'clinvar_curator_v4_dev';

describe('buildUpsertReviewSql', () => {
  const { sql, params } = buildUpsertReviewSql({
    dataset: DS, annotationId: '1786015663644', scvId: 'SCV000280373', scvVer: 2,
    status: 'OK', notes: "line1\nquote'd", reviewer: 'lbabb@broadinstitute.org'
  });
  it('MERGEs cvc_review_state, upserting status/reviewer + timestamps', () => {
    expect(sql).toContain(`MERGE \`clingen-dev.${DS}.cvc_review_state\` T`);
    expect(sql).toContain('WHEN MATCHED THEN UPDATE SET');
    expect(sql).toContain('WHEN NOT MATCHED THEN INSERT');
    expect(sql).toContain('date_added, date_last_updated');
  });
  it('carries scv_id/scv_ver on INSERT (the SP joins submissions on them)', () => {
    expect(sql).toContain('scv_id, scv_ver');
    expect(params.scvId).toBe('SCV000280373');
    expect(params.scvVer).toBe(2);
  });
  it('parameterizes free-text (no injection) + rejects a bad status', () => {
    expect(params.notes).toBe("line1\nquote'd");           // passed as a param, not inlined
    expect(sql).not.toContain("quote'd");
    expect(() => buildUpsertReviewSql({ dataset: DS, annotationId: '1', status: 'Bogus', reviewer: 'x' }))
      .toThrow(/status must be one of/);
  });
  it('is dataset-guarded (rejects legacy)', () => {
    expect(() => buildUpsertReviewSql({ dataset: 'clinvar_curator', annotationId: '1', status: 'OK', reviewer: 'x' }))
      .toThrow(/not an allowed v4/);
  });
});

describe('buildAssignSql (assignment gate)', () => {
  const { sql, params } = buildAssignSql({ dataset: DS, annotationId: '123', batchId: '136' });
  it('only assigns when reviewed OK, not already assigned, and action is assignable', () => {
    expect(sql).toContain("T.review_status = 'OK'");
    expect(sql).toContain('T.batch_id IS NULL');
    expect(sql).toContain("LOWER(a.action) IN ('flagging candidate','remove flagged submission')");
    expect(params.batch).toBe('136');
  });
  it('rejects a non-numeric batchId', () => {
    expect(() => buildAssignSql({ dataset: DS, annotationId: '1', batchId: '1;DROP' })).toThrow(/numeric/);
  });
});

describe('buildUnassignSql', () => {
  it('clears batch_id only for the given batch', () => {
    const { sql } = buildUnassignSql({ dataset: DS, annotationId: '1', batchId: '136' });
    expect(sql).toContain('SET batch_id = NULL');
    expect(sql).toContain('T.batch_id = @batch');
  });
});

describe('buildBulkUpsertReviewSql', () => {
  const { sql, params, types } = buildBulkUpsertReviewSql({
    dataset: DS, reviewer: 'r@x.org',
    edits: [
      { annotationId: '1', scvId: 'SCV1', scvVer: 2, status: 'OK', notes: "a'b" },
      { annotationId: '2', scvId: 'SCV2', scvVer: null, status: 'Fixed', notes: null }
    ]
  });
  it('MERGEs from an array-of-struct param (one job for all edits)', () => {
    expect(sql).toContain('USING UNNEST(@edits) S');
    expect(sql).toContain(`MERGE \`clingen-dev.${DS}.cvc_review_state\` T`);
    expect(params.edits.length).toBe(2);
    expect(params.edits[0]).toMatchObject({ annotation_id: '1', scv_id: 'SCV1', scv_ver: 2, status: 'OK', notes: "a'b" });
    expect(params.edits[1].scv_ver).toBeNull();
  });
  it('declares explicit struct/array types (so an empty array still types)', () => {
    expect(types.edits[0]).toMatchObject({ annotation_id: 'STRING', scv_ver: 'INT64', notes: 'STRING' });
    expect(types.reviewer).toBe('STRING');
  });
  it('rejects a bad status and guards the dataset', () => {
    expect(() => buildBulkUpsertReviewSql({ dataset: DS, reviewer: 'r', edits: [{ annotationId: '1', status: 'Bogus' }] }))
      .toThrow(/status must be one of/);
    expect(() => buildBulkUpsertReviewSql({ dataset: 'clinvar_curator', reviewer: 'r', edits: [] }))
      .toThrow(/not an allowed v4/);
  });
});

describe('buildBulkAssignSql / buildBulkUnassignSql', () => {
  it('assign uses IN UNNEST(@ids) with the per-row gate, correlated to T', () => {
    const { sql, params, types } = buildBulkAssignSql({ dataset: DS, annotationIds: ['1', '2'], batchId: '136' });
    expect(sql).toContain('T.annotation_id IN UNNEST(@ids)');
    expect(sql).toContain("T.review_status = 'OK'");
    expect(sql).toContain('a.annotation_id = T.annotation_id');
    expect(sql).toContain("LOWER(a.action) IN ('flagging candidate','remove flagged submission')");
    expect(params.ids).toEqual(['1', '2']);
    expect(params.batch).toBe('136');
    expect(types).toEqual({ ids: ['STRING'], batch: 'STRING' });
  });
  it('unassign clears batch_id only for the given batch, over the id set', () => {
    const { sql } = buildBulkUnassignSql({ dataset: DS, annotationIds: ['1'], batchId: '136' });
    expect(sql).toContain('SET batch_id = NULL');
    expect(sql).toContain('T.annotation_id IN UNNEST(@ids) AND T.batch_id = @batch');
  });
  it('rejects a non-numeric batchId', () => {
    expect(() => buildBulkAssignSql({ dataset: DS, annotationIds: ['1'], batchId: '1;DROP' })).toThrow(/numeric/);
  });
});

describe('makeReviewHandler', () => {
  const fake = () => {
    const calls = [];
    const runDml = async (sql, params, types) => { calls.push({ sql, params, types }); return calls._affected ?? 1; };
    return { calls, runDml, setAffected: (n) => { calls._affected = n; } };
  };
  it('setReview runs the upsert and returns applied count', async () => {
    const f = fake();
    const h = makeReviewHandler({ runDml: f.runDml, dataset: DS });
    const out = await h.setReview({ annotationId: '1', scvId: 'SCV1', scvVer: 1, status: 'OK', notes: 'n', reviewer: 'r@x.org' });
    expect(out.applied).toBe(1);
    expect(f.calls[0].sql).toContain('cvc_review_state');
  });
  it('assign reports eligible=false when the gate rejects (0 rows)', async () => {
    const f = fake(); f.setAffected(0);
    const h = makeReviewHandler({ runDml: f.runDml, dataset: DS });
    expect(await h.assign({ annotationId: '1', batchId: '136' })).toEqual({ applied: 0, eligible: false });
  });
  it('assign reports eligible=true when a row is updated', async () => {
    const f = fake(); f.setAffected(1);
    const h = makeReviewHandler({ runDml: f.runDml, dataset: DS });
    expect(await h.assign({ annotationId: '1', batchId: '136' })).toEqual({ applied: 1, eligible: true });
  });

  it('setReviews runs ONE bulk MERGE and passes types through', async () => {
    const f = fake(); f.setAffected(2);
    const h = makeReviewHandler({ runDml: f.runDml, dataset: DS });
    const out = await h.setReviews({ reviewer: 'r@x.org', edits: [
      { annotationId: '1', scvId: 'SCV1', scvVer: 1, status: 'OK', notes: 'n' },
      { annotationId: '2', scvId: 'SCV2', scvVer: 2, status: 'Fixed', notes: '' }
    ] });
    expect(out.applied).toBe(2);
    expect(f.calls.length).toBe(1);                          // single job for the whole selection
    expect(f.calls[0].sql).toContain('UNNEST(@edits)');
    expect(f.calls[0].types.edits[0].annotation_id).toBe('STRING');
  });
  it('setReviews / assignMany / unassignMany are a no-op on empty selection', async () => {
    const f = fake();
    const h = makeReviewHandler({ runDml: f.runDml, dataset: DS });
    expect(await h.setReviews({ reviewer: 'r', edits: [] })).toEqual({ applied: 0 });
    expect(await h.assignMany({ annotationIds: [], batchId: '136' })).toEqual({ applied: 0, requested: 0 });
    expect(await h.unassignMany({ annotationIds: [], batchId: '136' })).toEqual({ applied: 0, requested: 0 });
    expect(f.calls.length).toBe(0);                          // no job issued
  });
  it('assignMany reports applied + requested (applied<requested => some failed the gate)', async () => {
    const f = fake(); f.setAffected(1);
    const h = makeReviewHandler({ runDml: f.runDml, dataset: DS });
    expect(await h.assignMany({ annotationIds: ['1', '2'], batchId: '136' })).toEqual({ applied: 1, requested: 2 });
  });
});
