import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildAnnotation, validateAnnotation } = require('../annotation.js');

const vcv = { vcv: 'VCV000590935.4', variation_id: '590935' };
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
