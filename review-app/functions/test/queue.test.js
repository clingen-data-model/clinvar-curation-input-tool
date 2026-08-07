import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildQueueSql, makeQueueHandler } = require('../queue.js');
const { assertReadDataset } = require('../dataset-guard.js');

describe('buildQueueSql', () => {
  const sql = buildQueueSql({ dataset: 'clinvar_curator_v4_dev' });
  it('queries cvc_annotations over the "unreviewed" scope', () => {
    expect(sql).toContain('`clingen-dev.clinvar_curator_v4_dev.cvc_annotations`("unreviewed")');
  });
  it('LEFT JOINs the app in-progress cvc_review_state on annotation_id', () => {
    expect(sql).toMatch(/LEFT JOIN `clingen-dev\.clinvar_curator_v4_dev\.cvc_review_state` rs USING \(annotation_id\)/);
    expect(sql).toContain('rs.review_status AS rs_review_status');
  });
  it('is dataset-tokenized — never references the legacy clinvar_curator dataset', () => {
    expect(/`clingen-dev\.clinvar_curator\./.test(sql)).toBe(false);
  });
  it('rejects a non-v4 dataset (mis-config guard)', () => {
    expect(() => buildQueueSql({ dataset: 'clinvar_curator' })).toThrow(/not an allowed v4 dataset/);
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
});

describe('dataset-guard.assertReadDataset', () => {
  it('allows v4 datasets, rejects legacy + unknown', () => {
    expect(assertReadDataset('clinvar_curator_v4')).toBe('clinvar_curator_v4');
    expect(() => assertReadDataset('clinvar_curator')).toThrow();
    expect(() => assertReadDataset('nope')).toThrow();
  });
});
