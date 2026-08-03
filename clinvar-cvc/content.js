// Content script: on an initializePopup message, scrape the current ClinVar page.
// scrape.js is loaded FIRST in the manifest content_scripts, exposing the
// window.extractClinVarData global; under Node/tests we require it instead.

function handleInitializePopup(message, doc) {
  if (message && message.from === 'popup' && message.subject === 'initializePopup') {
    const extract = (typeof window !== 'undefined' && window.extractClinVarData) ||
                    require('./scrape.js').extractClinVarData;
    return extract(doc);
  }
  return null;
}

// The variation's prior-annotation rows most recently fetched by the service
// worker, kept so the click-to-expand popover can list an SCV's full history
// without another round-trip.
let lastHistoryRows = [];

// Removes the in-page history popover if one is open.
function closeScvPopover(doc) {
  const existing = doc.getElementById('cvc-hl-popover');
  if (existing) existing.remove();
}

// Opens an in-page popover, anchored under the clicked badge, listing every
// prior annotation for `scv` (date · curator · action/reason · notes). Built
// with textContent only (curator-entered text) — never innerHTML.
function showScvPopover(doc, anchorEl, scv) {
  closeScvPopover(doc);
  const entriesForScvFn = (typeof self !== 'undefined' && self.entriesForScv) ||
    require('./highlight.js').entriesForScv;
  const entries = entriesForScvFn(lastHistoryRows, scv);

  const pop = doc.createElement('div');
  pop.id = 'cvc-hl-popover';
  pop.className = 'cvc-hl-popover';

  const title = doc.createElement('div');
  title.className = 'cvc-hl-popover-title';
  title.textContent = `${scv} — ${entries.length} annotation${entries.length === 1 ? '' : 's'}`;
  pop.appendChild(title);

  if (!entries.length) {
    const empty = doc.createElement('div');
    empty.className = 'cvc-hl-popover-empty';
    empty.textContent = 'No prior annotations.';
    pop.appendChild(empty);
  } else {
    entries.forEach((e) => {
      const entry = doc.createElement('div');
      entry.className = 'cvc-hl-popover-entry';
      const meta = doc.createElement('div');
      meta.className = 'cvc-hl-popover-meta';
      meta.textContent = `${e.when} · ${e.who}`;
      const summary = doc.createElement('div');
      summary.className = 'cvc-hl-popover-summary';
      summary.textContent = e.summary;
      entry.appendChild(meta);
      entry.appendChild(summary);
      if (e.notes) {
        const notes = doc.createElement('div');
        notes.className = 'cvc-hl-popover-notes';
        notes.textContent = e.notes;
        entry.appendChild(notes);
      }
      pop.appendChild(entry);
    });
  }

  const view = doc.defaultView || (typeof window !== 'undefined' ? window : null);
  const rect = anchorEl.getBoundingClientRect();
  const scrollX = view ? view.scrollX : 0;
  const scrollY = view ? view.scrollY : 0;
  pop.style.position = 'absolute';
  pop.style.top = (rect.bottom + scrollY + 4) + 'px';
  pop.style.left = (rect.left + scrollX) + 'px';
  doc.body.appendChild(pop);

  // Close on any outside click. The opening click is stopPropagation'd on the
  // badge, so it won't reach this listener and immediately close the popover.
  const onDocClick = (ev) => {
    if (!pop.contains(ev.target)) {
      closeScvPopover(doc);
      doc.removeEventListener('click', onDocClick);
    }
  };
  doc.addEventListener('click', onDocClick);
}

// Decorates SCV submission rows that already have prior CvC annotations with
// a row tint + small badge + hover tooltip (see highlight.js for the pure
// summarize/decorate logic). Best-effort and idempotent: any prior
// decoration from an earlier run is stripped before reapplying, so repeated
// calls (SPA re-renders, reloads) never stack badges or duplicate classes.
// `data.row[i]` is assumed to align by index with the i-th
// `.submissions-germline-list tbody tr.germline-sub-col` row (see scrape.js's
// extractScvRows, which builds `row[]` by iterating that exact selector).
function applyHighlights(doc, summaryByScv) {
  const rowEls = doc.querySelectorAll('.submissions-germline-list tbody tr.germline-sub-col');
  const data = (typeof window !== 'undefined' && window.extractClinVarData) ? window.extractClinVarData(doc) : null;
  if (!data || !data.row) return;

  const decorateForScvFn = (typeof self !== 'undefined' && self.decorateForScv) ||
    require('./highlight.js').decorateForScv;

  // Idempotency first: remove any decoration left over from a prior run.
  doc.querySelectorAll('.cvc-hl-badge').forEach((badge) => badge.remove());
  doc.querySelectorAll('.cvc-hl').forEach((row) => {
    row.classList.remove('cvc-hl', 'cvc-hl-flagged', 'cvc-hl-noted');
    row.removeAttribute('title');
  });

  const count = Math.min(rowEls.length, data.row.length);
  for (let i = 0; i < count; i++) {
    const dec = decorateForScvFn(summaryByScv[data.row[i].scv]);
    if (!dec) continue;
    rowEls[i].classList.add(...dec.cssClass.split(' '));
    if (rowEls[i].cells && rowEls[i].cells[3]) {
      const scv = data.row[i].scv;
      const badge = doc.createElement('span');
      badge.className = 'cvc-hl-badge';
      badge.textContent = dec.badge;
      // Tooltip on the badge itself (not the <tr>): ClinVar's own cell/link
      // `title`s win over an ancestor row's title, so the badge is the only
      // reliable hover surface. Also the click target for the history popover.
      badge.title = dec.tooltip + ' — click for history';
      badge.style.cursor = 'pointer';
      badge.addEventListener('click', (ev) => {
        ev.stopPropagation();
        showScvPopover(doc, badge, scv);
      });
      rowEls[i].cells[3].appendChild(badge);
    }
  }
}

// Best-effort: asks the background service worker (silent-auth only — never
// prompts interactive sign-in) for this variation's prior-annotation
// history, then decorates matching rows. Any failure — not signed in,
// non-allowlisted 403, DOM shape changed — leaves the page exactly as
// ClinVar rendered it; this must never throw into the page.
function initHighlights() {
  try {
    const data = window.extractClinVarData(document);
    if (!data || !data.variation_id) return;
    chrome.runtime.sendMessage({ subject: 'getScvHistory', variationId: data.variation_id }, (resp) => {
      if (chrome.runtime.lastError || !resp || !resp.ok || !resp.rows || !resp.rows.length) return;
      try {
        lastHistoryRows = resp.rows;
        applyHighlights(document, summarizeHistoryByScv(resp.rows));
      } catch (e) {
        console.info('CvC highlight failed —', e && e.message);
      }
    });
  } catch (e) {
    console.info('CvC highlight failed —', e && e.message);
  }
}

// Browser wiring (skipped under Node/tests where chrome is a mock without a real page).
if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    const data = handleInitializePopup(message, document);
    if (data !== null) {
      sendResponse(data);
      return true; // async response handled
    }
    return false; // not our message; let other listeners respond
  });
}

// In-page highlight init — only in a real content-script context. Real
// extension content scripts always have `chrome.runtime.id` (the extension's
// own id); the test-suite's mocked `chrome` global (test/setup.js) does not
// set it, so this never fires under Node/tests, keeping initializePopup's
// behavior byte-for-byte unchanged there. The content script runs at
// document_end, so the SCV table is already present; call it once.
if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.id && chrome.runtime.sendMessage) {
  initHighlights();
}

if (typeof module !== 'undefined' && module.exports) { module.exports = { handleInitializePopup, applyHighlights }; }
