/**
 * Generate the file without finalizing the submissions.
 * Call finalizeBatch() to both generate and finalize submission.
 */
function generateOnly()
{
  generate(false);
}

/**
 * Generate file for next batch based on current assignments as of the datetime 
 * this is executed. And draft an email with that generated file attached.
 * And persist the assignments to the next-batch-id so that the next-batch-id
 * is incremented and a new review & submit process is started.
 * 
 * This is not intended to be undone by the user. A confirmation prompt will indicate this.
 * 
 */
function finalizeBatch()
{

  const generationResult = generate(true);
  // if the generation was cancelled or no rows were found to submit, return
  if (generationResult.count <= 0) {
    return;
  }

  createDraftEmail(generationResult);


  /**
   * prompt the user to determine to confirm the email was created 
   * as expected, if not do not "complete" the finalization process
   */

  /**
   * determine if there are any review records that have no status.
   * If so, warn user and stop the finalization process.
   */
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let revSubSheet = ss.getSheetByName("Review & Submit");
  var allData = revSubSheet.getRange('C2:E').getValues();
  var unreviewedData = allData.filter(function (row) {
    // test that all valid rows (annotation_id is not empty) have valid statuses
    return row[0] && (!row[2] || !["OK","Fixed","Archive"].includes(row[2]));  
  }); 
  
  const ui = SpreadsheetApp.getUi();
  if (unreviewedData.length) {
    const msg =
      `WARNING: there are one or more records that have no review status or are set to 'Question'.

      A complete review is indicated with a status of 'OK', 'Fixed' or 'Archive'.

      Select: 
      'OK' to continue which will leave the entries marked 'Question' or left unreviewed.
        OR
      'Cancel' to stop the finalization process and continue reviewing (or removing unreviewed entries)`
    
    const reply = ui.alert("Warning Unfinished Reviews Exist", msg,  ui.ButtonSet.OK_CANCEL);

    if (reply == ui.Button.CANCEL) {
      return;
    }
  }

  const msg =
    `Please verify that the submission email was drafted, the batch 
      submission file is attached and that file has the expected contents. 

      Continuing will finalize this batch submission, preserve 
      the reviews and prepare this google sheet for the next batch.

      Do you wish to continue?`

  const confirmed = ui.alert("Finalize Batch Confirmation", msg,  ui.ButtonSet.YES_NO);
  //if the user does not wish to finalize the batch, return
  if (confirmed == ui.Button.NO) {
    return;
  }
  /**
     * To finalize, we must do the following...
     * 1. MOVE the submissions, batch and review records from external to standard tables in BQ
     * 2. Update the next_batch_id and last_finalized_date.
     * 3. refresh the data in the sheet overall (call refresh() method). 
     */
  const insert_sql_stmts =[


    // batches, apply additional derivative data fields to assist with downstream processes
    `insert into clinvar_curator.cvc_clinvar_batches 
    SELECT
      "${generationResult.batchId}" as batch_id,
      TIMESTAMP('${generationResult.generatedDatetime}') as finalized_datetime,
      rel.release_date as batch_release_date,
      DATE(e.finalized_datetime)+1 AS batch_start_date,
      DATE(DATETIME('${generationResult.generatedDatetime}')) as batch_end_date,
      clinvar_ingest.determineMonthBasedOnRange(
        DATE(e.finalized_datetime)+1, 
        DATE(DATETIME('${generationResult.generatedDatetime}'))
      ) as submission
    FROM
        clinvar_curator.cvc_clinvar_batches e,
        clinvar_ingest.release_on(DATE(DATETIME('${generationResult.generatedDatetime}'))) rel
    WHERE e.batch_id < "${generationResult.batchId}"
    ORDER BY
        e.batch_id DESC
    LIMIT 1`,

    // submissions
    `insert into clinvar_curator.cvc_clinvar_submissions 
    select * 
    from clinvar_curator.cvc_clinvar_submissions_sheet e 
    where 
        e.annotation_id not in 
        (select s.annotation_id from clinvar_curator.cvc_clinvar_submissions s)`,

    // reviews
    `insert into clinvar_curator.cvc_clinvar_reviews 
    select 
        annotation_id,
        date_added,
        status,
        reviewer,
        notes,
        date_last_updated,
        "${generationResult.batchId}" batch_id
    from clinvar_curator.cvc_clinvar_reviews_sheet e 
    where 
        e.annotation_id not in 
        (select s.annotation_id from clinvar_curator.cvc_clinvar_reviews s)
      and
        (status IN ('OK','Archive','Fixed'))`
  ]
  insert_sql_stmts.forEach((insert_sql) => {
    copy_new_records_into(insert_sql);
  });

  const sheet_names = ["Submissions","Review & Submit"]
  // remove the records from the batches, submissions and reviews 
  sheet_names.forEach((sheet_name) => {
      let s = ss.getSheetByName(sheet_name);
    clearSheet(s, 1);
  });

  // set next batch_id and last_finalized_date
  ss.getRangeByName('next_batch_id').setValue(Number(generationResult.batchId)+1);
  ss.getRangeByName('mostRecentSubmittedBatchGeneration').setValue(generationResult.generatedDatetime);

  // refresh the external data connector sheet(s) to allow the moved data to be updated in the QC Annotation sheet.
  refresh();

  /**
   * add/remove data from the Submissions!A:D and 'Review & Submit'!C:C ranges 
   * to force the recalc of the calculated cols on the cvc_annotations_as_of_extract sheet
   * (specifically cols with headers "batch_id", "reviewer", "rev_status", & "reviewed_or_reviewing")
   */
  // on Submissions!A:D, set and restore a value on A2 so that the header is not lost
  let rng1 = ss.getRangeByName('Submissions!A2:A2')
  let origVal1 = rng1.getValue();
  rng1.setValue('x');
  rng1.setValue(origVal1);

  // on 'Review & Submit'!C:C set and restore a value on C2 so that the header is not lost
  let rng2 = ss.getRangeByName(`'Review & Submit'!C2:C2`)
  let origVal2 = rng2.getValue();
  rng2.setValue('x');
  rng2.setValue(origVal2);

}

function clearSheet(sheet, headerRows) {
  const rowCount = sheet.getLastRow();

  // no data, return
  if ((rowCount - headerRows) <= 0) return;

  // the R & S sheet is special and contains formulae and unreviewed items that should never be removed automatically
  if (sheet.getName() === 'Review & Submit') {
    // these are the R & S cols that need to be cleared.
    const cols = ["C","D","E","F","G","H",];
    // Define the full data range, including the header which we will skip in processing
    var lastRow = sheet.getLastRow();
    var range = sheet.getRange('A2:O' + lastRow);
    var values = range.getValues();
    var rowsToClear = [];

    // Iterate through rows, skipping the header
    for (var i = 0; i < values.length; i++) {
      var row = values[i];

      if (row[2] !== '' && (row[4] === 'OK' || row[4] === 'Archive' || row[4] === 'Fixed')) {
        cols.forEach((col) => {
          c = getIndexByColumn(col);
          // clear the specific cells
          sheet.getRange(i+2, c + 1, 1, 1).setValue(null);
        });
      }
    }
    // re-sort sheet after one or more rows have been removed
    range = sheet.getRange("2:"+sheet.getLastRow());
    range.sort([12,15]);
    clearCheckboxes(sheet,1,1);
  }
  else if (sheet.getName() === 'Batches' || sheet.getName() === 'Submissions') {
    // clear entire sheet (except headerRows)
    const colCount = sheet.getLastColumn();
    const emptyRows = Array(rowCount-headerRows).fill(Array(colCount)); 
    sheet.getRange(headerRows+1, 1, emptyRows.length, colCount).setValues(emptyRows);
  }

  return;
}

function getIndexByColumn(letter) {
  var column = 0, length = letter.length;
  letter = letter.toUpperCase();
  for (var i = 0; i < length; i++){
    column += (letter.charCodeAt(i) - 64) * Math.pow(26, length - i - 1);
  }
  return column - 1;
}

/**
* Moves the records from a google sheet range defined as a bq external table to a 
* corresponding standard bq table with the same name except for the "_sheet" suffix.
* 
* Insert all the records from the external table `clinvar_curator.cvc_clinvar_{$table_name}_sheet`
* into the standard table `clinvar_curator.cvc_clinvar_{$table_name}`.
* Then delete all the records form the external table `clinvar_curator.cvc_clinvar_{$table_name}_sheet`
*/
function copy_new_records_into(insert_sql) {

  // Cloud Platform project.
  const projectId = 'clingen-dev';

  const request = {
    query: insert_sql,
    useLegacySql: false
  };
  let queryResults = BigQuery.Jobs.query(request, projectId);
  const jobId = queryResults.jobReference.jobId;
  console.log(jobId);

  // Check on status of the Query Job.
  let sleepTimeMs = 500;
  while (!queryResults.jobComplete) {
    Utilities.sleep(sleepTimeMs);
    sleepTimeMs *= 2;
    queryResults = BigQuery.Jobs.getQueryResults(projectId, jobId);
  }
}


/**
 * Execute a BQ query that will capture all the annotations assigned to the 
 * 'next_batch_id' and format them in the clinvar annotation submission json format
 * separated by new line delimiters and saved to a statically defined
 * shared google drive found here 
 *     https://drive.google.com/drive/folders/1w_hncksAMGAmVIVVDJVD3M0fGVj4KL80
 * 
 * After the query runs it will prompt the user to indicate the number of 
 * annotations that will be saved to the file and the filename w/ link
 * for the user to confirm whether they want to continue.
 * 
 * If the user continues with the processing, the processed 'next_batch_id'
 * will be persisted so that it is not used for the next `next_batch_id`
 * 
 * @param {boolean} isFinal whether this is the final submission for the batch
 * 
 * @returns {any} an object with the status of the generation, the batch id, the number of annotations included in the file, the file object, and the date the file was generated  
 */
function generate(isFinal)
{
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const nextBatchId = ss.getRangeByName('next_batch_id').getValue().toString();
  console.log(nextBatchId);

  // Create a new Date object
  const today = new Date();
  // Get the year, month, and day from the Date object
  const year = today.getFullYear();
  const month = String(today.getMonth() + 1).padStart(2, '0');
  const day = String(today.getDate()).padStart(2, '0');
  const hour = String(today.getHours()).padStart(2, '0');
  const minute = String(today.getMinutes()).padStart(2, '0');
  const second = String(today.getSeconds()).padStart(2, '0');
  // Format the date as "YYYY-MM-DD"
  // const todayYYYYMMDD = `${year}-${month}-${day}`;
  const todayYYYYMMDDHHMMSS = `${year}-${month}-${day} ${hour}:${minute}:${second}`;
  
  // Cloud Platform project.
  const projectId = 'clingen-dev';
  const sql = 
    `WITH x AS 
      (SELECT 
        cvc.variation_id as \`Variation ID\`, 
        cvc.vcv_id as VCV, 
        cvc.scv_id||'.'||cvc.scv_ver as \`SCV ID\`, 
        cvc.submitter_id as \`Submitter ID\`, 
        cvc.action as Action, 
        cvc.reason as Reason, 
        REPLACE(cvc.notes, '\\n', ' ') as Notes, 
        FORMAT_TIMESTAMP('%FT%TZ', cvc.annotated_on) as \`Timestamp\` , 
        cvc.as_of_date as \`Date Created\`, 
        cvc.annotation_release_date as \`ClinVar Release Date\`, 
        cvc.is_outdated_scv as \`Is Annotation Outdated\`, 
        cvc.is_deleted_scv as \`Is Annotated SCV Deleted\`, 
        cvc.deleted_scv_release_date as \`SCV Deleted Release Date\` 
      FROM \`clinvar_curator.cvc_annotations\`("unreviewed") cvc
      JOIN \`clinvar_curator.cvc_clinvar_submissions_sheet\` ccs ON ccs.annotation_id = cvc.annotation_id
      where ccs.batch_id = "${nextBatchId}"
    )
    select TO_JSON_STRING(x) FROM x`
  console.log(sql);

  const request = {
    query: sql,      
    useLegacySql: false
  };
  let queryResults = BigQuery.Jobs.query(request, projectId);
  const jobId = queryResults.jobReference.jobId;
  console.log(jobId);

  // Check on status of the Query Job.
  let sleepTimeMs = 500;
  while (!queryResults.jobComplete) {
    Utilities.sleep(sleepTimeMs);
    sleepTimeMs *= 2;
    queryResults = BigQuery.Jobs.getQueryResults(projectId, jobId);
  }

  // Get all the rows of results.
  let rows = queryResults.rows;
  while (queryResults.pageToken) {
    queryResults = BigQuery.Jobs.getQueryResults(projectId, jobId, {
      pageToken: queryResults.pageToken
    });
    rows = rows.concat(queryResults.rows);
  }

  // determine the name of the file to generate and if it already exists and will be replaced.
  const jsonOutputFilename=`clinvar-annotation-submission-${nextBatchId}-${year}${month}${day}.json`;
  const clinvarSubmissionSharedFolderId = "1w_hncksAMGAmVIVVDJVD3M0fGVj4KL80"
  const dir = DriveApp.getFolderById( clinvarSubmissionSharedFolderId );
  const existingFiles = dir.getFilesByName(jsonOutputFilename);

  const ui = SpreadsheetApp.getUi(); // Same variations.
  let result = confirmJsonFileGeneration((!rows?0:rows.length), jsonOutputFilename, isFinal, existingFiles.hasNext())

  const retVal = {
    batchId: nextBatchId,
    count: (result == ui.Button.CANCEL ? -1 : rows.length),
    file: null,
    generatedDatetime: null
  };

  if (retVal.count > 0)  {

    // Trash the file(s) with the same name if they exists 
    while(existingFiles.hasNext()) {
      // ID of the file to be generated
      const previousGeneratedFileId = existingFiles.next().getId();
      // Trash before writing new file below
      Drive.Files.trash(previousGeneratedFileId, {supportsAllDrives: true});
    }
  
    // Append the results into one large text 'content' string
    let content = ""
    for (let i = 0; i < rows.length; i++) {
      const cols = rows[i].f;
      content += cols[0].v + '\n';
    }
    // create the new file
    const file = dir.createFile(jsonOutputFilename, content);
    console.log('Results json file created: %s', jsonOutputFilename);

    retVal.file = file;
    retVal.generatedDatetime = todayYYYYMMDDHHMMSS;
  }
  console.log(retVal);
  return retVal;
}

/**
 * Draft submission email in invoking user's google mail account.
 * 
 * @param {any} generationResult the results returned from the generate() function.
 * 
 * @returns {void}
 */
function createDraftEmail(generationResult)
{
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const recipientRows = ss.getRangeByName('submissionRecipients').getValues();
  const recipients = recipientRows.map(x => x[0]).filter(x => x).join(", ");
  console.log(recipients);
  const ccRecipientsRows = ss.getRangeByName('submissionCcRecipients').getValues();
  const ccRecipients = ccRecipientsRows.map(x => x[0]).filter(x => x).join(", ");
  console.log(ccRecipients);

  // Create a draft email with a file from Google Drive attached as a PDF.
  var file = DriveApp.getFileById(generationResult.file.getId());
  var msg = `Melissa & Kuljeet -\nHere is our next batch of ${generationResult.count} ClinGen ClinVar Annotations which we finalized for submission on ${generationResult.generatedDatetime}.\n\nPlease let us know if you have any questions or concerns.`;
  var subject = `ClinGen's Clinvar annotation submission #${generationResult.batchId}`;
  
  GmailApp.createDraft(recipients, subject, msg, {
      cc : ccRecipients,
      attachments: [generationResult.file.getBlob()],
      name: 'ClinGen Annotation of ClinVar Submission script'
  });

  return;

}

/**
 * A confirmation dialogue to allow the user to confirm or
 * cancel the generation and persistence of the generated
 * json file for the 'next batch id' 
 * 
 * @param {number} annotationCount the number of annotations that will be included in the file   
 * @param {string} jsonOutputFileName the name of the file to be generated  
 * @param {boolean} isFinal whether this is the final submission for the batch  
 * @param {boolean} fileExists whether the file already exists and will be replaced 
 * 
 * @returns the user response from the confirmation dialogue either Button.OK or Button.CANCEL
 */
function confirmJsonFileGeneration(annotationCount, jsonOutputFileName, isFinal, fileExists) {
  
  const ui = SpreadsheetApp.getUi(); // Same variations.
  const dialogueTitle = `ClinVar Submission Batch ${isFinal?"Finalization":"Generation"}`;
  
  if (annotationCount == 0) {
    // show "informational dialogue if nothing was selected"
    const msg = `No reviewed annotations have been assigned to the next batch. 
      To generate a file at least one record must be assigned (+).`
    return ui.alert(dialogueTitle, msg,  ui.ButtonSet.OK);
  }
  var finalMsgAddOn = "";
  if (isFinal) {
    finalMsgAddOn = `
    Additionally an email will be drafted for submitting it to ClinVar.

    NOTE: You will NOT be able to re-generate this batch again without administrative assistance.
    `;
  }
  const msg = `${annotationCount} reviewed annotation(s) will ${fileExists ? "replace the file(s) named" : "create a new file named"} '${jsonOutputFileName}' in the 'Clinvar Submissions' folder found here => 
    
  https://drive.google.com/drive/folders/1w_hncksAMGAmVIVVDJVD3M0fGVj4KL80
  ${finalMsgAddOn}
  Do you want to continue?`;
    
  return ui.alert(dialogueTitle, msg, ui.ButtonSet.OK_CANCEL);
}


