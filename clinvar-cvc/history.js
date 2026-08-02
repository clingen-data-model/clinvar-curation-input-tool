// Prior-annotation history: Firestore runQuery builder, response parser, and
// client-side sort. Pure logic only — no DOM/network/chrome.* wiring here.

var buildHistoryQuery;

(function () {
  buildHistoryQuery = function (variationId, collection) {
    return {
      structuredQuery: {
        from: [{ collectionId: collection }],
        where: {
          fieldFilter: {
            field: { fieldPath: 'variation_id' },
            op: 'EQUAL',
            value: { stringValue: String(variationId) }
          }
        },
        limit: 500
      }
    };
  };
})();

if (typeof window !== 'undefined') {
  window.buildHistoryQuery = buildHistoryQuery;
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { buildHistoryQuery };
}
