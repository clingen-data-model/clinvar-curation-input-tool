-- =============================================================================
-- CVC Flagging Status Report (by Submitter) -- parameterized table functions
-- =============================================================================
--
-- Purpose:
--   Reports the state of every SCV that CVC has submitted to ClinVar as a
--   "flagging candidate", as of a given ClinVar release date. Each SCV is in
--   one of three states:
--
--     - "flagged submission"         : the flag is applied (rank = -3) in the
--                                      report release.
--     - "removed flagged submission" : the SCV was flagged (rank = -3) at some
--                                      point but is no longer flagged in the
--                                      report release (the flag was removed).
--     - "flagging candidate"         : submitted to and processed by ClinVar but
--                                      never flagged (still pending, or superseded
--                                      by a newer submitter version).
--
--   Reproduces the submitter email-notification columns (SCV | Reason | Notes |
--   Curation date), enriched with submitter id/name, state, lifecycle dates and
--   two "aging" representations.
--
-- Packaging (table functions, so a report_release_date can be passed in):
--   - clinvar_curator.cvc_flagging_status_report_fn(report_release_date DATE)
--       Detail: one row per SCV (analysis-friendly snake_case columns).
--   - clinvar_curator.cvc_flagging_status_by_submitter_fn(report_release_date DATE)
--       Summary: one row per submitter x state, with an aging-bucket matrix.
--   - clinvar_curator.sheets_flagging_status_report_fn(report_release_date DATE)
--       Email-style column names for direct Looker Studio / Sheets consumption.
--
--   report_release_date: any date; snapped to the most recent AVAILABLE release
--   on or before it via clinvar_ingest.schema_on(). Pass NULL for the latest
--   release. (schema_on reflects releases whose data is materialized -- the same
--   universe as clinvar_scvs. Do NOT use clinvar_ingest.clinvar_releases: it is
--   a periodically-refreshed external-table copy that can lag the real data.)
--
-- Looker Studio / Connected Sheets usage (parameter + refresh):
--   Use a Custom Query and expose @report_release_date as a report parameter:
--
--     SELECT * FROM `@@DATASET@@.sheets_flagging_status_report_fn`(@report_release_date)
--
--   Changing the control (or refreshing) re-runs the query against the chosen
--   release. Pass a DATE; use CURRENT_DATE() as the parameter default for latest.
--
-- Ad-hoc usage:
--   SELECT * FROM `@@DATASET@@.cvc_flagging_status_report_fn`(NULL);
--   SELECT * FROM `@@DATASET@@.cvc_flagging_status_report_fn`(DATE '2026-06-27');
--   SELECT * FROM `@@DATASET@@.cvc_flagging_status_by_submitter_fn`(DATE '2026-06-27');
--
-- Lifecycle dates (kept distinct):
--   - curation_date        : curator's annotation date. Typically 30-60 days
--                            before the flag-release date (annotate -> 60-day
--                            grace period -> flag appears next release).
--   - batch_accepted_date  : when ClinVar accepted/processed the flagging
--                            candidate (SCV not yet in a release as flagged).
--                            Aging anchor for pending candidates.
--   - first_flagged_date   : the FIRST release containing this SCV's flagged
--                            (rank = -3) record -- the true "date flagged", NOT
--                            the submitted/processed date. Aging anchor for
--                            flagged submissions.
--   - flag_removed_date    : the first non-flagged release AFTER the last flagged
--                            release -- the release the flag was removed. Aging
--                            anchor for "removed flagged submission" rows.
--
-- Aging (both emitted):
--   - days_in_state : days between the report release and the state anchor date.
--   - aging_bucket  : 0-30 / 31-60 / 61-90 / 91-180 / 181-365 / 365+ days.
--   - grace_status  : (candidates) within vs past the 60-day grace window.
--
-- Scope / notes:
--   - Only non-rejected CVC flagging candidates are included, so NCBI-originated
--     flags are excluded.
--   - Deduplicated to the MOST RECENT flagging-candidate submission per SCV.
--   - Submissions listed in clinvar_curator.cvc_flagging_report_suppressions
--     (a manual hide list keyed by scv_id + scv_ver + batch_id) are removed
--     BEFORE dedup, so hiding one batch's submission still lets a newer
--     submission for the same SCV (a different batch) appear.
--   - Two "resolved" categories are INTENTIONALLY EXCLUDED from all output:
--       1. candidates overridden by a newer submitter version
--          (disposition 'never flagged — overridden by new submission version'), and
--       2. flagged submissions intentionally removed via a CVC "remove flagged
--          submission" request (removal_requested_date present).
--     Flags removed for other reasons (e.g. submitter version bump, no CVC remove
--     request) are retained as "removed flagged submission" rows.
--   - `was_ever_flagged` = (first_flagged_date IS NOT NULL). "flagging candidate"
--     rows are always never-flagged; a flag that was applied and later removed is
--     its own state, "removed flagged submission".
--   - "flagging candidate" rows carry a `candidate_disposition` (NULL for flagged
--     and removed-flagged rows). Values that survive the exclusion filter:
--       * 'pending flag (within grace period)'  -- still legitimately awaiting
--       * 'never flagged — past grace, no flag applied'
--                                               -- past grace, still our version
--     ('never flagged — overridden by new submission version' is computed but the
--      rows are excluded upstream, so it never appears in output.)
--   - SCVs that no longer exist in the report release (submitter deleted) are
--     excluded (they are not "removed flagged submissions" -- the SCV itself is
--     gone, not just its flag).
--   - Flagged submissions get `pending_removal` = TRUE when a non-rejected
--     "remove flagged submission" request for the same SCV was submitted on or
--     before the report date but the flag is still applied.
--
-- Dependencies:
--   - clinvar_curator.cvc_clinvar_submissions
--   - clinvar_curator.cvc_annotations_view
--   - clinvar_curator.cvc_batches_enriched
--   - clinvar_curator.cvc_rejected_scvs
--   - clinvar_curator.cvc_flagging_report_suppressions (deploy 10-flagging-report-suppressions.sql first)
--   - clinvar_ingest.clinvar_scvs
--   - clinvar_ingest.schema_on (TVF; snaps report date to an available release)
--   - clinvar_ingest.clinvar_submitters
--
-- =============================================================================


-- =============================================================================
-- Detail TVF: one row per SCV
-- =============================================================================

CREATE OR REPLACE TABLE FUNCTION `@@DATASET@@.cvc_flagging_status_report_fn`(report_release_date DATE)
AS (
  WITH
  -- Resolve the effective release once (snap to an available release).
  params AS (
    SELECT release_date AS effective_release_date
    FROM `clinvar_ingest.schema_on`(COALESCE(report_release_date, CURRENT_DATE()))
  ),

  -- All non-rejected CVC flagging-candidate submissions that were processed
  -- (accepted) by ClinVar on or before the report release date.
  flagging_submissions AS (
    SELECT
      s.scv_id,
      CAST(s.scv_ver AS INT64) AS submitted_scv_ver,
      s.batch_id,
      s.annotation_id,
      a.submitter_id,
      a.variation_id,
      a.vcv_id,
      a.reason,
      a.notes,
      a.curator,
      a.annotated_date,
      a.annotation_release_date,
      b.batch_accepted_date,
      b.grace_period_end_date
    FROM `@@DATASET@@.cvc_clinvar_submissions` s
    JOIN `@@DATASET@@.cvc_annotations_view` a
      ON s.annotation_id = a.annotation_id
    JOIN `@@DATASET@@.cvc_batches_enriched` b
      ON s.batch_id = b.batch_id
    CROSS JOIN params p
    LEFT JOIN `@@DATASET@@.cvc_rejected_scvs` r
      ON s.batch_id = r.batch_id
      AND s.scv_id = r.scv_id
      AND s.scv_ver = r.scv_ver
    -- Manually-maintained hide list, scoped to a specific submission
    -- (scv_id + scv_ver + batch_id). A newer submission for the same SCV in a
    -- future batch is a different key and is NOT suppressed.
    LEFT JOIN `@@DATASET@@.cvc_flagging_report_suppressions` sup
      ON sup.scv_id = s.scv_id
      AND sup.scv_ver = CAST(s.scv_ver AS INT64)
      AND sup.batch_id = s.batch_id
    WHERE a.action = 'flagging candidate'
      AND r.scv_id IS NULL                                  -- not rejected by NCBI
      AND sup.scv_id IS NULL                                -- not on the hide list
      -- Point-in-time gate: exclude batches processed AFTER the report date.
      AND b.batch_accepted_date <= p.effective_release_date
  ),

  -- Keep only the most recent submission per SCV (operative reason/notes/date).
  latest_submission AS (
    SELECT *
    FROM flagging_submissions
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY scv_id
      ORDER BY batch_accepted_date DESC, annotation_id DESC
    ) = 1
  ),

  -- State of each SCV in the report release (version + rank).
  scv_at_report AS (
    SELECT
      scv.id AS scv_id,
      scv.version AS report_version,
      scv.rank AS report_rank,
      scv.classification_abbrev AS report_classification
    FROM `clinvar_ingest.clinvar_scvs` scv
    CROSS JOIN params p
    WHERE p.effective_release_date BETWEEN scv.start_release_date AND scv.end_release_date
  ),

  -- First release (on or before the report date) in which the SCV was flagged.
  first_flagged AS (
    SELECT
      scv.id AS scv_id,
      MIN(scv.start_release_date) AS first_flagged_date,
      MAX(scv.start_release_date) AS last_flagged_date
    FROM `clinvar_ingest.clinvar_scvs` scv
    CROSS JOIN params p
    WHERE scv.rank = -3
      AND scv.start_release_date <= p.effective_release_date
    GROUP BY scv.id
  ),

  -- For SCVs that were flagged but are no longer flagged in the report release,
  -- the release the flag was removed = the first non-flagged release AFTER the
  -- last flagged release (on or before the report date). This is the aging
  -- anchor for "removed flagged submission" rows.
  flag_removed AS (
    SELECT
      scv.id AS scv_id,
      MIN(scv.start_release_date) AS flag_removed_date
    FROM `clinvar_ingest.clinvar_scvs` scv
    CROSS JOIN params p
    JOIN first_flagged ff
      ON ff.scv_id = scv.id
    WHERE scv.rank != -3
      AND scv.start_release_date > ff.last_flagged_date
      AND scv.start_release_date <= p.effective_release_date
    GROUP BY scv.id
  ),

  -- Non-rejected "remove flagged submission" requests submitted on or before the
  -- report date. Annotate a still-flagged SCV as pending removal (Scenario 7).
  remove_flagged_requests AS (
    SELECT
      s.scv_id,
      b.batch_accepted_date AS removal_requested_date,
      s.batch_id AS removal_batch_id,
      a.reason AS removal_reason,
      a.notes AS removal_notes
    FROM `@@DATASET@@.cvc_clinvar_submissions` s
    JOIN `@@DATASET@@.cvc_annotations_view` a
      ON s.annotation_id = a.annotation_id
    JOIN `@@DATASET@@.cvc_batches_enriched` b
      ON s.batch_id = b.batch_id
    CROSS JOIN params p
    LEFT JOIN `@@DATASET@@.cvc_rejected_scvs` r
      ON s.batch_id = r.batch_id
      AND s.scv_id = r.scv_id
      AND s.scv_ver = r.scv_ver
    WHERE a.action = 'remove flagged submission'
      AND r.scv_id IS NULL
      AND b.batch_accepted_date <= p.effective_release_date
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY s.scv_id
      ORDER BY b.batch_accepted_date DESC, s.annotation_id DESC
    ) = 1
  ),

  report_base AS (
    SELECT
      p.effective_release_date,
      ls.submitter_id,
      ls.scv_id,
      ls.submitted_scv_ver,
      ls.variation_id,
      ls.vcv_id,
      ls.batch_id,
      ls.annotation_id,
      ls.reason,
      ls.notes,
      ls.curator,
      ls.annotated_date,
      ls.batch_accepted_date,
      ls.grace_period_end_date,
      sar.report_version,
      sar.report_rank,
      sar.report_classification,
      ff.first_flagged_date,
      fr.flag_removed_date,
      -- Three states:
      --   flagged submission         -> flag is applied (rank = -3) in the release
      --   removed flagged submission -> was flagged (rank = -3) at some point but
      --                                 no longer flagged in the report release
      --   flagging candidate         -> submitted, never flagged (still pending or
      --                                 superseded by a newer submitter version)
      CASE
        WHEN sar.report_rank = -3 THEN 'flagged submission'
        WHEN ff.first_flagged_date IS NOT NULL THEN 'removed flagged submission'
        ELSE 'flagging candidate'
      END AS scv_state,
      (sar.report_version > ls.submitted_scv_ver) AS submitter_responded
    FROM latest_submission ls
    CROSS JOIN params p
    -- Must still exist in the report release (submitter-deleted SCVs dropped here).
    JOIN scv_at_report sar
      ON ls.scv_id = sar.scv_id
    LEFT JOIN first_flagged ff
      ON ls.scv_id = ff.scv_id
    LEFT JOIN flag_removed fr
      ON ls.scv_id = fr.scv_id
  ),

  report_aged AS (
    SELECT
      rb.*,
      -- Anchor date for aging in the current state:
      --   flagged submission         -> first_flagged_date (release flag applied)
      --   removed flagged submission -> flag_removed_date (release flag removed)
      --   flagging candidate         -> batch_accepted_date (submitted/processed)
      CASE rb.scv_state
        WHEN 'flagged submission'         THEN rb.first_flagged_date
        WHEN 'removed flagged submission' THEN rb.flag_removed_date
        ELSE rb.batch_accepted_date
      END AS state_anchor_date,
      DATE_DIFF(
        rb.effective_release_date,
        CASE rb.scv_state
          WHEN 'flagged submission'         THEN rb.first_flagged_date
          WHEN 'removed flagged submission' THEN rb.flag_removed_date
          ELSE rb.batch_accepted_date
        END,
        DAY
      ) AS days_in_state
    FROM report_base rb
  ),

  report_out AS (
  SELECT
    ra.effective_release_date AS report_release_date,
    ra.submitter_id,
    COALESCE(sub.current_name, CONCAT('Unknown submitter (', ra.submitter_id, ')')) AS submitter_name,
    ra.scv_state,
    -- Email-style core fields -------------------------------------------------
    ra.scv_id,
    ra.submitted_scv_ver,
    CONCAT(ra.scv_id, '.', CAST(ra.submitted_scv_ver AS STRING)) AS scv_accession,  -- e.g. SCV004820909.2
    ra.reason,
    ra.notes,
    ra.annotated_date AS curation_date,
    -- Context -----------------------------------------------------------------
    ra.variation_id,
    ra.vcv_id,
    ra.curator,
    ra.batch_id,
    ra.batch_accepted_date,
    ra.grace_period_end_date,
    -- First release the flag was introduced (NULL for never-flagged candidates).
    ra.first_flagged_date,
    -- Release the flag was removed (only for "removed flagged submission" rows).
    ra.flag_removed_date,
    ra.report_version AS current_scv_ver,
    ra.report_rank AS current_rank,
    ra.report_classification AS current_classification,
    ra.submitter_responded,
    (ra.first_flagged_date IS NOT NULL) AS was_ever_flagged,
    -- Disposition of a "flagging candidate" row (never flagged, so
    -- first_flagged_date IS NULL). NULL for flagged / removed-flagged rows, which
    -- have their own scv_state. The dominant past-grace cause is the submitter
    -- superseding our submitted version with a newer one.
    CASE
      WHEN ra.scv_state != 'flagging candidate' THEN NULL
      -- submitter put out a newer version than the one we submitted
      WHEN ra.report_version > ra.submitted_scv_ver THEN 'never flagged — overridden by new submission version'
      -- still inside the grace window (legitimately awaiting)
      WHEN ra.effective_release_date <= ra.grace_period_end_date THEN 'pending flag (within grace period)'
      -- past grace, still the submitted version (flag never applied)
      ELSE 'never flagged — past grace, no flag applied'
    END AS candidate_disposition,
    -- Aging: anchor + Option A (continuous) -----------------------------------
    ra.state_anchor_date,
    ra.days_in_state,
    -- Aging: Option B (buckets) -----------------------------------------------
    CASE
      WHEN ra.days_in_state IS NULL THEN 'unknown'
      WHEN ra.days_in_state <= 30  THEN '0-30 days'
      WHEN ra.days_in_state <= 60  THEN '31-60 days'
      WHEN ra.days_in_state <= 90  THEN '61-90 days'
      WHEN ra.days_in_state <= 180 THEN '91-180 days'
      WHEN ra.days_in_state <= 365 THEN '181-365 days'
      ELSE '365+ days'
    END AS aging_bucket,
    -- Grace-period context (meaningful for pending candidates) ----------------
    CASE
      WHEN ra.scv_state = 'flagged submission'         THEN 'n/a (flagged)'
      WHEN ra.scv_state = 'removed flagged submission' THEN 'n/a (removed)'
      WHEN ra.effective_release_date <= ra.grace_period_end_date THEN 'within grace period'
      ELSE 'past grace period'
    END AS grace_status,
    GREATEST(DATE_DIFF(ra.effective_release_date, ra.grace_period_end_date, DAY), 0) AS days_past_grace,
    -- Pending-removal annotation ----------------------------------------------
    (ra.report_rank = -3 AND rfr.scv_id IS NOT NULL) AS pending_removal,
    rfr.removal_requested_date,
    rfr.removal_batch_id,
    rfr.removal_reason,
    rfr.removal_notes
  FROM report_aged ra
  -- Resolve the submitter name with exactly one row per submitter id: prefer the
  -- active record, else the most recently deleted one (recovers removed orgs).
  LEFT JOIN (
    SELECT id, current_name
    FROM `clinvar_ingest.clinvar_submitters`
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY id
      ORDER BY (deleted_release_date IS NULL) DESC, end_release_date DESC
    ) = 1
  ) sub
    ON ra.submitter_id = sub.id
  LEFT JOIN remove_flagged_requests rfr
    ON ra.scv_id = rfr.scv_id
  )

  -- Intentionally exclude two "resolved" categories from the report:
  --   1. Flagging candidates overridden by a newer submitter version
  --      (candidate_disposition = 'never flagged — overridden by new submission version').
  --   2. Flagged submissions intentionally removed via a CVC "remove flagged
  --      submission" request (removal_requested_date IS NOT NULL). Flags that
  --      fell off for other reasons (e.g. a submitter version bump, no CVC remove
  --      request) are retained as "removed flagged submission" rows.
  SELECT *
  FROM report_out
  WHERE candidate_disposition IS DISTINCT FROM 'never flagged — overridden by new submission version'
    AND NOT (scv_state = 'removed flagged submission' AND removal_requested_date IS NOT NULL)
);


-- =============================================================================
-- Summary TVF: one row per submitter x state, with an aging-bucket matrix
-- =============================================================================

CREATE OR REPLACE TABLE FUNCTION `@@DATASET@@.cvc_flagging_status_by_submitter_fn`(report_release_date DATE)
AS (
  SELECT
    report_release_date,
    submitter_id,
    submitter_name,
    scv_state,
    COUNT(*) AS total_scvs,
    -- Aging matrix (Option B) -------------------------------------------------
    COUNTIF(aging_bucket = '0-30 days')     AS age_0_30,
    COUNTIF(aging_bucket = '31-60 days')    AS age_31_60,
    COUNTIF(aging_bucket = '61-90 days')    AS age_61_90,
    COUNTIF(aging_bucket = '91-180 days')   AS age_91_180,
    COUNTIF(aging_bucket = '181-365 days')  AS age_181_365,
    COUNTIF(aging_bucket = '365+ days')     AS age_365_plus,
    -- Continuous aging (Option A) ---------------------------------------------
    ROUND(AVG(days_in_state), 0) AS avg_days_in_state,
    MAX(days_in_state)           AS max_days_in_state,
    -- Grace + submitter activity context --------------------------------------
    COUNTIF(candidate_disposition = 'pending flag (within grace period)')          AS pending_in_grace,
    -- "never flagged" candidates still in the report (overridden-by-new-version
    -- candidates are intentionally excluded upstream, so they are not counted).
    COUNTIF(candidate_disposition = 'never flagged — past grace, no flag applied') AS never_flagged_past_grace,
    COUNTIF(submitter_responded) AS submitter_responded_count,
    -- Flagged submissions with a removal already requested but not yet applied.
    COUNTIF(pending_removal) AS flagged_pending_removal
  FROM `@@DATASET@@.cvc_flagging_status_report_fn`(report_release_date)
  GROUP BY report_release_date, submitter_id, submitter_name, scv_state
);


-- =============================================================================
-- Email-style TVF: submitter-facing column names (Looker Studio / Sheets)
-- =============================================================================
--
-- Mirrors the submitter email notification columns (SCV | Reason | Notes |
-- Curation date). Consume from a Looker Studio Custom Query:
--   SELECT * FROM `@@DATASET@@.sheets_flagging_status_report_fn`(@report_release_date)
-- =============================================================================

CREATE OR REPLACE TABLE FUNCTION `@@DATASET@@.sheets_flagging_status_report_fn`(report_release_date DATE)
AS (
  SELECT
    submitter_name                                   AS `Submitter`,
    submitter_id                                     AS `Submitter ID`,
    INITCAP(scv_state)                               AS `State`,
    candidate_disposition                            AS `Candidate disposition`,
    IF(was_ever_flagged, 'Yes', 'No')                AS `Ever flagged`,
    scv_accession                                    AS `SCV`,
    reason                                           AS `Reason`,
    COALESCE(notes, 'None')                          AS `Notes`,
    curation_date                                    AS `Curation date`,
    -- Lifecycle dates (kept distinct on purpose):
    --   Submitted/processed : ClinVar accepted the candidate (not yet flagged).
    --   Flag released       : first release containing the flagged (rank=-3) SCV.
    batch_accepted_date                              AS `Submitted or processed date`,
    first_flagged_date                               AS `Flag released date`,
    flag_removed_date                                AS `Flag removed date`,
    state_anchor_date                                AS `Aging since`,
    days_in_state                                    AS `Days in state`,
    aging_bucket                                     AS `Aging`,
    grace_status                                     AS `Grace status`,
    IF(submitter_responded, 'Yes', 'No')             AS `Submitter updated SCV`,
    IF(pending_removal, 'Yes — removal requested', 'No') AS `Pending removal`,
    removal_requested_date                           AS `Removal requested date`,
    removal_reason                                   AS `Removal reason`,
    CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', CAST(variation_id AS STRING)) AS `ClinVar Link`,
    report_release_date                              AS `Report release`
  FROM `@@DATASET@@.cvc_flagging_status_report_fn`(report_release_date)
);
