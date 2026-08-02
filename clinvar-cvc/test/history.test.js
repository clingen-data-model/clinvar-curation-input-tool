const { buildHistoryQuery } = require('../history.js');

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
