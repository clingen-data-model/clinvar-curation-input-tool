/**
 * CVC Resubmission Queue - Google Apps Script
 *
 * This script provides automation for the CVC Resubmission Tracking spreadsheet.
 *
 * SETUP:
 * 1. Open the Google Sheet
 * 2. Go to Extensions > Apps Script
 * 3. Paste this code
 * 4. Save and authorize the script
 * 5. Refresh the spreadsheet - a "CVC Tools" menu will appear
 *
 * REQUIREMENTS:
 * - Sheet named "Actionable - Extract" (extracted copy of Connected Sheet)
 * - Sheet named "Resubmission Queue" (created by Setup Queue Sheet)
 *
 * WORKFLOW:
 * 1. Create "Actionable" Connected Sheet from BigQuery view
 * 2. Extract to regular sheet: Data > Extract > Extract to new sheet
 * 3. Rename the extracted sheet to "Actionable - Extract"
 * 4. Select rows and use CVC Tools menu to add to queue
 *
 * NOTE: The script only works with "Actionable - Extract" sheet.
 * Connected Sheets do not support row selection, so extraction is required.
 */

// Configuration
const CONFIG = {
  EXTRACT_SHEET: 'Actionable - Extract',
  QUEUE_SHEET: 'Resubmission Queue',
  EXPORT_FOLDER_NAME: 'CVC Resubmission Exports'
};

// Queue sheet column headers
const QUEUE_HEADERS = [
  'SCV ID',
  'Current SCV Version',
  'Variation ID',
  'VCV ID',
  'Submitter ID',
  'Submitter Name',
  'Flagging Reason',
  'Source Tab',
  'Reviewed By',
  'Review Date',
  'Notes',
  'Status'
];

/**
 * Creates the custom menu when the spreadsheet opens
 */
function onOpen() {
  const ui = SpreadsheetApp.getUi();
  ui.createMenu('CVC Tools')
    .addItem('Add Selected to Queue', 'addSelectedToQueue')
    .addItem('Export Pending for Submission', 'exportPendingForSubmission')
    .addItem('Mark Selected as Submitted', 'markAsSubmitted')
    .addSeparator()
    .addItem('Highlight Queued SCVs', 'highlightQueuedScvs')
    .addItem('Clear Highlights', 'clearHighlights')
    .addSeparator()
    .addItem('Setup Queue Sheet', 'setupQueueSheet')
    .addItem('Help', 'showHelp')
    .addToUi();
}

/**
 * Creates the Resubmission Queue sheet with proper headers
 */
function setupQueueSheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let queueSheet = ss.getSheetByName(CONFIG.QUEUE_SHEET);

  if (queueSheet) {
    const ui = SpreadsheetApp.getUi();
    const response = ui.alert(
      'Queue Sheet Exists',
      'The Resubmission Queue sheet already exists. Do you want to clear it and start fresh?',
      ui.ButtonSet.YES_NO
    );

    if (response === ui.Button.YES) {
      queueSheet.clear();
    } else {
      return;
    }
  } else {
    queueSheet = ss.insertSheet(CONFIG.QUEUE_SHEET);
  }

  // Set headers
  const headerRange = queueSheet.getRange(1, 1, 1, QUEUE_HEADERS.length);
  headerRange.setValues([QUEUE_HEADERS]);
  headerRange.setFontWeight('bold');
  headerRange.setBackground('#4285f4');
  headerRange.setFontColor('white');

  // Set column widths
  queueSheet.setColumnWidth(1, 150);  // SCV ID
  queueSheet.setColumnWidth(2, 100);  // Version
  queueSheet.setColumnWidth(3, 100);  // Variation ID
  queueSheet.setColumnWidth(4, 120);  // VCV ID
  queueSheet.setColumnWidth(5, 100);  // Submitter ID
  queueSheet.setColumnWidth(6, 200);  // Submitter Name
  queueSheet.setColumnWidth(7, 200);  // Flagging Reason
  queueSheet.setColumnWidth(8, 100);  // Source Tab
  queueSheet.setColumnWidth(9, 100);  // Reviewed By
  queueSheet.setColumnWidth(10, 100); // Review Date
  queueSheet.setColumnWidth(11, 200); // Notes
  queueSheet.setColumnWidth(12, 100); // Status

  // Add data validation for Status column
  const statusRule = SpreadsheetApp.newDataValidation()
    .requireValueInList(['Pending', 'Submitted', 'Completed', 'Skipped'], true)
    .build();
  queueSheet.getRange('L2:L1000').setDataValidation(statusRule);

  // Freeze header row
  queueSheet.setFrozenRows(1);

  SpreadsheetApp.getUi().alert('Queue sheet created successfully!');
}

/**
 * Checks if the sheet name is the valid source sheet
 */
function isValidSourceSheet(sheetName) {
  return sheetName === CONFIG.EXTRACT_SHEET;
}

/**
 * Adds selected rows from the Actionable - Extract sheet to the queue.
 * Supports both contiguous block selections and non-contiguous selections
 * (e.g., Ctrl+click or Cmd+click to select random rows).
 */
function addSelectedToQueue() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const activeSheet = ss.getActiveSheet();
  const sheetName = activeSheet.getName();

  // Validate source sheet (must be "Actionable - Extract")
  if (!isValidSourceSheet(sheetName)) {
    SpreadsheetApp.getUi().alert(
      'Invalid Sheet',
      `Please select rows from the "${CONFIG.EXTRACT_SHEET}" sheet.\n\n` +
      'To create this sheet:\n' +
      '1. Open the "Actionable" Connected Sheet\n' +
      '2. Go to Data > Extract\n' +
      '3. Click "Extract to new sheet"\n' +
      '4. Rename the new sheet to "Actionable - Extract"',
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  // Get queue sheet
  let queueSheet = ss.getSheetByName(CONFIG.QUEUE_SHEET);
  if (!queueSheet) {
    SpreadsheetApp.getUi().alert(
      'Queue Not Found',
      'Please run "Setup Queue Sheet" first from the CVC Tools menu.',
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  // Get all selected ranges (supports non-contiguous selections with Ctrl/Cmd+click)
  const rangeList = activeSheet.getActiveRangeList();
  if (!rangeList) {
    SpreadsheetApp.getUi().alert('No selection found. Please select rows to add to the queue.');
    return;
  }

  // Collect all selected rows from all ranges
  const allSelectedRows = [];
  const ranges = rangeList.getRanges();

  for (const range of ranges) {
    const startRow = range.getRow();
    const numRows = range.getNumRows();

    // Skip if header row is included in this range
    if (startRow === 1) {
      // If range starts at header, skip row 1 but include rest
      if (numRows > 1) {
        const dataRange = activeSheet.getRange(2, 1, numRows - 1, activeSheet.getLastColumn());
        const rows = dataRange.getValues();
        rows.forEach((row, idx) => allSelectedRows.push({ row, rowNum: 2 + idx }));
      }
    } else {
      // Get full row data for each selected row
      const fullRowRange = activeSheet.getRange(startRow, 1, numRows, activeSheet.getLastColumn());
      const rows = fullRowRange.getValues();
      rows.forEach((row, idx) => allSelectedRows.push({ row, rowNum: startRow + idx }));
    }
  }

  if (allSelectedRows.length === 0) {
    SpreadsheetApp.getUi().alert('Please select data rows, not the header row.');
    return;
  }

  // Get header row to find column indices
  const headers = activeSheet.getRange(1, 1, 1, activeSheet.getLastColumn()).getValues()[0];

  // Map column names to indices (case-insensitive, trimmed)
  const colIndex = {};
  headers.forEach((h, i) => {
    if (h) {
      const normalized = h.toString().trim();
      colIndex[normalized] = i;
      // Also store lowercase version for flexible matching
      colIndex[normalized.toLowerCase()] = i;
    }
  });

  // Helper to find column index with flexible matching
  function findCol(name) {
    // Exact match first
    if (colIndex[name] !== undefined) return colIndex[name];
    if (colIndex[name.toLowerCase()] !== undefined) return colIndex[name.toLowerCase()];

    // Try variations without spaces/underscores
    const normalized = name.toLowerCase().replace(/[\s_-]/g, '');
    for (const key of Object.keys(colIndex)) {
      const keyNorm = key.toLowerCase().replace(/[\s_-]/g, '');
      if (keyNorm === normalized) {
        return colIndex[key];
      }
    }

    // Try partial match (contains)
    const lowerName = name.toLowerCase();
    for (const key of Object.keys(colIndex)) {
      if (key.toLowerCase().includes(lowerName) || lowerName.includes(key.toLowerCase())) {
        return colIndex[key];
      }
    }
    return undefined;
  }

  // Find SCV ID column - try multiple variations
  let scvIdCol = findCol('SCV ID');
  if (scvIdCol === undefined) scvIdCol = findCol('scv_id');
  if (scvIdCol === undefined) scvIdCol = findCol('SCVID');
  if (scvIdCol === undefined) scvIdCol = findCol('scv');

  // If still not found, look for any column containing 'scv' and 'id'
  if (scvIdCol === undefined) {
    for (let i = 0; i < headers.length; i++) {
      const h = (headers[i] || '').toString().toLowerCase();
      if (h.includes('scv') && (h.includes('id') || h === 'scv')) {
        scvIdCol = i;
        break;
      }
    }
  }

  if (scvIdCol === undefined) {
    SpreadsheetApp.getUi().alert(
      'Column Not Found',
      `Could not find SCV ID column.\n\nFound columns:\n${headers.filter(h => h).join('\n')}`,
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  // Get current user email (for reviewer)
  const userEmail = Session.getActiveUser().getEmail();
  const reviewer = userEmail.split('@')[0]; // Use part before @ as name
  const today = new Date();

  // Process selected rows
  const newQueueRows = [];

  // Get column indices for all fields we need
  // Try both display names (from Connected Sheets) and snake_case names (from extracts)
  const cols = {
    scvId: scvIdCol,
    version: findCol('Current SCV Version') ?? findCol('current_scv_ver'),
    variationId: findCol('Variation ID') ?? findCol('variation_id'),
    submitterId: findCol('Submitter ID') ?? findCol('submitter_id'),
    submitterName: findCol('Submitter Name') ?? findCol('submitter_name'),
    reason: findCol('Original Flagging Reason') ?? findCol('Flagging Reason') ?? findCol('flagging_reason')
  };

  for (const { row } of allSelectedRows) {
    // Skip empty rows (check if SCV ID exists)
    const scvId = cols.scvId !== undefined ? row[cols.scvId] : null;
    if (!scvId) continue;

    const queueRow = [
      scvId || '',
      cols.version !== undefined ? row[cols.version] || '' : '',
      cols.variationId !== undefined ? row[cols.variationId] || '' : '',
      '', // VCV ID - extract from link or use VCV ID column if available
      cols.submitterId !== undefined ? row[cols.submitterId] || '' : '',
      cols.submitterName !== undefined ? row[cols.submitterName] || '' : '',
      cols.reason !== undefined ? row[cols.reason] || '' : '',
      'Actionable', // Source tab
      reviewer,
      today,
      '', // Notes - blank for user to fill
      'Pending' // Status
    ];

    newQueueRows.push(queueRow);
  }

  if (newQueueRows.length === 0) {
    // Provide debugging info
    const debugInfo = [];
    debugInfo.push(`Selected ${allSelectedRows.length} row(s) across ${ranges.length} range(s)`);
    debugInfo.push(`SCV ID column index: ${cols.scvId}`);
    if (allSelectedRows.length > 0) {
      const firstRow = allSelectedRows[0].row;
      debugInfo.push(`First selected row (row ${allSelectedRows[0].rowNum}) has ${firstRow.length} columns`);
      debugInfo.push(`Value at SCV ID column: "${firstRow[cols.scvId]}"`);
      // Show first few values of the row
      debugInfo.push(`First 5 values: ${firstRow.slice(0, 5).map(v => `"${v}"`).join(', ')}`);
    }
    SpreadsheetApp.getUi().alert(
      'No Valid Rows Selected',
      `Could not find valid SCV IDs in your selection.\n\nDebug info:\n${debugInfo.join('\n')}`,
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  // Find next empty row in queue
  const lastRow = queueSheet.getLastRow();
  const nextRow = lastRow + 1;

  // Add rows to queue
  queueSheet.getRange(nextRow, 1, newQueueRows.length, QUEUE_HEADERS.length)
    .setValues(newQueueRows);

  SpreadsheetApp.getUi().alert(
    'Success',
    `Added ${newQueueRows.length} SCV(s) to the Resubmission Queue.`,
    SpreadsheetApp.getUi().ButtonSet.OK
  );
}

/**
 * Exports all "Pending" items from the queue as a CSV
 */
function exportPendingForSubmission() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const queueSheet = ss.getSheetByName(CONFIG.QUEUE_SHEET);

  if (!queueSheet) {
    SpreadsheetApp.getUi().alert('Queue sheet not found. Please run Setup Queue Sheet first.');
    return;
  }

  // Get all data
  const data = queueSheet.getDataRange().getValues();
  const headers = data[0];

  // Find status column index
  const statusIndex = headers.indexOf('Status');
  const scvIdIndex = headers.indexOf('SCV ID');
  const versionIndex = headers.indexOf('Current SCV Version');
  const variationIdIndex = headers.indexOf('Variation ID');
  const submitterIdIndex = headers.indexOf('Submitter ID');
  const reasonIndex = headers.indexOf('Flagging Reason');

  // Filter for Pending status
  const pendingRows = data.slice(1).filter(row => row[statusIndex] === 'Pending');

  if (pendingRows.length === 0) {
    SpreadsheetApp.getUi().alert('No pending items found in the queue.');
    return;
  }

  // Create export data with submission-ready format
  const exportHeaders = ['scv_id', 'scv_ver', 'variation_id', 'submitter_id', 'reason'];
  const exportData = [exportHeaders];

  for (const row of pendingRows) {
    exportData.push([
      row[scvIdIndex],
      row[versionIndex],
      row[variationIdIndex],
      row[submitterIdIndex],
      row[reasonIndex]
    ]);
  }

  // Convert to CSV
  const csv = exportData.map(row => row.map(cell => `"${cell}"`).join(',')).join('\n');

  // Create file in Drive
  const timestamp = Utilities.formatDate(new Date(), 'America/New_York', 'yyyy-MM-dd_HHmmss');
  const fileName = `cvc_resubmission_${timestamp}.csv`;

  // Find or create export folder
  let folder;
  const folders = DriveApp.getFoldersByName(CONFIG.EXPORT_FOLDER_NAME);
  if (folders.hasNext()) {
    folder = folders.next();
  } else {
    folder = DriveApp.createFolder(CONFIG.EXPORT_FOLDER_NAME);
  }

  const file = folder.createFile(fileName, csv, MimeType.CSV);

  SpreadsheetApp.getUi().alert(
    'Export Complete',
    `Exported ${pendingRows.length} pending SCV(s) to:\n\n` +
    `Folder: ${CONFIG.EXPORT_FOLDER_NAME}\n` +
    `File: ${fileName}\n\n` +
    `File URL: ${file.getUrl()}`,
    SpreadsheetApp.getUi().ButtonSet.OK
  );
}

/**
 * Marks selected rows in the queue as "Submitted"
 */
function markAsSubmitted() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const activeSheet = ss.getActiveSheet();

  if (activeSheet.getName() !== CONFIG.QUEUE_SHEET) {
    SpreadsheetApp.getUi().alert(
      'Invalid Sheet',
      'Please select rows in the "Resubmission Queue" sheet.',
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  const selection = activeSheet.getActiveRange();
  const startRow = selection.getRow();
  const numRows = selection.getNumRows();

  if (startRow === 1) {
    SpreadsheetApp.getUi().alert('Please select data rows, not the header row.');
    return;
  }

  // Get headers to find Status column
  const headers = activeSheet.getRange(1, 1, 1, activeSheet.getLastColumn()).getValues()[0];
  const statusCol = headers.indexOf('Status') + 1; // 1-indexed

  // Update status for selected rows
  for (let i = 0; i < numRows; i++) {
    activeSheet.getRange(startRow + i, statusCol).setValue('Submitted');
  }

  SpreadsheetApp.getUi().alert(`Marked ${numRows} row(s) as Submitted.`);
}

/**
 * Highlights rows in the Actionable - Extract sheet that are already in the queue
 */
function highlightQueuedScvs() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const queueSheet = ss.getSheetByName(CONFIG.QUEUE_SHEET);

  if (!queueSheet) {
    SpreadsheetApp.getUi().alert('Queue sheet not found. Please run Setup Queue Sheet first.');
    return;
  }

  const extractSheet = ss.getSheetByName(CONFIG.EXTRACT_SHEET);
  if (!extractSheet) {
    SpreadsheetApp.getUi().alert(
      'Extract Sheet Not Found',
      `Could not find "${CONFIG.EXTRACT_SHEET}" sheet.\n\n` +
      'To create this sheet:\n' +
      '1. Open the "Actionable" Connected Sheet\n' +
      '2. Go to Data > Extract\n' +
      '3. Click "Extract to new sheet"\n' +
      '4. Rename the new sheet to "Actionable - Extract"',
      SpreadsheetApp.getUi().ButtonSet.OK
    );
    return;
  }

  // Get all SCV IDs from the queue
  const queueData = queueSheet.getDataRange().getValues();
  const queuedScvIds = new Set();

  // Skip header row, get SCV IDs (column A)
  for (let i = 1; i < queueData.length; i++) {
    const scvId = queueData[i][0];
    if (scvId) {
      queuedScvIds.add(scvId.toString().trim());
    }
  }

  if (queuedScvIds.size === 0) {
    SpreadsheetApp.getUi().alert('No SCVs found in the queue.');
    return;
  }

  // Highlight matching rows in the extract sheet
  const count = highlightMatchingRows(extractSheet, queuedScvIds);

  const message = count > 0
    ? `Highlighted ${count} row(s) in "${CONFIG.EXTRACT_SHEET}".\n\nTotal SCVs in queue: ${queuedScvIds.size}`
    : `No matching rows found.\n\nTotal SCVs in queue: ${queuedScvIds.size}`;

  SpreadsheetApp.getUi().alert('Highlighting Complete', message, SpreadsheetApp.getUi().ButtonSet.OK);
}

/**
 * Helper function to highlight rows matching queued SCV IDs
 */
function highlightMatchingRows(sheet, queuedScvIds) {
  if (!sheet) return 0;

  const data = sheet.getDataRange().getValues();
  if (data.length <= 1) return 0;

  // Find SCV ID column (look for "SCV ID" or "scv_id" in header)
  const headers = data[0];
  let scvIdCol = headers.findIndex(h => h === 'SCV ID');
  if (scvIdCol === -1) scvIdCol = headers.findIndex(h => h === 'scv_id');
  if (scvIdCol === -1) scvIdCol = headers.findIndex(h =>
    h && h.toString().toLowerCase().includes('scv') && h.toString().toLowerCase().includes('id')
  );
  if (scvIdCol === -1) return 0;

  // Get the number of columns for the range
  const numCols = sheet.getLastColumn();

  let highlightCount = 0;

  // Check each row and apply highlighting
  for (let i = 1; i < data.length; i++) {
    const scvId = data[i][scvIdCol];
    const rowNum = i + 1;

    if (scvId && queuedScvIds.has(scvId.toString().trim())) {
      // Highlight the entire row light green
      sheet.getRange(rowNum, 1, 1, numCols).setBackground('#d9ead3');
      highlightCount++;
    }
  }

  return highlightCount;
}

/**
 * Clears all highlighting from the Actionable - Extract sheet
 */
function clearHighlights() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const extractSheet = ss.getSheetByName(CONFIG.EXTRACT_SHEET);

  if (!extractSheet) {
    SpreadsheetApp.getUi().alert(`Sheet "${CONFIG.EXTRACT_SHEET}" not found.`);
    return;
  }

  const lastRow = extractSheet.getLastRow();
  const lastCol = extractSheet.getLastColumn();

  if (lastRow > 1) {
    extractSheet.getRange(2, 1, lastRow - 1, lastCol).setBackground(null);
    SpreadsheetApp.getUi().alert(`Cleared highlights from "${CONFIG.EXTRACT_SHEET}".`);
  } else {
    SpreadsheetApp.getUi().alert('No data rows to clear.');
  }
}

/**
 * Shows help information
 */
function showHelp() {
  const help = `
CVC Resubmission Queue Tools

SETUP:
1. Create "Actionable" Connected Sheet from BigQuery view
2. Extract data: Data > Extract > Extract to new sheet
3. Rename the extracted sheet to "Actionable - Extract"

WORKFLOW:
1. Review SCVs in "Actionable - Extract" (use filters to narrow down)
2. Select rows you want to resubmit
3. Click CVC Tools > Add Selected to Queue
4. Click CVC Tools > Highlight Queued SCVs to see what's queued
5. Review the Resubmission Queue tab and add notes
6. Click CVC Tools > Export Pending for Submission
7. After submission, select rows and click Mark as Submitted

HIGHLIGHTING:
- "Highlight Queued SCVs" colors rows green in the Extract sheet
- "Clear Highlights" removes the coloring

TIPS:
- Select multiple contiguous rows with Shift+click
- Select non-contiguous rows with Ctrl+click (Windows) or Cmd+click (Mac)
- Both selection methods work with "Add Selected to Queue"
- The queue tracks who reviewed each SCV and when
- Exported files are saved to "${CONFIG.EXPORT_FOLDER_NAME}" in your Drive
- Status options: Pending, Submitted, Completed, Skipped

CONDITIONAL FORMATTING (Alternative to script highlighting):
To auto-highlight queued SCVs using native Sheets formatting:
1. Select all data rows in "Actionable - Extract" (e.g., A2:Z1000)
2. Format > Conditional formatting
3. Format cells if: Custom formula is
4. Formula: =COUNTIF('Resubmission Queue'!$A:$A,$A2)>0
5. Set background color to light green (#d9ead3)
6. Click Done

For issues, contact the ClinVar data team.
  `;

  SpreadsheetApp.getUi().alert('CVC Tools Help', help, SpreadsheetApp.getUi().ButtonSet.OK);
}
