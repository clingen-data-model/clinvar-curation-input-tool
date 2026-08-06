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
      // Lead with the SCV version the annotation was made on (e.g. "SCV v4"),
      // so cross-version history is legible (the SCV may now be a later version).
      meta.textContent = `${e.version ? 'SCV v' + e.version + ' · ' : ''}${e.when} · ${e.who}`;
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

// Removes the in-page Annotate form if one is open.
function closeAnnotateForm(doc) {
  const existing = doc.getElementById('cvc-annotate-form');
  if (existing) existing.remove();
}

// Clears all <option>/<optgroup> children of a <select>, keeping none.
// Mirrors popup.js's clearOptions helper (kept local — no shared DOM helper
// module exists to import from a content script).
function clearSelectOptions(select) {
  while (select.firstChild) select.removeChild(select.firstChild);
}

function addChooseOption(doc, select, label) {
  const opt = doc.createElement('option');
  opt.value = '';
  opt.textContent = label;
  opt.selected = true;
  select.appendChild(opt);
}

// Opens an in-page annotate form, anchored under the clicked button, for
// `scvRow` (an entry of the scraped `data.row[]`) against variation context
// `vcv` ({vcv, variation_id, name}). Mirrors popup.js's action→reason wiring
// (reasonOptionGroups, grouped <optgroup>s, reset-on-action-change) and
// save/status UX, but saves via the background service worker's
// `saveAnnotation` message instead of writing to Firestore directly (content
// scripts can't mint an auth token). Built with createElement +
// textContent/value only — never innerHTML — since curator-entered text and
// scraped submitter names flow through here. Best-effort: any failure is
// logged and swallowed, never thrown into the page.
function showAnnotateForm(doc, anchorEl, scvRow, vcv) {
  try {
    closeAnnotateForm(doc);
    closeScvPopover(doc);

    const actionsList = (typeof self !== 'undefined' && self.ACTIONS) || require('./vocab.js').ACTIONS;
    const reasonOptionGroupsFn = (typeof self !== 'undefined' && self.reasonOptionGroups) ||
      require('./popup-view.js').reasonOptionGroups;
    const validateAnnotationFn = (typeof self !== 'undefined' && self.validateAnnotation) ||
      require('./annotation.js').validateAnnotation;

    const form = doc.createElement('div');
    form.id = 'cvc-annotate-form';
    form.className = 'cvc-annotate-form';

    const title = doc.createElement('div');
    title.className = 'cvc-annotate-title';
    title.textContent = scvRow.submitter ? `Annotate ${scvRow.scv} — ${scvRow.submitter}` : `Annotate ${scvRow.scv}`;
    form.appendChild(title);

    // Action field.
    const actionField = doc.createElement('div');
    actionField.className = 'cvc-annotate-field';
    const actionLabel = doc.createElement('label');
    actionLabel.className = 'cvc-annotate-label';
    actionLabel.textContent = 'Action';
    const actionSelect = doc.createElement('select');
    actionSelect.className = 'cvc-annotate-select';
    addChooseOption(doc, actionSelect, 'Choose an action…');
    actionSelect.firstChild.disabled = true;
    (actionsList || []).forEach((action) => {
      const opt = doc.createElement('option');
      opt.value = action;
      opt.textContent = action;
      actionSelect.appendChild(opt);
    });
    actionField.appendChild(actionLabel);
    actionField.appendChild(actionSelect);
    form.appendChild(actionField);

    // Reason field — disabled until an action is chosen.
    const reasonField = doc.createElement('div');
    reasonField.className = 'cvc-annotate-field';
    const reasonLabel = doc.createElement('label');
    reasonLabel.className = 'cvc-annotate-label';
    reasonLabel.textContent = 'Reason';
    const reasonSelect = doc.createElement('select');
    reasonSelect.className = 'cvc-annotate-select';
    reasonSelect.disabled = true;
    addChooseOption(doc, reasonSelect, 'Choose...');
    reasonField.appendChild(reasonLabel);
    reasonField.appendChild(reasonSelect);
    form.appendChild(reasonField);

    actionSelect.addEventListener('change', () => {
      const action = actionSelect.value;
      clearSelectOptions(reasonSelect);
      addChooseOption(doc, reasonSelect, 'Choose...');
      reasonOptionGroupsFn(action).forEach((group) => {
        if (group.label) {
          const optgroup = doc.createElement('optgroup');
          optgroup.label = group.label;
          group.options.forEach((text) => {
            const opt = doc.createElement('option');
            opt.value = text;
            opt.textContent = text;
            optgroup.appendChild(opt);
          });
          reasonSelect.appendChild(optgroup);
        } else {
          group.options.forEach((text) => {
            const opt = doc.createElement('option');
            opt.value = text;
            opt.textContent = text;
            reasonSelect.appendChild(opt);
          });
        }
      });
      reasonSelect.disabled = !action;
      reasonSelect.value = '';
    });

    // Notes field.
    const notesField = doc.createElement('div');
    notesField.className = 'cvc-annotate-field';
    const notesLabel = doc.createElement('label');
    notesLabel.className = 'cvc-annotate-label';
    notesLabel.textContent = 'Notes';
    const notesEl = doc.createElement('textarea');
    notesEl.className = 'cvc-annotate-textarea';
    notesField.appendChild(notesLabel);
    notesField.appendChild(notesEl);
    form.appendChild(notesField);

    const saveButton = doc.createElement('button');
    saveButton.type = 'button';
    saveButton.className = 'cvc-annotate-save';
    saveButton.textContent = 'Save';
    form.appendChild(saveButton);

    const statusEl = doc.createElement('div');
    statusEl.className = 'cvc-annotate-status';
    form.appendChild(statusEl);

    saveButton.addEventListener('click', () => {
      try {
        const input = {
          action: actionSelect.value,
          reason: reasonSelect.value,
          notes: notesEl.value.trim()
        };
        const err = validateAnnotationFn({ scv: scvRow.scv, action: input.action, reason: input.reason });
        if (err) {
          statusEl.textContent = err;
          return;
        }

        saveButton.disabled = true;
        statusEl.textContent = 'Saving…';
        chrome.runtime.sendMessage({ subject: 'saveAnnotation', scvRow, vcv, input }, (resp) => {
          try {
            if (chrome.runtime.lastError) {
              statusEl.textContent = 'Save failed (extension error)';
              saveButton.disabled = false;
              return;
            }
            if (resp && resp.ok) {
              statusEl.textContent = 'Saved ✓';
              const view = doc.defaultView || (typeof window !== 'undefined' ? window : null);
              if (view && view.location) view.location.reload();
              return;
            }
            const reason = resp && resp.reason;
            if (reason === 'alreadyExists') {
              statusEl.textContent = 'This annotation was already saved.';
            } else if (reason === 'notAuthorized') {
              statusEl.textContent = 'Your account is not authorized to submit — contact an admin.';
            } else if (reason === 'invalid') {
              statusEl.textContent = (resp && resp.message) || 'Invalid annotation.';
            } else {
              statusEl.textContent = `Failed to save: ${(resp && resp.message) || 'unknown error'}`;
            }
            saveButton.disabled = false;
          } catch (e) {
            console.info('CvC: annotate save callback failed —', e && e.message);
          }
        });
      } catch (e) {
        console.info('CvC: annotate save failed —', e && e.message);
      }
    });

    const view = doc.defaultView || (typeof window !== 'undefined' ? window : null);
    const rect = anchorEl.getBoundingClientRect();
    const scrollX = view ? view.scrollX : 0;
    const scrollY = view ? view.scrollY : 0;
    form.style.position = 'absolute';
    form.style.top = (rect.bottom + scrollY + 4) + 'px';
    form.style.left = (rect.left + scrollX) + 'px';
    doc.body.appendChild(form);

    // Close on any outside click. The opening click is stopPropagation'd on
    // the Annotate button, so it won't reach this listener and immediately
    // close the form.
    const onDocClick = (ev) => {
      if (!form.contains(ev.target)) {
        closeAnnotateForm(doc);
        doc.removeEventListener('click', onDocClick);
      }
    };
    doc.addEventListener('click', onDocClick);
  } catch (e) {
    console.info('CvC: annotate form failed —', e && e.message);
  }
}

// Decorates SCV submission rows that already have prior CvC annotations with
// a row tint + small badge + hover tooltip (see highlight.js for the pure
// summarize/decorate logic), and — independent of any history — appends an
// "+ Annotate" button to EVERY row so a curator can annotate any SCV, not
// just ones with prior history. Best-effort and idempotent: any prior
// decoration/buttons from an earlier run are stripped before reapplying, so
// repeated calls (SPA re-renders, reloads) never stack badges or buttons.
// Within each section, `data.row` (filtered to that section's key) is assumed
// to align by index with the section's row elements (see scrape.js's
// extractScvRows, which builds `row[]` by iterating each section's rowSelector
// in registry order and tagging each row with its `section`). Only sections in
// the ANNOTATABLE_SCV_SECTIONS config get ANY badge — both the `+ Annotate`
// control and the `CvC N` history badge gate together per section.
function applyHighlights(doc, summaryByScv) {
  const data = (typeof window !== 'undefined' && window.extractClinVarData) ? window.extractClinVarData(doc) : null;
  if (!data || !data.row) return;

  const decorateForScvFn = (typeof self !== 'undefined' && self.decorateForScv) ||
    require('./highlight.js').decorateForScv;
  const scvBaseFn = (typeof self !== 'undefined' && self.scvBase) ||
    require('./highlight.js').scvBase;
  const annotatableSectionsFn = (typeof self !== 'undefined' && self.annotatableSections) ||
    require('./scv-sections.js').annotatableSections;

  // Idempotency first: remove any decoration/buttons left over from a prior run.
  doc.querySelectorAll('.cvc-hl-badge').forEach((badge) => badge.remove());
  doc.querySelectorAll('.cvc-annotate-btn').forEach((btn) => btn.remove());
  doc.querySelectorAll('.cvc-hl').forEach((row) => {
    row.classList.remove('cvc-hl', 'cvc-hl-flagged', 'cvc-hl-noted');
    row.removeAttribute('title');
  });

  const vcv = { vcv: data.vcv, variation_id: data.variation_id, name: data.name };

  // One pass per CONFIGURED section: query that section's rows, take that
  // section's scraped rows (data.row filtered by section key, in order), align
  // within the section, and inject into the section's `injectCell`.
  annotatableSectionsFn().forEach((section) => {
    const rowEls = doc.querySelectorAll(section.rowSelector);
    const sectionRows = data.row.filter((r) => r.section === section.key);
    const injectCell = section.injectCell;
    const count = Math.min(rowEls.length, sectionRows.length);
    for (let i = 0; i < count; i++) {
      const scvRow = sectionRows[i];
      const scv = scvRow.scv;
      // Match history by version-stripped base accession so annotations made on
      // any prior version of this SCV surface on the current row.
      const dec = decorateForScvFn(summaryByScv[scvBaseFn(scv)]);
      if (dec) {
        rowEls[i].classList.add(...dec.cssClass.split(' '));
      }
      if (!rowEls[i].cells || !rowEls[i].cells[injectCell]) continue;

      // Annotate control first on every row (regardless of prior history). It's
      // a <span> (not a <button>) styled as a badge: a real <button> inherits
      // ClinVar/USWDS button chrome (large rounded rectangle) that overrides our
      // styles, whereas a span renders exactly like the .cvc-hl-badge span.
      const annotateBtn = doc.createElement('span');
      annotateBtn.className = 'cvc-annotate-btn';
      annotateBtn.setAttribute('role', 'button');
      annotateBtn.textContent = '+ Annotate';
      annotateBtn.addEventListener('click', (ev) => {
        ev.stopPropagation();
        showAnnotateForm(doc, annotateBtn, scvRow, vcv);
      });
      rowEls[i].cells[injectCell].appendChild(annotateBtn);

      // ...then the CvC history badge after it, when the SCV has prior history.
      if (dec) {
        const badge = doc.createElement('span');
        badge.className = 'cvc-hl-badge ' + (dec.badgeClass || '');
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
        rowEls[i].cells[injectCell].appendChild(badge);
      }
    }
  });
}

// Diagnostic: when a scrape comes back empty on a ClinVar variation page (the
// content script only runs on variation pages, so an empty scrape means the DOM
// drifted), log a per-seam health report (dom-seams.js) so the broken location
// names itself in the console instead of leaving a silently-blank scrape.
// Best-effort, console-only — never throws, never touches the page.
function reportSeamDrift(doc) {
  try {
    const inspect = (typeof self !== 'undefined' && self.inspectSeams) ||
      (typeof require === 'function' ? require('./dom-seams.js').inspectSeams : null);
    const format = (typeof self !== 'undefined' && self.formatSeams) ||
      (typeof require === 'function' ? require('./dom-seams.js').formatSeams : null);
    if (!inspect || !format) return;
    const report = inspect(doc);
    const headline = report.ok
      ? 'CvC: ClinVar scrape returned no variation_id, yet all known DOM seams look healthy — scraper/inspector may need a new seam:'
      : 'CvC: ClinVar scrape returned no variation_id — a DOM seam has drifted:';
    console.warn(headline + '\n' + format(report));
  } catch (e) { /* diagnostics must never break the page */ }
}

// Best-effort: asks the background service worker (silent-auth only — never
// prompts interactive sign-in) for this variation's prior-annotation
// history, then decorates matching rows. Any failure — not signed in,
// non-allowlisted 403, DOM shape changed — leaves the page exactly as
// ClinVar rendered it; this must never throw into the page.
function initHighlights() {
  try {
    const data = window.extractClinVarData(document);
    // Empty scrape on a variation page => DOM drift: name the broken seam(s).
    if (!data || !data.variation_id) { reportSeamDrift(document); return; }
    chrome.runtime.sendMessage({ subject: 'getScvHistory', variationId: data.variation_id }, (resp) => {
      // Only a genuine failure leaves the page untouched — a messaging error, no
      // response, or a not-ok result (e.g. not signed in / not allow-listed).
      // A SUCCESSFUL fetch with ZERO history rows must still decorate: the
      // "+ Annotate" button belongs on EVERY row regardless of prior history
      // (only the "CvC N" history badge is history-dependent). Previously the
      // extra `!resp.rows.length` guard here suppressed ALL decoration on any
      // variation with no prior CvC annotations — so single/unannotated variants
      // never got a "+ Annotate" button.
      if (chrome.runtime.lastError || !resp || !resp.ok) return;
      try {
        lastHistoryRows = resp.rows || [];
        applyHighlights(document, summarizeHistoryByScv(lastHistoryRows));
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

if (typeof module !== 'undefined' && module.exports) { module.exports = { handleInitializePopup, applyHighlights, reportSeamDrift }; }
