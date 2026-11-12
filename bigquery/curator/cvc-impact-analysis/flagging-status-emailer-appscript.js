/**
 * ============================================================================
 * Flagging Status Report -> per-submitter emails (Google Apps Script)
 * ============================================================================
 *
 * Bound to the flagging-status spreadsheet:
 *   https://docs.google.com/spreadsheets/d/15V5UO52Caxzg7w1d-u43lGRpI_WTyEzoE1cQcaRp2KE/
 *
 * What it does:
 *   1. Reads the (filtered) flagging status report tab -- the output of
 *      clinvar_curator.sheets_flagging_status_report_fn.
 *   2. Groups rows by submitter (by "Submitter ID").
 *   3. Looks up each submitter's FIRST contact with a valid email from the
 *      contacts tab (loaded from clinvar_curator.submitter_contacts).
 *   4. Produces ONE email per submitter containing that submitter's records,
 *      addressed to that contact.
 *
 * Also on the "Flagging Emails" menu:
 *   - "Email full report as TSV (draft)": drafts one email to the NCBI ClinVar
 *     team (CONFIG.ncbiRecipients) with the ENTIRE report tab attached as a .tsv.
 *
 * Keeping contacts current:
 *   - "Sync missing contacts (scrape ClinVar)": finds flagging-candidate
 *     submitters not yet in submitter_contacts, scrapes their ClinVar Personnel
 *     sections (UrlFetchApp), and loads the rows into the table (WRITE_APPEND).
 *     BigQuery cannot fetch URLs, so a SQL proc/job cannot do this -- Apps Script
 *     can, keeping the whole flow in one place.
 *   - "Re-sync ALL contacts (overwrite)": rescrapes every flagging-candidate
 *     submitter and OVERWRITES the table (WRITE_TRUNCATE) so personnel changes
 *     are picked up. Truncates only after a full successful scrape (a timeout
 *     leaves the table untouched).
 *   First run prompts for the external-request auth scope. Both are capped at
 *   CONFIG.maxScrapePerRun; ~300 fetches can exceed Apps Script's ~6 min limit,
 *   so for a large backfill/resync use the Python scraper in
 *   scripts/submitter-contacts/ (no execution limit).
 *
 * Whatever rows are VISIBLE/exported on the report tab are what gets used, so
 * apply your filter first (this reads the sheet values, not the BigQuery table).
 *
 * SAFETY: this script ONLY creates Gmail drafts. It never sends. Review every
 * draft in Gmail and send manually.
 *   - 'preview' : log what would happen, create nothing.
 *   - 'draft'   : create Gmail drafts (default).
 *
 * Setup (one time):
 *   1. Extensions -> Apps Script, paste this file.
 *   2. Put the report on a tab named in CONFIG.reportSheetName (default: the
 *      active sheet).
 *   3. Contacts tab (CONFIG.contactsSheetName, default 'submitter_contacts')
 *      with columns submitter_id, email, contact_name, contact_index. Either:
 *        (a) Menu -> "Refresh contacts (from BigQuery)": enable the BigQuery
 *            advanced service (Editor -> Services (+) -> "BigQuery API") and set
 *            CONFIG.bqProjectId; the tab is (re)filled from
 *            clinvar_curator.submitter_contacts, OR
 *        (b) A Connected Sheets extract of the same table, OR
 *        (c) A manual paste of the scraped NDJSON loaded to that table.
 *   4. Reload the sheet; use the "Flagging Emails" menu.
 *
 * Connected Sheets alternative (no code): Data -> Data connectors ->
 * Connect to BigQuery, then "Extract" with query:
 *   SELECT submitter_id, submitter_name, contact_index, contact_name,
 *          contact_role, phone, email, status
 *   FROM `clinvar_curator.submitter_contacts`
 *   ORDER BY submitter_id, contact_index
 * pointed at a tab named 'submitter_contacts'.
 * ============================================================================
 */

var CONFIG = {
  // Tab holding the filtered flagging status report. '' => the active sheet.
  reportSheetName: '10a. Flagging Status Report',
  // 1-based row that holds the column headers on the report tab (a title row
  // above the headers is common -> set this to 2).
  reportHeaderRow: 2,
  // Tab holding the submitter_contacts export.
  contactsSheetName: 'submitter_contacts',
  // 1-based header row on the contacts tab (refreshContacts writes headers on row 1).
  contactsHeaderRow: 1,

  // "Refresh contacts" pulls this table via the BigQuery advanced service.
  // bqProjectId is the GCP project that runs (bills) the query; if the data
  // lives in that same project, bqContactsTable can be left dataset-qualified,
  // otherwise use a full 'project.dataset.table'.
  bqProjectId: 'clingen-dev',                                     // e.g. 'clingen-dev' (REQUIRED for refresh/sync)
  bqContactsTable: 'clinvar_curator.submitter_contacts',

  // "Sync missing contacts" scrapes ClinVar submitter pages (via UrlFetchApp) for
  // flagging-candidate submitters not yet in submitter_contacts, then streams the
  // results into that table. BigQuery cannot fetch URLs, so Apps Script does it.
  scrapeUserAgent: 'clinvar-curation-appscript/1.0 (contact: lbabb@broadinstitute.org)',
  scrapeDelayMs: 1000,    // politeness delay between page fetches
  maxScrapePerRun: 300,   // Apps Script ~6 min limit; cap per run and re-run for more

  // Report column header names (must match sheets_flagging_status_report_fn).
  reportSubmitterIdCol: 'Submitter ID',
  reportSubmitterNameCol: 'Submitter',
  reportReleaseCol: 'Report release',

  // Contacts column header names (must match the submitter_contacts export).
  contactSubmitterIdCol: 'submitter_id',
  contactEmailCol: 'email',
  contactNameCol: 'contact_name',
  contactOrderCol: 'contact_index', // used to pick the "first" contact; optional

  // Columns (by header name) to show in the per-submitter email table, in order.
  // Only those present on the report tab are used.
  emailTableColumns: [
    'SCV', 'State', 'Candidate disposition', 'Reason', 'Notes',
    'Curation date', 'Aging', 'Days in state', 'Grace status', 'ClinVar Link'
  ],

  // Email framing.
  subjectTemplate: 'ClinVar flagging status update — {submitter}',
  ccList: '',   // comma-separated addresses cc'd on every email (e.g. a curator inbox)
  bccList: '',
  fromName: 'ClinGen ClinVar Curation',
  // Optional: route everything to yourself for testing regardless of contact.
  overrideRecipient: '',

  maxEmails: 300, // safety cap

  // "Email full report as TSV" -> a Gmail DRAFT to the ClinVar team at NCBI with
  // the entire report tab attached as a .tsv. Configure the recipient(s).
  ncbiRecipients: '',   // comma-separated NCBI ClinVar team addresses (REQUIRED for that option)
  ncbiSubjectTemplate: 'ClinGen CVC flagging status report — {release}',
  ncbiBody:
    'Hello ClinVar team,\n\n' +
    'Attached is the ClinGen ClinVar Curation (CVC) flagging status report ' +
    '({rows} record(s), {release} release) as a tab-separated file.\n\n' +
    'Thanks,\nClinGen ClinVar Curation',
  tsvFilenamePrefix: 'cvc_flagging_status_report_'
};

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Flagging Emails')
    .addItem('Preview (log only)', 'previewFlaggingEmails')
    .addItem('Create drafts', 'draftFlaggingEmails')
    .addItem('Email full report as TSV (draft)', 'emailReportTsv')
    .addSeparator()
    .addItem('Sync missing contacts (scrape ClinVar)', 'syncMissingContacts')
    .addItem('Re-sync ALL contacts (overwrite)', 'resyncAllContacts')
    .addItem('Refresh contacts (from BigQuery)', 'refreshContacts')
    .addToUi();
}

function previewFlaggingEmails() { runFlaggingEmails('preview'); }
function draftFlaggingEmails()   { runFlaggingEmails('draft'); }

/**
 * Main entry point. This function only ever creates drafts (or previews);
 * there is intentionally no send path.
 * @param {'preview'|'draft'} mode
 */
function runFlaggingEmails(mode) {
  var ss = SpreadsheetApp.getActive();
  var reportSheet = CONFIG.reportSheetName
    ? ss.getSheetByName(CONFIG.reportSheetName)
    : ss.getActiveSheet();
  if (!reportSheet) throw new Error('Report sheet not found: ' + CONFIG.reportSheetName);

  var contactsSheet = ss.getSheetByName(CONFIG.contactsSheetName);
  if (!contactsSheet) throw new Error('Contacts sheet not found: ' + CONFIG.contactsSheetName);

  // Read all displayed rows. Filtering is done upstream in the extract that feeds
  // this tab, so every row shown here is intended to be included.
  var report = readSheetObjects(reportSheet, CONFIG.reportHeaderRow);
  var contacts = readSheetObjects(contactsSheet, CONFIG.contactsHeaderRow);

  // Diagnostics (see Executions / View > Logs).
  Logger.log('Report tab "%s": %s data row(s). Headers: %s',
    reportSheet.getName(), report.rows.length, report.headers.join(' | '));

  if (!report.rows.length) {
    toast_('No data rows on "' + reportSheet.getName() + '". If this tab is a LIVE '
      + 'Connected Sheet, use Data → Extract (or paste values) — Apps Script '
      + 'cannot read a live data-connector sheet.');
    return;
  }
  if (report.headers.indexOf(CONFIG.reportSubmitterIdCol) === -1) {
    toast_('Report tab has no "' + CONFIG.reportSubmitterIdCol + '" column on the '
      + 'header row. See the log for the headers actually found (a title row above '
      + 'the headers is the usual cause).');
    throw new Error('Missing "' + CONFIG.reportSubmitterIdCol + '" column. '
      + 'Headers found: ' + report.headers.join(' | '));
  }

  var contactBySubmitter = buildContactIndex_(contacts);
  var groups = groupBySubmitter_(report);
  Logger.log('Grouped into %s submitter(s); %s contact(s) loaded.',
    Object.keys(groups).length, contacts.rows.length);

  var tableCols = CONFIG.emailTableColumns.filter(function (c) {
    return report.headers.indexOf(c) !== -1;
  });
  var reportRelease = firstNonEmpty_(report.rows, CONFIG.reportReleaseCol);

  var made = 0, skipped = [];
  Object.keys(groups).forEach(function (submitterId) {
    if (made >= CONFIG.maxEmails) return;
    var g = groups[submitterId];
    var contact = contactBySubmitter[normId_(submitterId)];
    var recipient = CONFIG.overrideRecipient || (contact && contact.email) || '';

    if (!recipient) {
      skipped.push(submitterId + ' (' + g.submitterName + ') — no valid contact email');
      return;
    }

    var subject = CONFIG.subjectTemplate.replace('{submitter}', g.submitterName);
    var html = buildEmailHtml_(g.submitterName, contact, g.rows, tableCols, reportRelease);
    var plain = htmlToPlain_(html);
    var opts = {
      htmlBody: html,
      name: CONFIG.fromName,
      cc: CONFIG.ccList || undefined,
      bcc: CONFIG.bccList || undefined
    };

    if (mode === 'preview') {
      Logger.log('[preview] -> %s | %s | %s rows', recipient, subject, g.rows.length);
    } else { // draft — the only email-producing path; never sends
      GmailApp.createDraft(recipient, subject, plain, opts);
    }
    made++;
  });

  var msg = (mode === 'draft' ? 'Drafted ' : 'Previewed ')
    + made + ' email(s); ' + skipped.length + ' submitter(s) skipped.';
  Logger.log(msg);
  if (skipped.length) Logger.log('Skipped:\n' + skipped.join('\n'));
  toast_(msg + (skipped.length ? ' See View > Logs for skips.' : ''));
}

/**
 * Create a Gmail DRAFT to the NCBI ClinVar team with the ENTIRE report tab
 * attached as a .tsv. Never sends -- review and send the draft manually.
 */
function emailReportTsv() {
  if (!CONFIG.ncbiRecipients) {
    throw new Error('Set CONFIG.ncbiRecipients (comma-separated NCBI addresses) first.');
  }
  var ss = SpreadsheetApp.getActive();
  var reportSheet = CONFIG.reportSheetName
    ? ss.getSheetByName(CONFIG.reportSheetName)
    : ss.getActiveSheet();
  if (!reportSheet) throw new Error('Report sheet not found: ' + CONFIG.reportSheetName);

  var report = readSheetObjects(reportSheet, CONFIG.reportHeaderRow);
  if (!report.rows.length) { toast_('No rows on the report tab to send.'); return; }

  var release = firstNonEmpty_(report.rows, CONFIG.reportReleaseCol);
  var stamp = release
    ? String(release).replace(/[^0-9A-Za-z_-]/g, '')
    : Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  var filename = CONFIG.tsvFilenamePrefix + stamp + '.tsv';
  var blob = Utilities.newBlob(buildTsv_(report.headers, report.rows), 'text/tab-separated-values', filename);

  var subject = CONFIG.ncbiSubjectTemplate.replace('{release}', release || stamp);
  var body = CONFIG.ncbiBody
    .replace('{rows}', String(report.rows.length))
    .replace('{release}', release || stamp);

  GmailApp.createDraft(CONFIG.ncbiRecipients, subject, body, {
    attachments: [blob],
    name: CONFIG.fromName,
    cc: CONFIG.ccList || undefined,
    bcc: CONFIG.bccList || undefined
  });

  var msg = 'Drafted report TSV (' + report.rows.length + ' row(s), ' + filename + ') to '
    + CONFIG.ncbiRecipients + '.';
  Logger.log(msg);
  toast_(msg);
}

/** Build a TSV string from headers + row objects (tabs/newlines in cells flattened). */
function buildTsv_(headers, rows) {
  var esc = function (v) { return String(v == null ? '' : v).replace(/[\t\r\n]+/g, ' '); };
  var lines = [headers.map(esc).join('\t')];
  rows.forEach(function (r) {
    lines.push(headers.map(function (h) { return esc(r[h]); }).join('\t'));
  });
  return lines.join('\n');
}

/* -------------------------------------------------------------------------- */
/* Refresh contacts from BigQuery                                              */
/* -------------------------------------------------------------------------- */

/**
 * Pull clinvar_curator.submitter_contacts into the contacts tab via the BigQuery
 * advanced service. Requires: Apps Script Editor -> Services (+) -> "BigQuery API"
 * (identifier BigQuery), and CONFIG.bqProjectId set to a project you can bill
 * queries to. Overwrites the contacts tab contents with fresh data.
 */
function refreshContacts() {
  if (!CONFIG.bqProjectId) {
    throw new Error('Set CONFIG.bqProjectId (GCP billing project) before refreshing contacts.');
  }
  var sql =
    'SELECT submitter_id, submitter_name, contact_index, contact_name, contact_role, ' +
    '       phone, email, status, source_url, CAST(retrieved_at AS STRING) AS retrieved_at ' +
    'FROM `' + CONFIG.bqContactsTable + '` ' +
    'ORDER BY submitter_id, contact_index';

  var qr = bqQueryAll_(sql);
  var fields = qr.fields;
  var data = qr.rows.map(function (r) {
    return r.f.map(function (cell) { return cell.v == null ? '' : cell.v; });
  });

  var ss = SpreadsheetApp.getActive();
  var sheet = ss.getSheetByName(CONFIG.contactsSheetName) || ss.insertSheet(CONFIG.contactsSheetName);
  sheet.clearContents();
  if (fields.length) sheet.getRange(1, 1, 1, fields.length).setValues([fields]);
  if (data.length) sheet.getRange(2, 1, data.length, fields.length).setValues(data);

  var msg = 'Refreshed contacts: ' + data.length + ' row(s) from ' + CONFIG.bqContactsTable + '.';
  Logger.log(msg);
  toast_(msg);
}

/* -------------------------------------------------------------------------- */
/* Sync missing contacts: scrape ClinVar for new submitters                    */
/* -------------------------------------------------------------------------- */

/**
 * Find flagging-candidate submitters that are NOT yet in submitter_contacts,
 * scrape their ClinVar Personnel sections, and stream the rows into the table.
 * Idempotent: re-running only scrapes submitters still missing. Capped at
 * CONFIG.maxScrapePerRun per run (Apps Script has a ~6 minute execution limit).
 *
 * BigQuery cannot fetch URLs, so the scraping happens here (UrlFetchApp). After
 * this runs, use "Refresh contacts" to pull the new rows into the contacts tab
 * (streamed rows are queryable within a few seconds).
 */
function syncMissingContacts() {
  if (!CONFIG.bqProjectId) throw new Error('Set CONFIG.bqProjectId before syncing contacts.');

  var sql =
    'SELECT DISTINCT a.submitter_id ' +
    'FROM `clinvar_curator.cvc_clinvar_submissions` s ' +
    'JOIN `clinvar_curator.cvc_annotations_view` a ON s.annotation_id = a.annotation_id ' +
    'LEFT JOIN `' + CONFIG.bqContactsTable + '` c ON c.submitter_id = a.submitter_id ' +
    "WHERE a.action = 'flagging candidate' AND c.submitter_id IS NULL " +
    'ORDER BY 1';

  var ids = bqQueryAll_(sql).rows.map(function (r) { return r.f[0].v; }).filter(Boolean);
  if (!ids.length) { toast_('submitter_contacts is already complete — nothing to scrape.'); return; }

  var limit = Math.min(ids.length, CONFIG.maxScrapePerRun);
  var rowsToInsert = [], withEmail = 0;
  for (var i = 0; i < limit; i++) {
    var rows = fetchSubmitterContacts_(ids[i]);
    rowsToInsert = rowsToInsert.concat(rows);
    withEmail += rows.filter(function (r) { return r.email; }).length;
    if (i < limit - 1) Utilities.sleep(CONFIG.scrapeDelayMs);
  }

  loadContactRows_(rowsToInsert, 'WRITE_APPEND');
  try { refreshContacts(); } catch (e) {}

  var more = ids.length > limit ? (' — ' + (ids.length - limit) + ' still missing, run again') : '';
  var msg = 'Scraped ' + limit + ' new submitter(s) (' + withEmail + ' email row(s)); appended '
    + rowsToInsert.length + ' row(s)' + more + '.';
  Logger.log(msg);
  toast_(msg);
}

/**
 * Re-scrape ALL flagging-candidate submitters and OVERWRITE submitter_contacts.
 * Use this to refresh contacts when personnel change over time. Scrapes the full
 * set first, then replaces the table atomically (WRITE_TRUNCATE) -- so if the run
 * times out mid-scrape, the table is left untouched.
 */
function resyncAllContacts() {
  if (!CONFIG.bqProjectId) throw new Error('Set CONFIG.bqProjectId before syncing contacts.');
  var ui = SpreadsheetApp.getUi();

  var sql =
    'SELECT DISTINCT a.submitter_id ' +
    'FROM `clinvar_curator.cvc_clinvar_submissions` s ' +
    'JOIN `clinvar_curator.cvc_annotations_view` a ON s.annotation_id = a.annotation_id ' +
    "WHERE a.action = 'flagging candidate' " +
    'ORDER BY 1';
  var ids = bqQueryAll_(sql).rows.map(function (r) { return r.f[0].v; }).filter(Boolean);
  if (!ids.length) { toast_('No flagging-candidate submitters found.'); return; }

  var estMin = Math.ceil(ids.length * (CONFIG.scrapeDelayMs / 1000) / 60);
  var resp = ui.alert('Re-sync ALL submitter contacts',
    'Rescrape ' + ids.length + ' flagging-candidate submitter page(s) from ClinVar and '
    + 'OVERWRITE ' + CONFIG.bqContactsTable + '?\n\n'
    + 'Rough time: ~' + estMin + ' min. If it exceeds Apps Script’s ~6 min limit, '
    + 'use the Python scraper in scripts/submitter-contacts/ instead.',
    ui.ButtonSet.YES_NO);
  if (resp !== ui.Button.YES) { toast_('Re-sync cancelled.'); return; }

  var rows = [], withEmail = 0;
  for (var i = 0; i < ids.length; i++) {
    var r = fetchSubmitterContacts_(ids[i]);
    rows = rows.concat(r);
    withEmail += r.filter(function (x) { return x.email; }).length;
    if (i < ids.length - 1) Utilities.sleep(CONFIG.scrapeDelayMs);
  }
  if (!rows.length) throw new Error('Scrape produced no rows; table left unchanged.');

  loadContactRows_(rows, 'WRITE_TRUNCATE');   // atomic overwrite
  try { refreshContacts(); } catch (e) {}

  var msg = 'Re-synced ALL: ' + ids.length + ' submitter(s), ' + withEmail + ' email row(s), '
    + rows.length + ' row(s) written (table overwritten).';
  Logger.log(msg);
  toast_(msg);
}

/** Fetch + parse one submitter's Personnel section into row objects. */
function fetchSubmitterContacts_(submitterId) {
  var url = 'https://www.ncbi.nlm.nih.gov/clinvar/submitters/' + encodeURIComponent(submitterId) + '/';
  var now = new Date().toISOString();
  var resp;
  try {
    resp = UrlFetchApp.fetch(url, {
      muteHttpExceptions: true, followRedirects: true,
      headers: { 'User-Agent': CONFIG.scrapeUserAgent }
    });
  } catch (e) {
    return [contactRow_(submitterId, null, 0, null, null, null, null, 'fetch_failed', url, now)];
  }
  if (resp.getResponseCode() !== 200) {
    return [contactRow_(submitterId, null, 0, null, null, null, null, 'fetch_failed', url, now)];
  }
  var page = resp.getContentText();
  var name = submitterNameFromPage_(page);
  var contacts = parsePersonnel_(page);
  if (!contacts.length) {
    return [contactRow_(submitterId, name, 0, null, null, null, null, 'no_personnel', url, now)];
  }
  return contacts.map(function (c, idx) {
    return contactRow_(submitterId, name, idx, c.name, c.role, c.phone, c.email, 'ok', url, now);
  });
}

function contactRow_(id, name, idx, cname, role, phone, email, status, url, ts) {
  return {
    submitter_id: id, submitter_name: name, contact_index: idx,
    contact_name: cname, contact_role: role, phone: phone, email: email,
    status: status, source_url: url, retrieved_at: ts
  };
}

/** Parse the personnel <li> items -> [{name, role, phone, email}]. */
function parsePersonnel_(page) {
  var block = page.match(/data-section="personnel"[\s\S]*?<ul[^>]*personal_list[^>]*>([\s\S]*?)<\/ul>/i);
  if (!block) return [];
  var out = [], m, liRe = /<li[^>]*>([\s\S]*?)<\/li>/gi;
  while ((m = liRe.exec(block[1])) !== null) {
    var li = m[1];
    var email = (li.match(/mailto:([^"'>\s]+)/i) || [])[1] || null;
    var phone = (li.match(/Phone:\s*([^<]+)/i) || [])[1];
    phone = phone ? cleanHtml_(phone) : null;
    var head = cleanHtml_(li.split(/<br\s*\/?>/i)[0] || '');
    var name = head, role = null;
    if (head.indexOf(',') !== -1) { name = head.slice(0, head.indexOf(',')).trim(); role = head.slice(head.indexOf(',') + 1).trim(); }
    out.push({ name: name || null, role: role, phone: phone, email: email ? htmlUnescape_(email).trim() : null });
  }
  return out;
}

function submitterNameFromPage_(page) {
  var m = page.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  if (!m) return null;
  return cleanHtml_(m[1]).replace(/\s*-\s*(Submitter|ClinVar|NCBI)\b[\s\S]*$/i, '') || null;
}

/**
 * Write row objects into submitter_contacts with a load job (atomic, immediately
 * queryable, no streaming buffer). writeDisposition: 'WRITE_APPEND' | 'WRITE_TRUNCATE'.
 * Uses the destination table's existing schema (no schema/autodetect specified).
 */
function loadContactRows_(rowObjs, writeDisposition) {
  var ref = parseTableRef_(CONFIG.bqContactsTable);
  var ndjson = rowObjs.map(function (o) { return JSON.stringify(o); }).join('\n');
  var blob = Utilities.newBlob(ndjson, 'application/octet-stream');
  var job = {
    configuration: {
      load: {
        destinationTable: { projectId: ref.projectId, datasetId: ref.datasetId, tableId: ref.tableId },
        sourceFormat: 'NEWLINE_DELIMITED_JSON',
        writeDisposition: writeDisposition
      }
    }
  };
  var res = BigQuery.Jobs.insert(job, ref.projectId, blob);
  var jobId = res.jobReference.jobId, location = res.jobReference.location;
  while (!res.status || res.status.state !== 'DONE') {
    Utilities.sleep(1000);
    res = BigQuery.Jobs.get(ref.projectId, jobId, { location: location });
  }
  if (res.status.errorResult) {
    Logger.log('load job error: %s', JSON.stringify(res.status.errorResult));
    throw new Error('BigQuery load failed: ' + res.status.errorResult.message);
  }
}

function parseTableRef_(ref) {
  var p = String(ref).split('.');
  if (p.length === 3) return { projectId: p[0], datasetId: p[1], tableId: p[2] };
  if (p.length === 2) return { projectId: CONFIG.bqProjectId, datasetId: p[0], tableId: p[1] };
  throw new Error('bqContactsTable must be dataset.table or project.dataset.table: ' + ref);
}

/** Run a query and return {fields:[], rows:[]} across all result pages. */
function bqQueryAll_(sql) {
  var res = BigQuery.Jobs.query({ query: sql, useLegacySql: false, maxResults: 100000 }, CONFIG.bqProjectId);
  var jobId = res.jobReference.jobId, location = res.jobReference.location;
  while (!res.jobComplete) {
    Utilities.sleep(500);
    res = BigQuery.Jobs.getQueryResults(CONFIG.bqProjectId, jobId, { location: location });
  }
  var fields = (res.schema && res.schema.fields) ? res.schema.fields.map(function (f) { return f.name; }) : [];
  var rows = res.rows || [];
  var pageToken = res.pageToken;
  while (pageToken) {
    res = BigQuery.Jobs.getQueryResults(CONFIG.bqProjectId, jobId, { location: location, pageToken: pageToken });
    rows = rows.concat(res.rows || []);
    pageToken = res.pageToken;
  }
  return { fields: fields, rows: rows };
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Read a sheet into {headers:[], rows:[{header: value}]}.
 * Reads every displayed row (blank rows skipped). Filtering is handled upstream
 * in the extract that feeds the tab, so no filter-visibility logic here.
 * @param {Sheet} sheet
 * @param {number} [headerRow=1] 1-based row containing the column headers; rows
 *   above it are ignored, data is read from the row after it.
 */
function readSheetObjects(sheet, headerRow) {
  headerRow = headerRow || 1;
  var values = sheet.getDataRange().getDisplayValues();
  if (values.length < headerRow) return { headers: [], rows: [] };
  var headers = values[headerRow - 1].map(function (h) { return String(h).trim(); });
  var rows = [];
  for (var i = headerRow; i < values.length; i++) {
    var row = values[i];
    if (row.every(function (c) { return String(c).trim() === ''; })) continue; // skip blank
    var obj = {};
    for (var j = 0; j < headers.length; j++) obj[headers[j]] = row[j];
    rows.push(obj);
  }
  return { headers: headers, rows: rows };
}

/** submitterId -> {email, name} using the FIRST contact with a valid email. */
function buildContactIndex_(contacts) {
  var byId = {};
  contacts.rows.forEach(function (r) {
    var id = normId_(r[CONFIG.contactSubmitterIdCol]);
    if (!id) return;
    (byId[id] = byId[id] || []).push(r);
  });
  var out = {};
  Object.keys(byId).forEach(function (id) {
    var list = byId[id].slice().sort(function (a, b) {
      return orderNum_(a[CONFIG.contactOrderCol]) - orderNum_(b[CONFIG.contactOrderCol]);
    });
    for (var i = 0; i < list.length; i++) {
      var email = String(list[i][CONFIG.contactEmailCol] || '').trim();
      if (isValidEmail_(email)) {
        out[id] = { email: email, name: String(list[i][CONFIG.contactNameCol] || '').trim() };
        break;
      }
    }
  });
  return out;
}

/** Group report rows by submitter id. */
function groupBySubmitter_(report) {
  var groups = {};
  report.rows.forEach(function (r) {
    var id = String(r[CONFIG.reportSubmitterIdCol] || '').trim();
    if (!id) return;
    if (!groups[id]) groups[id] = { submitterName: String(r[CONFIG.reportSubmitterNameCol] || id).trim(), rows: [] };
    groups[id].rows.push(r);
  });
  return groups;
}

function buildEmailHtml_(submitterName, contact, rows, cols, reportRelease) {
  var esc = htmlEscape_;
  var greetingName = (contact && contact.name) ? contact.name.split(',')[0].split(' ')[0] : '';
  var hi = greetingName ? ('Hello ' + esc(greetingName) + ',') : 'Hello,';

  var thead = '<tr>' + cols.map(function (c) {
    return '<th style="text-align:left;border-bottom:2px solid #ccc;padding:6px 10px;font-size:13px;">' + esc(c) + '</th>';
  }).join('') + '</tr>';

  var tbody = rows.map(function (row) {
    return '<tr>' + cols.map(function (c) {
      var v = row[c] == null ? '' : String(row[c]);
      var cell = /^https?:\/\//i.test(v)
        ? '<a href="' + esc(v) + '">' + esc(v.replace(/^https?:\/\//, '')) + '</a>'
        : esc(v);
      return '<td style="border-bottom:1px solid #eee;padding:6px 10px;font-size:13px;vertical-align:top;">' + cell + '</td>';
    }).join('') + '</tr>';
  }).join('');

  return [
    '<div style="font-family:Arial,Helvetica,sans-serif;color:#222;">',
    '<p>' + hi + '</p>',
    '<p>The following ClinVar submission(s) from <b>' + esc(submitterName) + '</b> have been '
      + 'identified by the ClinGen ClinVar Curation (CVC) project as flagging candidates or '
      + 'flagged submissions' + (reportRelease ? (' as of the ' + esc(reportRelease) + ' ClinVar release') : '') + '. '
      + 'This summary mirrors the information in ClinVar’s post-processing notifications.</p>',
    '<table style="border-collapse:collapse;margin:12px 0;">',
    '<thead>' + thead + '</thead>',
    '<tbody>' + tbody + '</tbody>',
    '</table>',
    '<p>' + rows.length + ' record(s). Please reach out with any questions.</p>',
    '<p style="color:#666;font-size:12px;">Sent by the ClinGen ClinVar Curation team.</p>',
    '</div>'
  ].join('');
}

function isValidEmail_(s) { return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(s || '').trim()); }
function normId_(s) { return String(s == null ? '' : s).trim(); }
function orderNum_(s) { var n = parseInt(s, 10); return isNaN(n) ? 1e9 : n; }
function firstNonEmpty_(rows, col) {
  for (var i = 0; i < rows.length; i++) { var v = String(rows[i][col] || '').trim(); if (v) return v; }
  return '';
}
function htmlEscape_(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function htmlUnescape_(s) {
  return String(s == null ? '' : s)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ');
}
/** Strip tags, unescape entities, collapse whitespace. */
function cleanHtml_(s) {
  return htmlUnescape_(String(s == null ? '' : s).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}
function htmlToPlain_(html) {
  return html.replace(/<\/(tr|p|table|div)>/gi, '\n')
    .replace(/<th[^>]*>|<td[^>]*>/gi, '\t')
    .replace(/<[^>]+>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/\n{3,}/g, '\n\n').trim();
}
function toast_(msg) { try { SpreadsheetApp.getActive().toast(msg, 'Flagging Emails', 8); } catch (e) {} }
