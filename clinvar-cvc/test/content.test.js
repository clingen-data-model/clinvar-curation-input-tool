import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { handleInitializePopup } = require('../content.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');

describe('content.handleInitializePopup', () => {
  beforeEach(() => { document.documentElement.innerHTML = html; });
  it('returns scraped data for an initializePopup message', () => {
    const data = handleInitializePopup({ from: 'popup', subject: 'initializePopup' }, document);
    expect(data).not.toBeNull();
    expect(data.vcv).toBe('VCV000590935.4');
    expect(data.row.length).toBe(3);
  });
  it('returns null for unrelated messages', () => {
    expect(handleInitializePopup({ from: 'popup', subject: 'other' }, document)).toBeNull();
  });
});
