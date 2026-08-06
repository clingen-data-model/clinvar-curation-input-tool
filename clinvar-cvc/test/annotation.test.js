import { describe, it, test, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildAnnotation, validateAnnotation, annotationDocId } = require('../annotation.js');

const vcv = { vcv: 'VCV000590935.4', variation_id: '590935', name: 'NM_000.1(GENE):c.1A>T' };
const scvRow = { scv: 'SCV005831843.1', submitter: 'Labcorp', submitter_id: '500123',
                 interp: 'Uncertain significance', review: 'criteria provided, single submitter' };

describe('annotation', () => {
  it('builds the v4 doc with all fields', () => {
    const a = buildAnnotation(scvRow, vcv, { action: 'No Change', reason: '', notes: 'ok' }, 'jane@x.com');
    expect(a).toMatchObject({
      variation_id: '590935', vcv: 'VCV000590935.4', scv: 'SCV005831843.1',
      submitter: 'Labcorp', submitter_id: '500123', interp: 'Uncertain significance',
      review_status: 'criteria provided, single submitter', action: 'No Change',
      reason: '', notes: 'ok', user_email: 'jane@x.com'
    });
    expect(a.name).toBe('NM_000.1(GENE):c.1A>T');
    expect(a.created_at).toBeInstanceOf(Date);
  });
  it('requires an action', () => {
    expect(validateAnnotation({ scv: 'SCV1', action: '' })).toMatch(/action is required/i);
  });
  it('requires a reason unless No Change', () => {
    expect(validateAnnotation({ scv: 'SCV1', action: 'Flagging Candidate', reason: '' }))
      .toMatch(/reason is required/i);
    expect(validateAnnotation({ scv: 'SCV1', action: 'No Change', reason: '' })).toBeNull();
  });
  it('requires an SCV', () => {
    expect(validateAnnotation({ scv: '', action: 'No Change' })).toMatch(/scv.*required/i);
  });
});

const dedupBase = { variation_id:'590935', vcv:'VCV1', scv:'SCV1.1', submitter:'Lab',
  submitter_id:'5', interp:'Uncertain significance', review_status:'x',
  action:'No Change', reason:'', notes:'ok', user_email:'a@x.com',
  created_at: new Date('2020-01-01') };
describe('annotationDocId', () => {
  it('is stable + ignores created_at', async () => {
    const a = await annotationDocId(dedupBase);
    const b = await annotationDocId({ ...dedupBase, created_at: new Date('2099-01-01') });
    expect(a).toBe(b);
    expect(a).toMatch(/^[0-9a-f]{64}$/);
  });
  it('differs when any entry field differs', async () => {
    const a = await annotationDocId(dedupBase);
    expect(await annotationDocId({ ...dedupBase, notes: 'ok ' })).not.toBe(a);
    expect(await annotationDocId({ ...dedupBase, user_email: 'b@x.com' })).not.toBe(a);
    expect(await annotationDocId({ ...dedupBase, action: 'Flagging Candidate' })).not.toBe(a);
  });
  it('avoids field-boundary collisions (canonicalization is unambiguous)', async () => {
    const x = await annotationDocId({ ...dedupBase, reason: 'a', notes: 'b' });
    const y = await annotationDocId({ ...dedupBase, reason: 'a b', notes: '' });
    expect(x).not.toBe(y);
  });
  it('name does not affect the doc id (not part of dedup)', async () => {
    const a = await annotationDocId({ ...dedupBase, name: 'foo' });
    const b = await annotationDocId({ ...dedupBase, name: 'bar' });
    expect(a).toBe(b);
  });
});

test('buildAnnotation stores annotation_id = UNIX_MILLIS(created_at) as a string', () => {
  const scv = { scv: 'SCV1', submitter: 'S', submitter_id: '9', interp: 'Pathogenic', review: 'criteria' };
  const vcv = { variation_id: '1', vcv: 'VCV1', name: 'X' };
  const a = buildAnnotation(scv, vcv, { action: 'Flagging Candidate', reason: 'r', notes: 'n' }, 'a@b.org');
  expect(a.annotation_id).toBe(String(a.created_at.getTime()));
  expect(typeof a.annotation_id).toBe('string');
});

test('annotation_id does NOT affect the dedup doc id (excluded from DEDUP_FIELDS)', async () => {
  const scv = { scv: 'SCV1', submitter: 'S', submitter_id: '9', interp: 'Pathogenic', review: 'criteria' };
  const vcv = { variation_id: '1', vcv: 'VCV1', name: 'X' };
  const a = buildAnnotation(scv, vcv, { action: 'No Change', reason: '', notes: '' }, 'a@b.org');
  const b = { ...a, annotation_id: 'different', created_at: new Date(0) };
  expect(await annotationDocId(a)).toBe(await annotationDocId(b));
});
