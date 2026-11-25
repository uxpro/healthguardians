// Minimal Supabase client: password sign-in, token refresh, RPC calls and inserts over REST with the JWT.
import { CONFIG } from './config.js';
import { loadSession, saveSession, clearSession } from './session.js';

export class ApiError extends Error {
  constructor(message, { status = 0, code = '' } = {}) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }
}

// Friendly text for the errors the user can actually cause.
export function errorText(err) {
  const m = String(err?.message || err || '');
  if (/invalid login credentials|invalid_grant/i.test(m)) return 'E-mail or password is not correct.';
  if (/email not confirmed/i.test(m)) return 'This account is not confirmed yet.';
  if (/session_expired/.test(m)) return 'Your session has ended. Please sign in again.';
  if (/hg_access_denied/.test(m)) return 'This account has no access to the Health Guardian dashboards.';
  if (/hg_rate_limited/.test(m)) return 'Too many actions in a short time. Wait a minute and try again.';
  if (/hg_unknown_humanoid/.test(m)) return 'That humanoid is not available for this account.';
  if (/check constraint|violates/.test(m)) return 'Some values are not valid. Please check the form.';
  if (/failed to fetch|networkerror|load failed/i.test(m)) return 'No connection to the server. Check your network.';
  return 'Something went wrong. Please try again.';
}

export function createApi({ fetchImpl = (...a) => globalThis.fetch(...a), now = () => Date.now(), config = CONFIG } = {}) {
  const base = config.supabaseUrl.replace(/\/$/, '');
  const headers = (token) => ({
    apikey: config.supabaseKey,
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  });
  let refreshing = null;

  async function readError(res) {
    let body = {};
    try { body = await res.json(); } catch { /* not JSON */ }
    const msg = body.message || body.msg || body.error_description || body.error || `HTTP ${res.status}`;
    return new ApiError(msg, { status: res.status, code: body.code || body.error_code || '' });
  }

  function store(data) {
    const expiresAt = data.expires_at ?? Math.floor(now() / 1000) + (data.expires_in ?? 3600);
    saveSession({ ...data, expires_at: expiresAt });
    return loadSession();
  }

  async function signIn(email, password) {
    const res = await fetchImpl(`${base}/auth/v1/token?grant_type=password`, {
      method: 'POST', headers: headers(), body: JSON.stringify({ email: String(email).trim(), password }),
    });
    if (!res.ok) throw await readError(res);
    return store(await res.json());
  }

  async function refresh() {
    if (refreshing) return refreshing;
    refreshing = (async () => {
      const s = loadSession();
      if (!s) throw new ApiError('session_expired', { status: 401 });
      const res = await fetchImpl(`${base}/auth/v1/token?grant_type=refresh_token`, {
        method: 'POST', headers: headers(), body: JSON.stringify({ refresh_token: s.refresh_token }),
      });
      if (!res.ok) {
        clearSession();
        throw new ApiError('session_expired', { status: 401 });
      }
      return store(await res.json());
    })();
    try { return await refreshing; } finally { refreshing = null; }
  }

  async function token() {
    let s = loadSession();
    if (!s) throw new ApiError('session_expired', { status: 401 });
    if (!s.expires_at || s.expires_at - 60 <= Math.floor(now() / 1000)) s = await refresh();
    return s.access_token;
  }

  // Authenticated request; refreshes the token once on 401.
  async function authed(path, init = {}, retried = false) {
    const t = await token();
    const res = await fetchImpl(`${base}${path}`, { ...init, headers: { ...headers(t), ...(init.headers || {}) } });
    if (res.status === 401 && !retried) {
      await refresh();
      return authed(path, init, true);
    }
    if (!res.ok) throw await readError(res);
    if (res.status === 204) return null;
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }

  return {
    signIn,
    refresh,
    token,
    session: loadSession,
    rpc: (name, args = {}) => authed(`/rest/v1/rpc/${encodeURIComponent(name)}`, { method: 'POST', body: JSON.stringify(args) }),
    insert: (table, row) => authed(`/rest/v1/${encodeURIComponent(table)}`, {
      method: 'POST', body: JSON.stringify(row), headers: { Prefer: 'return=minimal' },
    }),
    user: () => authed('/auth/v1/user', { method: 'GET' }),
    async signOut() {
      const s = loadSession();
      clearSession();
      if (!s) return;
      try {
        await fetchImpl(`${base}/auth/v1/logout`, { method: 'POST', headers: headers(s.access_token) });
      } catch { /* the local session is gone either way */ }
    },
  };
}
