# S1+S2 Foundation (Environments + Test Infra) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if
> subagents available) or superpowers:executing-plans to implement this plan. Steps
> use checkbox (`- [ ]`) syntax for tracking. Run everything from the repo root
> unless a step says otherwise. Parent roadmap:
> `docs/superpowers/plans/2026-08-01-clinvar-cvc-production.md`.

**Goal:** Stand up a Vitest test harness for the extension and a runtime dev/prod
environment switch, so all later work is test-driven and trialable against a
disposable `clingen-cvc-dev` project without touching production.

**Architecture:** Dev-only Node tooling (`package.json` + Vitest + jsdom) lives in
`clinvar-cvc/`; the shipped MV3 extension stays build-free. A pure `env.js` module
resolves per-environment Firestore config (projectId/apiKey/databaseId/collection);
`firebase-config.js` becomes a thin selector. The OAuth `client_id` stays shared in
`manifest.json` (whitelisted in both projects' Firebase Google providers), so one
loaded extension can switch data environments via a constant/toggle.

**Tech Stack:** Vitest, jsdom, Node ≥18, existing vanilla MV3 JS, gcloud/firebase CLIs.

**Decisions in force:** D1=A (clingen-cvc=prod, add clingen-cvc-dev), D3=A (Vitest+jsdom),
D5 (config-constant env selection; shared OAuth client whitelisted in both projects).

---

## File Structure

- Create `clinvar-cvc/package.json` — dev tooling + `test` script (NOT shipped; MV3 ignores it).
- Create `clinvar-cvc/vitest.config.js` — jsdom environment, globals on.
- Create `clinvar-cvc/test/setup.js` — `chrome.*` + `fetch` mocks.
- Create `clinvar-cvc/test/getMatch.test.js` — first unit test (pure, imports `scvc/content.js`).
- Create `clinvar-cvc/test/fixtures/clinvar-variation.html` — captured ClinVar page.
- Create `clinvar-cvc/test/scrape.characterization.test.js` — pins `scvc` scraper output.
- Create `clinvar-cvc/env.js` — pure `resolveConfig(env)`.
- Create `clinvar-cvc/test/env.test.js` — env-resolution tests.
- Modify `clinvar-cvc/firebase-config.js` — use `resolveConfig`; add prod+dev blocks.
- Modify `clinvar-cvc/popup.html` — load `env.js` before `firebase-config.js`; dev banner element.
- Modify `clinvar-cvc/popup.js` — show dev banner when env != prod.
- Modify `clinvar-cvc/setup-clingen-cvc.sh` — replace hardcoded `PROJECT`/`MY_EMAIL` with `${CVC_PROJECT:-...}`/`${CVC_EMAIL:-...}` env overrides so it can provision dev.
- Create `clinvar-cvc/.gitignore` — ignore `node_modules/`.

---

## Chunk 1: S2 — Test harness

### Task 1: Dev tooling scaffold

**Files:**
- Create: `clinvar-cvc/package.json`, `clinvar-cvc/vitest.config.js`, `clinvar-cvc/.gitignore`

- [ ] **Step 1: Create `clinvar-cvc/.gitignore`**

```
node_modules/
coverage/
```

- [ ] **Step 2: Create `clinvar-cvc/package.json`**

```json
{
  "name": "clinvar-cvc-extension",
  "version": "4.0.0-dev",
  "private": true,
  "description": "Dev tooling for the ClinVar CvC extension (not shipped with the MV3 bundle).",
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "devDependencies": {
    "jsdom": "^25.0.0",
    "vitest": "^2.1.0"
  }
}
```

> ⚠️ **Do NOT add `"type": "module"`.** The extension's runtime files (`env.js`
> here, `scvc/content.js`) are CommonJS (`module.exports`) and the tests load them
> with `createRequire(...).require('../env.js')`. Under `"type":"module"` that
> `require` throws `ERR_REQUIRE_ESM` (Node 18/20) or returns an empty namespace
> (Node ≥22.12) — so `resolveConfig` would be `undefined`. Leaving the package as
> CommonJS keeps those requires working; Vitest still runs the ESM test files and
> `vitest.config.js` because Vite transforms them regardless of the package type.

- [ ] **Step 3: Create `clinvar-cvc/vitest.config.js`**

```js
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./test/setup.js'],
    include: ['test/**/*.test.js']
  }
});
```

- [ ] **Step 4: Install and verify the runner**

Run (from `clinvar-cvc/`): `npm install && npx vitest run`
Expected: install succeeds; Vitest runs and reports "No test files found" (or 0 tests).

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/package.json clinvar-cvc/vitest.config.js clinvar-cvc/.gitignore
git commit -m "test(cvc): add Vitest + jsdom dev harness"
```

### Task 2: chrome/fetch mocks + first pure unit test

**Files:**
- Create: `clinvar-cvc/test/setup.js`, `clinvar-cvc/test/getMatch.test.js`
- Under test: `scvc/content.js` (read-only; already `module.exports` `getMatch`)

- [ ] **Step 1: Write the mock setup**

`clinvar-cvc/test/setup.js`:
```js
import { vi } from 'vitest';

// Minimal chrome.* surface used by the extension; expand per test as needed.
globalThis.chrome = {
  runtime: { sendMessage: vi.fn(), onMessage: { addListener: vi.fn() }, lastError: null },
  identity: {
    getProfileUserInfo: vi.fn((opts, cb) => cb({ email: 'tester@example.com' })),
    getAuthToken: vi.fn((opts, cb) => cb('fake-google-token'))
  },
  storage: { local: { get: vi.fn((k, cb) => cb({})), set: vi.fn((o, cb) => cb && cb()) } },
  tabs: { query: vi.fn(), sendMessage: vi.fn() }
};

globalThis.fetch = vi.fn();
```

- [ ] **Step 2: Write the failing test**

`clinvar-cvc/test/getMatch.test.js`:
```js
import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { getMatch } = require('../../scvc/content.js');

describe('getMatch', () => {
  it('returns the requested capture group', () => {
    expect(getMatch('Accession: VCV000012345.1', /Accession:\s*(VCV\d+\.\d+)/, 1))
      .toBe('VCV000012345.1');
  });
  it('returns empty string on no match', () => {
    expect(getMatch('nothing here', /(SCV\d+)/, 1)).toBe('');
  });
});
```

- [ ] **Step 3: Run to verify it fails (import path / env not yet right)**

Run: `cd clinvar-cvc && npx vitest run test/getMatch.test.js`
Expected: initially may FAIL if `scvc/content.js` top-level code throws under jsdom.
If it fails on `chrome`/`document` at import, confirm the `typeof` guards in
`scvc/content.js` cover it (they do). Fix the import approach if needed.

- [ ] **Step 4: Make it pass**

No production change expected — `getMatch` is pure and exported. If import fails,
the only allowed fix here is the test's import mechanism (do NOT modify `scvc/`).

- [ ] **Step 5: Run to verify pass**

Run: `cd clinvar-cvc && npm test`
Expected: 2 passing tests.

- [ ] **Step 6: Commit**

```bash
git add clinvar-cvc/test/setup.js clinvar-cvc/test/getMatch.test.js
git commit -m "test(cvc): harness mocks + first pure unit test (getMatch)"
```

### Task 3: Characterization test for the ClinVar scraper

Pins `scvc/content.js` `extractClinVarData()` output on a real page BEFORE it is
ported/refactored in S0 — the safety net that proves the refactor is behavior-preserving.

**Files:**
- Create: `clinvar-cvc/test/fixtures/clinvar-variation.html`, `clinvar-cvc/test/scrape.characterization.test.js`

- [ ] **Step 1: Use the existing captured fixture**

The repo already has a usable capture at
`testing/html-samples/example-clinvar-page.html` (115 KB) — it contains every
selector `extractClinVarData()` needs (`new-variant-details`, `germline-section`,
`germline-stars-icon`, `variant-details-table`, `timeline-table`,
`submissions-germline-list` with 3 `germline-sub-col` rows / ≥2 SCVs, VCV, and
"Variation ID"). Copy it in:

```bash
mkdir -p clinvar-cvc/test/fixtures
cp testing/html-samples/example-clinvar-page.html clinvar-cvc/test/fixtures/clinvar-variation.html
```

> Note: it's not confirmed this page includes a *flagged* submission. Treat the
> flagged-submission edge case as a **follow-up fixture** (capture one later and
> add a second characterization test); do not block this task on it.

- [ ] **Step 2: Write the characterization test**

`clinvar-cvc/test/scrape.characterization.test.js`:
```js
import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const { extractClinVarData } = require('../../scvc/content.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');

describe('extractClinVarData (characterization of scvc scraper)', () => {
  beforeEach(() => { document.documentElement.innerHTML = html; });

  it('extracts VCV identity + a non-empty SCV list', () => {
    const data = extractClinVarData();
    expect(data.vcv).toMatch(/^VCV\d+/);
    expect(data.variation_id).toMatch(/^\d+$/);
    expect(Array.isArray(data.row)).toBe(true);
    expect(data.row.length).toBeGreaterThan(0);
    // Snapshot the full shape so any future scraper change is caught.
    expect(data).toMatchSnapshot();
  });
});
```

- [ ] **Step 3: Run — generate the snapshot**

Run: `cd clinvar-cvc && npx vitest run test/scrape.characterization.test.js`
Expected: PASS and a snapshot file is written under `test/__snapshots__/`.
Manually eyeball the snapshot: VCV, variation_id, and each SCV's `scv`/`submitter`/
`interp` must be correct for the chosen page. If wrong, the fixture or expectations
are off (still no `scvc/` change).

- [ ] **Step 4: Commit**

```bash
git add clinvar-cvc/test/fixtures/ clinvar-cvc/test/scrape.characterization.test.js clinvar-cvc/test/__snapshots__/
git commit -m "test(cvc): characterization snapshot of the ClinVar scraper"
```

---

## Chunk 2: S1 — Environments

### Task 4: Pure environment resolver (TDD)

**Files:**
- Create: `clinvar-cvc/env.js`, `clinvar-cvc/test/env.test.js`

- [ ] **Step 1: Write the failing test**

`clinvar-cvc/test/env.test.js`:
```js
import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { resolveConfig } = require('../env.js');

describe('resolveConfig', () => {
  it('defaults to prod', () => {
    expect(resolveConfig().projectId).toBe('clingen-cvc');
    expect(resolveConfig().env).toBe('prod');
  });
  it('resolves dev', () => {
    const c = resolveConfig('dev');
    expect(c.projectId).toBe('clingen-cvc-dev');
    expect(c.collection).toBe('clinvar_cvc_ext_annotations');
    expect(c.databaseId).toBe('(default)');
  });
  it('throws on unknown env', () => {
    expect(() => resolveConfig('staging')).toThrow(/unknown env/i);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run test/env.test.js`
Expected: FAIL — `Cannot find module '../env.js'`.

- [ ] **Step 3: Implement `clinvar-cvc/env.js`**

```js
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

// Browser (classic script): expose globals for firebase-config.js.
if (typeof window !== 'undefined') { window.resolveConfig = resolveConfig; window.ENVIRONMENTS = ENVIRONMENTS; }
// Node/Vitest:
if (typeof module !== 'undefined' && module.exports) { module.exports = { resolveConfig, ENVIRONMENTS }; }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npx vitest run test/env.test.js`
Expected: 3 passing (dev apiKey placeholder is fine for this logic test).

> Note: `env.test.js` does NOT assert `dev.apiKey`, so green here does **not** mean
> the dev environment is wired — that happens in Task 6 (real dev apiKey). Don't
> mistake a green Chunk 2 for "dev is ready."

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/env.js clinvar-cvc/test/env.test.js
git commit -m "feat(cvc): env resolver for dev/prod config selection"
```

### Task 5: Wire firebase-config.js + popup dev banner

**Files:**
- Modify: `clinvar-cvc/firebase-config.js`, `clinvar-cvc/popup.html`, `clinvar-cvc/popup.js`

- [ ] **Step 1: Rewrite `firebase-config.js` as a thin selector**

```js
// Active environment: 'prod' (default) or 'dev'. Flip to 'dev' (or load the
// dev-pointed unpacked copy) to trial changes against clingen-cvc-dev.
const ACTIVE_ENV = 'prod';
const FIREBASE_CONFIG = { ...resolveConfig(ACTIVE_ENV), authMode: 'google' };
```

- [ ] **Step 2: Load `env.js` first + add a banner element in `popup.html`**

Before `firebase-config.js`:
```html
<script src="env.js"></script>
```
In the body (top):
```html
<div id="env-banner" style="display:none;background:#b91c1c;color:#fff;font-size:11px;padding:2px 6px;text-align:center;">DEV</div>
```

- [ ] **Step 3: Show the banner when env != prod**

`popup.js` already has a `document.addEventListener('DOMContentLoaded', async () => { ... })`
handler, and `FIREBASE_CONFIG` is a global in scope there (from `firebase-config.js`,
loaded first). Insert this at the **top of that existing handler's body**:
```js
if ((FIREBASE_CONFIG.env || 'prod') !== 'prod') {
  const b = document.getElementById('env-banner');
  if (b) { b.textContent = `DEV — ${FIREBASE_CONFIG.projectId}`; b.style.display = 'block'; }
}
```

- [ ] **Step 4: Manual verify**

Load unpacked `clinvar-cvc/`, confirm normal (prod) load shows no banner and a save
still works. Temporarily set `ACTIVE_ENV='dev'` → banner shows (writes will fail
until Task 6 creates the dev project — expected).

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/firebase-config.js clinvar-cvc/popup.html clinvar-cvc/popup.js
git commit -m "feat(cvc): config-driven env selection + dev banner"
```

### Task 6: Provision `clingen-cvc-dev` (runbook — not TDD)

**Files:** none in-repo (uses `setup-clingen-cvc.sh` + console). Record the dev
`apiKey` into `env.js` when done.

- [ ] **Step 1a: Make `setup-clingen-cvc.sh` env-overridable (one-time)**

The script currently hardcodes `PROJECT="clingen-cvc"` and
`MY_EMAIL="lbabb@broadinstitute.org"`. Change those two lines to read overrides so
the same script builds either project without in-place editing:
```bash
PROJECT="${CVC_PROJECT:-clingen-cvc}"
MY_EMAIL="${CVC_EMAIL:-lbabb@broadinstitute.org}"
```
Commit:
```bash
git add clinvar-cvc/setup-clingen-cvc.sh
git commit -m "chore(cvc): make setup script project/email overridable via env"
```

- [ ] **Step 1b: Provision the dev project**

```bash
cd clinvar-cvc && CVC_PROJECT=clingen-cvc-dev ./setup-clingen-cvc.sh
```
It creates the project, links billing, enables APIs, creates Firestore `(default)`
nam5, deploys rules, seeds the allowlist, and (with the extension manifest present)
grants the compute-SA build roles, deploys the Firestore→BigQuery extension, and
grants Cloud Run Invoker. ⚠️ New project → its OAuth consent screen + Google
provider are console-only (Step 2).

- [ ] **Step 2: Console steps for dev (mirror prod)**

- Google Auth Platform ▸ Audience: External + In production.
- Enable the **Google** provider; under "Whitelist client IDs from external
  projects" add the **same** manifest `client_id` used by prod (so one extension
  works against both).
- Project settings ▸ get the dev **Web apiKey** → paste into `env.js` `dev.apiKey`.

- [ ] **Step 3: Verify dev is isolated**

Set `ACTIVE_ENV='dev'`, reload the extension, submit a test annotation. Confirm it
lands in **clingen-cvc-dev** Firestore and **not** in prod. Then set `ACTIVE_ENV`
back to `'prod'`.

- [ ] **Step 4: Commit the dev apiKey (public) + run full suite**

```bash
cd clinvar-cvc && npm test        # all green
git add clinvar-cvc/env.js
git commit -m "chore(cvc): wire clingen-cvc-dev apiKey for trialing"
```

---

## Definition of done (S1+S2)

- `cd clinvar-cvc && npm test` runs green (getMatch, scraper characterization, env).
- A dev project `clingen-cvc-dev` mirrors prod; flipping `ACTIVE_ENV` routes writes
  there, with a visible DEV banner; prod is never touched during trials.
- The scraper's current behavior is snapshotted, ready to guard the S3→S0 refactor.

**Next sub-plan:** S3 (scvc refactor analysis) → S0 (foundation port), which will
extend this harness with field-mapping and validation tests.
