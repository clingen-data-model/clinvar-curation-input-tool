import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildReflagCandidatesSql, buildReflagDoc, reflagDocId, makeReflagHandler, ACTION } = require('../reflag.js');

const DS = 'clinvar_curator_v4_dev';

describe('buildReflagCandidatesSql', () => {
  it('reads the broad resubmission set, badges autoreflag, joins current review_status', () => {
    const { sql, params } = buildReflagCandidatesSql({ dataset: DS });
    expect(sql).toContain(`\`clingen-dev.${DS}.cvc_resubmission_candidates\` r`);
    expect(sql).toContain(`FROM \`clingen-dev.${DS}.cvc_autoreflag_candidates\` WHERE is_autoreflag_candidate`);
    expect(sql).toContain('(a.scv_id IS NOT NULL) AS is_autoreflag');
    expect(sql).toContain('cs.review_status AS current_review_status');
    expect(sql).toContain('oa.curator_email AS orig_curator, oa.annotation_date AS orig_annotated_date');
    expect(sql).toContain('LEFT JOIN `clingen-dev.clinvar_curator_v4_dev.cvc_annotations_native_v4` oa ON oa.annotation_id = r.annotation_id');
    expect(params).toEqual({});
  });
  it('EXCLUDES candidates that already have a current-version annotation', () => {
    const { sql } = buildReflagCandidatesSql({ dataset: DS });
    expect(sql).toContain(`NOT EXISTS (SELECT 1 FROM \`clingen-dev.${DS}.cvc_annotations_native_v4\` n WHERE n.scv_id = r.scv_id || '.' || CAST(r.current_scv_ver AS STRING))`);
    expect(sql).not.toContain('already_reflagged');
  });
  it('keeps exactly ONE row per scv_id — the latest submission (dedup via QUALIFY)', () => {
    const { sql } = buildReflagCandidatesSql({ dataset: DS });
    expect(sql).toContain('QUALIFY ROW_NUMBER() OVER (PARTITION BY r.scv_id ORDER BY r.batch_accepted_date DESC, r.submitted_scv_ver DESC) = 1');
  });
  it('restricts to selected scvIds for the write path (parameterized), still excluding annotated', () => {
    const { sql, params } = buildReflagCandidatesSql({ dataset: DS, scvIds: ['SCV1', 'SCV2'] });
    expect(sql).toContain('NOT EXISTS');
    expect(sql).toContain('r.scv_id IN UNNEST(@scvIds)');
    expect(params).toEqual({ scvIds: ['SCV1', 'SCV2'] });
  });
  it('is dataset-guarded (rejects legacy)', () => {
    expect(() => buildReflagCandidatesSql({ dataset: 'clinvar_curator' })).toThrow(/not an allowed v4/);
  });
});

describe('buildReflagDoc', () => {
  const cand = {
    scv_id: 'SCV000245527', variation_id: '209185', vcv_id: 'VCV000209185',
    submitter_id: '1006', submitter_name: 'Baylor Genetics', orig_batch_id: '102',
    flagging_reason: 'New submission that appears to update an older one',
    current_scv_ver: 2, current_vcv_ver: 5, current_classification: 'Likely pathogenic',
    current_review_status: 'criteria provided, single submitter'
  };
  const now = new Date('2026-08-09T12:00:00Z');
  const doc = buildReflagDoc(cand, 'lbabb@broadinstitute.org', now);
  it('brings the SCV up to date (current version/classification/review status)', () => {
    expect(doc.scv).toBe('SCV000245527.2');
    expect(doc.vcv).toBe('VCV000209185.5');
    expect(doc.interp).toBe('Likely pathogenic');
    expect(doc.review_status).toBe('criteria provided, single submitter');
    expect(doc.action).toBe(ACTION);            // 'Flagging Candidate'
    expect(doc.reason).toBe(cand.flagging_reason);
    expect(doc.user_email).toBe('lbabb@broadinstitute.org');
    expect(doc.annotation_id).toBe(String(now.getTime()));
  });
  it('stamps reflag provenance in notes', () => {
    expect(doc.notes).toContain('Reflag of SCV000245527');
    expect(doc.notes).toContain('orig batch 102');
    expect(doc.notes).toContain('without substantive change');
  });
  it('unwraps BQ {value} wrappers on version fields', () => {
    const d = buildReflagDoc({ ...cand, current_scv_ver: { value: 3 }, current_vcv_ver: { value: 7 } }, 'r@x.org', now);
    expect(d.scv).toBe('SCV000245527.3');
    expect(d.vcv).toBe('VCV000209185.7');
  });
});

describe('reflagDocId', () => {
  it('is a stable 64-hex SHA-256 that ignores created_at/annotation_id (dedup)', async () => {
    const base = { variation_id: '1', vcv: 'VCV1.2', scv: 'SCV1.2', submitter: 'S', submitter_id: '9',
      interp: 'LP', review_status: 'rs', action: 'Flagging Candidate', reason: 'r', notes: 'n', user_email: 'e' };
    const a = await reflagDocId({ ...base, created_at: new Date('2020-01-01'), annotation_id: '111' });
    const b = await reflagDocId({ ...base, created_at: new Date('2026-01-01'), annotation_id: '999' });
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    expect(a).toBe(b);                          // created_at/annotation_id excluded
    const c = await reflagDocId({ ...base, reason: 'DIFFERENT' });
    expect(c).not.toBe(a);                      // a dedup field differs → different id
  });
});

describe('makeReflagHandler.reflag', () => {
  const cand = {
    scv_id: 'SCV1', variation_id: '1', vcv_id: 'VCV1', submitter_id: '9', submitter_name: 'Lab',
    orig_batch_id: '100', flagging_reason: 'reason', current_scv_ver: 2, current_vcv_ver: 3,
    current_classification: 'Pathogenic', current_review_status: 'rs'
  };
  const now = () => new Date('2026-08-09T12:00:00Z');

  it('re-fetches selected candidates, builds + creates capture docs, reports results', async () => {
    const writes = [];
    const h = makeReflagHandler({
      dataset: DS, now,
      runQuery: async () => [cand],
      createCaptureDoc: async (id, doc) => { writes.push({ id, scv: doc.scv, action: doc.action }); }
    });
    const out = await h.reflag({ scvIds: ['SCV1'], userEmail: 'r@x.org' });
    expect(out.created).toBe(1);
    expect(writes[0].scv).toBe('SCV1.2');
    expect(writes[0].action).toBe('Flagging Candidate');
    expect(writes[0].id).toMatch(/^[0-9a-f]{64}$/);        // content-hash doc id
  });
  it('counts an ALREADY_EXISTS create as skipped (already reflagged)', async () => {
    const h = makeReflagHandler({
      dataset: DS, now,
      runQuery: async () => [cand],
      createCaptureDoc: async () => { throw new Error('6 ALREADY_EXISTS: entity already exists'); }
    });
    const out = await h.reflag({ scvIds: ['SCV1'], userEmail: 'r@x.org' });
    expect(out).toMatchObject({ created: 0, skipped: 1 });
    expect(out.results[0].status).toBe('already-reflagged');
  });
  it('empty selection is a no-op (no query, no writes)', async () => {
    let queried = false;
    const h = makeReflagHandler({ dataset: DS, now, runQuery: async () => { queried = true; return []; }, createCaptureDoc: async () => {} });
    expect(await h.reflag({ scvIds: [], userEmail: 'r@x.org' })).toEqual({ created: 0, skipped: 0, results: [] });
    expect(queried).toBe(false);
  });
});
