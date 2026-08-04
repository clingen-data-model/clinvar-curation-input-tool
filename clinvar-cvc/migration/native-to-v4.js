/**
 * Pure transforms for the one-time history migration:
 * native BigQuery row (clingen-dev.clinvar_curator.clinvar_annotations_native)
 * -> v4 Firestore annotation doc -> Firestore REST `fields` payload.
 *
 * No DOM, no chrome.*, no network. Deliberately ignores the never-implemented
 * override_field/override_value/column_o/retired/retired_date columns.
 */

function nativeRowToV4Doc(row) {
  return {
    variation_id: row.variation_id,
    vcv: row.vcv_id,
    name: row.variation_name,
    scv: row.scv_id,
    submitter: row.submitter_name,
    submitter_id: row.submitter_id,
    interp: row.interpretation,
    review_status: row.review_status,
    action: row.action,
    reason: row.reason,
    notes: row.notes,
    user_email: row.curator_email,
    created_at: row.annotation_date,
    annotation_id: row.annotation_id
  };
}

function toFirestoreFields(doc) {
  const fields = {};
  for (const [key, value] of Object.entries(doc)) {
    if (key === 'created_at') {
      fields[key] = { timestampValue: value };
    } else if (value === null || value === undefined) {
      fields[key] = { nullValue: null };
    } else {
      fields[key] = { stringValue: String(value) };
    }
  }
  return fields;
}

// Splits an array into groups of at most `size` items each, preserving
// order. Shared by migrate.js and wipe-collection.js so both stay under the
// Firestore batchWrite 500-writes-per-request limit.
function chunk(arr, size) {
  const chunks = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { nativeRowToV4Doc, toFirestoreFields, chunk };
}
if (typeof window !== 'undefined') {
  window.nativeRowToV4Doc = nativeRowToV4Doc;
  window.toFirestoreFields = toFirestoreFields;
  window.chunk = chunk;
}
