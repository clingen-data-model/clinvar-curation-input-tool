/**
 * CVC Impact Analysis Refresh — Apps Script Integration
 *
 * Add this to the existing Apps Script that finalizes batches.
 *
 * Two entry points:
 *   refreshCvcImpactAnalysis()       — Interactive: confirmation dialog + polling + result alerts
 *   refreshCvcImpactAnalysisSilent() — Programmatic: no dialogs, returns boolean, logs only
 *
 * Call the silent version from batch finalization code. Use the interactive
 * version from a menu item or button.
 *
 * SETUP:
 * 1. In the Apps Script editor, go to Services > Add a service > BigQuery API (v2)
 * 2. Add this code to the existing script
 * 3. Call refreshCvcImpactAnalysisSilent() after batch finalization,
 *    or add refreshCvcImpactAnalysis() to a menu for manual use
 *
 * The procedure takes 2-5 minutes to run. It rebuilds all 11 materialized
 * tables in the CVC Impact Analysis pipeline in dependency order.
 *
 * Uses Jobs.insert (async) instead of Jobs.query (sync) since the procedure
 * runs longer than the Apps Script UI timeout. The job is submitted, then
 * polled for completion.
 */

const IMPACT_CONFIG = {
  PROJECT_ID: 'clingen-dev',
  PROCEDURE: 'CALL `clinvar_curator.refresh_cvc_impact_analysis`()'
};

/**
 * Submits the BigQuery refresh job and polls for completion.
 * Core logic with no UI dialogs — results are logged only.
 *
 * @returns {boolean} true if successful, false if failed
 */
function refreshCvcImpactAnalysisSilent() {
  try {
    const job = {
      configuration: {
        query: {
          query: IMPACT_CONFIG.PROCEDURE,
          useLegacySql: false
        }
      }
    };

    const response = BigQuery.Jobs.insert(job, IMPACT_CONFIG.PROJECT_ID);
    const jobId = response.jobReference.jobId;
    Logger.log('Submitted impact analysis refresh job: ' + jobId);

    return pollForCompletionSilent_(jobId);

  } catch (error) {
    Logger.log('Impact analysis refresh error: ' + error.message);
    return false;
  }
}

/**
 * Interactive version: shows confirmation dialog, then calls the refresh
 * and displays result alerts. Use this from menu items or buttons.
 *
 * @returns {boolean} true if successful, false if failed or cancelled
 */
function refreshCvcImpactAnalysis() {
  const ui = SpreadsheetApp.getUi();

  const confirm = ui.alert(
    'Refresh Impact Analysis?',
    'This will rebuild all CVC impact analysis tables (2-5 minutes).\n\n' +
    'Continue?',
    ui.ButtonSet.YES_NO
  );

  if (confirm !== ui.Button.YES) return false;

  const success = refreshCvcImpactAnalysisSilent();

  if (success) {
    ui.alert(
      'Refresh Complete',
      'All CVC impact analysis tables have been rebuilt successfully.\n\n' +
      'Google Sheets charts will reflect the new data after refreshing ' +
      'the data connector (Data > Data connectors > Refresh data).',
      ui.ButtonSet.OK
    );
  } else {
    ui.alert(
      'Refresh Failed',
      'Error refreshing impact analysis tables. Check Apps Script logs for details.\n\n' +
      'Try running manually in BigQuery console:\n' +
      IMPACT_CONFIG.PROCEDURE,
      ui.ButtonSet.OK
    );
  }

  return success;
}

/**
 * Polls a BigQuery job until completion. No UI dialogs.
 * @param {string} jobId - The BigQuery job ID to poll
 * @returns {boolean} true if job completed successfully
 * @private
 */
function pollForCompletionSilent_(jobId) {
  const maxAttempts = 60; // 10 minutes at 10-second intervals

  for (let i = 0; i < maxAttempts; i++) {
    Utilities.sleep(10000); // 10 seconds

    const job = BigQuery.Jobs.get(IMPACT_CONFIG.PROJECT_ID, jobId);
    const status = job.status;

    if (status.state === 'DONE') {
      if (status.errorResult) {
        Logger.log('Impact analysis refresh failed: ' + status.errorResult.message);
        return false;
      }
      Logger.log('Impact analysis refresh completed successfully.');
      return true;
    }
  }

  Logger.log('Impact analysis refresh timed out after 10 minutes. Job ID: ' + jobId);
  return false;
}
