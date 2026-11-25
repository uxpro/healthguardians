// Shared header, footer, cookie notice and accessibility widget for every public page.
// Pages contain <header id="site-header"></header> ... <footer id="site-footer"></footer>.
import { hasSession } from './session.js';
import { storage } from './storage.js';

export const NAV = [
  ['about.html', 'About'],
  ['business-model.html', 'Business model'],
  ['use-cases.html', 'Use cases'],
  ['partners.html', 'Partners'],
  ['success-stories.html', 'Stories'],
  ['faq.html', 'FAQ'],
  ['contact.html', 'Contact'],
];

export const LOGO_SVG = `<svg class="mark" viewBox="0 0 40 40" aria-hidden="true">
  <path d="M20 2 36 8v12c0 9.5-6.6 15.7-16 18C10.6 35.7 4 29.5 4 20V8z" fill="#1dbf73" stroke="#1d2125" stroke-width="3" stroke-linejoin="round"/>
  <rect x="11" y="14" width="18" height="12" rx="3" fill="#fbf9f2" stroke="#1d2125" stroke-width="2.5"/>
  <circle cx="16" cy="20" r="2.2" fill="#1d2125"/><circle cx="24" cy="20" r="2.2" fill="#1d2125"/>
  <path d="M20 14v-4" stroke="#1d2125" stroke-width="2.5" stroke-linecap="round"/></svg>`;

function currentFile() {
  const f = location.pathname.split('/').pop();
  return f === '' ? 'index.html' : f;
}

export function renderHeader(el) {
  const here = currentFile();
  const signedIn = hasSession();
  el.className = 'site-header';
  el.innerHTML = `
    <a class="skip-link" href="#main">Skip to content</a>
    <div class="inner">
      <a class="logo" href="index.html" aria-label="Health Guardians home">${LOGO_SVG}<span>Health <b>Guardians</b></span></a>
      <button class="btn small menu-toggle" aria-expanded="false" aria-controls="main-nav">Menu</button>
      <nav class="main-nav" id="main-nav" aria-label="Main">
        ${NAV.map(([href, text]) => `<a href="${href}"${href === here ? ' aria-current="page"' : ''}>${text}</a>`).join('')}
      </nav>
      <div class="actions">
        ${signedIn
          ? '<a class="btn primary" href="dashboard.html">Dashboard <span class="arrow"></span></a>'
          : '<a class="btn primary" href="login.html">Sign in <span class="arrow"></span></a>'}
      </div>
    </div>`;
  const toggle = el.querySelector('.menu-toggle');
  const nav = el.querySelector('.main-nav');
  toggle.addEventListener('click', () => {
    const open = nav.classList.toggle('open');
    toggle.setAttribute('aria-expanded', String(open));
  });
}

export function renderFooter(el) {
  el.className = 'site-footer';
  el.innerHTML = `
    <div class="inner">
      <div>
        <a class="logo" href="index.html" style="color:var(--cream)">${LOGO_SVG}<span>Health <b style="color:var(--mint)">Guardians</b></span></a>
        <p style="margin-top:14px">Care humanoids for clinics: rented, deployed, monitored and maintained by HG Group.</p>
        <p class="mono">HG Group (demo company)<br>Registered office: to be confirmed<br>support@healthguardians.example</p>
      </div>
      <div><h4>Company</h4><ul>
        <li><a href="about.html">About us</a></li><li><a href="business-model.html">Business model</a></li>
        <li><a href="success-stories.html">Success stories</a></li><li><a href="careers.html">Careers</a></li>
      </ul></div>
      <div><h4>Customers</h4><ul>
        <li><a href="use-cases.html">Use cases</a></li><li><a href="partners.html">Partners</a></li>
        <li><a href="faq.html">FAQ</a></li><li><a href="contact.html">Contact and support</a></li>
      </ul></div>
      <div><h4>Legal</h4><ul>
        <li><a href="rental-terms.html">Rental and service terms</a></li><li><a href="privacy.html">Privacy policy</a></li>
        <li><a href="cookies.html">Cookies and stored data</a></li>
        <li><a href="privacy.html#contact">Personal data contact</a></li>
      </ul></div>
      <p class="legal">&copy; <span data-year></span> HG Group. Demonstration website: customers, humanoids and events are fictitious. Powered by HG Group.</p>
    </div>`;
  el.querySelector('[data-year]').textContent = String(new Date().getFullYear());
}

// ---------------------------------------------------------------- cookie notice (essential storage only)
export function renderCookieNotice() {
  if (storage.get('hg.consent')) return null;
  const box = document.createElement('div');
  box.className = 'card cookie-notice';
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-label', 'Cookies and stored data');
  box.innerHTML = `
    <h3>Cookies and stored data</h3>
    <p>This site uses no tracking and no advertising cookies. It only stores what it needs: your sign-in session,
    this choice and your accessibility settings, in your browser.</p>
    <div class="row"><button class="btn primary small" data-ok>OK, understood</button>
    <a class="btn small" href="cookies.html">Details</a></div>`;
  box.querySelector('[data-ok]').addEventListener('click', () => {
    storage.set('hg.consent', JSON.stringify({ essential: true, at: new Date().toISOString() }));
    box.remove();
  });
  document.body.appendChild(box);
  return box;
}

// ---------------------------------------------------------------- accessibility widget
const A11Y_DEFAULT = { scale: 1, contrast: false, motion: false, links: false };

export function applyA11y(s) {
  const root = document.documentElement;
  root.style.setProperty('--text-scale', String(s.scale));
  root.classList.toggle('a11y-contrast', !!s.contrast);
  root.classList.toggle('a11y-motion', !!s.motion);
  root.classList.toggle('a11y-links', !!s.links);
}

export function loadA11y() {
  try { return { ...A11Y_DEFAULT, ...JSON.parse(storage.get('hg.a11y') || '{}') }; } catch { return { ...A11Y_DEFAULT }; }
}

export function renderA11yWidget() {
  let s = loadA11y();
  applyA11y(s);
  const btn = document.createElement('button');
  btn.className = 'btn dark a11y-toggle';
  btn.setAttribute('aria-label', 'Accessibility settings');
  btn.setAttribute('aria-expanded', 'false');
  btn.textContent = 'Aa';
  const panel = document.createElement('div');
  panel.className = 'card a11y-panel';
  panel.hidden = true;
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-label', 'Accessibility settings');
  panel.innerHTML = `
    <h3>Accessibility</h3>
    <div class="switch-row"><span>Text size</span><span class="row">
      <button class="btn small" data-scale="1">A</button><button class="btn small" data-scale="1.15">A+</button>
      <button class="btn small" data-scale="1.3">A++</button></span></div>
    <label class="switch-row">High contrast <input type="checkbox" data-k="contrast"></label>
    <label class="switch-row">Reduce motion <input type="checkbox" data-k="motion"></label>
    <label class="switch-row">Underline links <input type="checkbox" data-k="links"></label>
    <button class="btn small" data-reset>Reset</button>`;
  const save = () => { storage.set('hg.a11y', JSON.stringify(s)); applyA11y(s); sync(); };
  const sync = () => {
    panel.querySelectorAll('[data-k]').forEach((i) => { i.checked = !!s[i.dataset.k]; });
    panel.querySelectorAll('[data-scale]').forEach((b) => b.classList.toggle('primary', Number(b.dataset.scale) === s.scale));
  };
  panel.querySelectorAll('[data-scale]').forEach((b) => b.addEventListener('click', () => { s.scale = Number(b.dataset.scale); save(); }));
  panel.querySelectorAll('[data-k]').forEach((i) => i.addEventListener('change', () => { s[i.dataset.k] = i.checked; save(); }));
  panel.querySelector('[data-reset]').addEventListener('click', () => { s = { ...A11Y_DEFAULT }; save(); });
  btn.addEventListener('click', () => {
    panel.hidden = !panel.hidden;
    btn.setAttribute('aria-expanded', String(!panel.hidden));
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !panel.hidden) { panel.hidden = true; btn.setAttribute('aria-expanded', 'false'); btn.focus(); } });
  sync();
  document.body.append(panel, btn);
}

export function initSite() {
  const h = document.getElementById('site-header');
  const f = document.getElementById('site-footer');
  if (h) renderHeader(h);
  if (f) renderFooter(f);
  renderCookieNotice();
  renderA11yWidget();
}

if (typeof document !== 'undefined' && !document.body?.dataset.noSite) initSite();
