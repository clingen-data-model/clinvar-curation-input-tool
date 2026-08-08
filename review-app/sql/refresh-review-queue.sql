-- Materialize the enriched-unreviewed set for the FAST review queue.
-- @@DATASET@@ = clinvar_curator_v4_dev [dev] / clinvar_curator_v4 [prod shadow].
--
-- The queue's expensive half is cvc_annotations("unreviewed") — a ~2.5 GB
-- clinvar_ingest join. Run THIS batch-side (after the adapter brings new captures
-- into native_v4, and at finalize when reviewed rows drop) so that scan happens
-- once here, not on every /queue load. The queue then reads this small table +
-- a live LEFT JOIN to cvc_review_state (see functions/queue.js buildQueueSql).
CREATE OR REPLACE TABLE `clingen-dev.@@DATASET@@.cvc_review_queue_base` AS
SELECT
  annotation_id, variation_id, vcv_id, scv_id, scv_ver, submitter_id, submitter_name,
  action, reason, notes, curator, clinvar_review_status, classif_type, latest_scv_classification,
  is_outdated_scv, is_deleted_scv, is_latest_annotation, has_prior_scv_id_annotation,
  latest_scv_ver, annotated_on
FROM `clingen-dev.@@DATASET@@.cvc_annotations`("unreviewed");
