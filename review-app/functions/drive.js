// drive.js — thin, injected Google Drive writer for submission files. The
// `drive` client (googleapis drive_v3) is injected so the orchestration
// (trash any same-name file in the target folder, then create) unit-tests with
// a fake — the wiring (real client + auth) is deploy-time.
//
// Non-impact: writes ONLY to the configured folder id, which pre-cutover is a
// SEPARATE dev folder (never the live submission folder), and the filenames are
// `v4-DEV-` prefixed (see submission.js), so it cannot touch or shadow live
// submission files. Always `supportsAllDrives` — the target is a Shared Drive
// the Functions runtime SA must be a member of (see review-app/README.md).
function makeDriveWriter(drive) {
  return {
    async writeNdjson({ folderId, filename, content }) {
      if (!folderId) throw new Error('drive.writeNdjson: folderId required');
      // Trash any existing same-name file so re-generate is idempotent (scoped
      // to THIS folder — never a name-based sweep of the live folder).
      const safeName = String(filename).replace(/'/g, "\\'");
      const list = await drive.files.list({
        q: `name = '${safeName}' and '${folderId}' in parents and trashed = false`,
        fields: 'files(id)', supportsAllDrives: true, includeItemsFromAllDrives: true
      });
      for (const f of (list.data.files || [])) {
        await drive.files.update({ fileId: f.id, requestBody: { trashed: true }, supportsAllDrives: true });
      }
      const created = await drive.files.create({
        requestBody: { name: filename, parents: [folderId], mimeType: 'application/json' },
        media: { mimeType: 'application/json', body: content },
        fields: 'id, webViewLink', supportsAllDrives: true
      });
      return { id: created.data.id, link: created.data.webViewLink };
    }
  };
}

module.exports = { makeDriveWriter };
