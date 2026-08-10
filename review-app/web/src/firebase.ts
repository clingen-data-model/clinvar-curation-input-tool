// Firebase init + auth. Uses the Hosting auto-config (/__/firebase/init.json) so
// the same build works in dev and prod without hardcoding project config.
import { initializeApp, type FirebaseApp } from 'firebase/app';
import {
  getAuth, GoogleAuthProvider, signInWithPopup, signOut,
  onAuthStateChanged, type User, type Auth
} from 'firebase/auth';

let app: FirebaseApp;
let auth: Auth;

export async function initFirebase(): Promise<Auth> {
  const res = await fetch('/__/firebase/init.json');
  const config = await res.json();
  app = initializeApp(config);
  auth = getAuth(app);
  return auth;
}

export const projectId = (): string | undefined => app?.options?.projectId as string | undefined;
export const provider = new GoogleAuthProvider();
export const login = () => signInWithPopup(auth, provider);
export const logout = () => signOut(auth);
export const onAuth = (cb: (u: User | null) => void) => onAuthStateChanged(auth, cb);
export const currentUser = () => auth?.currentUser ?? null;
export const idToken = () => auth.currentUser!.getIdToken();
