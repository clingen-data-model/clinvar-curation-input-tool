-- 00-review-state-schema.sql — Review & Submit web-app workflow state, in the
-- v4 lineage (@@DATASET@@ = clinvar_curator_v4_dev [dev] / clinvar_curator_v4
-- [prod shadow]). NEVER clinvar_curator (the deploy script's guard enforces).
--
-- Converts the three passthrough staging VIEWS (SELECT * FROM legacy) into REAL
-- writable tables the app owns, seeded by a one-time snapshot of legacy content
-- (gated read-only by the join-integrity check — submissions resolve 100% in
-- base_mv; the 14 orphan reviews are the known ignore=TRUE set, benign under the
-- reviews LEFT-join). Uses DROP VIEW + CTAS because CREATE OR REPLACE TABLE
-- cannot replace a view. The CREATE ... IF NOT EXISTS + seed are idempotent, but
-- the DROP VIEW→CTAS conversion is a ONE-TIME step per environment (once
-- converted the names are tables, not views). Run once per shadow dataset.

-- reviews
DROP VIEW IF EXISTS `clingen-dev.@@DATASET@@.cvc_clinvar_reviews`;
CREATE TABLE IF NOT EXISTS `clingen-dev.@@DATASET@@.cvc_clinvar_reviews` AS
  SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews`;

-- submissions
DROP VIEW IF EXISTS `clingen-dev.@@DATASET@@.cvc_clinvar_submissions`;
CREATE TABLE IF NOT EXISTS `clingen-dev.@@DATASET@@.cvc_clinvar_submissions` AS
  SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions`;

-- batches (CTAS copies the real schema incl. yymm/monyy + the `submission` RECORD)
DROP VIEW IF EXISTS `clingen-dev.@@DATASET@@.cvc_clinvar_batches`;
CREATE TABLE IF NOT EXISTS `clingen-dev.@@DATASET@@.cvc_clinvar_batches` AS
  SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_batches`;

-- In-progress review/assignment state, written by the app (Chunk 4); empty now.
-- scv_id/scv_ver captured at assignment (the SP joins submissions on them);
-- scv_ver INT64 matches cvc_clinvar_submissions.scv_ver (INTEGER). Two review
-- timestamps mirror the reviews table (date_added at auto-review, updated on edit).
CREATE TABLE IF NOT EXISTS `clingen-dev.@@DATASET@@.cvc_review_state` (
  annotation_id     STRING NOT NULL,
  scv_id            STRING,
  scv_ver           INT64,
  review_status     STRING,   -- OK | Fixed | Archive | Question | (null = unreviewed)
  reviewer          STRING,
  notes             STRING,
  batch_id          STRING,   -- null = not assigned to the next batch
  date_added        TIMESTAMP,
  date_last_updated TIMESTAMP
);

-- Single-row config: next batch id + finalize stamp + the reviewer allow-list
-- (distinct from allowed_curators) and submission recipients (NOT the live
-- sheet's named ranges). Reviewers/recipients seeded empty for dev — set before
-- Chunk 4/5 use them.
CREATE TABLE IF NOT EXISTS `clingen-dev.@@DATASET@@.cvc_review_config` (
  next_batch_id          STRING,
  last_finalized_date    TIMESTAMP,
  reviewers              ARRAY<STRING>,
  submission_recipients  ARRAY<STRING>,
  submission_cc          ARRAY<STRING>,
  last_finalized_file    STRING,         -- name of the last finalized submission file (protected from deletion)
  base_release_date      DATE            -- clinvar_ingest release the queue base was last enriched against
);
-- Additive migrations for pre-existing config tables.
ALTER TABLE `clingen-dev.@@DATASET@@.cvc_review_config` ADD COLUMN IF NOT EXISTS last_finalized_file STRING;
ALTER TABLE `clingen-dev.@@DATASET@@.cvc_review_config` ADD COLUMN IF NOT EXISTS base_release_date DATE;
-- Seed the single config row only if the table is empty (idempotent).
INSERT INTO `clingen-dev.@@DATASET@@.cvc_review_config`
  (next_batch_id, last_finalized_date, reviewers, submission_recipients, submission_cc)
SELECT
  CAST((SELECT MAX(SAFE_CAST(batch_id AS INT64)) + 1
        FROM `clingen-dev.@@DATASET@@.cvc_clinvar_batches`) AS STRING),
  NULL, [], [], []
FROM UNNEST([1])   -- a FROM is required for the WHERE NOT EXISTS guard below
WHERE NOT EXISTS (SELECT 1 FROM `clingen-dev.@@DATASET@@.cvc_review_config`);
