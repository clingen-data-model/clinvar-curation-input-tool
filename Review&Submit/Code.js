/**
 * Event handler triggered when a cell is edited.
 * @param {Object} e - The event object containing information about the edit event.
 */
function onEdit(e) {
  const revSubmSheetName = "Review & Submit";
  var sheet = e.source.getActiveSheet();
  var editedColumn = e.range.getColumn();
  
  // if cols 5, 6 or 7 are one of the edited cells in the "Review & Submit" sheet....
  if((sheet.getName() === revSubmSheetName) && (editedColumn >= 5 || editedColumn <= 7)) {
    // update the last updated datetime every time a review status value is changed.
    var row = e.range.getRow();

    // if the status column is not empty then update the date otherwise remove it.
    var now = null;
    if(sheet.getRange(row,5).getValue() != "") {
      now = new Date();
    }
    sheet.getRange(row,8).setValue(now);
  }
}

const ANNO_EXTRACT_SHEET_NAME = "cvc_annotations_as_of_extract";
const LAST_REFRESH_EXEC_RANGE_NAME = "lastRefreshExecutedAt";

/**
 * Refreshes the review sheet with the latest annotations.
 */
function refresh() {
  refreshAnnotations();
  var currentdate = new Date(); 
  var lastRefreshExecutedAt = SpreadsheetApp.getActiveSpreadsheet().getRangeByName(LAST_REFRESH_EXEC_RANGE_NAME);
  lastRefreshExecutedAt.setValue("Last Refresh Exec: " + formatDate(currentdate, true));
}

/**
 * Refreshes the annotations data.
 */
function refreshAnnotations() {
  SpreadsheetApp.enableAllDataSourcesExecution();
  refreshDataSourceTable(ANNO_EXTRACT_SHEET_NAME);
  appendNewToReviews();
}

function refreshDataSourceTable(sheetName) {
  var annotationSheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(sheetName);
  var dataSourceTable = annotationSheet.getDataSourceTables()[0];
  dataSourceTable.refreshData();
  dataSourceTable.waitForCompletion(60);
}

function appendNewToReviews() {
  const IN_REVIEW_COL = 25;   // col Z in extract sheet
  const ANNOTATION_ID_COL = 0;
  const CURATOR_COL = 8;
  const ACTION_COL = 9;
  const LATEST_ANNO_COL = 12;
  const OUTDATED_SCV_COL = 14;
  const CLASSIF_DIFF_COL = 16;
  const DELETED_SCV_COL = 17;
  const REVIEW_STATUS_COL = 23;

  const REVIEWERS_RANGE_NAME = "reviewers";
  const REVIEW_AND_SUBMIT_SHEET_NAME = "Review & Submit";

  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const annoExtractSheet = ss.getSheetByName(ANNO_EXTRACT_SHEET_NAME);
  const annoExtractData = annoExtractSheet.getDataRange().getDisplayValues();
  
  const newAnnoData = annoExtractData.filter(rec => !rec[IN_REVIEW_COL]);

  // Initialize the current datetime and reviewers list
  const nowDateTime = new Date();
  const reviewers = transpose(ss.getRangeByName(REVIEWERS_RANGE_NAME).getDisplayValues())[0];

  let selectedRows = [];
  newAnnoData.forEach((rowVals, row) => {  
    const curator = rowVals[CURATOR_COL];
    const action = rowVals[ACTION_COL];
    const latestAnno = rowVals[LATEST_ANNO_COL];
    const outdatedSCV = rowVals[OUTDATED_SCV_COL];
    const classifDiff = rowVals[CLASSIF_DIFF_COL];
    const deletedSCV = rowVals[DELETED_SCV_COL];
    const revstat = rowVals[REVIEW_STATUS_COL];

    const newRow = [Number(rowVals[ANNOTATION_ID_COL]), nowDateTime, "", "", "", ""]; // Initialize newRow with 6 elements

    // Default values for status and note
    let status = "";
    let note = "";

    // Helper function to set status and note
    function setStatus(newStatus, newNote) {
      status = newStatus;
      note = newNote;
    }

    // Check conditions for status and note
    if (deletedSCV === "Yes") {
      setStatus("Archive", "SCV has been deleted by submitter.");
    } else if (latestAnno !== "Yes") {
      setStatus("", "A newer annotation for this SCV takes precedence. Please verify that it is intentional.");
    } else if (outdatedSCV === "Yes" && classifDiff !== "") {
      setStatus("", "Re-curation needed. SCV classification has been updated by submitter.");
    } else if (action === ACTION_NO_CHANGE) {
      setStatus("OK", `Latest '${ACTION_NO_CHANGE}' actions auto reviewed for all curators, even if outdated as long as SCV has no classification change.`);
    } else if (action === ACTION_FLAGGING_CANDIDATE && revstat === REVSTAT_FLAGGED_SUBMISSION) {
      setStatus("", `Review needed. This '${ACTION_FLAGGING_CANDIDATE}' is on an SCV that is already a '${REVSTAT_FLAGGED_SUBMISSION}'.`);
    } else if (action === ACTION_REMOVE_FLAGGED_SUBMISSION && revstat !== REVSTAT_FLAGGED_SUBMISSION) {
      setStatus("", `Review needed. This '${ACTION_REMOVE_FLAGGED_SUBMISSION}' is on an SCV that is NOT a '${REVSTAT_FLAGGED_SUBMISSION}'.`);
    } else if (![ACTION_NO_CHANGE, ACTION_FLAGGING_CANDIDATE, ACTION_REMOVE_FLAGGED_SUBMISSION].includes(action)) {
      setStatus("", "Error: Invalid or missing action. Inform development team.");
    } else if (outdatedSCV === "Yes") {
      setStatus("", "Re-curation needed. SCV has been updated by submitter with no classification change.");
    } else if (reviewers.includes(curator)) {
      setStatus("OK", "Curator's annotation does not require manual review.");
    } else {
      setStatus("", "Review needed. Curator's annotation requires manual review.");
    }

    // Assign status and note to newRow
    newRow[2] = status;
    newRow[4] = note;

    // Update newRow based on status
    if (status !== "") {
      newRow[3] = "auto*";
      newRow[5] = nowDateTime;
    }

    // Add the new row to the selectedRows array for inclusion
    selectedRows.push(newRow);

  });

  if (selectedRows.length > 0) {
    const revSubSheet = ss.getSheetByName(REVIEW_AND_SUBMIT_SHEET_NAME);
    const VCV_ID_COL = 11;
    const SCV_ID_COL = 12;
    const ANNO_DATE_TIME_COL = 15;

    let lastRow = getLastRow_(revSubSheet, 3);
    revSubSheet.getRange(lastRow + 1, 3, selectedRows.length, 6).setValues(selectedRows);

    // Re-sort the sheet after rows have been added
    let range = revSubSheet.getRange("2:" + revSubSheet.getLastRow());
    range.sort([VCV_ID_COL, SCV_ID_COL, {column: ANNO_DATE_TIME_COL, ascending: false}]);
  }
}

/**
* Gets the transposed representation of a 2d array.
*
* @param {matrix} 2d array to be transposed
* @return {Array} The transposition of the 2d `matrix` array param
*/
function transpose(matrix) {
  return matrix[0].map((col, i) => matrix.map(row => row[i]));
}

/**
* Gets the position of the last row that has visible content in a column of the sheet.
* When column is undefined, returns the last row that has visible content in any column.
*
* @param {Sheet} sheet A sheet in a spreadsheet.
* @param {Number} columnNumber Optional. The 1-indexed position of a column in the sheet.
* @return {Number} The 1-indexed row number of the last row that has visible content.
*/
function getLastRow_(sheet, columnNumber) {
  // version 1.5, written by --Hyde, 4 April 2021
  const values = (
    columnNumber
      ? sheet.getRange(1, columnNumber, sheet.getLastRow() || 1, 1)
      : sheet.getDataRange()
  ).getDisplayValues();
  let row = values.length - 1;
  while (row && !values[row].join('')) row--;
  return row + 1;
}

/**
 * Formats the given date into a string representation.
 * @param {Date} thisDate - The date to be formatted.
 * @param {boolean} inclTime - Whether to include the time in the formatted string.
 * @returns {string} The formatted date string.
 */
function formatDate(thisDate, inclTime) {
  const long = {
    hour12: false,
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    month: "short",
    year: "numeric",
  };
  const short = {
    hour12: false,
    day: "numeric",
    month: "short",
    year: "numeric",
  };
  var fdate = thisDate.toLocaleString("en-us", inclTime?long:short);
  return fdate;
}

// this method assumes all values in the colIdx will be set to FALSE - except header row 1 (use setValues())
/**
* Assumes the column at given position contains checkboxes of which their values should be set to FALSE.
*
* @param {sheet} the sheet containing a column of checkboxes
* @param {headerRows} the number of header rows (can be 0) these will not be included in the reset.
* @param {colPos} the 1-based index of the column that contains the checkboxes
*/
function clearCheckboxes(sheet, headerRows, colPos) {
  sheet.getRange(headerRows+1,colPos,sheet.getMaxRows()-headerRows).setValue(false); 
}

function clearAllCheckboxes() {
  const checkboxSheets = ["Review & Submit"];
  const s = SpreadsheetApp.getActiveSpreadsheet().getActiveSheet();
  if (checkboxSheets.includes(s.getName())) {
    clearCheckboxes(s,1,1);
  }
  return;
}
