import { api } from '../api';
import { bqv, type HistoryRow } from '../types';
import { CellHover } from './CellHover';

// Prior-annotations history as a hover popover (portal, so it escapes the cell's
// overflow). Fetched once per SCV (module cache).
const cache: Record<string, HistoryRow[]> = {};

const namePart = (email: string) => (email || '').split('@')[0];
function fmt(h: HistoryRow): string {
  const rev = h.review_status
    ? ` [ ${h.review_status}${h.reviewer ? ' (' + namePart(h.reviewer) + ')' : ''}${h.batch_id ? ' *' + h.batch_id + '*' : ''} ]`
    : '';
  return `.${bqv(h.scv_ver)}\t${bqv(h.annotated_date)} (${namePart(h.curator)}) ${h.action || ''} ${h.reason || ''}${rev}`;
}

export function HistoryHover({ scvId }: { scvId: string }) {
  const load = async () => {
    let rows = cache[scvId];
    if (!rows) { try { rows = cache[scvId] = await api.scvHistory(scvId); } catch (e) { return <pre>Error: {(e as Error).message}</pre>; } }
    return (
      <>
        <div className="hist-hd">Prior annotations — {scvId} ({rows.length})</div>
        <pre>{rows.length ? rows.map(fmt).join('\n') : 'No prior annotations found.'}</pre>
      </>
    );
  };
  return <CellHover className="hist" label={<span className="hist-link">history ▸</span>} load={load} />;
}
