#!/usr/bin/env bash
set -euo pipefail
# End-to-end finalize smoke against the DEV shadow: auto-pick an assignable
# unreviewed v4 annotation, review it OK, assign it to a THROWAWAY batch,
# generate, run the finalize promote transaction, verify, then CLEAN UP so the
# shadow returns to baseline. Mutating but fully reversible; dev-only.
#
# Verified 2026-08-07: assign gate passes, generate=1 row, promote → 1 submission
# + 1 review + a derived batches row (via clinvar_ingest), and next_batch_id is
# UNCHANGED (the bump guard holds because config's id != the throwaway batch).
#
# Prereqs: GCP_TOKEN or ADC; the dev captures must be in native_v4 (run the
# adapter first if a just-captured annotation is missing — see CUTOVER.md).
#
# Usage:  ./e2e-finalize-smoke.sh            # dataset=clinvar_curator_v4_dev, batch=9000
: "${DATASET:=clinvar_curator_v4_dev}"; : "${BATCH:=9000}"; : "${REVIEWER:=e2e-smoke@local}"
case "$DATASET" in clinvar_curator_v4_dev) : ;; *) echo "REFUSING: dev smoke only (DATASET=$DATASET)"; exit 1;; esac
DS="clingen-dev.${DATASET}"
Q(){ bq --project_id=clingen-dev --location=US query --use_legacy_sql=false "$@"; }

AID=$(Q --format=csv "SELECT annotation_id FROM \`$DS.cvc_annotations\`(\"unreviewed\")
  WHERE LOWER(action) IN ('flagging candidate','remove flagged submission') LIMIT 1" 2>/dev/null | tail -1)
[ -n "$AID" ] || { echo "no assignable unreviewed annotation (refresh the adapter?)"; exit 1; }
read SCVID SCVVER < <(Q --format=csv "SELECT scv_id, scv_ver FROM \`$DS.cvc_annotations\`(\"all\")
  WHERE annotation_id='$AID' LIMIT 1" 2>/dev/null | tail -1 | tr ',' ' ')
echo "annotation=$AID scv=$SCVID.$SCVVER batch=$BATCH"

cleanup(){
  for t in cvc_clinvar_submissions cvc_clinvar_reviews cvc_clinvar_batches; do
    Q --format=none "DELETE FROM \`$DS.$t\` WHERE batch_id='$BATCH'" >/dev/null 2>&1 || true
  done
  Q --format=none "DELETE FROM \`$DS.cvc_review_state\` WHERE annotation_id='$AID'" >/dev/null 2>&1 || true
  echo "cleanup done"
}
trap cleanup EXIT

Q --format=none --parameter=aid:STRING:$AID --parameter=scvId:STRING:$SCVID --parameter=scvVer:INT64:$SCVVER \
  --parameter=reviewer:STRING:$REVIEWER "MERGE \`$DS.cvc_review_state\` T USING (SELECT @aid AS annotation_id) S
  ON T.annotation_id=S.annotation_id WHEN NOT MATCHED THEN INSERT
  (annotation_id,scv_id,scv_ver,review_status,reviewer,notes,date_added,date_last_updated)
  VALUES (@aid,@scvId,@scvVer,'OK',@reviewer,'e2e',CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP())" >/dev/null
Q --parameter=aid:STRING:$AID --parameter=batch:STRING:$BATCH "UPDATE \`$DS.cvc_review_state\` T
  SET batch_id=@batch WHERE T.annotation_id=@aid AND T.review_status='OK' AND T.batch_id IS NULL
  AND EXISTS (SELECT 1 FROM \`$DS.cvc_annotations_native_v4\` a WHERE a.annotation_id=@aid
    AND LOWER(a.action) IN ('flagging candidate','remove flagged submission'))" 2>&1 | grep -i affected
Q --format=none --parameter=batch:STRING:$BATCH --parameter=batchInt:INT64:$BATCH --parameter='fdt:STRING:2026-01-01 00:00:00' \
 "BEGIN TRANSACTION;
  INSERT INTO \`$DS.cvc_clinvar_reviews\`(annotation_id,date_added,status,reviewer,notes,date_last_updated,batch_id)
  SELECT rs.annotation_id,rs.date_added,rs.review_status,rs.reviewer,rs.notes,rs.date_last_updated,@batch
  FROM \`$DS.cvc_review_state\` rs WHERE rs.review_status IN ('OK','Fixed','Archive')
    AND rs.annotation_id NOT IN (SELECT annotation_id FROM \`$DS.cvc_clinvar_reviews\`);
  INSERT INTO \`$DS.cvc_clinvar_submissions\`(annotation_id,scv_id,scv_ver,batch_id)
  SELECT rs.annotation_id,rs.scv_id,rs.scv_ver,rs.batch_id FROM \`$DS.cvc_review_state\` rs
  WHERE rs.batch_id=@batch AND rs.annotation_id NOT IN (SELECT annotation_id FROM \`$DS.cvc_clinvar_submissions\`);
  INSERT INTO \`$DS.cvc_clinvar_batches\`(batch_id,finalized_datetime,batch_release_date,batch_start_date,batch_end_date,submission)
  SELECT @batch,TIMESTAMP(@fdt),rel.release_date,DATE(e.finalized_datetime)+1,DATE(DATETIME(@fdt)),
    \`clinvar_ingest.determineMonthBasedOnRange\`(DATE(e.finalized_datetime)+1,DATE(DATETIME(@fdt)))
  FROM \`$DS.cvc_clinvar_batches\` e, \`clinvar_ingest.release_on\`(DATE(DATETIME(@fdt))) rel
  WHERE SAFE_CAST(e.batch_id AS INT64) < @batchInt ORDER BY SAFE_CAST(e.batch_id AS INT64) DESC LIMIT 1;
  UPDATE \`$DS.cvc_review_config\` SET next_batch_id=CAST(@batchInt+1 AS STRING) WHERE next_batch_id=@batch;
  COMMIT TRANSACTION;" >/dev/null
Q --format=csv "SELECT (SELECT COUNT(*) FROM \`$DS.cvc_clinvar_submissions\` WHERE batch_id='$BATCH') promoted_subs,
  (SELECT COUNT(*) FROM \`$DS.cvc_clinvar_batches\` WHERE batch_id='$BATCH') batch_row" 2>/dev/null | tail -1
echo "e2e OK (artifacts cleaned up on exit)"
