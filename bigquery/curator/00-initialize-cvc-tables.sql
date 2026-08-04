-- TABLES to support the clinvar curation dashboard, reporting and downstream processing

CREATE TABLE `clinvar_curator.cvc_clinvar_reviews`
(
  annotation_id STRING,
  date_added TIMESTAMP,
  status STRING,
  reviewer STRING,
  notes STRING,
  date_last_updated TIMESTAMP,
  batch_id STRING
)
;

CREATE TABLE `clinvar_curator.cvc_clinvar_submissions`
(
  annotation_id STRING,
  scv_id STRING,
  scv_ver STRING,
  batch_id STRING
)
;

CREATE TABLE `clinvar_curator.cvc_clinvar_batches`
(
  batch_id STRING,
  finalized_datetime TIMESTAMP
)
;

-- VIEWS to support the clinvar curation dashboard, reporting and downstream processing

-- before running the materialized view the clinvar_annotations_native table must be
-- created using the setup-external-tables.sh script and the scheduling job should be
-- setup to refresh it from the underlying google sheet table


-- ============================================================================
-- Materialized View: clinvar_curator.cvc_annotations_base_mv
--
-- Description:
--   This materialized view consolidates and enriches ClinVar curation annotation
--   records for downstream analysis and reporting. It joins annotation data with
--   release metadata, clinical significance mappings, review statuses, and batch
--   submission information. The view provides normalized and derived fields such
--   as annotation and review labels, action abbreviations, and flags for review
--   and submission status. It is intended to serve as a comprehensive base for
--   curation workflows and reporting in the ClinVar curation system.
--
-- Source Tables:
--   - clinvar_curator.clinvar_annotations_native
--   - clinvar_ingest.all_releases_materialized
--   - clinvar_ingest.scv_clinsig_map
--   - clinvar_ingest.status_definitions
--   - clinvar_curator.cvc_clinvar_submissions
--   - clinvar_curator.cvc_clinvar_reviews
--   - clinvar_curator.cvc_clinvar_batches
--
-- Key Features:
--   - Normalizes and parses annotation and submission identifiers.
--   - Maps clinical significance and review status to standardized forms.
--   - Derives user-friendly labels for annotations and reviews.
--   - Flags records as reviewed or submitted.
--   - Handles edge cases in release date logic to avoid date overflow errors.
--
-- Usage:
--   Use this view as a base for querying curated ClinVar annotation data,
--   including review and submission status, for reporting and analysis.
-- ============================================================================
CREATE OR REPLACE MATERIALIZED VIEW clinvar_curator.cvc_annotations_base_mv
AS
WITH anno AS (
  SELECT
    CAST(UNIX_MILLIS(a.annotation_date) AS STRING) AS annotation_id,
    rel.release_date AS annotation_release_date,
    a.vcv_id AS vcv_axn,
    -- Using REGEXP_EXTRACT is a supported alternative to SPLIT + OFFSET
    REGEXP_EXTRACT(a.scv_id, r'([^.]*)') AS scv_id,
    SAFE_CAST(REGEXP_EXTRACT(a.scv_id, r'\.([0-9]+)$') AS INT64) AS scv_ver,
    REGEXP_EXTRACT(a.vcv_id, r'([^.]*)') AS vcv_id,
    SAFE_CAST(REGEXP_EXTRACT(a.vcv_id, r'\.([0-9]+)$') AS INT64) AS vcv_ver,
    CAST(a.variation_id AS STRING) AS variation_id,
    CAST(a.submitter_id AS STRING) AS submitter_id,
    LOWER(a.action) AS action,
    REGEXP_EXTRACT(a.curator_email, r'([^@]+)') AS curator,
    a.annotation_date AS annotated_on,
    DATE(a.annotation_date) AS annotated_date,
    a.reason,
    a.notes,
    CASE LOWER(a.action)
      WHEN 'flagging candidate' THEN 'flag'
      WHEN 'no change' THEN 'no chg'
      WHEN 'remove flagged submission' THEN 'rem flg sub'
      ELSE 'unk'
    END AS action_abbrev,
    LEFT(a.reason, 25) || IF(LENGTH(a.reason) > 25, '...', '') AS reason_abbrev,
    a.review_status AS clinvar_review_status,
    a.ignore,
    map.cv_clinsig_type as clinsig_type,
    def.rank
  FROM `clinvar_curator.clinvar_annotations_native` AS a
  JOIN `clinvar_ingest.all_releases_materialized` AS rel
    ON a.annotation_date >= TIMESTAMP(rel.release_date + INTERVAL 1 DAY)
    -- This logic prevents the date overflow error for the max date
    AND (
      rel.next_release_date = DATE('9999-12-31')
      OR a.annotation_date < TIMESTAMP(rel.next_release_date + INTERVAL 1 DAY)
    )
  LEFT JOIN `clinvar_ingest.scv_clinsig_map` map
    ON map.scv_term = LOWER(a.interpretation)
  LEFT JOIN `clinvar_ingest.status_definitions` def
    ON LOWER(a.review_status) = def.review_status
    -- Temporal logic: Ensure the rank matches the name valid at time of annotation
    AND DATE(a.annotation_date) BETWEEN def.start_release_date AND def.end_release_date
),
anno_review AS (
  SELECT
    a.*,
    rev.reviewer,
    rev.status AS review_status,
    rev.notes AS review_notes,
    IF(
      rev.annotation_id IS NULL, NULL,
      FORMAT(
        '%s (%s)%s',
        COALESCE(rev.status, 'n/a'),
        COALESCE(rev.reviewer, 'n/a'),
        COALESCE(CONCAT(' *', sub.batch_id, '*'), '')
      )
    ) AS review_label,
    rev.batch_id,
    DATE(b_rev.finalized_datetime) AS batch_date,
    b_rev.batch_release_date,
    (sub.annotation_id IS NOT NULL) AS is_submitted
  FROM anno AS a
  LEFT JOIN `clinvar_curator.cvc_clinvar_submissions` AS sub
    ON sub.annotation_id = a.annotation_id
  LEFT JOIN `clinvar_curator.cvc_clinvar_reviews` AS rev
    ON rev.annotation_id = a.annotation_id
  LEFT JOIN `clinvar_curator.cvc_clinvar_batches` AS b_rev
    ON b_rev.batch_id = rev.batch_id
)
SELECT
  ar.*,
  FORMAT(
    '%t (%s) %s: %s',
    ar.annotated_date,
    COALESCE(ar.curator, 'n/a'),
    ar.action_abbrev,
    COALESCE(ar.reason_abbrev, 'n/a')
  ) AS annotation_label,
  (ar.batch_id IS NOT NULL) AS is_reviewed
FROM anno_review AS ar
;

-- ============================================================================
-- View: clinvar_curator.cvc_annotations_view
--
-- Description:
--   This view provides a convenient interface to the materialized view
--   `cvc_annotations_base_mv`, adding an `is_latest` flag to indicate whether
--   each annotation is the most recent for its SCV ID within a batch.
--   The `is_latest` field is computed using an analytic function that checks
--   if there are any later annotations for the same SCV ID and batch.
--
-- Usage:
--   Use this view to easily filter for the latest annotation per SCV in each batch,
--   or to access all annotation records with additional metadata and review status.
-- ============================================================================

CREATE OR REPLACE VIEW clinvar_curator.cvc_annotations_view
AS
  SELECT
    *,
    -- This analytic function is now in a standard view
    (
      COUNT(annotated_date) OVER (
        PARTITION BY batch_id, scv_id
        ORDER BY annotation_id
        ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
      ) = 0
    ) AS is_latest
  FROM `clinvar_curator.cvc_annotations_base_mv`
;

-- This script creates a view named `cvc_batch_scv_max_annotation_view` in the `clinvar_curator` schema.
-- The view aggregates data from the `cvc_clinvar_reviews` with their corresponding`cvc_annotations_view` data.
-- It selects the batch ID, SCV ID, and the maximum annotation ID for each SCV ID within each batch.
-- The view is useful for identifying the latest annotation for each SCV ID in a given batch.
CREATE OR REPLACE VIEW clinvar_curator.cvc_batch_scv_max_annotation_view
AS
  SELECT
    ccr.batch_id,
    av.scv_id,
    max(av.annotation_id) annotation_id
  FROM `clinvar_curator.cvc_clinvar_reviews` ccr
  JOIN `clinvar_curator.cvc_annotations_base_mv` av
  ON
    av.annotation_id = ccr.annotation_id
  GROUP BY
    av.scv_id,
    ccr.batch_id
  ;

-- This script creates or replaces the view `clinvar_curator.cvc_submitted_annotations_view`.
-- The view provides a comprehensive overview of submitted annotations, including their validity status,
-- reasons for invalid submissions, and various metadata related to the submission and annotation process.
--
-- The view includes the following columns:
-- - valid_submission: A boolean indicating if the submission was valid for NCBI's receipt.
-- - invalid_submission_reason: A string describing the reason why NCBI rejected the submission.
-- - batch_id: The batch identifier from the `cvc_clinvar_submissions` table.
-- - batch_release_date: The release date of the batch
-- - submission_date: The date the annotation was submitted
-- - submission_month_year: The month and year of submission in 'MON'YY' format.
-- - submission_yy_mm: The year and month of submission in 'YY-MM' format.
-- - variation_id: The variation identifier from the `cvc_annotations_view` table.
-- - vcv_axn: The VCV action from the `cvc_annotations_view` table.
-- - vcv_id: The VCV identifier from the `cvc_annotations_view` table.
-- - vcv_ver: The VCV version from the `cvc_annotations_view` table.
-- - scv_id: The SCV identifier from the `cvc_annotations_view` table.
-- - scv_ver: The SCV version from the `cvc_annotations_view` table.
-- - submitter_id: The submitter identifier from the `cvc_annotations_view` table.
-- - action: The action taken from the `cvc_annotations_view` table.
-- - reason: The reason for the action from the `cvc_annotations_view` table.
-- - notes: Additional notes from the `cvc_annotations_view` table.
-- - curator: The curator responsible from the `cvc_annotations_view` table.
-- - annotation_id: The annotation identifier from the `cvc_annotations_view` table.
-- - annotated_date: The date the annotation was made from the `cvc_annotations_view` table.
--
-- The view joins data from the following tables:
-- - `clinvar_curator.cvc_clinvar_submissions`: Provides submission data.
-- - `clinvar_curator.cvc_annotations_view`: Provides annotation data.
-- - `clinvar_ingest.clinvar_scvs`: Provides SCV data for validating submissions.
-- - `clinvar_curator.cvc_clinvar_submissions`: Provides prior submission data for comparison.
CREATE OR REPLACE VIEW clinvar_curator.cvc_submitted_annotations_view
AS
SELECT
    IF(vs.id is null OR vs.version != av.scv_ver OR ccs_prior.annotation_id is not null, FALSE, TRUE) as valid_submission,
    CASE
    WHEN (vs.id is NULL) THEN
      'deleted prior to submission'
    WHEN (vs.version != av.scv_ver) THEN
      'updated prior to submission'
    WHEN (ccs_prior.annotation_id is not null) THEN
      'submitted in prior batch'
    END as invalid_submission_reason,
    ccs.batch_id,
    b.batch_release_date,
    b.batch_end_date as submission_date,
    b.submission.monyy as submission_month_year,
    b.submission.yymm as submission_yy_mm,
    av.variation_id,
    av.vcv_axn,
    av.vcv_id,
    av.vcv_ver,
    av.scv_id,
    av.scv_ver,
    av.submitter_id,
    av.action,
    av.reason,
    av.notes,
    av.curator,
    av.annotation_id,
    av.annotated_date,
    av.annotation_release_date,
    av.review_status
  FROM `clinvar_curator.cvc_clinvar_submissions` ccs
  JOIN `clinvar_curator.cvc_clinvar_batches` b
  ON
    b.batch_id = ccs.batch_id
  JOIN `clinvar_curator.cvc_annotations_base_mv` av
  ON
    av.annotation_id = ccs.annotation_id
  LEFT JOIN `clinvar_ingest.clinvar_scvs` vs
  ON
    vs.id = ccs.scv_id
    AND
    b.batch_release_date BETWEEN vs.start_release_date AND vs.end_release_date
  LEFT JOIN `clinvar_curator.cvc_clinvar_submissions` ccs_prior
  ON
    ccs_prior.batch_id < ccs.batch_id
    AND
    ccs_prior.scv_id = ccs.scv_id
    AND
    ccs_prior.scv_ver = ccs.scv_ver
;

-- This script creates or replaces the view `clinvar_curator.cvc_submitted_outcomes_view`.
-- The view provides a summary of the outcomes of submitted annotations based on the latest release date.
--
-- The view is constructed using a Common Table Expression (CTE) `latest_release` to fetch the most recent release date.
--
-- The main SELECT statement joins the `cvc_submitted_annotations_view` with the `latest_release` CTE and two instances of the `clinvar_scvs` table.
--
-- The `outcome` field is determined using a CASE statement that evaluates various conditions:
--   - "invalid submission" if the submission is not valid.
--   - "deleted" if the submission has been deleted.
--   - "flagged" if the submission has been flagged.
--   - "resubmitted, reclassified" or "resubmitted, same classification" if the submission has been resubmitted with or without reclassification.
--   - "pending (or rejected)" for other cases.
--
-- The view also includes additional fields from the `cvc_submitted_annotations_view` such as:
--   - `invalid_submission_reason`
--   - `batch_id`
--   - `batch_release_date`
--   - `submission_date`
--   - `submission_month_year`
--   - `submission_yy_mm`
--   - `variation_id`
--   - `vcv_axn`
--   - `vcv_id`
--   - `vcv_ver`
--   - `scv_id`
--   - `scv_ver`
--   - `submitter_id`
--   - `action`
--   - `reason`
--   - `notes`
--   - `curator`
--   - `annotation_id`
--   - `annotated_date`
--   - `review_status`
CREATE OR REPLACE VIEW clinvar_curator.cvc_submitted_outcomes_view
AS
  SELECT
    latest_release.release_date as report_release_date,
    CASE
      WHEN (NOT sa.valid_submission) THEN
        "invalid submission"
      WHEN (cur_vs.id is null) THEN
        "deleted"
      WHEN (cur_vs.rank = -3) THEN
        "flagged"
      WHEN (cur_vs.version > sa.scv_ver) THEN
        IF(cur_vs.classif_type <> anno_vs.classif_type, "resubmitted, reclassified", "resubmitted, same classification")
      ELSE
        "pending (or rejected)"
    END as outcome,
    sa.invalid_submission_reason,
    sa.batch_id,
    sa.batch_release_date,
    sa.submission_date,
    sa.submission_month_year,
    sa.submission_yy_mm,
    sa.variation_id,
    sa.vcv_axn,
    sa.vcv_id,
    sa.vcv_ver,
    sa.scv_id,
    sa.scv_ver,
    sa.submitter_id,
    sa.action,
    sa.reason,
    sa.notes,
    sa.curator,
    sa.annotation_id,
    sa.annotated_date,
    sa.annotation_release_date,
    sa.review_status
  FROM `clinvar_curator.cvc_submitted_annotations_view` sa
  JOIN `clinvar_ingest.release_on`(CURRENT_DATE()) latest_release ON TRUE
  LEFT JOIN `clinvar_ingest.clinvar_scvs` cur_vs
  ON
    cur_vs.id = sa.scv_id
    AND
    latest_release.release_date between cur_vs.start_release_date and cur_vs.end_release_date
  LEFT JOIN `clinvar_ingest.clinvar_scvs` anno_vs
  ON
    anno_vs.id = sa.scv_id
    AND
    sa.annotation_release_date between anno_vs.start_release_date and anno_vs.end_release_date
  ;
