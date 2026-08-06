-- Passthrough staging views for the shadow `clinvar_curator_v4` lineage.
--
-- The shadow lineage's cvc_annotations_base_mv (deployed with
-- DATASET=clinvar_curator_v4) joins against `@@DATASET@@.cvc_clinvar_reviews`
-- / `cvc_clinvar_submissions` / `cvc_clinvar_batches`, and the impact-analysis
-- lineage joins against `@@DATASET@@.cvc_rejected_scvs`. Rather than
-- re-bootstrapping (and diverging from) that staging state, the shadow reads
-- the identical legacy rows through plain `SELECT *` views of the same names.
-- No id remap is needed — all staging ids resolve directly against the
-- shadow's annotation source (see `00-initialize-cvc-tables.sql`'s
-- `@@ANNO_ID@@` token). Legacy `clinvar_curator.*` objects are read-only here
-- and are never modified.

CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_reviews`     AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews`;
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_submissions` AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions`;
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_batches`     AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_batches`;
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_rejected_scvs`       AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_rejected_scvs`;
