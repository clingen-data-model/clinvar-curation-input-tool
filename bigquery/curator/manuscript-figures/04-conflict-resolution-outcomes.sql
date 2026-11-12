-- ============================================================================
-- Script: 04-conflict-resolution-outcomes.sql
--
-- Description:
--   One row per variant reviewed by CvC, describing what its flagging candidates
--   would do to the variant's aggregate classification at the point they were
--   submitted to ClinVar. This is the only input to Figure 4:
--     Figure 4A - share of reviewed variants by outcome (figure_4a_outcome)
--     Figure 4B - direction of conflict resolution (before_state -> after_state)
--
--   Running this script creates a table function and the views behind the
--   Figure 4 sheet. It reads ClinVar and CvC data and changes neither.
--     bq query --use_legacy_sql=false < 04-conflict-resolution-outcomes.sql
--   generate_figure4.py then calls the table function and draws each panel as its
--   own titled image.
--
-- Table function:
--   clinvar_ingest.manuscript_figure4_variant_outcomes(as_of_date DATE)
--   Includes batches with batch_release_date <= as_of_date. NULL means all
--   batches. The manuscript text currently describes Aug 2023 - May 2026.
--
-- Views (all batches, because a view cannot take a parameter):
--   clinvar_ingest.manuscript_figure4_variant_outcomes_view
--   clinvar_ingest.manuscript_figure4a_outcomes_view
--   clinvar_ingest.manuscript_figure4a_outcome_detail_view
--   clinvar_ingest.manuscript_figure4b_flows_view
--   clinvar_ingest.manuscript_figure4b_final_classifications_view
--   clinvar_ingest.manuscript_figure4b_conflict_combinations_view
--   clinvar_ingest.manuscript_figure4_rank_group_transitions_view
--
-- Excluded annotations:
--   Every read of CvC annotations, reviews and submissions anti-joins
--   clinvar_ingest.manuscript_excluded_annotations (00-excluded-scvs.sql; run it
--   first) on annotation_id. Those are the discordance project retraction's
--   flags and removals (batch 129), on 233 SCVs. They count as never annotated:
--   they are not batch decisions, flagging candidates or remove flagged
--   submissions. Other CvC work on the same SCVs still counts, such as no change
--   annotations and later re-flags, and every other retracted flag counts as an
--   ordinary retraction. Don't anti-join on manuscript_excluded_scvs.scv_id,
--   which would drop that other work too.
--
-- Reviews:
--   A batch's decision on an SCV is its latest annotation in that batch, after
--   leaving out the excluded annotations. Archive reviews never count. A
--   submission counts only when the batch's decision on that SCV is the same
--   action.
--
-- Method:
--   "Before" is the path SCVs in ClinVar on the batch release. "After" removes
--   the variant's flagging candidates from that same set. Nothing later than the
--   batch release is used, so resubmissions, deletions and flag removals that
--   came afterward do not change the result.
--
--   ClinVar builds the aggregate from the highest ranked group of SCVs, so before
--   and after are each read from their own top ranked group. When every SCV in
--   the top group is flagged, the after state comes from the next group down and
--   rank_lowered is TRUE. rank_groups lists every group for reporting on the
--   lower groups, which can change while the aggregate does not.
--
--   Rank -3 (already flagged) is excluded. Ranks in path SCVs are 4 (practice
--   guideline), 3 (expert panel), 1 (criteria provided) and 0 (no criteria).
--
-- State mask (same encoding as clinvar_sum_vsp_rank_group.agg_sig_type):
--   B/LB = 1, VUS = 2, P/LP = 4, summed over the distinct tiers in the group.
--   Tier comes from clinsig_type, so VUS-H/M/L and uncertain risk alleles count
--   as VUS, and low penetrance and risk alleles count as P/LP.
--     0 none left    1 B/LB    2 VUS    3 VUS vs B/LB
--     4 P/LP         5 P/LP vs B/LB     6 P/LP vs VUS    7 P/LP vs VUS vs B/LB
--   Conflict = 3, 5, 6, 7. Medically significant conflict = 5, 6, 7.
--
-- Classification groups, for the labels within a tier:
--   P = p, p-lp (pathogenic, low penetrance), era (established risk allele)
--   LP = lp, lp-lp (likely pathogenic, low penetrance), lra (likely risk allele)
--   VUS = vus, vus-h, vus-m, vus-l, ura (uncertain risk allele)
--   LB = lb. B = b.
--
-- Variants flagged in more than one batch:
--   Each batch is evaluated on its own, using only that batch's flagging
--   candidates and the SCVs in ClinVar on its release. An earlier flag that
--   ClinVar has applied is rank -3 and already out of that release. An earlier
--   flag that it has not applied still counts as a contributing SCV. The variant
--   keeps its strongest outcome, in the order of outcome_priority below, and the
--   latest batch on a tie.
--
-- Output Columns:
--   variation_id, as_of_batch_release_date
--   figure_4a_outcome      - Conflict resolved, Conflict reduced, Classification
--                            removed, Flagged, not resolved, No change
--   outcome_detail         - Finer outcome that rolls up to figure_4a_outcome
--   batch_id, batch_release_date - Batch that gave the reported outcome
--   before_mask/state/classif/top_rank - Top ranked group before flagging
--   after_mask/state/classif/top_rank  - Top ranked group after flagging
--   after_classif_group    - after_classif in classification groups, e.g. P + LP
--   conflict_group         - medically significant, non-medically significant,
--                            or NULL when the top ranked group had no conflict
--   panel_b_node           - Conflict type shown on the left of the Sankey
--   conflict_combination   - Full set of labels, with related labels grouped
--   shown_in_panel_b       - The variant left its conflict state to a single tier,
--                            or from medically significant to VUS vs B/LB
--   rank_lowered           - After state comes from a lower group than before
--   top_rank_flagged_scvs  - Flagging candidates in the before top ranked group
--   resolution_flagged_scvs - Flagging candidates in the before top ranked group
--                            and any group down to the after top ranked group
--   flagged_scvs           - Flagging candidates among contributing SCVs
--   lower_rank_conflict_resolved - A group below the top went from conflict to
--                            no conflict, whether or not the aggregate changed
--   rank_groups            - Before and after state of each rank group
--   flagged_batch_count    - Batches with a valid flagging candidate
--   any_flag_retracted     - A flagging candidate was retracted by as_of_date
--   reasons                - Flagging reasons on the variant
-- ============================================================================

CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure4_variant_outcomes`(as_of_date DATE) AS (

WITH cutoff AS (
  SELECT COALESCE(as_of_date, MAX(batch_release_date)) AS as_of
  FROM `clinvar_curator.cvc_clinvar_batches`
),

-- Each batch's decision on an SCV: its latest annotation in that batch. Excluded
-- annotations count as never annotated, so the latest is chosen without them
-- (the same ranking as is_latest otherwise). Archive reviews were corrected
-- before submission and never count, and superseded annotations in the same
-- batch don't either.
batch_latest AS (
  SELECT
    av.annotation_id,
    av.batch_id,
    av.scv_id,
    av.variation_id,
    av.action,
    av.review_status,
    av.annotation_release_date
  FROM `clinvar_curator.cvc_annotations_view` av
  JOIN `clinvar_curator.cvc_clinvar_batches` b
    ON b.batch_id = av.batch_id
  JOIN cutoff
    ON b.batch_release_date <= cutoff.as_of
  LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` x
    ON x.annotation_id = av.annotation_id
  WHERE x.annotation_id IS NULL
    AND av.annotated_date IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY av.batch_id, av.scv_id ORDER BY av.annotation_id DESC) = 1
),

batch_decisions AS (
  SELECT * EXCEPT (review_status)
  FROM batch_latest
  WHERE review_status IS DISTINCT FROM 'Archive'
),

-- Reviewed variants: the denominator. Any batch decision on a path SCV counts.
reviewed AS (
  SELECT DISTINCT bd.variation_id
  FROM batch_decisions bd
  JOIN `clinvar_ingest.clinvar_scvs` s
    ON s.id = bd.scv_id
    AND s.proposition_type = 'path'
    AND bd.annotation_release_date BETWEEN s.start_release_date AND s.end_release_date
  WHERE bd.variation_id IS NOT NULL
),

-- Flagging candidates accepted into a batch for a path SCV, where the batch's
-- decision on the SCV is still a flagging candidate.
flagging_candidates AS (
  SELECT DISTINCT
    sa.annotation_id,
    sa.variation_id,
    sa.batch_id,
    sa.batch_release_date,
    sa.scv_id,
    sa.scv_ver,
    sa.reason
  FROM `clinvar_curator.cvc_submitted_annotations_view` sa
  JOIN cutoff
    ON sa.batch_release_date <= cutoff.as_of
  JOIN batch_decisions bd
    ON bd.batch_id = sa.batch_id
    AND bd.scv_id = sa.scv_id
    AND bd.action = 'flagging candidate'
  LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` x
    ON x.annotation_id = sa.annotation_id
  JOIN `clinvar_ingest.clinvar_scvs` s
    ON s.id = sa.scv_id
    AND s.proposition_type = 'path'
    AND sa.batch_release_date BETWEEN s.start_release_date AND s.end_release_date
  WHERE sa.action = 'flagging candidate'
    AND sa.review_status IS DISTINCT FROM 'Archive'
    AND x.annotation_id IS NULL
    -- valid_submission treats any earlier submission of the same SCV version as
    -- a duplicate. Excluded annotations count as never submitted, so a flag that
    -- is a duplicate only of them is still valid.
    AND (
      sa.valid_submission
      OR (
        sa.invalid_submission_reason = 'submitted in prior batch'
        AND NOT EXISTS (
          SELECT 1
          FROM `clinvar_curator.cvc_submitted_annotations_view` p
          LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` px
            ON px.annotation_id = p.annotation_id
          WHERE px.annotation_id IS NULL
            AND p.scv_id = sa.scv_id
            AND p.scv_ver = sa.scv_ver
            AND p.batch_id < sa.batch_id
        )
      )
    )
),

-- Remove flagged submissions, judged the same way.
retractions AS (
  SELECT DISTINCT sa.annotation_id, sa.scv_id, sa.batch_release_date
  FROM `clinvar_curator.cvc_submitted_annotations_view` sa
  JOIN cutoff
    ON sa.batch_release_date <= cutoff.as_of
  JOIN batch_decisions bd
    ON bd.batch_id = sa.batch_id
    AND bd.scv_id = sa.scv_id
    AND bd.action = 'remove flagged submission'
  LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` x
    ON x.annotation_id = sa.annotation_id
  WHERE sa.action = 'remove flagged submission'
    AND sa.review_status IS DISTINCT FROM 'Archive'
    AND x.annotation_id IS NULL
),

events AS (
  SELECT DISTINCT variation_id, batch_id, batch_release_date
  FROM flagging_candidates
),

-- Each batch removes only its own flagging candidates. Matching on version below
-- drops SCVs resubmitted before the batch release.
event_removals AS (
  SELECT DISTINCT variation_id, batch_id, scv_id, scv_ver
  FROM flagging_candidates
),

event_scvs AS (
  SELECT
    e.variation_id,
    e.batch_id,
    e.batch_release_date,
    s.id AS scv_id,
    s.rank,
    s.classif_type,
    CASE s.clinsig_type WHEN 2 THEN 4 WHEN 1 THEN 2 WHEN 0 THEN 1 END AS tier_bit,
    er.scv_id IS NOT NULL AS is_flagged
  FROM events e
  JOIN `clinvar_ingest.clinvar_scvs` s
    ON s.variation_id = e.variation_id
    AND s.proposition_type = 'path'
    AND s.rank >= 0
    AND e.batch_release_date BETWEEN s.start_release_date AND s.end_release_date
  LEFT JOIN event_removals er
    ON er.variation_id = e.variation_id
    AND er.batch_id = e.batch_id
    AND er.scv_id = s.id
    AND er.scv_ver = s.version
),

rank_groups AS (
  SELECT
    variation_id,
    batch_id,
    batch_release_date,
    rank,
    BIT_OR(tier_bit) AS before_mask,
    BIT_OR(IF(is_flagged, 0, tier_bit)) AS after_mask,
    COUNT(DISTINCT scv_id) AS scv_count,
    COUNT(DISTINCT IF(is_flagged, scv_id, NULL)) AS flagged_count,
    STRING_AGG(DISTINCT classif_type, '/' ORDER BY classif_type) AS before_classif,
    STRING_AGG(DISTINCT IF(is_flagged, NULL, classif_type), '/' ORDER BY IF(is_flagged, NULL, classif_type)) AS after_classif
  FROM event_scvs
  GROUP BY variation_id, batch_id, batch_release_date, rank
),

event_states AS (
  SELECT
    variation_id,
    batch_id,
    batch_release_date,
    MAX(rank) AS before_top_rank,
    MAX_BY(before_mask, rank) AS before_mask,
    MAX_BY(before_classif, rank) AS before_classif,
    MAX(IF(after_mask > 0, rank, NULL)) AS after_top_rank,
    COALESCE(MAX_BY(after_mask, IF(after_mask > 0, rank, NULL)), 0) AS after_mask,
    MAX_BY(after_classif, IF(after_mask > 0, rank, NULL)) AS after_classif,
    MAX_BY(flagged_count, rank) AS top_rank_flagged_scvs,
    SUM(flagged_count) AS flagged_scvs,
    ARRAY_AGG(
      STRUCT(rank, scv_count, flagged_count, before_mask, after_mask, before_classif, after_classif)
      ORDER BY rank DESC
    ) AS rank_groups
  FROM rank_groups
  GROUP BY variation_id, batch_id, batch_release_date
),

event_outcomes AS (
  SELECT
    *,
    after_top_rank IS NOT NULL AND after_top_rank < before_top_rank AS rank_lowered,
    (
      SELECT SUM(g.flagged_count)
      FROM UNNEST(rank_groups) g
      WHERE after_top_rank IS NULL OR g.rank >= after_top_rank
    ) AS resolution_flagged_scvs,
    (
      SELECT LOGICAL_OR(g.before_mask IN (3, 5, 6, 7) AND g.after_mask IN (1, 2, 4))
      FROM UNNEST(rank_groups) g
      WHERE g.rank < before_top_rank
    ) AS lower_rank_conflict_resolved,
    CASE
      WHEN flagged_scvs = 0 THEN 'no contributing scv flagged'
      WHEN top_rank_flagged_scvs = 0 AND before_mask IN (3, 5, 6, 7) THEN 'conflict, top rank not flagged'
      WHEN top_rank_flagged_scvs = 0 THEN 'non-conflict, top rank not flagged'
      WHEN before_mask IN (3, 5, 6, 7) AND after_mask = 0 THEN 'conflict resolved, no classification left'
      WHEN before_mask IN (3, 5, 6, 7) AND after_mask IN (1, 2, 4) THEN 'conflict resolved'
      WHEN before_mask IN (5, 6, 7) AND after_mask = 3 THEN 'significant conflict reduced'
      WHEN before_mask IN (3, 5, 6, 7) THEN 'other conflict modified'
      WHEN after_mask = 0 THEN 'non-conflict removed'
      WHEN after_mask IN (3, 5, 6, 7) THEN 'conflict exposed at lower rank'
      WHEN after_mask != before_mask THEN 'non-conflict, classification changed at lower rank'
      ELSE 'non-conflict modified'
    END AS outcome_detail
  FROM event_states
),

variant_outcomes AS (
  SELECT
    eo.*,
    CASE
      WHEN outcome_detail IN ('conflict resolved', 'conflict resolved, no classification left') THEN 1
      WHEN outcome_detail = 'significant conflict reduced' THEN 2
      WHEN outcome_detail = 'non-conflict removed' THEN 3
      WHEN outcome_detail = 'other conflict modified' THEN 4
      WHEN outcome_detail = 'conflict exposed at lower rank' THEN 5
      WHEN outcome_detail = 'non-conflict, classification changed at lower rank' THEN 6
      WHEN outcome_detail = 'non-conflict modified' THEN 7
      WHEN outcome_detail = 'conflict, top rank not flagged' THEN 8
      WHEN outcome_detail = 'non-conflict, top rank not flagged' THEN 9
      ELSE 10
    END AS outcome_priority
  FROM event_outcomes eo
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY variation_id
    ORDER BY outcome_priority, batch_release_date DESC
  ) = 1
),

variant_flags AS (
  SELECT
    fc.variation_id,
    COUNT(DISTINCT fc.batch_id) AS flagged_batch_count,
    LOGICAL_OR(r.scv_id IS NOT NULL) AS any_flag_retracted,
    ARRAY_TO_STRING(ARRAY_AGG(DISTINCT fc.reason IGNORE NULLS ORDER BY fc.reason), ' | ') AS reasons
  FROM flagging_candidates fc
  LEFT JOIN retractions r
    ON r.scv_id = fc.scv_id
    AND r.batch_release_date > fc.batch_release_date
  GROUP BY fc.variation_id
),

variant_labels AS (
  SELECT
    variation_id,
    before_mask,
    EXISTS(SELECT 1 FROM UNNEST(SPLIT(before_classif, '/')) t WHERE t IN ('p', 'p-lp', 'era')) AS has_p,
    EXISTS(SELECT 1 FROM UNNEST(SPLIT(before_classif, '/')) t WHERE t IN ('lp', 'lp-lp', 'lra')) AS has_lp,
    EXISTS(SELECT 1 FROM UNNEST(SPLIT(before_classif, '/')) t WHERE t LIKE 'vus%' OR t = 'ura') AS has_vus,
    EXISTS(SELECT 1 FROM UNNEST(SPLIT(before_classif, '/')) t WHERE t = 'lb') AS has_lb,
    EXISTS(SELECT 1 FROM UNNEST(SPLIT(before_classif, '/')) t WHERE t = 'b') AS has_b,
    NULLIF(ARRAY_TO_STRING([
      IF(EXISTS(SELECT 1 FROM UNNEST(SPLIT(after_classif, '/')) t WHERE t IN ('p', 'p-lp', 'era')), 'P', NULL),
      IF(EXISTS(SELECT 1 FROM UNNEST(SPLIT(after_classif, '/')) t WHERE t IN ('lp', 'lp-lp', 'lra')), 'LP', NULL),
      IF(EXISTS(SELECT 1 FROM UNNEST(SPLIT(after_classif, '/')) t WHERE t LIKE 'vus%' OR t = 'ura'), 'VUS', NULL),
      IF(EXISTS(SELECT 1 FROM UNNEST(SPLIT(after_classif, '/')) t WHERE t = 'lb'), 'LB', NULL),
      IF(EXISTS(SELECT 1 FROM UNNEST(SPLIT(after_classif, '/')) t WHERE t = 'b'), 'B', NULL)
    ], ' + '), '') AS after_classif_group
  FROM variant_outcomes
),

state_labels AS (
  SELECT * FROM UNNEST([
    STRUCT(0 AS mask, 'No classification' AS state),
    (1, 'B/LB'),
    (2, 'VUS'),
    (3, 'VUS vs B/LB'),
    (4, 'P/LP'),
    (5, 'P/LP vs B/LB'),
    (6, 'P/LP vs VUS'),
    (7, 'P/LP vs VUS vs B/LB')
  ])
)

SELECT
  r.variation_id,
  cutoff.as_of AS as_of_batch_release_date,
  CASE
    WHEN vo.variation_id IS NULL THEN 'No change'
    WHEN vo.outcome_priority = 1 THEN 'Conflict resolved'
    WHEN vo.outcome_priority = 2 THEN 'Conflict reduced'
    WHEN vo.outcome_priority = 3 THEN 'Classification removed'
    ELSE 'Flagged, not resolved'
  END AS figure_4a_outcome,
  COALESCE(vo.outcome_detail, 'no flagging candidate submitted') AS outcome_detail,
  vo.batch_id,
  vo.batch_release_date,
  vo.before_mask,
  bl.state AS before_state,
  vo.before_classif,
  vo.before_top_rank,
  vo.after_mask,
  al.state AS after_state,
  vo.after_classif,
  vl.after_classif_group,
  vo.after_top_rank,
  CASE
    WHEN vo.before_mask IN (5, 6, 7) THEN 'medically significant'
    WHEN vo.before_mask = 3 THEN 'non-medically significant'
  END AS conflict_group,
  -- P vs LP is kept apart except in three-tier conflicts. A slash means either
  -- or both of its labels, so B/LB is B, LB or both.
  CASE vl.before_mask
    WHEN 7 THEN 'P/LP vs VUS vs B/LB'
    WHEN 6 THEN IF(vl.has_p AND vl.has_lp, 'P + LP vs VUS', IF(vl.has_p, 'P vs VUS', 'LP vs VUS'))
    WHEN 5 THEN IF(vl.has_p AND vl.has_lp, 'P + LP vs B/LB', IF(vl.has_p, 'P vs B/LB', 'LP vs B/LB'))
    WHEN 3 THEN IF(vl.has_b AND vl.has_lb, 'VUS vs B+LB', IF(vl.has_b, 'VUS vs B', 'VUS vs LB'))
  END AS panel_b_node,
  IF(vl.before_mask IN (3, 5, 6, 7),
    CONCAT(
      IF(vl.before_mask = 3, 'VUS', ARRAY_TO_STRING([IF(vl.has_p, 'P', NULL), IF(vl.has_lp, 'LP', NULL)], ' + ')),
      ' vs ',
      ARRAY_TO_STRING([
        IF(vl.has_vus AND vl.before_mask != 3, 'VUS', NULL),
        IF(vl.has_lb, 'LB', NULL),
        IF(vl.has_b, 'B', NULL)
      ], ' + ')
    ),
    NULL
  ) AS conflict_combination,
  COALESCE(
    (vo.before_mask IN (5, 6, 7) AND vo.after_mask IN (1, 2, 3, 4))
    OR (vo.before_mask = 3 AND vo.after_mask IN (1, 2, 4)),
    FALSE
  ) AS shown_in_panel_b,
  vo.rank_lowered,
  vo.top_rank_flagged_scvs,
  vo.resolution_flagged_scvs,
  vo.flagged_scvs,
  COALESCE(vo.lower_rank_conflict_resolved, FALSE) AS lower_rank_conflict_resolved,
  TO_JSON_STRING(vo.rank_groups) AS rank_groups,
  vf.flagged_batch_count,
  vf.any_flag_retracted,
  vf.reasons
FROM reviewed r
CROSS JOIN cutoff
LEFT JOIN variant_outcomes vo
  ON vo.variation_id = r.variation_id
LEFT JOIN variant_flags vf
  ON vf.variation_id = r.variation_id
LEFT JOIN variant_labels vl
  ON vl.variation_id = r.variation_id
LEFT JOIN state_labels bl
  ON bl.mask = vo.before_mask
LEFT JOIN state_labels al
  ON al.mask = vo.after_mask
);

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure4_variant_outcomes_view` AS
SELECT *
FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(CAST(NULL AS DATE))
ORDER BY variation_id;

-- Figure 4A: one row per pie slice, in chart order.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure4a_outcomes_view` AS
WITH slices AS (
  SELECT * FROM UNNEST([
    STRUCT(1 AS chart_order, 'Conflict resolved' AS outcome),
    (2, 'Conflict reduced'),
    (3, 'Classification removed'),
    (4, 'Flagged, not resolved'),
    (5, 'No change')
  ])
),
counts AS (
  SELECT
    figure_4a_outcome AS outcome,
    ANY_VALUE(as_of_batch_release_date) AS as_of_batch_release_date,
    COUNT(*) AS variants
  FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(CAST(NULL AS DATE))
  GROUP BY figure_4a_outcome
)
SELECT
  MAX(c.as_of_batch_release_date) OVER () AS as_of_batch_release_date,
  s.chart_order,
  s.outcome,
  COALESCE(c.variants, 0) AS variants,
  ROUND(100 * COALESCE(c.variants, 0) / SUM(c.variants) OVER (), 2) AS percent_of_reviewed
FROM slices s
LEFT JOIN counts c
  ON c.outcome = s.outcome
ORDER BY s.chart_order;

-- Figure 4A: the finer outcomes behind each slice.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure4a_outcome_detail_view` AS
SELECT
  as_of_batch_release_date,
  figure_4a_outcome AS outcome,
  outcome_detail,
  COUNT(*) AS variants,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percent_of_reviewed
FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(CAST(NULL AS DATE))
GROUP BY as_of_batch_release_date, outcome, outcome_detail
ORDER BY outcome, outcome_detail;

-- Figure 4B: one row per Sankey flow. Non-medically significant conflicts are the
-- separate Sankey.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure4b_flows_view` AS
SELECT
  as_of_batch_release_date,
  conflict_group,
  panel_b_node AS conflict_when_flagged,
  after_state AS state_after_flagging,
  COUNT(*) AS variants,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY conflict_group), 2) AS percent_of_group
FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(CAST(NULL AS DATE))
WHERE shown_in_panel_b
GROUP BY as_of_batch_release_date, conflict_group, conflict_when_flagged, state_after_flagging
ORDER BY conflict_group, conflict_when_flagged, state_after_flagging;

-- Figure 4B at its most granular: one row per exact starting conflict and exact
-- classification groups left, so the rows can be collated into any grouping. Filter
-- manuscript_figure4_variant_outcomes_view on conflict_combination (the starting
-- conflict) and after_classif_group (the groups left) to list the variants in a row.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure4b_final_classifications_view` AS
WITH state_order AS (
  SELECT * FROM UNNEST([
    STRUCT(1 AS chart_order, 'P/LP' AS state),
    (2, 'VUS'),
    (3, 'VUS vs B/LB'),
    (4, 'B/LB')
  ])
),
final_groups AS (
  SELECT
    as_of_batch_release_date,
    conflict_group,
    panel_b_node AS conflict_when_flagged,
    conflict_combination AS classification_to_start,
    before_top_rank AS top_rank_to_start,
    after_state AS state_after_flagging,
    after_classif_group AS classifications_left,
    after_top_rank AS top_rank_after,
    COUNT(*) AS variants,
    SUM(resolution_flagged_scvs) AS flagged_scvs
  FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(CAST(NULL AS DATE))
  WHERE shown_in_panel_b
  GROUP BY
    as_of_batch_release_date, conflict_group, conflict_when_flagged, classification_to_start,
    top_rank_to_start, state_after_flagging, classifications_left, top_rank_after
)
SELECT
  g.as_of_batch_release_date,
  g.conflict_group,
  g.conflict_when_flagged,
  g.classification_to_start,
  g.top_rank_to_start,
  o.chart_order,
  g.state_after_flagging,
  g.classifications_left,
  g.top_rank_after,
  g.variants,
  g.flagged_scvs,
  ROUND(100 * g.variants / SUM(g.variants) OVER (PARTITION BY g.conflict_group), 2) AS percent_of_group
FROM final_groups g
JOIN state_order o
  ON o.state = g.state_after_flagging
ORDER BY g.conflict_group, g.classification_to_start, o.chart_order, g.variants DESC;

-- Every medically significant combination, including variants that stayed in
-- conflict and so are not drawn in panel B.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure4b_conflict_combinations_view` AS
SELECT
  as_of_batch_release_date,
  conflict_combination,
  panel_b_node,
  after_state AS state_after_flagging,
  shown_in_panel_b,
  COUNT(*) AS variants
FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(CAST(NULL AS DATE))
WHERE conflict_group = 'medically significant'
GROUP BY as_of_batch_release_date, conflict_combination, panel_b_node, state_after_flagging, shown_in_panel_b
ORDER BY conflict_combination, variants DESC;

-- Every rank group that had a flagging candidate, whether or not it decides the
-- aggregate.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure4_rank_group_transitions_view` AS
WITH state_labels AS (
  SELECT * FROM UNNEST([
    STRUCT(0 AS mask, 'No classification' AS state),
    (1, 'B/LB'),
    (2, 'VUS'),
    (3, 'VUS vs B/LB'),
    (4, 'P/LP'),
    (5, 'P/LP vs B/LB'),
    (6, 'P/LP vs VUS'),
    (7, 'P/LP vs VUS vs B/LB')
  ])
),
rank_group_rows AS (
  SELECT
    v.as_of_batch_release_date,
    v.before_top_rank,
    CAST(JSON_VALUE(g, '$.rank') AS INT64) AS rank,
    CAST(JSON_VALUE(g, '$.flagged_count') AS INT64) AS flagged_count,
    CAST(JSON_VALUE(g, '$.before_mask') AS INT64) AS before_mask,
    CAST(JSON_VALUE(g, '$.after_mask') AS INT64) AS after_mask
  FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(CAST(NULL AS DATE)) v,
    UNNEST(JSON_QUERY_ARRAY(v.rank_groups)) g
)
SELECT
  g.as_of_batch_release_date,
  g.rank,
  IF(g.rank = g.before_top_rank, 'top', 'lower') AS group_position,
  b.state AS state_before,
  a.state AS state_after,
  COUNT(*) AS variants
FROM rank_group_rows g
JOIN state_labels b
  ON b.mask = g.before_mask
JOIN state_labels a
  ON a.mask = g.after_mask
WHERE g.flagged_count > 0
GROUP BY g.as_of_batch_release_date, g.rank, group_position, state_before, state_after
ORDER BY g.rank DESC, group_position DESC, variants DESC;
