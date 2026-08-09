import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildQueueSql, buildRefreshQueueSql, buildInBqSql, splitScv, shapeFreshRow, mergeQueue, makeQueueHandler } = require('../queue.js');
const { assertReadDataset } = require('../dataset-guard.js');

describe('buildQueueSql (reads the materialized base — fast, no TVF)', () => {
  const sql = buildQueueSql({ dataset: 'clinvar_curator_v4_dev' });
  it('reads cvc_review_queue_base (NOT the cvc_annotations TVF)', () => {
    expect(sql).toContain('`clingen-dev.clinvar_curator_v4_dev.cvc_review_queue_base` base');
    expect(sql).not.toContain('cvc_annotations`(');
  });
  it('LEFT JOINs the LIVE in-progress cvc_review_state on annotation_id', () => {
    expect(sql).toMatch(/LEFT JOIN `clingen-dev\.clinvar_curator_v4_dev\.cvc_review_state` rs USING \(annotation_id\)/);
    expect(sql).toContain('rs.review_status AS rs_review_status');
  });
  it('selects latest_scv_classification (drives the auto-review suggestion)', () => {
    expect(sql).toContain('base.latest_scv_classification');
  });
  it('is dataset-tokenized — never references the legacy clinvar_curator dataset', () => {
    expect(/`clingen-dev\.clinvar_curator\./.test(sql)).toBe(false);
  });
  it('rejects a non-v4 dataset (mis-config guard)', () => {
    expect(() => buildQueueSql({ dataset: 'clinvar_curator' })).toThrow(/not an allowed v4 dataset/);
  });
});

describe('buildRefreshQueueSql (batch-side materialization)', () => {
  const sql = buildRefreshQueueSql({ dataset: 'clinvar_curator_v4_dev' });
  it('CREATE OR REPLACEs the base table from cvc_annotations("unreviewed")', () => {
    expect(sql).toContain('CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator_v4_dev.cvc_review_queue_base`');
    expect(sql).toContain('`clingen-dev.clinvar_curator_v4_dev.cvc_annotations`("unreviewed")');
  });
  it('is WRITE-guarded (refuses the legacy dataset as a create target)', () => {
    expect(() => buildRefreshQueueSql({ dataset: 'clinvar_curator' })).toThrow();
  });
});

describe('makeQueueHandler', () => {
  it('runs the queue SQL and returns { rows }', async () => {
    const seen = {};
    const runQuery = async (sql) => { seen.sql = sql; return [{ annotation_id: '1' }, { annotation_id: '2' }]; };
    const handler = makeQueueHandler({ runQuery, dataset: 'clinvar_curator_v4_dev' });
    const out = await handler();
    expect(out.rows).toHaveLength(2);
    expect(seen.sql).toBe(buildQueueSql({ dataset: 'clinvar_curator_v4_dev' }));
  });
  it('normalizes a null result to an empty array', async () => {
    const handler = makeQueueHandler({ runQuery: async () => null, dataset: 'clinvar_curator_v4' });
    expect((await handler()).rows).toEqual([]);
  });
  it('attaches an auto-review suggestion to each row (autoReview wired in)', async () => {
    const rows = [
      { annotation_id: '1', action: 'no change', is_latest_annotation: true, curator: 'x@x.org' },
      { annotation_id: '2', action: 'flagging candidate', is_latest_annotation: true, is_deleted_scv: true, curator: 'x@x.org' }
    ];
    const handler = makeQueueHandler({
      runQuery: async () => rows, dataset: 'clinvar_curator_v4_dev', getReviewers: async () => []
    });
    const out = await handler();
    expect(out.rows[0].auto_status).toBe('OK');       // "no change" → auto-OK
    expect(out.rows[1].auto_status).toBe('Archive');  // deleted SCV → Archive
    expect(out.rows[1].auto_note).toMatch(/deleted/);
  });
});

describe('freshness: buildInBqSql / splitScv / shapeFreshRow / mergeQueue', () => {
  it('buildInBqSql checks candidate ids against native_v4, parameterized + guarded', () => {
    const { sql, params } = buildInBqSql({ dataset: 'clinvar_curator_v4_dev', ids: ['1', 2] });
    expect(sql).toContain('`clingen-dev.clinvar_curator_v4_dev.cvc_annotations_native_v4`');
    expect(sql).toContain('annotation_id IN UNNEST(@ids)');
    expect(params.ids).toEqual(['1', '2']); // stringified
    expect(() => buildInBqSql({ dataset: 'clinvar_curator', ids: [] })).toThrow(/not an allowed v4/);
  });
  it('splitScv splits the full accession on the last dot', () => {
    expect(splitScv('SCV000993408.4')).toEqual({ scv_id: 'SCV000993408', scv_ver: '4' });
    expect(splitScv('SCV1')).toEqual({ scv_id: 'SCV1', scv_ver: '' });
  });
  it('shapeFreshRow maps a Firestore doc to a null-flag, fresh queue row (action lowercased)', () => {
    const r = shapeFreshRow({ annotation_id: '9', variation_id: '9', vcv: 'VCV9', scv: 'SCV9.2',
      submitter: 'Lab', action: 'Flagging Candidate', reason: 'x', notes: 'n', user_email: 'c@x.org',
      review_status: 'criteria provided', created_at: '2026-08-08T00:00:00Z' });
    expect(r).toMatchObject({ annotation_id: '9', vcv_id: 'VCV9', scv_id: 'SCV9', scv_ver: '2',
      submitter_name: 'Lab', action: 'flagging candidate', curator: 'c@x.org',
      clinvar_review_status: 'criteria provided', is_outdated_scv: null, auto_status: '', fresh: true });
    expect(r.rs_review_status).toBeNull();
  });
  it('shapeFreshRow surfaces a SAVED review state so the overlay is not shown as unsaved', () => {
    const r = shapeFreshRow({ annotation_id: '9', scv: 'SCV9.2', action: 'Flagging Candidate' },
      { review_status: 'OK', reviewer: 'c@x.org', notes: 'looks good', batch_id: null });
    expect(r.rs_review_status).toBe('OK');
    expect(r.rs_reviewer).toBe('c@x.org');
  });
  it('mergeQueue appends only fresh candidates not in BQ and not already listed', () => {
    const bq = [{ annotation_id: 'A' }, { annotation_id: 'B' }];
    const candidates = [
      { annotation_id: 'A', scv: 'SCVa.1' }, // already in BQ result → skip
      { annotation_id: 'C', scv: 'SCVc.1' }, // in native_v4 (inBq) → skip (enrichment pending in BQ set)
      { annotation_id: 'D', scv: 'SCVd.1' }  // truly fresh → include
    ];
    const merged = mergeQueue(bq, candidates, new Set(['C']));
    expect(merged.map((r) => r.annotation_id)).toEqual(['A', 'B', 'D']);
    expect(merged.find((r) => r.annotation_id === 'D').fresh).toBe(true);
  });
});

describe('makeQueueHandler with Firestore freshness', () => {
  const dataset = 'clinvar_curator_v4_dev';
  const bqSql = buildQueueSql({ dataset });
  it('merges a fresh Firestore capture (not yet in BQ) into the BQ queue', async () => {
    const runQuery = async (sql) => {
      if (sql === bqSql) return [{ annotation_id: 'A', action: 'no change', is_latest_annotation: true }];
      return []; // buildInBqSql: none of the candidates are in native_v4 yet
    };
    const getRecentCaptures = async () => [{ annotation_id: 'NEW', scv: 'SCV5.1', action: 'flagging candidate' }];
    const out = await makeQueueHandler({ runQuery, dataset, getReviewers: async () => [], getRecentCaptures })();
    expect(out.rows.map((r) => r.annotation_id)).toEqual(['A', 'NEW']);
    const fresh = out.rows.find((r) => r.annotation_id === 'NEW');
    expect(fresh).toMatchObject({ fresh: true, auto_status: '' });
  });
  it('does NOT double-show a capture already present in BQ (native_v4)', async () => {
    const runQuery = async (sql, params) => {
      if (sql === bqSql) return [{ annotation_id: 'A', action: 'no change', is_latest_annotation: true }];
      return [{ annotation_id: 'KNOWN' }]; // buildInBqSql says KNOWN is already in native_v4
    };
    const getRecentCaptures = async () => [{ annotation_id: 'KNOWN', scv: 'SCV1.1' }];
    const out = await makeQueueHandler({ runQuery, dataset, getReviewers: async () => [], getRecentCaptures })();
    expect(out.rows.map((r) => r.annotation_id)).toEqual(['A']); // KNOWN not appended as fresh
  });
  it('a fresh row surfaces its SAVED review state (not shown as unsaved)', async () => {
    const runQuery = async (sql) => {
      if (sql === bqSql) return [];
      if (sql.includes('cvc_annotations_native_v4')) return []; // not yet in BQ
      if (sql.includes('cvc_review_state')) return [{ annotation_id: 'NEW', review_status: 'OK', reviewer: 'c@x.org', notes: 'ok', batch_id: null }];
      return [];
    };
    const getRecentCaptures = async () => [{ annotation_id: 'NEW', scv: 'SCV9.1', action: 'Flagging Candidate' }];
    const out = await makeQueueHandler({ runQuery, dataset, getReviewers: async () => [], getRecentCaptures })();
    const fresh = out.rows.find((r) => r.annotation_id === 'NEW');
    expect(fresh).toMatchObject({ fresh: true, rs_review_status: 'OK', action: 'flagging candidate' });
  });
  it('without getRecentCaptures, behaves exactly as the BQ-only queue', async () => {
    const handler = makeQueueHandler({ runQuery: async () => [{ annotation_id: 'A' }], dataset, getReviewers: async () => [] });
    expect((await handler()).rows.map((r) => r.annotation_id)).toEqual(['A']);
  });
});

describe('dataset-guard.assertReadDataset', () => {
  it('allows v4 datasets, rejects legacy + unknown', () => {
    expect(assertReadDataset('clinvar_curator_v4')).toBe('clinvar_curator_v4');
    expect(() => assertReadDataset('clinvar_curator')).toThrow();
    expect(() => assertReadDataset('nope')).toThrow();
  });
});
