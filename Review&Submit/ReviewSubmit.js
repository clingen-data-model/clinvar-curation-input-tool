// Define constants for action values
const ACTION_NO_CHANGE = "no change";
const ACTION_FLAGGING_CANDIDATE = "flagging candidate";
const ACTION_REMOVE_FLAGGED_SUBMISSION = "remove flagged submission";
const REVSTAT_FLAGGED_SUBMISSION = "flagged submission";

/**
 * Displays a dialogue box with information about the 
 * Add, Remove, Assign, and Unassign actions.
 * 
 * @param {number[]} validRows - An array of valid row numbers.
 * @param {number[]} invalidRows - An array of invalid row numbers.
 * @param {string} action - The transfer action ('add', 'remove', 'assign', or 'unassign').
 * @returns {void} - Returns nothing.
 */
function transferDialogue(validRows, invalidRows, action) {
  
  let ui = SpreadsheetApp.getUi(); // Same variations.
  let buttonSet = (validRows.length > 0 ? ui.ButtonSet.OK_CANCEL : ui.ButtonSet.OK);
  let dialogueTitle = `${action.charAt(0).toUpperCase() + action.slice(1)} Review & Submit Records`;
  // +1 to row numbers so that they correlate with the visual display
  let valid = validRows.map(entry => entry + 1);
  let invalid = invalidRows.map(entry => entry + 1);

  action = action.toLowerCase();
  let pastTenseAction = action + (action == 'remove' ? 'd' : 'ed');
  let invalidReason = `require${invalid.length > 1 ? "" : "s"} the status to be 'OK', the action to be either '${ACTION_FLAGGING_CANDIDATE}' or '${ACTION_REMOVE_FLAGGED_SUBMISSION}' AND can not already be assigned to the batch`;
  if (action == 'add') {
    invalidReason = "exists in Review & Submit";
  }
  else if (action == 'remove') {
    invalidReason = `${invalid.length > 1 ? "are" : "is" } assigned to the batch`;
  }
  else if (action == 'unassign') {
    invalidReason = `${invalid.length > 1 ? "are" : "is" } not assigned to the batch`;
  }
  
  if ((validRows.length + invalidRows.length) == 0) {
    // show "informational dialogue if nothing was selected"
    return ui.alert(dialogueTitle, `No records were selected. To ${action} records select one or more checkboxes in Col A first.`, buttonSet);
  }
  
  let disallowedMsg = "";
  if (invalid.length == 1 ) {
    disallowedMsg = `The selected record on row [${invalid[0]}] ${invalidReason}. It will NOT be ${pastTenseAction} and it will be unchecked.`;
  }
  // limit the number of row numbers displayed to 5
  else if (invalid.length > 1 && invalid.length < 6) {
    disallowedMsg = `${invalid.length} selected records on rows [${invalid}] ${invalidReason}. These will NOT be ${pastTenseAction} and they will be unchecked.`;
  }
  else if (invalid.length > 5) {
    disallowedMsg = `${invalid.length} selected records ${invalidReason}. These will NOT be ${pastTenseAction} and they will be unchecked.`;
  }

  let allowedMsg = "";
  if (valid.length == 1) {
    allowedMsg = `The selected record on row [${valid[0]}] will be ${pastTenseAction}.\n\nDo you wish to continue?`;
  }
  // limit the number of row numbers displayed to 5
  else if (valid.length > 1 && valid.length < 6) {
    allowedMsg = `${valid.length} selected records on rows [${valid}] will be ${pastTenseAction}.\n\nDo you wish to continue?`;
  }
  else if (valid.length > 5) {
    allowedMsg = `${valid.length} selected records will be ${pastTenseAction}.\n\nDo you wish to continue?`;
  }
  
  let msg = "";
  if (allowedMsg == "") {
    msg = disallowedMsg;
  }
  else if (disallowedMsg == "") {
    msg = allowedMsg;
  }
  else {
    msg = `NOTE: ${disallowedMsg}\n\n${allowedMsg}`;
  }
  
  return ui.alert(dialogueTitle, msg, buttonSet);
}


/**
 * Assigns selected rows to the next batch for review and submission.
 */
function assignToNextBatch() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const revSubSheetName = "Review & Submit";
  const revSubSheet = ss.getActiveSheet();
  if (revSubSheet.getName() != revSubSheetName) {
    return;
  }

  const revSubSheetData = revSubSheet.getDataRange().getDisplayValues();
 
  // construct a data array of the key col values that have been checked (A = TRUE)
  var validRows = new Array();
  var invalidRows = new Array();
  var selectedRows = new Array();
  var nextBatchId = ss.getRangeByName('next_batch_id').getValue().toString();

  revSubSheetData.forEach((rowVals, row) => {
    // get checkbox cell from each row
    var selected = rowVals[0];
    
    if (selected === 'TRUE') {
      var submittedBatchId = Number(rowVals[8]);
      var action = rowVals[16];
      var reviewStatus = rowVals[4];

      if (submittedBatchId || !reviewStatus || (reviewStatus !== 'OK') || (![ACTION_FLAGGING_CANDIDATE, ACTION_REMOVE_FLAGGED_SUBMISSION].includes(action))) {
        invalidRows.push(row);
      }
      else
      {
        // create new rows
        var newRow = [
          Number(rowVals[2]),
          rowVals[11],
          rowVals[12],
          nextBatchId
        ];
        selectedRows.push(newRow);
        validRows.push(row);
      }
    }
  });

  let ui = SpreadsheetApp.getUi();
  let result = transferDialogue(validRows,invalidRows, "Assign");

  // console.log(result);

  if (result == ui.Button.OK) {
    // console.log(selectedRows);
    if ( selectedRows.length > 0) {
      let submissionsSheet = ss.getSheetByName("Submissions");
      submissionsSheet.getRange(submissionsSheet.getLastRow()+1, 1, selectedRows.length, 4).setValues(selectedRows);
      submissionsSheet.sort(2);
    }
    clearCheckboxes(revSubSheet,1, 1);
  }
  else if (result == ui.Button.CANCEL) {
    // do nothing
  }

  return;
}

/**
 * Unassigns selected submissions from the active `Review & Submit` sheet 
 * from the next available batch id if and only if it is already assigned
 * to the next available batch id.
 */
function unassignFromNextBatch() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const revSubSheetName = "Review & Submit";
  const revSubSheet = ss.getActiveSheet();
  if (revSubSheet.getName() != revSubSheetName) {
    return;
  }

  const revSubSheetData = revSubSheet.getDataRange().getDisplayValues();
 
  // construct a data array of the key col values that have been checked (A = TRUE)
  var validRows = new Array();
  var invalidRows = new Array();
  var millisToUnassign = new Array();
  var nextBatchId = ss.getRangeByName('next_batch_id').getValue();

  revSubSheetData.forEach((rowVals, row) => {
    // get checkbox cell from each row
    var selected = rowVals[0];
    
    if(selected === 'TRUE') {
      var submittedBatchId = Number(rowVals[8]);

      if ((submittedBatchId !== nextBatchId)) {
        invalidRows.push(row);
      }
      else
      {
        // capture millis_id to be unassigned
        millisToUnassign.push(Number(rowVals[2]));
        validRows.push(row);
      }
    }
  });

  let ui = SpreadsheetApp.getUi();
  let result = transferDialogue(validRows,invalidRows, "Unassign");

  if (result == ui.Button.OK) {

    if (millisToUnassign.length > 0) {
      var submissionsSheet = ss.getSheetByName("Submissions");
      var values = submissionsSheet.getDataRange().getValues();
      const resetRow = [new Array(4)];
      var foundCnt = 0;

      for(var i = values.length ; ((i >= 1) && (millisToUnassign.length > foundCnt)); --i) { //bottom-up loop thru submissions data
        let thisMillisId = values[i-1][0];
        if ( thisMillisId && millisToUnassign.includes(thisMillisId) ) {
          // reset the row
          submissionsSheet.getRange(i,1,1,4).setValues(resetRow);
          // stop looping once all millis have been reset
          foundCnt++;
        }
      }
      // re-sort submittedAnnotationsRange after one or more rows have been removed
      submissionsSheet.sort(2);
    }
    
    // mass-set all checkbox values to FALSE
    clearCheckboxes(revSubSheet,1, 1);

  }
  else if (result == ui.Button.CANCEL) {
    // do nothing
  }

  return;
}
