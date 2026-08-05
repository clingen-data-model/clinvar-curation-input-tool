// highlight.js — pure per-SCV history summary + decoration decision.
// Dual-mode: `window.*` global in the browser page / service worker (`self`),
// `module.exports` under Node/tests.

// SCV accessions are `<base>.<version>` (e.g. SCV000993408.4). CvC annotations
// belong to the SCV across ALL its versions, so history is grouped/matched by
// the version-stripped BASE accession; the version is retained per-record for
// display (an annotation made on v4 still surfaces when the SCV is now v6).
function scvBase(scv) { return String(scv || '').split('.')[0]; }
function scvVersion(scv) { const p = String(scv || '').split('.'); return p.length > 1 ? p[1] : ''; }

function summarizeHistoryByScv(rows) {
  const summary = {};
  (rows || []).forEach(function (row) {
    if (!row || !row.scv) return;
    const scv = scvBase(row.scv);
    if (!summary[scv]) {
      summary[scv] = { count: 0, flagged: false, lastAction: undefined, lastWho: undefined, lastWhen: undefined, _lastCreatedAt: undefined };
    }
    const entry = summary[scv];
    entry.count += 1;
    if (row.action === 'Flagging Candidate' || row.action === 'Remove Flagged Submission') {
      entry.flagged = true;
    }
    if (entry._lastCreatedAt === undefined || (row.created_at || '') > entry._lastCreatedAt) {
      entry._lastCreatedAt = row.created_at || '';
      entry.lastAction = row.action;
      entry.lastWho = row.user_email;
      entry.lastWhen = row.created_at ? row.created_at.slice(0, 10) : undefined;
    }
  });
  Object.keys(summary).forEach(function (scv) {
    delete summary[scv]._lastCreatedAt;
  });
  return summary;
}

function decorateForScv(summary) {
  if (!summary) return null;
  const cssClass = 'cvc-hl ' + (summary.flagged ? 'cvc-hl-flagged' : 'cvc-hl-noted');
  const badge = 'CvC ' + summary.count;
  let tooltip = `${summary.lastAction} — ${summary.lastWho} (${summary.lastWhen})`;
  if (summary.count > 1) {
    tooltip += ` · ${summary.count} annotations`;
  }
  return { cssClass, badge, tooltip };
}

// Display-ready history entries for a single SCV, newest-first — feeds the
// in-page click-to-expand popover. Self-contained (sorts internally) so it
// doesn't depend on history.js being loaded in the content script.
function entriesForScv(rows, scv) {
  const base = scvBase(scv);
  return (rows || [])
    .filter(function (r) { return r && scvBase(r.scv) === base; })
    .slice()
    .sort(function (a, b) {
      const ad = String(a.created_at || '');
      const bd = String(b.created_at || '');
      if (ad === bd) return 0;
      return ad < bd ? 1 : -1;
    })
    .map(function (r) {
      return {
        version: scvVersion(r.scv),
        when: r.created_at ? String(r.created_at).slice(0, 10) : '',
        who: r.user_email || '',
        summary: r.reason ? `${r.action} — ${r.reason}` : (r.action || ''),
        notes: r.notes || ''
      };
    });
}

(function (root) {
  if (root) {
    root.summarizeHistoryByScv = summarizeHistoryByScv;
    root.decorateForScv = decorateForScv;
    root.entriesForScv = entriesForScv;
    root.scvBase = scvBase;
    root.scvVersion = scvVersion;
  }
})(typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : null));
if (typeof module !== 'undefined' && module.exports) { module.exports = { summarizeHistoryByScv, decorateForScv, entriesForScv, scvBase, scvVersion }; }
