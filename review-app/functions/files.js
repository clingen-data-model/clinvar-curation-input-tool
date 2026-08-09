// files.js — generated-submission-file management. Lists a batch's generated
// NDJSON files in the Drive folder, lets a curator TRASH draft files from the
// app, and (post-finalize) bulk-removes the drafts — but NEVER the finalized
// submission file (the name recorded in cvc_review_config.last_finalized_file).
// Injected drive + getFinalizedName() → unit-testable; no direct API/auth here.
const { submissionFilePrefix } = require('./submission.js');

function makeFilesHandler({ drive, folderId, env, getFinalizedName }) {
  const finalized = () => (getFinalizedName ? getFinalizedName() : Promise.resolve(null));
  const listBatch = (batchId) => drive.listFiles({ folderId, namePrefix: submissionFilePrefix({ batchId, env }) });
  return {
    // All generated files for a batch, each flagged `protected` if it is the
    // finalized submission file.
    async list({ batchId }) {
      const [files, fin] = [await listBatch(batchId), await finalized()];
      return files.map((f) => ({ ...f, protected: !!fin && f.name === fin }));
    },
    // Trash ONE file — refused if it is the finalized submission file.
    async remove({ fileId }) {
      const fin = await finalized();
      const name = await drive.getName({ fileId });
      if (fin && name === fin) {
        throw Object.assign(new Error('cannot delete the finalized submission file'), { code: 'protected' });
      }
      await drive.trashFile({ fileId });
      return { trashed: fileId, name };
    },
    // Trash ALL of a batch's generated files EXCEPT the finalized one (the
    // post-finalize "remove all drafts" cleanup).
    async removeDrafts({ batchId }) {
      const [files, fin] = [await listBatch(batchId), await finalized()];
      let removed = 0;
      for (const f of files) {
        if (fin && f.name === fin) continue; // keep the finalized file
        await drive.trashFile({ fileId: f.id });
        removed++;
      }
      return { removed, kept: files.length - removed };
    }
  };
}

module.exports = { makeFilesHandler };
