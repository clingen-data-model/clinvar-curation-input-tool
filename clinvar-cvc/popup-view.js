/**
 * Pure view-helpers for the rich popup: formatting an SCV row into a picker
 * option label, and turning vocab.js's grouped reason object into an
 * ordered array of {label, options} groups the DOM layer can render as
 * <optgroup> (or flat options, for the '' label group).
 *
 * Pure module: no DOM, no chrome.*. Dual-mode (window.* + module.exports),
 * matching vocab.js / annotation.js.
 */

function truncate(str, num) {
  if (str.length <= num) {
    return str;
  }
  return str.slice(0, num) + '...';
}

function scvOptionLabel(row) {
  return `${row.scv} (${row.interp}) ${truncate(row.submitter, 15)}`;
}

function reasonOptionGroups(action) {
  const reasonsForAction =
    (typeof window !== 'undefined' && window.reasonsForAction) ||
    require('./vocab.js').reasonsForAction;
  const grouped = reasonsForAction(action);
  return Object.entries(grouped).map(([label, options]) => ({ label, options }));
}

function isScrapeable(d) {
  return !!(d && d.vcv && Array.isArray(d.row) && d.row.length > 0);
}

function historyView(rows, currentScv) {
  return rows.map((row) => ({
    when: (row.created_at || '').slice(0, 10),
    who: row.user_email,
    scv: row.scv,
    summary: row.reason ? `${row.action} — ${row.reason}` : row.action,
    notes: row.notes,
    isCurrent: !!currentScv && row.scv === currentScv
  }));
}

if (typeof window !== 'undefined') {
  window.scvOptionLabel = scvOptionLabel;
  window.reasonOptionGroups = reasonOptionGroups;
  window.isScrapeable = isScrapeable;
  window.historyView = historyView;
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { scvOptionLabel, reasonOptionGroups, isScrapeable, historyView };
}
