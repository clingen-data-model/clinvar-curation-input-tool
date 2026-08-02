import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { nativeRowToV4Doc, toFirestoreFields } = require('../migration/native-to-v4.js');
const { buildAnnotation, annotationDocId } = require('../annotation.js');

const nativeRow = {
  variation_id: '590935',
  vcv_id: 'VCV000590935.4',
  variation_name: 'NM_000.1(GENE):c.1A>T',
  scv_id: 'SCV005831843.1',
  submitter_name: 'Labcorp',
  submitter_id: '500123',
  interpretation: 'Uncertain significance',
  review_status: 'criteria provided, single submitter',
  action: 'No Change',
  reason: '',
  notes: 'reviewed, looks fine',
  curator_email: 'jane@x.com',
  annotation_date: '2019-05-01T12:00:00Z',
  // override-ish columns that must be ignored entirely
  override_field: 'something',
  override_value: 'else',
  column_o: 'noise',
  retired: true,
  retired_date: '2020-01-01T00:00:00Z'
};

describe('nativeRowToV4Doc', () => {
  it('maps every native column to the correct v4 field', () => {
    const doc = nativeRowToV4Doc(nativeRow);
    expect(doc).toEqual({
      variation_id: '590935',
      vcv: 'VCV000590935.4',
      name: 'NM_000.1(GENE):c.1A>T',
      scv: 'SCV005831843.1',
      submitter: 'Labcorp',
      submitter_id: '500123',
      interp: 'Uncertain significance',
      review_status: 'criteria provided, single submitter',
      action: 'No Change',
      reason: '',
      notes: 'reviewed, looks fine',
      user_email: 'jane@x.com',
      created_at: '2019-05-01T12:00:00Z'
    });
    // override fields must not leak into the v4 doc
    expect(doc.override_field).toBeUndefined();
    expect(doc.override_value).toBeUndefined();
    expect(doc.column_o).toBeUndefined();
    expect(doc.retired).toBeUndefined();
    expect(doc.retired_date).toBeUndefined();
  });

  it('produces a doc id identical to a live buildAnnotation doc for the same annotation (KEY GUARANTEE)', async () => {
    const migrated = nativeRowToV4Doc(nativeRow);

    const vcv = { vcv: 'VCV000590935.4', variation_id: '590935', name: 'NM_000.1(GENE):c.1A>T' };
    const scvRow = {
      scv: 'SCV005831843.1',
      submitter: 'Labcorp',
      submitter_id: '500123',
      interp: 'Uncertain significance',
      review: 'criteria provided, single submitter'
    };
    const input = { action: 'No Change', reason: '', notes: 'reviewed, looks fine' };
    const live = buildAnnotation(scvRow, vcv, input, 'jane@x.com');

    const migratedId = await annotationDocId(migrated);
    const liveId = await annotationDocId(live);
    expect(migratedId).toBe(liveId);
  });

  it('maps a null notes to notes: null, and annotationDocId treats it the same as an empty string', async () => {
    const rowWithNullNotes = { ...nativeRow, notes: null };
    const doc = nativeRowToV4Doc(rowWithNullNotes);
    expect(doc.notes).toBeNull();

    const docWithEmptyNotes = nativeRowToV4Doc({ ...nativeRow, notes: '' });

    const idNull = await annotationDocId(doc);
    const idEmpty = await annotationDocId(docWithEmptyNotes);
    expect(idNull).toBe(idEmpty);
  });
});

describe('toFirestoreFields', () => {
  it('maps created_at to a timestampValue', () => {
    const fields = toFirestoreFields({ created_at: '2019-05-01T12:00:00Z' });
    expect(fields.created_at).toEqual({ timestampValue: '2019-05-01T12:00:00Z' });
  });

  it('maps a plain string field to a stringValue', () => {
    const fields = toFirestoreFields({ vcv: 'VCV000590935.4' });
    expect(fields.vcv).toEqual({ stringValue: 'VCV000590935.4' });
  });

  it('maps a null field to a nullValue', () => {
    const fields = toFirestoreFields({ notes: null });
    expect(fields.notes).toEqual({ nullValue: null });
  });

  it('maps an empty string to a stringValue of empty string (not null)', () => {
    const fields = toFirestoreFields({ reason: '' });
    expect(fields.reason).toEqual({ stringValue: '' });
  });
});
