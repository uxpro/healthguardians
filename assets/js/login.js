// Sign-in page: password sign-in with Supabase Auth, then a check that the account has Health Guardian access.
import { createApi, errorText } from './api.js';
import { hasSession } from './session.js';
import { JURY, juryOpen } from './jury.js';

const api = createApi();
const form = document.getElementById('login-form');
const msg = document.getElementById('login-msg');
const btn = document.getElementById('login-btn');

function show(text) {
  msg.textContent = text;
  msg.hidden = !text;
}

document.getElementById('show-pw').addEventListener('change', (e) => {
  document.getElementById('password').type = e.target.checked ? 'text' : 'password';
});

// RobotHack jury: the logo reveals the read-only jury sign-in until the access ends.
const hint = document.getElementById('jury-hint');
if (hint && juryOpen()) {
  hint.hidden = false;
  document.getElementById('jury-until').textContent = `the end of ${JURY.untilText}`;
  const logo = document.getElementById('jury-logo');
  const reveal = () => {
    const box = document.getElementById('jury-secret');
    if (!box.hidden) return;
    document.getElementById('jury-cred').textContent = `${JURY.email} · ${JURY.password}`;
    box.hidden = false;
    logo.setAttribute('aria-expanded', 'true');
  };
  logo.addEventListener('mouseenter', reveal);
  logo.addEventListener('focus', reveal);
  logo.addEventListener('click', reveal);
  document.getElementById('jury-use').addEventListener('click', () => {
    form.email.value = JURY.email;
    form.password.value = JURY.password;
    document.getElementById('login-btn').focus();
  });
}

// Already signed in: go straight to the dashboard.
if (hasSession()) location.replace('dashboard.html');

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const email = form.email.value.trim();
  const password = form.password.value;
  if (!email || !password) { show('Enter your e-mail and password.'); return; }
  btn.disabled = true;
  show('');
  try {
    await api.signIn(email, password);
    const me = await api.rpc('hg_whoami');
    if (!me) {
      await api.signOut();
      show('This account has no access to the Health Guardian dashboards.');
      return;
    }
    try { await api.rpc('hg_log_action', { p_action: 'sign_in', p_details: {} }); } catch { /* logging must not block */ }
    location.assign('dashboard.html');
  } catch (err) {
    show(errorText(err));
  } finally {
    btn.disabled = false;
  }
});
