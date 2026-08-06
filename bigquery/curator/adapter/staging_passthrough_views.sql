-- Passthrough staging views for a shadow `_v4` lineage.
--
-- The shadow lineage's cvc_annotations_base_mv joins against
-- `@@DATASET@@.cvc_clinvar_reviews` / `cvc_clinvar_submissions` /
-- `cvc_clinvar_batches`, and the impact-analysis lineage joins against
-- `@@DATASET@@.cvc_rejected_scvs`. Rather than re-bootstrapping (and diverging
-- from) that staging state, the shadow reads the identical legacy rows through
-- plain `SELECT *` views of the same names. No id remap is needed — all staging
-- ids resolve directly against the shadow's annotation source (see
-- `00-initialize-cvc-tables.sql`'s `@@ANNO_ID@@` token). Legacy
-- `clinvar_curator.*` objects are the single source of review/submission/batch
-- state and are read-only here — never modified.
--
-- Parameterized by @@STAGING_DATASET@@ (the shadow's dataset) so ONE file serves
-- both shadows; the SOURCE stays legacy `clinvar_curator` (shared staging):
--   prod shadow: STAGING_DATASET=clinvar_curator_v4  (default)
--   dev shadow:  STAGING_DATASET=clinvar_curator_v4_dev
-- Applied with: sed "s/@@STAGING_DATASET@@/<dataset>/g" file | bq query ...

CREATE OR REPLACE VIEW `clingen-dev.@@STAGING_DATASET@@.cvc_clinvar_reviews`     AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews`;
CREATE OR REPLACE VIEW `clingen-dev.@@STAGING_DATASET@@.cvc_clinvar_submissions` AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions`;
CREATE OR REPLACE VIEW `clingen-dev.@@STAGING_DATASET@@.cvc_clinvar_batches`     AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_batches`;
CREATE OR REPLACE VIEW `clingen-dev.@@STAGING_DATASET@@.cvc_rejected_scvs`       AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_rejected_scvs`;
