import { describe, it, expect, beforeAll } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, '../popup.html'), 'utf8');

describe('popup.html markup', () => {
  beforeAll(() => {
    const bodyMatch = html.match(/<body[^>]*>([\s\S]*)<\/body>/i);
    document.body.innerHTML = bodyMatch ? bodyMatch[1] : html;
  });

  it.each([
    'env-banner',
    'scvselect',
    'action',
    'reason',
    'notes',
    'save',
    'status'
  ])('has an element with id "%s"', (id) => {
    expect(document.getElementById(id)).not.toBeNull();
  });

  it('does not load any CDN/remote script or stylesheet (MV3 CSP)', () => {
    expect(html).not.toMatch(/https?:\/\//);
  });

  it('loads scripts in the required order', () => {
    const scripts = [...html.matchAll(/<script[^>]*src="([^"]+)"/g)].map((m) => m[1]);
    expect(scripts).toEqual([
      'env.js',
      'firebase-config.js',
      'vocab.js',
      'annotation.js',
      'popup-view.js',
      'popup.js'
    ]);
  });
});
