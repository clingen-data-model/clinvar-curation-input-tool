import { useEffect, useState } from 'react';
import { initFirebase, onAuth, login, logout, projectId } from './firebase';
import { api } from './api';
import type { Config } from './types';
import { ReviewView } from './views/ReviewView';
import { ReflagView } from './views/ReflagView';

type AuthState = 'loading' | 'signed-out' | 'unauthorized' | 'ready';

export function App() {
  const [authState, setAuthState] = useState<AuthState>('loading');
  const [email, setEmail] = useState<string>('');
  const [config, setConfig] = useState<Config | null>(null);
  const [tab, setTab] = useState<'review' | 'reflag'>('review');

  useEffect(() => {
    let unsub = () => {};
    initFirebase().then((auth) => {
      void auth;
      unsub = onAuth(async (user) => {
        if (!user) { setAuthState('signed-out'); return; }
        setEmail(user.email || '');
        try {
          await api.whoami();          // 403 here if not allow-listed
          setConfig(await api.config());
          setAuthState('ready');
        } catch {
          setAuthState('unauthorized');
        }
      });
    });
    return () => unsub();
  }, []);

  const dev = projectId() !== 'clingen-cvc';
  const refreshConfig = async () => setConfig(await api.config());

  return (
    <>
      {dev && <div id="dev-banner">DEV</div>}
      <header>
        <h1>ClinVar Curator — Review &amp; Submit</h1>
        <span className="whoami">{email || 'Not signed in.'}</span>
        {authState === 'signed-out'
          ? <button onClick={() => login()}>Sign in with Google</button>
          : <button onClick={() => logout()}>Sign out</button>}
      </header>

      {authState === 'loading' && <p>Loading…</p>}
      {authState === 'unauthorized' && <p>{email} — not authorized (contact an admin).</p>}

      {authState === 'ready' && config && (
        <main>
          {config.releaseStale && (
            <div id="release-banner">
              <span>⚠ A newer ClinVar release ({config.currentRelease}) is available; the queue reflects{' '}
                {config.baseReleaseDate || 'an older release'}. Re-process this review cycle before finalizing.</span>
              <button onClick={async () => { await api.reprocess(); await refreshConfig(); }}>Re-process now</button>
            </div>
          )}
          <nav id="views">
            <button className={tab === 'review' ? 'active' : 'secondary'} onClick={() => setTab('review')}>Review &amp; Submit</button>
            <button className={tab === 'reflag' ? 'active' : 'secondary'} onClick={() => setTab('reflag')}>Reflag</button>
          </nav>

          <div hidden={tab !== 'review'}><ReviewView config={config} onConfigChange={refreshConfig} /></div>
          <div hidden={tab !== 'reflag'}><ReflagView /></div>
        </main>
      )}
    </>
  );
}
