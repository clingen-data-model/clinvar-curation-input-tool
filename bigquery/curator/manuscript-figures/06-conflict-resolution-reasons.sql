-- ============================================================================
-- Script: 06-conflict-resolution-reasons.sql
--
-- Description:
--   One row per time a ClinVar conflict resolved, with the reason it resolved.
--   This covers all of ClinVar, not only variants CvC reviewed. It is the only
--   input to Figure 6:
--     Figure 6A - total resolutions by reason and conflict type
--     Figure 6B - the same counts by monthly ClinVar release
--
--   Running this script creates a table function and the views behind the
--   Figure 6 sheet. It reads ClinVar, CvC and conflict analytics data and changes
--   none of them.
--     bq query --use_legacy_sql=false < 06-conflict-resolution-reasons.sql
--   generate_figure6.py then calls the table function and draws both panels.
--
-- Dependencies:
--   clinvar_ingest.conflict_vcv_change_detail, monthly_conflict_vcv_scv_summary,
--   monthly_conflict_scv_changes and monthly_conflict_snapshots. These are result
--   tables built by scripts/conflict-resolution-analysis/00-run-all-analytics.sh
--   in clinvar-ingest-bq-tools, and nothing schedules that script. Run it first to
--   pick up new releases.
--   clinvar_curator.cvc_submitted_annotations_view for CvC's own submissions.
--
-- Table function:
--   clinvar_ingest.manuscript_figure6_resolution_events(as_of_date DATE)
--   Includes monthly releases from August 2023, when CvC began, through as_of_date.
--   NULL means the latest monthly release in the conflict tables. A date between
--   releases uses the last release on or before it.
--
-- Views (latest monthly release, because a view cannot take a parameter):
--   clinvar_ingest.manuscript_figure6_resolution_events_view
--   clinvar_ingest.manuscript_figure6a_reason_totals_view
--   clinvar_ingest.manuscript_figure6b_monthly_view
--   clinvar_ingest.manuscript_figure6_granular_view
--   clinvar_ingest.manuscript_figure6_submitter_concentration_view
--
-- Method:
--   The series uses the first ClinVar release of each month, and compares each
--   one with the release before it. A conflict is in the release's top ranked
--   group, among germline pathogenicity SCVs (proposition_type = 'path'), and is
--   either medically significant (P/LP vs VUS and/or B/LB) or not (VUS vs B/LB).
--
--   An event is counted in the release where the conflict stopped. A conflict
--   that returned later still counts, and returned_by_cutoff marks it. A variant
--   that resolves twice is two events, so report events and variants separately.
--
-- Reasons:
--   source_primary_reason is the reason from the conflict tables, which give each
--   event one reason. Where more than one thing changed, they apply this order:
--   expert panel, higher rank, flagged, removed, rank lowered, reclassified.
--   all_scv_reasons lists everything that changed, and reason_count counts it.
--
--   Three source reasons describe context rather than a cause, so this script
--   maps them to the SCV change behind them, in that same order:
--   single_submitter_withdrawn, vcv_rank_changed and outlier_reclassified. Events
--   with no matching change are Other.
--
--   Flagged through CvC means a flagged SCV had a valid CvC flagging candidate
--   submitted on or before that release, matched on accession. Flagged outside CvC
--   means none did, such as flags from NCBI.
--
-- Excluded SCVs:
--   SCVs listed in clinvar_ingest.manuscript_excluded_scvs (00-excluded-scvs.sql)
--   are left out: the 321 SCVs whose gene-disease relationship flag CvC later
--   retracted. They are not CvC flagging candidates here, and an event whose
--   reason SCVs are all excluded is dropped, because the retracted flag caused
--   it. Run that script first.
--
-- CvC candidates before a submitter's change:
--   cvc_candidate_before and cvc_candidate_within_60_days apply to any reason.
--   They report timing only, and do not show that CvC caused the change. The 60
--   day test allows for a change anywhere between the two releases, so it can
--   include a change slightly more than 60 days after submission.
--
-- Classification groups, for classification_to_start:
--   P = p, p-lp (pathogenic, low penetrance), era (established risk allele)
--   LP = lp, lp-lp (likely pathogenic, low penetrance), lra (likely risk allele)
--   VUS = vus, vus-h, vus-m, vus-l, ura (uncertain risk allele)
--   LB = lb. B = b.
--   CDFS = cdfs (conflicting data from submitters), which sits in the VUS tier and
--   stays its own label because it has no agreed group.
--   In a label, a plus means both together and "vs" separates conflicting tiers.
--
-- Output Columns:
--   as_of_release_date, snapshot_release_date, prev_snapshot_release_date,
--   release_month, variation_id
--   conflict_group         - medically significant, non-medically significant
--   conflict_rank_tier     - Star tier of the conflict before it resolved
--   outlier_status         - With Outlier, No Outlier
--   resolution_reason      - The reason shown in the figure
--   source_primary_reason  - The reason from the conflict tables
--   all_scv_reasons, reason_count
--   source_agg_classif     - Original classification codes before it resolved
--   classification_to_start - The same codes in classification groups
--   classification_after   - Tier of the top ranked group after it resolved
--   reason_scv_count       - SCVs whose change matches resolution_reason
--   reason_scvs, changed_submitters (separated by " | ")
--   cvc_candidate_before, cvc_candidate_within_60_days
--   returned_by_cutoff, first_return_release, in_conflict_at_cutoff
-- ============================================================================

CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure6_resolution_events`(as_of_date DATE)
AS (
  WITH
  cutoff AS (
    SELECT MAX(snapshot_release_date) AS as_of
    FROM `clinvar_ingest.conflict_vcv_change_detail`
    WHERE as_of_date IS NULL OR snapshot_release_date <= as_of_date
  ),

  resolved AS (
    SELECT
      d.snapshot_release_date,
      d.prev_snapshot_release_date,
      d.variation_id,
      IF(d.conflict_type = 'Clinsig', 'medically significant', 'non-medically significant') AS conflict_group,
      d.conflict_rank_tier,
      d.outlier_status,
      d.primary_reason AS source_primary_reason,
      ARRAY_TO_STRING(d.scv_reasons, ', ') AS all_scv_reasons,
      d.reason_count,
      s.curr_vcv_agg_sig_type,
      s.scvs_flagged_contributing,
      s.scvs_removed_contributing,
      s.scvs_rank_downgraded,
      s.scvs_reclassified_contributing,
      s.scvs_added_higher_rank,
      cutoff.as_of
    FROM `clinvar_ingest.conflict_vcv_change_detail` d
    CROSS JOIN cutoff
    LEFT JOIN `clinvar_ingest.monthly_conflict_vcv_scv_summary` s
      ON s.variation_id = d.variation_id
      AND s.snapshot_release_date = d.snapshot_release_date
    WHERE d.vcv_change_status = 'resolved'
      AND d.snapshot_release_date >= DATE '2023-08-01'
      AND d.snapshot_release_date <= cutoff.as_of
  ),

  -- Context reasons map to the change behind them, in the source's own order.
  reasoned AS (
    SELECT
      r.*,
      CASE
        WHEN source_primary_reason = 'expert_panel_added' THEN 'expert_panel'
        WHEN source_primary_reason = 'higher_rank_scv_added' THEN 'higher_rank'
        WHEN source_primary_reason = 'scv_flagged' THEN 'flagged'
        WHEN source_primary_reason = 'scv_removed' THEN 'removed'
        WHEN source_primary_reason = 'scv_rank_downgraded' THEN 'rank_lowered'
        WHEN source_primary_reason = 'scv_reclassified' THEN 'reclassified'
        WHEN ARRAY_LENGTH(scvs_flagged_contributing) > 0 THEN 'flagged'
        WHEN ARRAY_LENGTH(scvs_removed_contributing) > 0 THEN 'removed'
        WHEN ARRAY_LENGTH(scvs_rank_downgraded) > 0 THEN 'rank_lowered'
        WHEN ARRAY_LENGTH(scvs_reclassified_contributing) > 0 THEN 'reclassified'
        ELSE 'other'
      END AS base_reason
    FROM resolved r
  ),

  with_scvs AS (
    SELECT
      r.* EXCEPT (
        scvs_flagged_contributing, scvs_removed_contributing, scvs_rank_downgraded,
        scvs_reclassified_contributing, scvs_added_higher_rank
      ),
      CASE base_reason
        WHEN 'flagged' THEN scvs_flagged_contributing
        WHEN 'removed' THEN scvs_removed_contributing
        WHEN 'rank_lowered' THEN scvs_rank_downgraded
        WHEN 'reclassified' THEN scvs_reclassified_contributing
        WHEN 'expert_panel' THEN scvs_added_higher_rank
        WHEN 'higher_rank' THEN scvs_added_higher_rank
        ELSE ARRAY<STRING>[]
      END AS reason_scvs
    FROM reasoned r
  ),

  -- Valid flagging candidates, the same test Figure 4 uses.
  candidates AS (
    SELECT DISTINCT sa.scv_id, sa.submission_date
    FROM `clinvar_curator.cvc_submitted_annotations_view` sa
    LEFT JOIN `clinvar_ingest.manuscript_excluded_scvs` x
      ON x.scv_id = sa.scv_id
    WHERE sa.action = 'flagging candidate'
      AND sa.valid_submission
      AND x.scv_id IS NULL
  ),

  -- Events caused only by excluded SCVs.
  excluded_events AS (
    SELECT e.snapshot_release_date, e.variation_id
    FROM with_scvs e, UNNEST(e.reason_scvs) AS scv
    LEFT JOIN `clinvar_ingest.manuscript_excluded_scvs` x
      ON x.scv_id = REGEXP_EXTRACT(scv, r'SCV\d+')
    GROUP BY e.snapshot_release_date, e.variation_id
    HAVING LOGICAL_AND(x.scv_id IS NOT NULL)
  ),

  cvc_timing AS (
    SELECT
      e.snapshot_release_date,
      e.variation_id,
      LOGICAL_OR(c.submission_date <= e.snapshot_release_date) AS cvc_candidate_before,
      LOGICAL_OR(
        c.submission_date <= e.snapshot_release_date
        AND c.submission_date >= DATE_SUB(e.prev_snapshot_release_date, INTERVAL 60 DAY)
      ) AS cvc_candidate_within_60_days
    FROM with_scvs e, UNNEST(e.reason_scvs) AS scv
    JOIN candidates c ON c.scv_id = REGEXP_EXTRACT(scv, r'SCV\d+')
    GROUP BY e.snapshot_release_date, e.variation_id
  ),

  submitters AS (
    SELECT
      e.snapshot_release_date,
      e.variation_id,
      ARRAY_TO_STRING(ARRAY_AGG(DISTINCT COALESCE(sc.prev_submitter_name, sc.curr_submitter_name) IGNORE NULLS ORDER BY COALESCE(sc.prev_submitter_name, sc.curr_submitter_name)), ' | ') AS changed_submitters
    FROM with_scvs e, UNNEST(e.reason_scvs) AS scv
    JOIN `clinvar_ingest.monthly_conflict_scv_changes` sc
      ON sc.variation_id = e.variation_id
      AND sc.snapshot_release_date = e.snapshot_release_date
      AND sc.scv_id = scv
    GROUP BY e.snapshot_release_date, e.variation_id
  ),

  returned AS (
    SELECT
      e.snapshot_release_date,
      e.variation_id,
      MIN(m.snapshot_release_date) AS first_return_release,
      LOGICAL_OR(m.snapshot_release_date = e.as_of) AS in_conflict_at_cutoff
    FROM with_scvs e
    JOIN `clinvar_ingest.monthly_conflict_snapshots` m
      ON m.variation_id = e.variation_id
      AND m.snapshot_release_date > e.snapshot_release_date
      AND m.snapshot_release_date <= e.as_of
    GROUP BY e.snapshot_release_date, e.variation_id
  ),

  -- The classification codes in the release before it resolved, in groups.
  start_state AS (
    SELECT
      e.snapshot_release_date,
      e.variation_id,
      m.agg_classif AS source_agg_classif,
      ARRAY(
        SELECT DISTINCT
          CASE
            WHEN code IN ('p', 'p-lp', 'era') THEN 'P'
            WHEN code IN ('lp', 'lp-lp', 'lra') THEN 'LP'
            WHEN code IN ('vus', 'vus-h', 'vus-m', 'vus-l', 'ura') THEN 'VUS'
            WHEN code = 'lb' THEN 'LB'
            WHEN code = 'b' THEN 'B'
            ELSE UPPER(code)
          END
        FROM UNNEST(SPLIT(m.agg_classif, '/')) AS code
      ) AS groups_present
    FROM with_scvs e
    LEFT JOIN `clinvar_ingest.monthly_conflict_snapshots` m
      ON m.variation_id = e.variation_id
      AND m.snapshot_release_date = e.prev_snapshot_release_date
  ),

  start_label AS (
    SELECT
      snapshot_release_date,
      variation_id,
      source_agg_classif,
      ARRAY_TO_STRING(
        ARRAY(
          SELECT tier FROM UNNEST([
            STRUCT(1 AS ord, ARRAY_TO_STRING(ARRAY(SELECT g FROM UNNEST(['P', 'LP']) AS g WHERE g IN UNNEST(groups_present)), ' + ') AS tier),
            STRUCT(2, ARRAY_TO_STRING(ARRAY(SELECT g FROM UNNEST(['VUS', 'CDFS']) AS g WHERE g IN UNNEST(groups_present)), ' + ')),
            STRUCT(3, ARRAY_TO_STRING(ARRAY(SELECT g FROM UNNEST(['B', 'LB']) AS g WHERE g IN UNNEST(groups_present)), ' + '))
          ])
          WHERE tier != ''
          ORDER BY ord
        ),
        ' vs '
      ) AS classification_to_start
    FROM start_state
  )

  SELECT
    e.as_of AS as_of_release_date,
    e.snapshot_release_date,
    e.prev_snapshot_release_date,
    FORMAT_DATE('%Y-%m', e.snapshot_release_date) AS release_month,
    e.variation_id,
    e.conflict_group,
    e.conflict_rank_tier,
    e.outlier_status,
    CASE e.base_reason
      WHEN 'reclassified' THEN 'Reclassified'
      WHEN 'removed' THEN 'Removed'
      WHEN 'rank_lowered' THEN 'Rank lowered'
      WHEN 'flagged' THEN IF(COALESCE(t.cvc_candidate_before, FALSE), 'Flagged through CvC', 'Flagged outside CvC')
      WHEN 'expert_panel' THEN 'Expert panel added'
      WHEN 'higher_rank' THEN '1 star added to 0 star conflict'
      ELSE 'Other'
    END AS resolution_reason,
    e.source_primary_reason,
    e.all_scv_reasons,
    e.reason_count,
    l.source_agg_classif,
    l.classification_to_start,
    CASE e.curr_vcv_agg_sig_type
      WHEN 1 THEN 'B/LB'
      WHEN 2 THEN 'VUS'
      WHEN 4 THEN 'P/LP'
      ELSE 'No classification'
    END AS classification_after,
    ARRAY_LENGTH(e.reason_scvs) AS reason_scv_count,
    ARRAY_TO_STRING(e.reason_scvs, ', ') AS reason_scvs,
    su.changed_submitters,
    COALESCE(t.cvc_candidate_before, FALSE) AS cvc_candidate_before,
    COALESCE(t.cvc_candidate_within_60_days, FALSE) AS cvc_candidate_within_60_days,
    b.first_return_release IS NOT NULL AS returned_by_cutoff,
    b.first_return_release,
    COALESCE(b.in_conflict_at_cutoff, FALSE) AS in_conflict_at_cutoff
  FROM with_scvs e
  LEFT JOIN cvc_timing t USING (snapshot_release_date, variation_id)
  LEFT JOIN submitters su USING (snapshot_release_date, variation_id)
  LEFT JOIN returned b USING (snapshot_release_date, variation_id)
  LEFT JOIN start_label l USING (snapshot_release_date, variation_id)
  LEFT JOIN excluded_events x USING (snapshot_release_date, variation_id)
  WHERE x.variation_id IS NULL
);

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure6_resolution_events_view`
AS
SELECT * FROM `clinvar_ingest.manuscript_figure6_resolution_events`(NULL);

-- Panel A. Each reason appears once per conflict type and once for all conflicts.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure6a_reason_totals_view`
AS
WITH
events AS (
  SELECT e.*, grp AS panel_group
  FROM `clinvar_ingest.manuscript_figure6_resolution_events_view` e,
    UNNEST([e.conflict_group, 'all conflicts']) AS grp
)
SELECT
  ANY_VALUE(as_of_release_date) AS as_of_release_date,
  panel_group AS conflict_group,
  resolution_reason,
  COUNT(*) AS resolution_events,
  COUNT(DISTINCT variation_id) AS variants,
  SUM(reason_scv_count) AS reason_scvs,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY panel_group), 2) AS percent_of_group,
  COUNTIF(returned_by_cutoff) AS returned_by_cutoff,
  COUNTIF(in_conflict_at_cutoff) AS in_conflict_at_cutoff,
  COUNTIF(reason_count > 1) AS events_with_multiple_reasons,
  COUNTIF(cvc_candidate_before) AS events_with_cvc_candidate_before,
  COUNTIF(cvc_candidate_within_60_days) AS events_with_cvc_candidate_within_60_days
FROM events
GROUP BY panel_group, resolution_reason
ORDER BY panel_group, resolution_events DESC;

-- Panel B. Releases with no events for a reason have no row for that reason.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure6b_monthly_view`
AS
SELECT
  ANY_VALUE(as_of_release_date) AS as_of_release_date,
  snapshot_release_date,
  release_month,
  conflict_group,
  resolution_reason,
  COUNT(*) AS resolution_events,
  COUNT(DISTINCT variation_id) AS variants,
  SUM(reason_scv_count) AS reason_scvs
FROM `clinvar_ingest.manuscript_figure6_resolution_events_view`
GROUP BY snapshot_release_date, release_month, conflict_group, resolution_reason
ORDER BY snapshot_release_date, conflict_group, resolution_events DESC;

-- The most granular table, one row per exact starting state and result.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure6_granular_view`
AS
SELECT
  ANY_VALUE(as_of_release_date) AS as_of_release_date,
  conflict_group,
  classification_to_start,
  resolution_reason,
  classification_after,
  COUNT(*) AS resolution_events,
  COUNT(DISTINCT variation_id) AS variants,
  SUM(reason_scv_count) AS reason_scvs,
  COUNTIF(returned_by_cutoff) AS returned_by_cutoff,
  COUNTIF(cvc_candidate_before) AS events_with_cvc_candidate_before
FROM `clinvar_ingest.manuscript_figure6_resolution_events_view`
GROUP BY conflict_group, classification_to_start, resolution_reason, classification_after
ORDER BY conflict_group, classification_to_start, resolution_events DESC;

-- Which submitters' changes drive each reason. An event with changes from two
-- submitters counts once for each, so rows can add up to more than the reason total.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure6_submitter_concentration_view`
AS
SELECT
  ANY_VALUE(e.as_of_release_date) AS as_of_release_date,
  e.resolution_reason,
  submitter,
  COUNT(*) AS resolution_events,
  COUNT(DISTINCT e.snapshot_release_date) AS releases,
  MIN(e.snapshot_release_date) AS first_release,
  MAX(e.snapshot_release_date) AS last_release
FROM `clinvar_ingest.manuscript_figure6_resolution_events_view` e,
  UNNEST(SPLIT(e.changed_submitters, ' | ')) AS submitter
GROUP BY e.resolution_reason, submitter
ORDER BY e.resolution_reason, resolution_events DESC;
