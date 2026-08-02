// Prior-annotation history: Firestore runQuery builder, response parser, and
// client-side sort. Pure logic only — no DOM/network/chrome.* wiring here.

var buildHistoryQuery, parseHistoryRows, sortHistoryDesc;

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

  var HISTORY_FIELDS = [
    'variation_id', 'vcv', 'name', 'scv', 'submitter', 'submitter_id',
    'interp', 'review_status', 'action', 'reason', 'notes', 'user_email',
    'created_at'
  ];

  function decode(field) {
    if (!field) return '';
    if (field.stringValue !== undefined) return field.stringValue;
    if (field.timestampValue !== undefined) return field.timestampValue;
    return '';
  }

  parseHistoryRows = function (runQueryResponse) {
    var rows = [];
    (runQueryResponse || []).forEach(function (el) {
      if (!el || !el.document) return;
      var fields = el.document.fields || {};
      var row = {};
      HISTORY_FIELDS.forEach(function (key) {
        row[key] = decode(fields[key]);
      });
      rows.push(row);
    });
    return rows;
  };

  sortHistoryDesc = function (rows) {
    return (rows || []).slice().sort(function (a, b) {
      var aDate = String((a && a.created_at) || '');
      var bDate = String((b && b.created_at) || '');
      if (aDate === bDate) return 0;
      return aDate < bDate ? 1 : -1;
    });
  };
})();

if (typeof window !== 'undefined') {
  window.buildHistoryQuery = buildHistoryQuery;
  window.parseHistoryRows = parseHistoryRows;
  window.sortHistoryDesc = sortHistoryDesc;
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { buildHistoryQuery, parseHistoryRows, sortHistoryDesc };
}
