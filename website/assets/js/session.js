// The signed-in session (JWT + refresh token), kept in this browser only.
import { storage } from './storage.js';

export const SESSION_KEY = 'hg.session';

export function loadSession() {
  try {
    const s = JSON.parse(storage.get(SESSION_KEY) || 'null');
    return s && typeof s.access_token === 'string' && typeof s.refresh_token === 'string' ? s : null;
  } catch {
    return null;
  }
}

export function saveSession(s) {
  storage.set(SESSION_KEY, JSON.stringify({
    access_token: s.access_token,
    refresh_token: s.refresh_token,
    expires_at: s.expires_at,
    email: s.email ?? s.user?.email ?? null,
    user_id: s.user_id ?? s.user?.id ?? null,
  }));
}

export function clearSession() {
  storage.remove(SESSION_KEY);
}

export function hasSession() {
  return loadSession() !== null;
}
