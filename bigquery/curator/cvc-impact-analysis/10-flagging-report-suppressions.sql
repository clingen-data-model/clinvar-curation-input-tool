-- =============================================================================
-- CVC Flagging Status Report -- Suppressed Submissions ("hide list")
-- =============================================================================
--
-- Purpose:
--   A small, manually-maintained table of flagging-candidate SUBMISSIONS that
--   should be hidden from the flagging status report
--   (10-flagging-status-report.sql). Each row identifies one submission by
--   (scv_id, scv_ver, batch_id) -- i.e. a specific SCV version submitted in a
--   specific CVC batch.
--
--   The report filters on this table by all three keys, so suppression is scoped
--   to that exact submission. If a NEWER submission for the same SCV shows up in
--   a future batch, it is a different (scv_ver / batch_id) and will NOT be
--   suppressed -- it re-enters the report normally.
--
-- Deploy order:
--   Deploy this table BEFORE (re)creating the report table functions in
--   10-flagging-status-report.sql, which reference it.
--
-- Maintenance:
--   - Add a submission to hide:    INSERT one row (scv_id, scv_ver, batch_id, note).
--   - Stop hiding a submission:    DELETE the corresponding row.
--   The CREATE below is IF NOT EXISTS and the seed is an idempotent MERGE, so
--   re-running this script never drops manually-added rows.
--
-- =============================================================================

CREATE TABLE IF NOT EXISTS `@@DATASET@@.cvc_flagging_report_suppressions`
(
  scv_id STRING NOT NULL,        -- e.g. 'SCV003932453'
  scv_ver INT64 NOT NULL,        -- submitted version, e.g. 1
  batch_id STRING NOT NULL,      -- CVC batch the submission belongs to, e.g. '107'
  note STRING,                   -- optional: why this submission is hidden
  suppressed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);


-- Seed the initial hide list (idempotent: only inserts rows not already present).
MERGE `@@DATASET@@.cvc_flagging_report_suppressions` T
USING (
  SELECT
    s.scv_id,
    s.scv_ver,
    s.batch_id,
    'initial hide list' AS note
  FROM UNNEST([
    STRUCT('SCV003932453' AS scv_id, 1 AS scv_ver, '107' AS batch_id),
    STRUCT('SCV003932457', 2, '107'),
    STRUCT('SCV003932454', 1, '107'),
    STRUCT('SCV003932452', 1, '107'),
    STRUCT('SCV003932456', 1, '107'),
    STRUCT('SCV003932455', 1, '107'),
    STRUCT('SCV002061632', 2, '108'),
    STRUCT('SCV004041830', 1, '115'),
    STRUCT('SCV001164567', 1, '102')
  ]) s
) S
ON  T.scv_id  = S.scv_id
AND T.scv_ver = S.scv_ver
AND T.batch_id = S.batch_id
WHEN NOT MATCHED THEN
  INSERT (scv_id, scv_ver, batch_id, note)
  VALUES (S.scv_id, S.scv_ver, S.batch_id, S.note);
