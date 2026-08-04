-- =============================================================================
-- CVC Batch Enriched View
-- =============================================================================
--
-- Purpose:
--   Creates a view that enriches cvc_clinvar_batches with:
--   - batch_accepted_date: Derived from batch_end_date (when ClinVar accepted the batch)
--   - grace_period_end_date: 60 days after acceptance (when flags are applied)
--   - first_release_after_grace_period: The next ClinVar release after grace ends
--
-- Dependencies:
--   - clinvar_curator.cvc_clinvar_batches
--   - clinvar_ingest.clinvar_releases
--
-- Note: batch_end_date in cvc_clinvar_batches is the date ClinVar accepted/processed
-- the batch. Previously this was maintained in a separate cvc_batch_accepted_dates
-- table loaded from a TSV file; now uses the source table directly.
--
-- Output:
--   - clinvar_curator.cvc_batches_enriched
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_batches_enriched`
AS
SELECT
  b.batch_id,
  b.finalized_datetime,
  b.batch_release_date,
  b.batch_start_date,
  b.batch_end_date,
  b.submission,
  -- batch_end_date IS the accepted date (previously from separate TSV table)
  b.batch_end_date AS batch_accepted_date,
  -- 60-day grace period ends on this date
  DATE_ADD(b.batch_end_date, INTERVAL 60 DAY) AS grace_period_end_date,
  -- The first ClinVar release after the grace period ends
  (
    SELECT MIN(release_date)
    FROM `clinvar_ingest.clinvar_releases`
    WHERE release_date > DATE_ADD(b.batch_end_date, INTERVAL 60 DAY)
  ) AS first_release_after_grace_period
FROM `clinvar_curator.cvc_clinvar_batches` b
WHERE b.batch_end_date IS NOT NULL
ORDER BY b.batch_id;
