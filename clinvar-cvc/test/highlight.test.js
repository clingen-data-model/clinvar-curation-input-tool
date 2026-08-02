const { summarizeHistoryByScv } = require('../highlight.js');

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
