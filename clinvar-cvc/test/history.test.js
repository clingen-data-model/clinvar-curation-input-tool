const { buildHistoryQuery, parseHistoryRows, sortHistoryDesc } = require('../history.js');

describe('buildHistoryQuery', () => {
  it('builds a structuredQuery filtering by variation_id with a safety limit and NO orderBy', () => {
    const q = buildHistoryQuery('590935', 'clinvar_cvc_ext_annotations');
    expect(q).toEqual({
      structuredQuery: {
        from: [{ collectionId: 'clinvar_cvc_ext_annotations' }],
        where: {
          fieldFilter: {
            field: { fieldPath: 'variation_id' },
            op: 'EQUAL',
            value: { stringValue: '590935' }
          }
        },
        limit: 500
      }
    });
    // orderBy must be absent so no composite index is required
    expect(q.structuredQuery.orderBy).toBeUndefined();
  });
});

describe('parseHistoryRows', () => {
  const resp = [
    { document: { name: 'projects/p/databases/(default)/documents/c/abc', fields: {
      variation_id: { stringValue: '9' }, vcv: { stringValue: 'VCV000000009.99' },
      name: { stringValue: 'NM_000410.4(HFE):c.845G>A' }, scv: { stringValue: 'SCV000020162.8' },
      submitter: { stringValue: 'OMIM' }, action: { stringValue: 'Flagging Candidate' },
      reason: { stringValue: 'Outlier claim' }, notes: { nullValue: null },
      user_email: { stringValue: 'jratliff@broadinstitute.org' },
      created_at: { timestampValue: '2023-11-14T20:25:27Z' } } }, readTime: '2024-01-01T00:00:00Z' },
    { readTime: '2024-01-01T00:00:00Z' } // bookkeeping element — must be skipped
  ];

  it('maps documents to plain annotation objects and skips non-document elements', () => {
    const rows = parseHistoryRows(resp);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      scv: 'SCV000020162.8', submitter: 'OMIM', action: 'Flagging Candidate',
      reason: 'Outlier claim', user_email: 'jratliff@broadinstitute.org',
      created_at: '2023-11-14T20:25:27Z', name: 'NM_000410.4(HFE):c.845G>A'
    });
  });

  it('decodes nullValue and missing fields to empty string', () => {
    const rows = parseHistoryRows(resp);
    expect(rows[0].notes).toBe('');
  });

  it('returns [] for an empty response', () => {
    expect(parseHistoryRows([])).toEqual([]);
  });
});

it('sorts newest-first by created_at, stable for equal timestamps', () => {
  const rows = [
    { scv: 'a', created_at: '2023-01-01T00:00:00Z' },
    { scv: 'b', created_at: '2024-06-01T00:00:00Z' },
    { scv: 'c', created_at: '2023-12-31T23:59:59Z' }
  ];
  expect(sortHistoryDesc(rows).map(r => r.scv)).toEqual(['b', 'c', 'a']);
});

it('does not mutate the input array', () => {
  const rows = [{ scv: 'a', created_at: '2023-01-01T00:00:00Z' }, { scv: 'b', created_at: '2024-01-01T00:00:00Z' }];
  const copy = rows.slice();
  sortHistoryDesc(rows);
  expect(rows).toEqual(copy);
});
