/**
 * Per-environment Firestore config. The OAuth client_id is NOT here — it stays
 * in manifest.json (one client, whitelisted in BOTH projects' Firebase Google
 * providers), so a single loaded extension can switch DATA environments safely.
 * Only public identifiers below.
 */
const ENVIRONMENTS = {
  prod: {
    projectId: 'clingen-cvc',
    apiKey: 'AIzaSyApRKUWc9WnpLB7cryD9VDp7R7MTtm3tBM',
    databaseId: '(default)',
    collection: 'clinvar_cvc_ext_annotations'
  },
  dev: {
    projectId: 'clingen-cvc-dev',
    apiKey: 'PASTE_DEV_WEB_API_KEY_HERE',
    databaseId: '(default)',
    collection: 'clinvar_cvc_ext_annotations'
  }
};

function resolveConfig(env) {
  const key = (env || 'prod').toLowerCase();
  if (!ENVIRONMENTS[key]) throw new Error(`Unknown env "${env}"`);
  return { env: key, ...ENVIRONMENTS[key] };
}

if (typeof window !== 'undefined') { window.resolveConfig = resolveConfig; window.ENVIRONMENTS = ENVIRONMENTS; }
if (typeof module !== 'undefined' && module.exports) { module.exports = { resolveConfig, ENVIRONMENTS }; }
