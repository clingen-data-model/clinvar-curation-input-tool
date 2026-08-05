const { summarizeHistoryByScv, decorateForScv, entriesForScv } = require('../highlight.js');

describe('summarizeHistoryByScv', () => {
  const rows = [
    { scv: 'SCV1', action: 'Flagging Candidate', user_email: 'a@x.org', created_at: '2024-01-02T00:00:00Z' },
    { scv: 'SCV1', action: 'No Change',          user_email: 'b@x.org', created_at: '2024-03-01T00:00:00Z' },
    { scv: 'SCV2', action: 'No Change',          user_email: 'c@x.org', created_at: '2023-05-01T00:00:00Z' }
  ];

  it('groups by scv with a count', () => {
    const m = summarizeHistoryByScv(rows);
    expect(m.SCV1.count).toBe(2);
    expect(m.SCV2.count).toBe(1);
  });

  it('flags an SCV that has ANY Flagging Candidate / Remove Flagged Submission action', () => {
    const m = summarizeHistoryByScv(rows);
    expect(m.SCV1.flagged).toBe(true);   // has a Flagging Candidate
    expect(m.SCV2.flagged).toBe(false);  // only No Change
  });

  it('captures the most-recent action/curator/date per scv', () => {
    const m = summarizeHistoryByScv(rows);
    expect(m.SCV1.lastAction).toBe('No Change');        // 2024-03-01 is newest for SCV1
    expect(m.SCV1.lastWho).toBe('b@x.org');
    expect(m.SCV1.lastWhen).toBe('2024-03-01');
  });

  it('returns {} for empty input', () => {
    expect(summarizeHistoryByScv([])).toEqual({});
  });
});

describe('decorateForScv', () => {
  it('returns null when there is no history for the scv', () => {
    expect(decorateForScv(undefined)).toBeNull();
  });

  it('badges a flagged SCV with a warn class and count', () => {
    const d = decorateForScv({ count: 2, flagged: true, lastAction: 'Flagging Candidate', lastWho: 'a@x.org', lastWhen: '2024-01-02' });
    expect(d.cssClass).toBe('cvc-hl cvc-hl-flagged');
    expect(d.badge).toBe('CvC 2');
    expect(d.tooltip).toContain('Flagging Candidate');
    expect(d.tooltip).toContain('a@x.org');
    expect(d.tooltip).toContain('2024-01-02');
  });

  it('badges a non-flagged annotated SCV with a neutral class', () => {
    const d = decorateForScv({ count: 1, flagged: false, lastAction: 'No Change', lastWho: 'c@x.org', lastWhen: '2023-05-01' });
    expect(d.cssClass).toBe('cvc-hl cvc-hl-noted');
    expect(d.badge).toBe('CvC 1');
  });
});

describe('entriesForScv', () => {
  const rows = [
    { scv: 'SCV1', action: 'Flagging Candidate', reason: 'Outlier claim', notes: 'n1', user_email: 'a@x.org', created_at: '2024-01-02T00:00:00Z' },
    { scv: 'SCV1', action: 'No Change',          reason: '',             notes: '',   user_email: 'b@x.org', created_at: '2024-03-01T00:00:00Z' },
    { scv: 'SCV2', action: 'No Change',          reason: '',             notes: '',   user_email: 'c@x.org', created_at: '2023-05-01T00:00:00Z' }
  ];

  it('returns only the given SCV, newest-first, as display entries', () => {
    const e = entriesForScv(rows, 'SCV1');
    expect(e).toHaveLength(2);
    expect(e[0].when).toBe('2024-03-01');            // newest first
    expect(e[0].who).toBe('b@x.org');
    expect(e[0].summary).toBe('No Change');           // no reason -> action only
    expect(e[1].summary).toBe('Flagging Candidate — Outlier claim');
    expect(e[1].notes).toBe('n1');
  });

  it('returns [] when the SCV has no history', () => {
    expect(entriesForScv(rows, 'SCVX')).toEqual([]);
    expect(entriesForScv([], 'SCV1')).toEqual([]);
  });
});

describe('cross-version history (matched by base SCV accession)', () => {
  const rows = [
    { scv: 'SCV999.4', action: 'Flagging Candidate', reason: 'r', notes: '', user_email: 'a@x.org', created_at: '2023-01-01T00:00:00Z' },
    { scv: 'SCV999.6', action: 'No Change',          reason: '',  notes: '', user_email: 'b@x.org', created_at: '2024-01-01T00:00:00Z' }
  ];

  it('summarizeHistoryByScv aggregates all versions under the base accession', () => {
    const m = summarizeHistoryByScv(rows);
    expect(m.SCV999.count).toBe(2);          // both versions counted under the base
    expect(m['SCV999.4']).toBeUndefined();   // NOT keyed by the full (versioned) accession
    expect(m['SCV999.6']).toBeUndefined();
  });

  it('entriesForScv returns all versions for the base and labels each with its version (newest-first)', () => {
    const e = entriesForScv(rows, 'SCV999.6');   // current row is v6
    expect(e.length).toBe(2);                    // includes the v4 annotation made on an older version
    expect(e[0].version).toBe('6');              // 2024 (newest) first
    expect(e[1].version).toBe('4');              // 2023 older version still surfaces
  });

  it('entriesForScv matches regardless of which version the current row is', () => {
    expect(entriesForScv(rows, 'SCV999.4').length).toBe(2); // same 2 entries when viewing v4
    expect(entriesForScv(rows, 'SCV999').length).toBe(2);   // and when given a bare base
  });
});

describe('decorateForScv badge tone by action composition', () => {
  it('yellow when the SCV history is ONLY "No Change"', () => {
    const m = summarizeHistoryByScv([
      { scv: 'S.1', action: 'No Change', created_at: '2024-01-01T00:00:00Z' },
      { scv: 'S.2', action: 'No Change', created_at: '2024-02-01T00:00:00Z' }
    ]);
    expect(decorateForScv(m.S).badgeClass).toBe('cvc-hl-badge-yellow');
  });
  it('red when there are ZERO "No Change" (all flag/remove)', () => {
    const m = summarizeHistoryByScv([
      { scv: 'S.1', action: 'Flagging Candidate', created_at: '2024-01-01T00:00:00Z' },
      { scv: 'S.2', action: 'Remove Flagged Submission', created_at: '2024-02-01T00:00:00Z' }
    ]);
    expect(decorateForScv(m.S).badgeClass).toBe('cvc-hl-badge-red');
  });
  it('orange when a MIX of "No Change" and other actions', () => {
    const m = summarizeHistoryByScv([
      { scv: 'S.1', action: 'No Change', created_at: '2024-01-01T00:00:00Z' },
      { scv: 'S.2', action: 'Flagging Candidate', created_at: '2024-02-01T00:00:00Z' }
    ]);
    expect(decorateForScv(m.S).badgeClass).toBe('cvc-hl-badge-orange');
  });
});
