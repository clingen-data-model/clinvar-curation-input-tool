// Shapes returned by the /api backend (see functions/queue.js, config.js, reflag.js).
// Kept loose where the backend passes BQ values through; the UI normalizes.

export type BqVal = string | number | boolean | null | { value: string | number };

export interface Config {
  nextBatchId: string | null;
  reviewers: string[];
  submissionRecipients: string[];
  submissionCc: string[];
  lastFinalizedFile: string | null;
  baseReleaseDate: string | null;
  currentRelease: string | null;
  releaseStale: boolean;
}

export interface QueueRow {
  annotation_id: string;
  variation_id: string;
  vcv_id: string;
  scv_id: string;
  scv_ver: BqVal;
  submitter_id: string;
  submitter_name?: string;
  action: string;
  reason: string;
  notes: string;
  clinvar_review_status?: string;
  classif_type?: string;
  latest_scv_classification?: string;
  is_outdated_scv: boolean | null;
  is_outdated_vcv: boolean | null;
  is_moved_scv: boolean | null;
  is_deleted_scv: boolean | null;
  is_latest_annotation: boolean | null;
  deleted_scv_release_date?: BqVal;
  has_prior_scv_id_annotation: boolean | null;
  has_prior_scv_ver_annotation: boolean | null;
  has_prior_submission_batch_id: boolean | null;
  latest_scv_ver?: BqVal;
  auto_status?: string;
  auto_note?: string;
  fresh?: boolean;
  rs_review_status: string | null;
  rs_notes: string | null;
  rs_batch_id: string | null;
}

export interface HistoryRow {
  scv_id: string;
  scv_ver: BqVal;
  annotated_date: BqVal;
  curator: string;
  action: string;
  reason: string;
  review_status: string | null;
  reviewer: string | null;
  batch_id: string | null;
  is_submitted_annotation: boolean | null;
}

export interface ReflagCandidate {
  scv_id: string;
  variation_id: string;
  vcv_id: string;
  submitter_id: string;
  submitter_name: string;
  orig_batch_id: string;
  orig_annotation_id: string;
  flagging_reason: string;
  outcome: string;
  resubmission_reason: string;
  current_scv_ver: BqVal;
  current_vcv_ver: BqVal;
  current_classification: string;
  current_classif_type: string;
  is_autoreflag: boolean;
  was_reclassified: boolean;
  already_reflagged: boolean;
  version_bump_count: BqVal;
}

export interface GenerateResult {
  count: number;
  filename?: string;
  link?: string | null;
  mailto?: string | null;
  warnings?: { needsReview?: number };
  finalized?: boolean;
}

export interface GeneratedFile { id: string; name: string; link: string; protected: boolean }

// BQ DATE/TIMESTAMP come back as { value } — unwrap to the scalar.
export const bqv = (v: BqVal | undefined): string => {
  if (v == null) return '';
  if (typeof v === 'object' && 'value' in v) return String(v.value);
  return String(v);
};
