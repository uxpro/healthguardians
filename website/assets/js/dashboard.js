// Health Guardian dashboards.
//   role "user"  -> customer dashboard (Central Clinic: fall detection, simulated; North Clinic: conversation support, live)
//   role "admin" -> Health Guardian Logistics Dashboard (availability and logistics only, no use cases or patients)
// Data comes from the hg_* database functions with the signed-in account's JWT; new events are fetched by polling.
import { createApi, errorText } from './api.js';
import { hasSession } from './session.js';
import { CONFIG } from './config.js';
import { renderA11yWidget } from './site.js';
import {
  humanize, escapeHtml as e, fmtDate, fmtTime, fmtDateTime, fmtHours, isToday, typeClass, flagText, payloadText, toCsv,
} from './format.js';
import { FEATURES, INJECT_BUTTONS, REMINDERS, TECHNICIANS, sparePartsFor, warehouseRows } from './data.js';
import { createCentralSimulator, environment, reliability } from './sim.js';
import { lineChart, barChart, eventsPerHour } from './charts.js';
import { robotSvg } from './robot-art.js';
import { createFace, createCheckIn, browserSpeak, MODES } from './face.js';
import { LOGO_SVG } from './site.js';

const api = createApi();
const $ = (sel, root = document) => root.querySelector(sel);

const S = {
  me: null,
  fleet: [],
  events: [],          // newest first, unique by event_id
  seen: new Set(),
  selectedId: null,
  view: null,
  tab: 'customer',
  lastSync: null,
  syncOk: true,
  sim: null,
  face: null,
  checkIn: null,
  speech: false,
  timers: [],
  latest: null,        // newest event shown in the animation widget
  plots: new Set(),    // customer dashboard: plots the user has revealed
};

const isAdmin = () => S.me?.role === 'admin';
const customer = () => S.me?.customer || null;
const selected = () => S.fleet.find((h) => h.id === S.selectedId) || null;

// ---------------------------------------------------------------- views per role
// customer dashboard: tabs (F1-F4) and the menu in the top bar
const conversation = () => customer()?.use_case === 'conversation_support';
const TABS_USER = () => (conversation()
  ? [['overview', 'Overview'], ['face', 'Virtual face'], ['activity', 'Activity & log'], ['demo', 'Demo events']]
  : [['overview', 'Overview'], ['environment', 'Environment'], ['activity', 'Activity & log']]);
const MENU_USER = [
  ['account', 'Account'],
  ['extension', 'Rental extension'],
  ['ticket', 'Support ticket'],
  ['export', 'Export'],
];
const VIEWS_USER = [['overview', 'Overview'], ['face', 'Virtual face'], ['environment', 'Environment'], ['activity', 'Activity & log'],
  ['demo', 'Demo events'], ['account', 'Account details'], ['extension', 'Request rental period extension'],
  ['ticket', 'Create a support ticket'], ['export', 'Export events to Excel']];
const VIEWS_ADMIN = [
  ['fleet', 'Fleet overview'],
  ['account', 'Account details'],
  ['deploy', 'Deploy a humanoid'],
  ['maintenance', 'Schedule maintenance and service'],
  ['ticket', 'Create a support ticket'],
  ['export', 'Export events to Excel'],
  ['warehouse', 'Warehouse availability'],
  ['audit', 'Audit log'],
];
const views = () => (isAdmin() ? VIEWS_ADMIN : VIEWS_USER);

// ---------------------------------------------------------------- helpers
function logAction(action, details = {}) {
  api.rpc('hg_log_action', { p_action: action, p_details: details }).catch(() => { /* never block the UI */ });
}

function toast(html, kind = '') {
  const box = $('#toast');
  const el = document.createElement('div');
  el.className = `card ${kind}`;
  el.style.marginBottom = '12px';
  el.innerHTML = html;
  box.prepend(el);
  setTimeout(() => el.remove(), 6000);
  while (box.children.length > 3) box.lastChild.remove();
}

function later(fn, ms) {
  const id = setTimeout(fn, ms);
  S.timers.push(id);
  return id;
}

function addEvents(list, { live }) {
  const fresh = [];
  for (const ev of list) {
    if (!ev || S.seen.has(ev.event_id)) continue;
    S.seen.add(ev.event_id);
    // logistics never shows payloads (also for simulated events)
    fresh.push(isAdmin() ? { ...ev, payload: {} } : ev);
  }
  if (!fresh.length) return [];
  S.events = [...fresh, ...S.events]
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at) || String(b.event_id).localeCompare(String(a.event_id)))
    .slice(0, 1500);
  if (live) {
    const newest = fresh.reduce((a, b) => (new Date(a.created_at) >= new Date(b.created_at) ? a : b));
    S.latest = newest;
    animateWidget(newest);
    for (const ev of fresh.filter((x) => x.type !== 'KEEP_ALIVE').slice(0, 2)) {
      toast(`<p class="kicker">New ${e(humanize(ev.type))}</p><b>${e(ev.name)}</b><br>${e(humanize(ev.label))} · ${fmtTime(ev.created_at)}`, ev.type === 'ENVIRONMENT_VARIABLE_ALARM' ? 'mint' : '');
    }
  } else if (!S.latest && S.events.length) {
    S.latest = S.events[0];
  }
  return fresh;
}

function eventsFor(id) {
  return id ? S.events.filter((ev) => ev.humanoid_id === id) : S.events;
}

function countToday(list) {
  const now = new Date();
  return list.filter((ev) => isToday(ev.created_at, now)).length;
}

function incidents30(h) {
  // server count (30 days) + simulated alerts in this browser
  const sim = h.customer_id === 'central-clinic'
    ? S.events.filter((ev) => ev.humanoid_id === h.id && ev.source === 'simulated' && ev.type !== 'KEEP_ALIVE').length : 0;
  return (h.incidents_30d || 0) + sim;
}

// ---------------------------------------------------------------- data
async function loadFleet() {
  S.fleet = (await api.rpc('hg_fleet')) || [];
  if (!S.selectedId || !selected()) {
    const pick = S.fleet.find((h) => h.live) || S.fleet.find((h) => h.instance_status === 'deployed') || S.fleet[0];
    S.selectedId = pick ? pick.id : null;
  }
}

async function poll() {
  try {
    const dbEvents = S.events.filter((ev) => ev.source !== 'simulated');
    const newest = dbEvents.length ? new Date(dbEvents[0].created_at).getTime() : Date.now() - 24 * 3600e3;
    const since = new Date(newest - 10_000).toISOString();     // small overlap; duplicates are dropped
    const list = await api.rpc('hg_feed', { p_since: since, p_limit: 200 });
    const fresh = addEvents(list || [], { live: true });
    S.syncOk = true;
    S.lastSync = new Date();
    // an alert changes the incident counters: reload them now instead of waiting for the fleet refresh
    if (fresh.some((x) => x.type !== 'KEEP_ALIVE')) { try { await loadFleet(); } catch { /* keep the old counts */ } }
    if (fresh.length) refreshLive();
  } catch (err) {
    S.syncOk = false;
    if (err?.message === 'session_expired') { location.replace('login.html'); return; }
  }
  renderSync();
}

function startSimulation() {
  const central = S.fleet.filter((h) => h.customer_id === 'central-clinic');
  if (!central.length) return;
  if (!isAdmin() && !customer()?.simulated) return;
  S.sim = createCentralSimulator(central);
  addEvents(S.sim.history(24), { live: false });
  const loop = () => {
    later(() => {
      const ev = S.sim.next();
      if (ev && addEvents([ev], { live: true }).length) refreshLive();
      loop();
    }, S.sim.nextDelay());
  };
  loop();
}

// ---------------------------------------------------------------- shell
function renderTop() {
  if (!isAdmin()) { renderTopUser(); return; }
  const c = customer();
  const initials = c ? c.name.split(/\s+/).map((w) => w[0]).join('').slice(0, 2).toUpperCase() : 'HG';
  $('#top').innerHTML = `
    <span class="customer-logo" aria-hidden="true">${isAdmin() ? LOGO_SVG : e(initials)}</span>
    <div>
      <div class="title">${isAdmin() ? 'Health Guardian Logistics Dashboard' : `${e(c.name)} dashboard`}</div>
      <div class="muted" style="font-size:.85rem">${isAdmin() ? 'HG Group' : `${e(humanize(c.unique_id))} · ${e(humanize(c.use_case))}`}</div>
    </div>
    <div class="who">
      <span id="sync" class="muted" style="font-size:.85rem"></span>
      <span class="chip ${isAdmin() ? 'purple' : 'mint'}">${e(S.me.email)} · ${isAdmin() ? 'Admin' : 'User'}</span>
      <a class="btn small" href="index.html">Back</a>
      <button class="btn small dark" id="sign-out">Sign out</button>
    </div>`;
  $('#sign-out').addEventListener('click', signOut);
  renderSync();
}

// Customer dashboard (console style): one-line menu bar, F1-F4 tabs, status bar at the bottom.
function renderTopUser() {
  const c = customer();
  document.body.classList.add('dos');
  $('#side').hidden = true;
  $('#top').innerHTML = `
    <div class="dos-bar">
      <span class="dos-brand">HEALTH GUARDIANS ▸ ${e(c.name.toUpperCase())}</span>
      <span class="title sr-only">${e(c.name)} dashboard</span>
      <span class="dos-sub">${e(humanize(c.unique_id))} · ${e(humanize(c.use_case))}</span>
      <span class="dos-sp"></span>
      <span id="sync"></span>
      <span id="who">${e(S.me.display_name || S.me.email)} · User</span>
      <nav class="dos-menu" aria-label="Account and requests">${MENU_USER.map(([id, t]) =>
        `<button data-view="${id}">${e(t)}</button>`).join('')}<a href="index.html">Website</a><button id="sign-out">Sign out</button></nav>
    </div>
    <div class="dos-tabs" role="tablist" aria-label="Dashboard">${TABS_USER().map(([id, t], i) =>
      `<button role="tab" data-view="${id}" aria-selected="false"><b>F${i + 1}</b>${e(t)}</button>`).join('')}</div>`;
  $('#top').querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => go(b.dataset.view)));
  $('#sign-out').addEventListener('click', signOut);
  bindCustomerClicks();
  const bar = document.createElement('footer');
  bar.className = 'dos-status';
  bar.id = 'dos-status';
  document.body.append(bar);
  document.addEventListener('keydown', (ev) => {
    const n = /^F([1-9])$/.exec(ev.key);
    const tab = n && TABS_USER()[Number(n[1]) - 1];
    if (!tab || ev.altKey || ev.ctrlKey || ev.metaKey) return;
    ev.preventDefault();
    go(tab[0]);
  });
  renderSync();
}

function markTabs() {
  $('#top').querySelectorAll('[role="tab"]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.view === S.view)));
  $('#top').querySelectorAll('.dos-menu [data-view]').forEach((b) => b.toggleAttribute('aria-current', b.dataset.view === S.view));
  const who = $('#who');
  if (who) who.textContent = `${S.me.display_name || S.me.email} · User`;
  const bar = $('#dos-status');
  if (bar) {
    bar.innerHTML = `${TABS_USER().map(([id, t], i) => `<span><b>F${i + 1}</b>${e(t)}</span>`).join('')}<span class="dos-sp"></span>
      <span>${customer()?.simulated ? 'Simulated events (demo)' : 'Live database events'}</span>`;
  }
}

function renderSync() {
  const el = $('#sync');
  if (!el) return;
  if (!isAdmin()) {
    el.innerHTML = S.syncOk ? `<span class="sync-dot"></span>LIVE${S.lastSync ? ` ${fmtTime(S.lastSync)}` : ''}`
      : '<span class="sync-dot off"></span>OFFLINE, retrying';
    el.title = `Polling every ${CONFIG.pollMs / 1000} s`;
    return;
  }
  el.innerHTML = S.syncOk
    ? `<span class="sync-dot"></span>Live · polling every ${CONFIG.pollMs / 1000} s${S.lastSync ? ` · synced ${fmtTime(S.lastSync)}` : ''}`
    : '<span class="sync-dot off"></span>Connection lost, retrying...';
}

function renderSide() {
  if (!isAdmin()) { markTabs(); return; }
  const head = isAdmin()
    ? `<div class="side-head"><p class="kicker">HG Group</p><b>${e(S.me.display_name || S.me.email)}</b><br><span class="chip purple" style="margin-top:6px">Admin</span></div>`
    : `<div class="side-head"><p class="kicker">${e(customer().name)}</p><b>${e(S.me.display_name || S.me.email)}</b><br><span class="chip mint" style="margin-top:6px">User</span></div>`;
  $('#side').innerHTML = head + views().map(([id, text]) =>
    `<button class="nav" data-view="${id}" ${S.view === id ? 'aria-current="true"' : ''}>${e(text)}</button>`).join('') +
    `<div class="side-foot">${isAdmin()
      ? '<p class="muted">All actions are written to the audit log with your account. Only account details are a working form; the other forms are mock-ups.</p>'
      : '<p class="muted">Account details are a working form; extension and ticket forms are mock-ups.</p>'}
      <span class="chip">Powered by HG Group</span></div>`;
  $('#side').querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => go(b.dataset.view)));
}

function go(view, { log = true } = {}) {
  if (S.checkIn?.running) S.checkIn.stop();     // also when another humanoid is picked
  S.checkIn = null;
  S.face?.destroy();
  S.face = null;
  S.view = view;
  renderSide();
  renderView();
  $('#main').classList.toggle('dos-fit', !isAdmin() && ['overview', 'face', 'environment', 'activity', 'demo'].includes(view));
  if (log) logAction('open_view', { view });
  $('#main').focus({ preventScroll: true });
  window.scrollTo(0, 0);
}

async function signOut() {
  S.timers.forEach(clearTimeout);
  // write the audit line before the token is revoked (at most 1.5 s)
  await Promise.race([api.rpc('hg_log_action', { p_action: 'sign_out', p_details: {} }).catch(() => {}),
    new Promise((r) => setTimeout(r, 1500))]);
  await api.signOut();
  location.assign('login.html');
}

// ---------------------------------------------------------------- shared panels
function selectHumanoidCard(list) {
  return `<div class="card">
    <label for="humanoid-select">Search humanoid</label>
    <select id="humanoid-select">${list.map((h) =>
      `<option value="${e(h.id)}" ${h.id === S.selectedId ? 'selected' : ''}>${e(humanize(h.label))} · ${e(humanize(h.model_id))}${
        isAdmin() ? ` · ${e(h.customer_name || humanize(h.instance_status))}` : ''}${h.live ? ' · live' : ''}</option>`).join('')}</select>
    <p class="hint mono">${e(selected()?.id || '')}</p>
  </div>`;
}

function eventWidget() {
  const ev = S.latest;
  return `<div class="card event-widget ${ev ? `t-${e(ev.type)}` : ''}" id="event-widget" aria-live="polite">
    <span class="pulse" aria-hidden="true"></span>
    <div style="min-width:0">
      <p class="kicker">${isAdmin() ? 'Latest event from any humanoid' : 'Latest event'}</p>
      ${ev ? `<b>${e(ev.name)}</b> <span class="chip ${typeClass(ev.type)}">${e(humanize(ev.type))}</span><br>
        <span class="muted">${e(humanize(ev.label))} · ${fmtDateTime(ev.created_at)}${ev.source === 'simulated' ? ' · simulated' : ''}</span>`
        : '<span class="muted">Waiting for the first event...</span>'}
    </div></div>`;
}

function animateWidget(ev) {
  const w = $('#event-widget');
  if (!w) return;
  w.outerHTML = eventWidget(ev);
  const nw = $('#event-widget');
  nw.classList.remove('flash');
  void nw.offsetWidth;
  nw.classList.add('flash');
}

function leds(flag) {
  return `<div class="leds" role="img" aria-label="Integrity: ${e(flagText(flag))}">
    <span class="led green ${flag === 'green' ? 'on' : ''}" title="Normal"></span>
    <span class="led yellow ${flag === 'yellow' ? 'on' : ''}" title="Action is needed"></span>
    <span class="led red ${flag === 'red' ? 'on' : ''}" title="Critical"></span>
    <b>${e(flagText(flag))}</b></div>`;
}

function capabilities(h) {
  return `<div class="card"><h3>Robot capabilities</h3><ul class="feature-list">${FEATURES.map((f) => {
    const on = (h.features || []).includes(f);
    return `<li class="${on ? '' : 'off'}">${e(humanize(f))}<span class="chip ${on ? 'green' : 'grey'}">${on ? 'Available' : 'Not available'}</span></li>`;
  }).join('')}</ul></div>`;
}

function overviewTable(h) {
  const statusChip = { deployed: 'green', in_stock: 'blue', maintenance: 'yellow', in_transit: 'purple' }[h.instance_status] || 'grey';
  const testChip = { passed: 'green', passed_with_warnings: 'yellow', failed: 'red' }[h.system_test] || 'grey';
  return `<div class="card" id="overview-card"><h3>General overview · ${e(humanize(h.label))}</h3>
    <table class="kv">
      <tr><th>Number of incidents (30 days)</th><td><b id="incidents">${incidents30(h)}</b></td></tr>
      <tr><th>Humanoid state</th><td><span class="chip ${statusChip}">${e(humanize(h.instance_status))}</span></td></tr>
      <tr><th>Battery autonomy</th><td>${fmtHours(h.battery_autonomy_h)}</td></tr>
      <tr><th>System test report</th><td><span class="chip ${testChip}">${e(humanize(h.system_test))}</span> on ${fmtDate(h.system_test_on)}</td></tr>
      ${isAdmin() ? '' : `<tr><th>Scheduled maintenance</th><td>${fmtDate(h.next_maintenance)}</td></tr>`}
      <tr><th>Integrity flags</th><td>${leds(h.integrity_flag)}</td></tr>
    </table></div>`;
}

function robotLog(h, { gateway = false, limit = 120 } = {}) {
  const list = eventsFor(h?.id).slice(0, limit);
  const rows = list.map((ev) => `<tr>
      <td>${fmtDate(ev.created_at)}</td><td>${fmtTime(ev.created_at)}</td><td class="mono">${ev.code}</td>
      <td class="type"><span class="chip ${typeClass(ev.type)}">${e(humanize(ev.type))}</span></td>
      <td>${e(ev.name)}</td>${gateway ? `<td>${e(humanize(ev.source))}</td>` : `<td>${e(payloadText(ev.payload)) || '<span class="muted">-</span>'}</td>`}</tr>`).join('');
  const head = isAdmin() ? `<h3 style="margin-top:4px">${gateway ? 'Robot log: requests sent through our gateway' : 'Robot log'}</h3>` : '';
  return `<div id="robot-log">${head}
    <div class="table-scroll"><table class="brut log-table">
      <thead><tr><th>Date</th><th>Time</th><th>Code</th><th>Type</th><th>Event</th><th>${gateway ? 'Source' : 'Payload'}</th></tr></thead>
      <tbody>${rows || `<tr><td colspan="6" class="empty">No events in the last 24 hours</td></tr>`}</tbody>
    </table></div></div>`;
}

function eventsChart(list) {
  return `<div class="card chart" id="events-chart"><h3>Events per hour (last 24 hours)</h3>
    ${barChart(eventsPerHour(list), { title: 'Events per hour' })}
    <div class="legend"><span><i style="background:#1dbf73"></i>Keep alive only</span><span><i style="background:#f2545b"></i>Hour with alerts</span></div></div>`;
}

// ---------------------------------------------------------------- customer dashboard (console style)
// One screen per tab, no page scrolling: boxes in a 3-column grid, the robot picture always top right.
function box(title, body, { cls = '', id = '' } = {}) {
  return `<section class="dbox ${cls}"${id ? ` id="${id}"` : ''}><h3>${title}</h3><div class="dbox-body">${body}</div></section>`;
}

const useCaseTitle = () => (conversation() ? 'Conversation support' : 'Fall detection');

function chipFor(kind, value) {
  const map = kind === 'state'
    ? { deployed: 'green', in_stock: 'blue', maintenance: 'yellow', in_transit: 'purple' }
    : { passed: 'green', passed_with_warnings: 'yellow', failed: 'red' };
  return `<span class="chip ${map[value] || 'grey'}">${e(humanize(value))}</span>`;
}

function humanoidSelect() {
  return `<label class="sr-only" for="humanoid-select">Humanoid</label>
    <select id="humanoid-select">${S.fleet.map((h) =>
      `<option value="${e(h.id)}" ${h.id === S.selectedId ? 'selected' : ''}>${e(humanize(h.label))} · ${e(humanize(h.model_id))}${h.live ? ' · live' : ''}</option>`).join('')}</select>`;
}

function robotBox(h) {
  return box(e(humanize(h.model_id)), `<div class="dos-robot">${robotSvg(h, { line: true })}</div>
    <table class="dkv">
      <tr><th>Humanoid</th><td>${e(humanize(h.label))}</td></tr>
      <tr><th>Locomotion</th><td>${e(humanize(h.locomotion || '-'))}</td></tr>
      <tr><th>State</th><td>${chipFor('state', h.instance_status)}</td></tr>
    </table>
    <p class="dos-hint">Placeholder drawing; the model photo follows.</p>`, { cls: 'robot-box' });
}

function overviewKv(h) {
  return `<table class="dkv">
    <tr><th>Incidents (30 days)</th><td><b id="incidents">${incidents30(h)}</b></td></tr>
    <tr><th>State</th><td>${chipFor('state', h.instance_status)}</td></tr>
    <tr><th>Battery autonomy</th><td>${fmtHours(h.battery_autonomy_h)}</td></tr>
    <tr><th>System test</th><td>${chipFor('test', h.system_test)} ${fmtDate(h.system_test_on)}</td></tr>
    <tr><th>Next maintenance</th><td>${fmtDate(h.next_maintenance)}</td></tr>
    <tr><th>Integrity flags</th><td>${leds(h.integrity_flag)}</td></tr>
  </table>`;
}

function capabilityList(h) {
  return `<ul class="dos-caps">${FEATURES.map((f) => {
    const on = (h.features || []).includes(f);
    return `<li class="${on ? '' : 'off'}">${e(humanize(f))}<span>${on ? '● ON' : '○ OFF'}</span></li>`;
  }).join('')}</ul>`;
}

function eventsChartPlain(list) {
  return `<div class="chart">${barChart(eventsPerHour(list), { title: 'Events per hour' })}
    <div class="legend"><span><i style="background:#1dbf73"></i>Keep alive only</span><span><i style="background:#f2545b"></i>Hour with alerts</span></div></div>`;
}

function tempChart(h) {
  const pts = environment(S.fleet.indexOf(h)).points;
  return `<div class="chart">${lineChart({
    title: 'Room temperature, last 24 hours',
    series: [{ name: 'Temperature', fill: '#a8e6c5', points: pts.map((p) => ({ x: p.t, y: p.temperature })) }],
    yMin: 16, yMax: 30, hLines: [{ y: 26, label: 'Alarm above 26 °C' }],
    xFormat: (t) => `${String(new Date(t).getHours()).padStart(2, '0')}h`, yFormat: (v) => `${v}°`,
  })}</div>`;
}

// Plots stay hidden until the user asks for them.
const PLOTS = {
  hour: { title: 'Events per hour · last 24 h', render: (h) => eventsChartPlain(eventsFor(h.id)), wrap: 'events-chart-wrap' },
  temp: { title: 'Room temperature · last 24 h', render: (h) => tempChart(h), wrap: 'temp-chart-wrap' },
};

function plotBlock(key, h) {
  const p = PLOTS[key];
  const open = S.plots.has(key);
  return `<div class="plot ${open ? 'open' : ''}" id="plot-${key}">
    <div class="plot-head"><span>${e(p.title)}</span>
      <button class="dbtn" data-plot="${key}" aria-expanded="${open}">${open ? '▾ Hide plot' : '▸ Show plot'}</button></div>
    ${open ? `<div class="plot-body" id="${p.wrap}">${p.render(h)}</div>` : '<div class="plot-off">Plot hidden</div>'}</div>`;
}

function todayBody(h, list) {
  return `<div class="dos-stats">
      <div><b class="big" id="events-today">${countToday(list)}</b><span>events · ${e(humanize(h.label))}</span></div>
      <div><b class="big" id="events-today-all">${countToday(S.events)}</b><span>events · all humanoids</span></div>
      <div><b class="big">${S.fleet.length}</b><span>humanoids · your fleet</span></div>
    </div>
    ${eventWidget()}
    ${customer().simulated ? '<p class="dos-hint"><span class="chip yellow">Simulated events (demo)</span> generated in this browser, not stored</p>' : ''}`;
}

function supportBody() {
  return `<table class="dkv">
    <tr><th>Powered by</th><td>HG Group</td></tr>
    <tr><th>E-mail</th><td style="font-size:11.5px">support@healthguardians.example</td></tr>
  </table>
  <div class="dos-actions"><button class="dbtn" data-view="extension">Rental extension</button><button class="dbtn" data-view="ticket">Support ticket</button></div>`;
}

function noHumanoid() {
  return `<h1>${e(customer().name)}</h1><p class="notice">No humanoids are deployed for this account yet.</p>`;
}

function customerOverview() {
  const h = selected();
  if (!h) return noHumanoid();
  return `<h1 class="sr-only">${useCaseTitle()} · Overview</h1>
  <div class="dos-grid">
    ${box('Humanoid', `${humanoidSelect()}<table class="dkv">
      <tr><th>UUID</th><td class="mono">${e(h.id)}</td></tr>
      <tr><th>Patient UUID</th><td class="mono">${e(h.demo_patient_uuid || 'Not linked')}</td></tr>
      <tr><th>Patient match</th><td>Anonymous · only your clinic</td></tr></table>`)}
    ${box('Today', todayBody(h, eventsFor(h.id)))}
    ${robotBox(h)}
    ${box('General overview', overviewKv(h), { id: 'overview-card' })}
    ${box('Capabilities', capabilityList(h) + plotBlock('hour', h))}
    ${box('Latest robot log', robotLog(h, { limit: 40 }), { cls: 'span2 grow' })}
    ${box('Support', supportBody(), { cls: 'grow' })}
  </div>`;
}

function customerFace() {
  const h = selected();
  if (!h) return noHumanoid();
  const live = S.fleet.find((x) => x.live);
  const faceBox = h.live
    ? box('Robotic virtual face', `<div class="face-wrap"><span class="chip face-mode" id="face-mode">Idling</span><canvas id="face" aria-hidden="true"></canvas>
        <div class="face-caption" id="face-caption">Press "Start check-in" to talk to the patient.</div></div>`, { cls: 'span2 rows3 face-box' })
    : box('Robotic virtual face', `<p>The check-in of ${e(humanize(h.label))} runs on the humanoid itself; its events appear in the log.</p>
        ${live ? `<p>The live demo humanoid is <b>${e(humanize(live.label))}</b>. Select it to run the check-in here.</p>` : ''}`, { cls: 'span2 rows3' });
  const control = box('Check-in', `${humanoidSelect()}
      ${h.live ? `<label class="dos-check"><input type="checkbox" id="voice" ${S.speech ? 'checked' : ''}> Voice</label>
      <div class="dos-actions"><button class="dbtn primary" id="start-checkin">Start check-in</button><button class="dbtn" id="stop-checkin" disabled>Stop</button></div>
      <p class="dos-label">Patient answer</p>
      <div class="answers" id="answers"><span class="dos-hint">The answer buttons appear while the face is listening.</span></div>
      <p class="dos-hint">Same daily check-in as the HealthGuardians app. Every answer is saved as an event; worrying answers raise an emergency.</p>` : ''}`, { cls: 'grow' });
  return `<h1 class="sr-only">${useCaseTitle()} · Virtual face</h1><div class="dos-grid">${faceBox}${robotBox(h)}${control}</div>`;
}

function customerEnvironment() {
  const h = selected();
  if (!h) return noHumanoid();
  const env = environment(S.fleet.indexOf(h));
  const reminders = (h.features || []).flatMap((f) => (REMINDERS[f] || []).map((r) => ({ ...r, f })))
    .sort((a, b) => a.at.localeCompare(b.at));
  return `<h1 class="sr-only">${useCaseTitle()} · Environment</h1><div class="dos-grid">
    ${box(`Environmental data · room of ${e(humanize(h.label))}`, `<div class="dos-stats">
        <div><b class="big">${env.current.temperature} °C</b><span>temperature</span></div>
        <div><b class="big">${env.current.humidity} %</b><span>humidity</span></div>
        <div><b class="big">${env.current.co2}</b><span>ppm CO2 · air quality</span></div></div>
        ${plotBlock('temp', h)}`, { cls: 'span2' })}
    ${robotBox(h)}
    ${box('Friendly reminders (based on the available features)', `<div class="table-scroll"><table class="brut"><thead><tr><th>Time</th><th>Reminder</th><th>Feature</th></tr></thead><tbody>
      ${reminders.map((r) => `<tr><td class="mono">${e(r.at)}</td><td>${e(r.text)}</td><td>${e(humanize(r.f))}</td></tr>`).join('')
        || '<tr><td colspan="3" class="empty">No reminder feature on this humanoid</td></tr>'}</tbody></table></div>`, { cls: 'span2 rows23 grow' })}
    ${box('Humanoid', `${humanoidSelect()}${overviewKv(h).replace('id="incidents"', '')}`, { cls: 'grow' })}
  </div>`;
}

function customerActivity() {
  const h = selected();
  if (!h) return noHumanoid();
  return `<h1 class="sr-only">${useCaseTitle()} · Activity and log</h1><div class="dos-grid">
    ${box('Activity', plotBlock('hour', h), { cls: 'span2' })}
    ${robotBox(h)}
    ${box('Robot log · last 24 hours', robotLog(h), { cls: 'span2 rows23 grow' })}
    ${box('Today', `${humanoidSelect()}${todayBody(h, eventsFor(h.id))}<div class="dos-actions"><button class="dbtn" data-view="export">Export to Excel</button></div>`, { cls: 'grow' })}
  </div>`;
}

function customerDemo() {
  const h = selected();
  if (!h) return noHumanoid();
  const ok = h.instance_status === 'deployed';
  return `<h1 class="sr-only">${useCaseTitle()} · Demo events</h1><div class="dos-grid">
    ${box('Demo data injection', ok ? `<p>Sends a real event for ${e(humanize(h.label))} to the database. It shows up here and on the logistics dashboard within seconds.</p>
      <div class="field"><label for="inject-note">Note (optional)</label><input id="inject-note" maxlength="140" placeholder="e.g. Room 2.07"></div>
      <div class="inject-grid">${INJECT_BUTTONS.map((b) => `<button class="dbtn ${b.code >= 128 ? 'danger' : b.code >= 64 ? 'warn' : ''}" data-inject="${b.code}">${e(b.label)} <span class="mono">(${b.code})</span></button>`).join('')}</div>
      <p id="inject-msg" role="status"></p>` : `<p>${e(humanize(h.label))} is not deployed, so no events can be sent for it.</p>`, { cls: 'span2' })}
    ${robotBox(h)}
    ${box('Latest robot log', robotLog(h, { limit: 40 }), { cls: 'span2 rows23 grow' })}
    ${box('Humanoid', `${humanoidSelect()}<p class="dos-hint">Events are sent for the selected humanoid.</p>`, { cls: 'grow' })}
  </div>`;
}

function bindCustomerOverview() {
  bindHumanoidSelect();
  document.querySelectorAll('[data-inject]').forEach((b) => b.addEventListener('click', async () => {
    const h = selected();
    const msg = $('#inject-msg');
    b.disabled = true;
    try {
      await api.rpc('hg_inject_event', { p_humanoid: h.id, p_code: Number(b.dataset.inject), p_note: $('#inject-note').value || null });
      msg.textContent = 'Event sent. Waiting for the next poll...';
      await poll();
      msg.textContent = `Event sent at ${fmtTime(new Date())}.`;
    } catch (err) {
      msg.textContent = errorText(err);
    } finally {
      b.disabled = false;
    }
  }));
  const canvas = $('#face');
  if (!canvas) return;
  S.face = createFace(canvas, { reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches || document.documentElement.classList.contains('a11y-motion') });
  const startBtn = $('#start-checkin');
  const stopBtn = $('#stop-checkin');
  $('#voice').addEventListener('change', (ev) => { S.speech = ev.target.checked; });
  S.checkIn = createCheckIn({
    speak: (text) => (S.speech ? browserSpeak(text) : null),
    log: async (eventType, mode, { session_id: sessionId, question = null, answer = null, details = {} }) => {
      try {
        await api.insert('hg_events', {
          session_id: sessionId, event_type: eventType, mode, question, answer, details,
          client_time: new Date().toISOString(),
        });
        poll();
      } catch (err) {
        toast(`<b>Event not saved</b><br>${e(errorText(err))}`);
      }
    },
    onState: ({ mode, caption, options, running }) => {
      S.face?.setMode(mode);
      const m = $('#face-mode');
      if (!m) return;
      m.textContent = MODES[mode]?.label || mode;
      $('#face-caption').textContent = caption;
      startBtn.disabled = running;
      stopBtn.disabled = !running;
      $('#answers').innerHTML = options
        ? options.map(([v, label]) => `<button class="dbtn" data-answer="${e(v)}">${e(label)}</button>`).join('')
        : '<span class="dos-hint">The answer buttons appear while the face is listening.</span>';
      $('#answers').querySelectorAll('[data-answer]').forEach((btn) => btn.addEventListener('click', () => S.checkIn.answer(btn.dataset.answer)));
    },
  });
  startBtn.addEventListener('click', () => { logAction('start_check_in', { humanoid: selected()?.label }); S.checkIn.start(); });
  stopBtn.addEventListener('click', () => S.checkIn.stop());
}

// Plot buttons and the request buttons inside the customer views (one listener for the whole page).
function bindCustomerClicks() {
  $('#main').addEventListener('click', (ev) => {
    const plot = ev.target.closest('[data-plot]');
    if (plot) {
      const key = plot.dataset.plot;
      if (S.plots.has(key)) S.plots.delete(key); else { S.plots.add(key); logAction('show_plot', { plot: key }); }
      const h = selected();
      const el = $(`#plot-${key}`);
      if (el && h) el.outerHTML = plotBlock(key, h);
      return;
    }
    const v = ev.target.closest('.dbox [data-view]');
    if (v) go(v.dataset.view);
  });
}

function bindHumanoidSelect() {
  const sel = $('#humanoid-select');
  sel?.addEventListener('change', () => {
    S.selectedId = sel.value;
    logAction('select_humanoid', { humanoid: selected()?.label });
    go(S.view, { log: false });
  });
}

// ---------------------------------------------------------------- logistics overview
function logisticsOverview() {
  const h = selected();
  const groups = S.tab === 'customer' ? groupByCustomer() : groupByOem();
  return `
    <p class="kicker">Availability and logistics</p>
    <h1>Fleet overview</h1>
    <div class="dash-grid" style="margin-top:18px">
      <div class="span-8 stack">
        ${selectHumanoidCard(S.fleet)}
        ${eventWidget()}
        <div class="row"><div class="tabs" role="tablist" aria-label="Fleet view">
          <button role="tab" data-tab="customer" aria-selected="${S.tab === 'customer'}">Fleet by customer</button>
          <button role="tab" data-tab="oem" aria-selected="${S.tab === 'oem'}">Fleet by OEM</button></div>
          <span class="spacer"></span><span class="muted">${S.fleet.length} humanoids · ${S.fleet.filter((x) => x.instance_status === 'deployed').length} deployed</span></div>
        <div class="matrix" role="tabpanel">${groups.map(([title, sub, units]) => `
          <div class="card group"><h3>${e(title)} <span class="chip">${units.length}</span></h3><p class="muted" style="margin:0">${e(sub)}</p>
            ${units.map((u) => `<button class="unit" data-unit="${e(u.id)}" aria-pressed="${u.id === S.selectedId}">
              <span class="mini-led ${e(u.integrity_flag)}" aria-hidden="true"></span>
              <span style="flex:1">${e(humanize(u.label))}<br><span class="muted" style="font-weight:600;font-size:.85rem">${e(humanize(S.tab === 'customer' ? u.model_id : (u.customer_name || u.instance_status)))}</span></span>
              <span class="chip ${u.instance_status === 'deployed' ? 'green' : 'blue'}" style="font-size:.7rem">${e(humanize(u.instance_status))}</span></button>`).join('')}
          </div>`).join('')}</div>
        ${h ? `<h2 style="margin-top:28px">${e(humanize(h.label))}</h2>
        ${overviewTable(h)}
        <div class="dash-grid"><div class="span-5">${capabilities(h)}</div><div class="span-7" id="events-chart-wrap">${eventsChart(eventsFor(h.id))}</div></div>
        <div class="card">${robotLog(h, { gateway: true })}</div>` : ''}
      </div>
      ${h ? `<aside class="span-4 stack">
        <div class="card"><p class="kicker">${e(humanize(h.model_id))}</p><div class="robot-figure">${robotSvg(h)}</div>
          <p class="hint">Dummy picture; the model photo follows.</p></div>
        <div class="card"><h3>Indicators system integrity</h3>${leds(h.integrity_flag)}</div>
        <div class="card"><table class="kv">
          <tr><th>In stock (same model)</th><td><b>${h.in_stock_same_model ?? 0}</b></td></tr>
          <tr><th>Currently deployed</th><td>${e(h.customer_name || 'Not deployed')}</td></tr>
          <tr><th>Operating time</th><td>${fmtHours(h.operating_hours)}</td></tr>
          <tr><th>Estimated time to failure</th><td>${fmtHours(h.time_to_failure_h)}</td></tr>
          <tr><th>OEM ID</th><td class="mono">${e(h.oem_id)}</td></tr>
          <tr><th>Humanoid UUID</th><td class="mono" style="word-break:break-all">${e(h.id)}</td></tr>
        </table></div>
        <button class="btn" data-goto="parts">Components list <span class="arrow"></span></button>
        <button class="btn" data-goto="reliability">Time to failure plot <span class="arrow"></span></button>
        <div class="card"><h3>Humanoid history</h3>
          <table class="brut"><thead><tr><th>Date</th><th>Maintenance</th><th>Replaced parts</th></tr></thead><tbody>
          ${(h.history || []).map((x) => `<tr><td class="mono">${fmtDate(x.done_on)}</td><td>${e(x.action)}</td><td>${e(x.parts || '-')}</td></tr>`).join('')
            || '<tr><td colspan="3" class="empty">No history</td></tr>'}</tbody></table></div>
      </aside>` : ''}
    </div>`;
}

function groupByCustomer() {
  const map = new Map();
  for (const u of S.fleet) {
    const key = u.customer_name || 'HG warehouse and service';
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(u);
  }
  return [...map.entries()].sort(([a], [b]) => (a.startsWith('HG') ? 1 : b.startsWith('HG') ? -1 : a.localeCompare(b)))
    .map(([k, units]) => [k, k.startsWith('HG') ? 'Not deployed: stock, service and transport' : 'Deployed humanoids', units]);
}

function groupByOem() {
  const map = new Map();
  for (const u of S.fleet) {
    const key = u.oem_id;
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(u);
  }
  return [...map.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([oem, units]) => {
    const variants = [...new Set(units.map((u) => humanize(u.model_id)))].join(', ');
    return [humanize(oem), `Humanoid variants: ${variants}`, units];
  });
}

function bindLogisticsOverview() {
  bindHumanoidSelect();
  document.querySelectorAll('[data-tab]').forEach((b) => b.addEventListener('click', () => {
    S.tab = b.dataset.tab;
    logAction('switch_tab', { tab: S.tab });
    go('fleet', { log: false });
  }));
  document.querySelectorAll('[data-unit]').forEach((b) => b.addEventListener('click', () => {
    S.selectedId = b.dataset.unit;
    logAction('select_humanoid', { humanoid: selected()?.label });
    go('fleet', { log: false });
  }));
  document.querySelectorAll('[data-goto]').forEach((b) => b.addEventListener('click', () => go(b.dataset.goto)));
}

// ---------------------------------------------------------------- per-instance sub views (logistics)
function partsView() {
  const h = selected();
  const parts = sparePartsFor(h?.oem_id);
  return `<button class="btn small" data-goto="fleet">&larr; Back to the fleet</button>
    <p class="kicker" style="margin-top:18px">${e(humanize(h?.label))} · ${e(humanize(h?.model_id))}</p>
    <h1>Components list</h1>
    <p class="notice warn">Mock-up: artificial parts list of ${e(humanize(h?.oem_id))}.</p>
    <div class="table-scroll" style="max-height:none;margin-top:18px"><table class="brut">
      <thead><tr><th>Spare part</th><th>Description</th><th>In stock</th><th>Status</th><th></th></tr></thead><tbody>
      ${parts.map((p) => `<tr><td>${e(humanize(p.id))}</td><td>${e(p.description)}</td><td class="mono">${p.inStock}</td>
        <td><span class="chip ${p.reorder ? 'yellow' : 'green'}">${p.reorder ? 'Reorder' : 'In stock'}</span></td>
        <td><button class="btn small" data-mock="request_part" data-part="${e(p.id)}">Request part</button></td></tr>`).join('')}
      </tbody></table></div><p id="mock-msg" role="status" style="margin-top:12px"></p>`;
}

function reliabilityView() {
  const h = selected();
  const rel = reliability(h.operating_hours, h.time_to_failure_h);
  return `<button class="btn small" data-goto="fleet">&larr; Back to the fleet</button>
    <p class="kicker" style="margin-top:18px">${e(humanize(h.label))} · ${e(humanize(h.model_id))}</p>
    <h1>Estimated time to failure</h1>
    <div class="dash-grid" style="margin-top:18px">
      <div class="card chart span-8"><h3>Simulated system reliability</h3>
        ${lineChart({
          title: 'Reliability over operating hours',
          series: [{ name: 'Reliability', fill: '#a8e6c5', points: rel.series.map((p) => ({ x: p.t, y: p.r * 100 })) }],
          yMin: 0, yMax: 100, height: 300,
          hLines: [{ y: rel.threshold * 100, label: `Threshold ${Math.round(rel.threshold * 100)} %` }],
          vLines: [{ x: rel.failAt, label: 'Estimated failure' }],
          marks: [{ x: rel.current.t, y: rel.current.r * 100, label: 'Now' }],
          xFormat: (t) => `${Math.round(t)} h`, yFormat: (v) => `${v} %`,
        })}
        <div class="legend"><span><i style="background:#a8e6c5"></i>Reliability R(t)</span><span><i style="background:#f2545b"></i>Threshold</span><span><i style="background:#ffd23f"></i>Current operating time</span></div>
      </div>
      <div class="card span-4"><table class="kv">
        <tr><th>Operating time</th><td>${fmtHours(h.operating_hours)}</td></tr>
        <tr><th>Estimated time to failure</th><td>${fmtHours(h.time_to_failure_h)}</td></tr>
        <tr><th>Reliability now</th><td>${(rel.current.r * 100).toFixed(1)} %</td></tr>
        <tr><th>Threshold</th><td>${Math.round(rel.threshold * 100)} %</td></tr>
        <tr><th>Model</th><td>Weibull, shape ${rel.beta}, scale ${Math.round(rel.eta)} h</td></tr>
      </table><p class="hint">Simulated: the curve is fitted so that it crosses the threshold when the estimated time to failure runs out, as components wear.</p>
      ${leds(h.integrity_flag)}</div>
    </div>`;
}

// ---------------------------------------------------------------- forms
function accountView() {
  const c = customer();
  return `<p class="kicker">Working form</p><h1>Account details</h1>
    <div class="dash-grid" style="margin-top:18px">
      <form class="card span-6" id="account-form" novalidate>
        <div class="field"><label for="acc-email">E-mail</label><input id="acc-email" value="${e(S.me.email)}" readonly></div>
        <div class="field"><label for="acc-name">Display name</label><input id="acc-name" maxlength="80" value="${e(S.me.display_name || '')}"></div>
        <div class="field"><label for="acc-phone">Phone</label><input id="acc-phone" maxlength="25" value="${e(S.me.phone || '')}" inputmode="tel" pattern="[0-9 +()/-]{0,25}">
          <p class="hint">Digits, spaces and + ( ) / - only.</p></div>
        <button class="btn primary" type="submit">Save</button>
        <p id="acc-msg" role="status" style="margin:12px 0 0"></p>
      </form>
      <div class="card span-6"><table class="kv">
        <tr><th>Role</th><td>${isAdmin() ? 'Admin (HG logistics)' : 'User (customer)'}</td></tr>
        ${c ? `<tr><th>Customer</th><td>${e(c.name)}</td></tr><tr><th>Customer unique ID</th><td class="mono">${e(humanize(c.unique_id))}</td></tr>
        <tr><th>Use case</th><td>${e(humanize(c.use_case))}</td></tr>` : ''}
        <tr><th>Member since</th><td>${fmtDate(S.me.member_since)}</td></tr>
        <tr><th>Last sign-in</th><td id="acc-last">-</td></tr>
      </table></div>
    </div>`;
}

function bindAccount() {
  api.user().then((u) => { const el = $('#acc-last'); if (el) el.textContent = fmtDateTime(u?.last_sign_in_at); }).catch(() => {});
  $('#account-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const msg = $('#acc-msg');
    const phone = $('#acc-phone').value.trim();
    if (!/^[0-9 +()/-]{0,25}$/.test(phone)) { msg.textContent = 'Phone: use digits, spaces and + ( ) / - only.'; return; }
    try {
      S.me = await api.rpc('hg_update_account', { p_display_name: $('#acc-name').value, p_phone: phone });
      msg.textContent = 'Saved.';
      renderSide();
    } catch (err) {
      msg.textContent = errorText(err);
    }
  });
}

function mockForm(kind) {
  const stock = S.fleet.filter((h) => h.instance_status === 'in_stock');
  const options = (list) => list.map((h) => `<option value="${e(h.id)}" ${h.id === S.selectedId ? 'selected' : ''}>${e(humanize(h.label))}</option>`).join('');
  const F = {
    extension: ['Request rental period extension', `
      <div class="field"><label for="m1">Humanoid</label><select id="m1">${options(S.fleet)}</select></div>
      <div class="field"><label for="m2">Extend until</label><input id="m2" type="date"></div>
      <div class="field"><label for="m3">Reason</label><textarea id="m3" rows="3" maxlength="500"></textarea></div>`],
    ticket: ['Create a support ticket', `
      <div class="field"><label for="m1">Type</label><select id="m1"><option>General</option><option>Humanoid has an issue</option></select></div>
      <div class="field"><label for="m2">Priority</label><select id="m2"><option>Low</option><option selected>Normal</option><option>High</option><option>Critical</option></select></div>
      <div class="field"><label for="m3">Robotic platform</label><select id="m3">${options(S.fleet)}</select></div>
      ${isAdmin() ? `<div class="field"><label for="m4">Authorised by</label><select id="m4"><option>Fleet manager</option><option>Head of service</option><option>Customer success manager</option></select></div>` : ''}
      <div class="field"><label for="m5">Description</label><textarea id="m5" rows="4" maxlength="1000"></textarea></div>`],
    deploy: ['Deploy a humanoid', `
      <div class="field"><label for="m1">Humanoid in stock</label><select id="m1">${options(stock)}</select></div>
      <div class="field"><label for="m2">Customer</label><select id="m2"><option>Central Clinic</option><option>North Clinic</option></select></div>
      <div class="field"><label for="m3">Deployment date</label><input id="m3" type="date"></div>
      <div class="field"><label for="m4">Technician</label><select id="m4">${TECHNICIANS.map((t) => `<option>${e(t)}</option>`).join('')}</select></div>`],
    maintenance: ['Schedule maintenance and service', `
      <div class="field"><label for="m1">Humanoid</label><select id="m1">${options(S.fleet)}</select></div>
      <div class="field"><label for="m2">Service type</label><select id="m2"><option>Scheduled maintenance</option><option>Repair</option><option>Part replacement</option><option>System test</option></select></div>
      <div class="field"><label for="m3">Technician</label><select id="m3">${TECHNICIANS.map((t) => `<option>${e(t)}</option>`).join('')}</select></div>
      <div class="field"><label for="m4">Preferred date</label><input id="m4" type="date"></div>`],
  }[kind];
  return `<p class="kicker">Mock-up</p><h1>${e(F[0])}</h1>
    <p class="notice warn">Demo only: this form shows the view, but nothing is sent or changed. The action is written to the audit log.</p>
    <form class="card" id="mock-form" style="max-width:720px;margin-top:18px" novalidate>${F[1]}
      <button class="btn primary" type="submit">${kind === 'maintenance' ? 'Send request to technician' : 'Submit'}</button>
      <div id="mock-msg" role="status" style="margin-top:14px"></div></form>`;
}

function bindMock(kind) {
  $('#mock-form').addEventListener('submit', (ev) => {
    ev.preventDefault();
    const msg = $('#mock-msg');
    const sel = $('#m1');
    const label = sel?.selectedOptions?.[0]?.textContent || '';
    logAction(`mock_${kind}`, { humanoid: label });
    if (kind === 'maintenance') {
      const tech = $('#m3').value;
      msg.innerHTML = `<p class="notice">Request sent to <b>${e(tech)}</b>. Status: <span class="chip yellow status-pill" id="tech-status">Waiting for the technician</span></p>`;
      later(() => {
        const st = $('#tech-status');
        if (st) { st.className = 'chip green status-pill'; st.textContent = 'Technician has accepted the request'; }
      }, 4000);
    } else {
      msg.innerHTML = '<p class="notice">Received (demo). Nothing was sent.</p>';
    }
  });
}

function exportView() {
  return `<p class="kicker">Download</p><h1>Export events to Excel</h1>
    <form class="card" id="export-form" style="max-width:720px;margin-top:18px">
      <div class="field"><label for="x1">Humanoid</label><select id="x1"><option value="">All humanoids</option>${S.fleet.map((h) =>
        `<option value="${e(h.id)}">${e(humanize(h.label))}</option>`).join('')}</select></div>
      <div class="field"><label for="x2">Period</label><select id="x2"><option value="today">Today</option><option value="24" selected>Last 24 hours</option><option value="all">Everything loaded in this session</option></select></div>
      <button class="btn primary" type="submit">Download CSV for Excel</button>
      <p class="hint">${isAdmin() ? 'The logistics export has no payloads.' : 'Includes the payload of each event.'} The file opens in Excel.</p>
      <p id="x-msg" role="status"></p></form>`;
}

export function eventsCsv(list, { admin }) {
  const cols = [
    { title: 'Date', value: (r) => fmtDate(r.created_at) }, { title: 'Time', value: (r) => fmtTime(r.created_at) },
    { title: 'Humanoid', value: (r) => humanize(r.label) }, { title: 'Humanoid UUID', value: 'humanoid_id' },
    { title: 'Code', value: 'code' }, { title: 'Type', value: (r) => humanize(r.type) }, { title: 'Event', value: 'name' },
    { title: 'Source', value: (r) => humanize(r.source) },
  ];
  if (!admin) cols.push({ title: 'Payload', value: (r) => payloadText(r.payload) });
  return toCsv(list, cols);
}

function bindExport() {
  $('#export-form').addEventListener('submit', (ev) => {
    ev.preventDefault();
    const id = $('#x1').value;
    const period = $('#x2').value;
    const now = Date.now();
    let list = eventsFor(id || null);
    if (period === 'today') list = list.filter((x) => isToday(x.created_at));
    if (period === '24') list = list.filter((x) => now - new Date(x.created_at).getTime() <= 24 * 3600e3);
    const blob = new Blob([eventsCsv(list, { admin: isAdmin() })], { type: 'text/csv;charset=utf-8' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `hg-events-${isAdmin() ? 'fleet' : customer().id}-${fmtDate(new Date())}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    $('#x-msg').textContent = `${list.length} events exported.`;
    logAction('export_events', { rows: list.length, period });
  });
}

function warehouseView() {
  const rows = warehouseRows();
  return `<p class="kicker">Mock-up data</p><h1>Warehouse availability</h1>
    <div class="row" style="margin:18px 0"><label for="w-filter" style="margin:0">Show</label>
      <select id="w-filter" style="width:auto"><option value="">Everything</option><option value="Humanoid">Humanoids</option>
      <option value="OEM_A">Spare parts OEM A</option><option value="OEM_B">Spare parts OEM B</option><option value="OEM_C">Spare parts OEM C</option><option value="OEM_D">Spare parts OEM D</option></select>
      <span class="spacer"></span><span class="muted" id="w-count"></span></div>
    <div class="table-scroll" style="max-height:560px"><table class="brut" id="w-table">
      <thead><tr><th>Kind</th><th>Item</th><th>Detail</th><th>Quantity</th><th>Status</th><th>Location</th></tr></thead>
      <tbody>${rows.map((r) => `<tr data-kind="${e(r.kind)}" data-id="${e(r.id)}"><td>${e(r.kind)}</td><td>${e(humanize(r.id))}</td><td>${e(r.kind === 'Humanoid' ? humanize(r.detail) : r.detail)}</td>
        <td class="mono">${r.qty}</td><td><span class="chip ${{ in_stock: 'green', reorder: 'yellow', maintenance: 'yellow', in_transit: 'blue', ordered: 'grey' }[r.status] || 'grey'}">${e(humanize(r.status))}</span></td><td>${e(r.location)}</td></tr>`).join('')}
      </tbody></table></div>`;
}

function bindWarehouse() {
  const f = $('#w-filter');
  const apply = () => {
    let n = 0;
    document.querySelectorAll('#w-table tbody tr').forEach((tr) => {
      const v = f.value;
      const show = !v || (v === 'Humanoid' ? tr.dataset.kind === 'Humanoid' : tr.dataset.kind === 'Spare part' && tr.dataset.id.includes(`_${v}_`));
      tr.hidden = !show;
      if (show) n += 1;
    });
    $('#w-count').textContent = `${n} rows`;
  };
  f.addEventListener('change', apply);
  apply();
}

function auditView() {
  return `<p class="kicker">Admins only</p><h1>Audit log</h1>
    <div class="row" style="margin:18px 0"><button class="btn small" id="audit-refresh">Refresh</button><span class="muted" id="audit-info"></span></div>
    <div class="table-scroll" style="max-height:640px"><table class="brut">
      <thead><tr><th>Date</th><th>Time</th><th>Account</th><th>Role</th><th>Action</th><th>Details</th></tr></thead>
      <tbody id="audit-body"><tr><td colspan="6" class="empty">Loading...</td></tr></tbody></table></div>`;
}

async function bindAudit() {
  const load = async () => {
    const body = $('#audit-body');
    try {
      const rows = (await api.rpc('hg_audit', { p_limit: 300 })) || [];
      if (!$('#audit-body')) return;
      body.innerHTML = rows.map((r) => `<tr><td>${fmtDate(r.created_at)}</td><td>${fmtTime(r.created_at)}</td><td>${e(r.email || 'deleted account')}</td>
        <td>${e(humanize(r.role))}</td><td><b>${e(humanize(r.action))}</b></td><td class="mono" style="font-size:.8rem">${e(Object.entries(r.details || {}).map(([k, v]) => `${humanize(k)}: ${typeof v === 'object' ? JSON.stringify(v) : (/^[A-Za-z]+(_[A-Za-z0-9]+)+$/.test(String(v)) ? humanize(v) : v)}`).join(' · '))}</td></tr>`).join('')
        || '<tr><td colspan="6" class="empty">No entries yet</td></tr>';
      $('#audit-info').textContent = `${rows.length} entries · ${fmtTime(new Date())}`;
    } catch (err) {
      body.innerHTML = `<tr><td colspan="6" class="empty">${e(errorText(err))}</td></tr>`;
    }
  };
  $('#audit-refresh').addEventListener('click', load);
  await load();
}

// ---------------------------------------------------------------- render
function renderView() {
  const main = $('#main');
  const v = S.view;
  if (!isAdmin()) {
    const page = { overview: customerOverview, face: conversation() ? customerFace : null, environment: conversation() ? null : customerEnvironment,
      activity: customerActivity, demo: conversation() ? customerDemo : null }[v];
    if (page) { main.innerHTML = page(); bindCustomerOverview(); return; }
  }
  if (v === 'fleet') { main.innerHTML = logisticsOverview(); bindLogisticsOverview(); return; }
  if (v === 'parts' && isAdmin()) { main.innerHTML = partsView(); bindSubview(); return; }
  if (v === 'reliability' && isAdmin() && selected()) { main.innerHTML = reliabilityView(); bindSubview(); return; }
  if (v === 'account') { main.innerHTML = accountView(); bindAccount(); return; }
  if (['extension', 'ticket'].includes(v) || (isAdmin() && ['deploy', 'maintenance'].includes(v))) { main.innerHTML = mockForm(v); bindMock(v); return; }
  if (v === 'export') { main.innerHTML = exportView(); bindExport(); return; }
  if (v === 'warehouse' && isAdmin()) { main.innerHTML = warehouseView(); bindWarehouse(); return; }
  if (v === 'audit' && isAdmin()) { main.innerHTML = auditView(); bindAudit(); return; }
  go(isAdmin() ? 'fleet' : 'overview', { log: false });
}

function bindSubview() {
  document.querySelectorAll('[data-goto]').forEach((b) => b.addEventListener('click', () => go(b.dataset.goto)));
  document.querySelectorAll('[data-mock]').forEach((b) => b.addEventListener('click', () => {
    logAction(`mock_${b.dataset.mock}`, { part: b.dataset.part });
    $('#mock-msg').innerHTML = `<span class="notice">Request for ${e(humanize(b.dataset.part))} received (demo). Nothing was sent.</span>`;
  }));
}

// Updates the live parts of the overview without rebuilding forms or the face.
const LIVE_VIEWS = ['overview', 'fleet', 'face', 'environment', 'activity', 'demo'];
function refreshLive() {
  if (!LIVE_VIEWS.includes(S.view)) return;
  const h = selected();
  const list = eventsFor(h?.id);
  const t = $('#events-today'); if (t) t.textContent = String(countToday(list));
  const ta = $('#events-today-all'); if (ta) ta.textContent = String(countToday(S.events));
  const inc = $('#incidents'); if (inc && h) inc.textContent = String(incidents30(h));
  const log = $('#robot-log');
  if (log && h) log.outerHTML = robotLog(h, { gateway: isAdmin(), limit: !isAdmin() && S.view !== 'activity' ? 40 : 120 });
  const ch = $('#events-chart-wrap'); if (ch) ch.innerHTML = isAdmin() ? eventsChart(list) : eventsChartPlain(list);
}

// ---------------------------------------------------------------- boot
async function boot() {
  renderA11yWidget();
  if (!hasSession()) { location.replace('login.html'); return; }
  try {
    S.me = await api.rpc('hg_whoami');
    if (!S.me) {
      await api.signOut();
      $('#main').innerHTML = `<div class="card" style="max-width:640px"><h1>No access</h1><p>This account has no access to the Health Guardian dashboards.</p><a class="btn primary" href="login.html">Sign in with another account</a></div>`;
      return;
    }
    await loadFleet();
    const initial = await api.rpc('hg_feed', { p_since: new Date(Date.now() - 24 * 3600e3).toISOString(), p_limit: 500 });
    addEvents(initial || [], { live: false });
    S.lastSync = new Date();
  } catch (err) {
    if (err?.message === 'session_expired') { location.replace('login.html'); return; }
    $('#main').innerHTML = `<div class="notice error">${e(errorText(err))}</div>`;
    return;
  }
  startSimulation();
  renderTop();
  go(isAdmin() ? 'fleet' : 'overview', { log: false });
  const tick = () => later(async () => { await poll(); tick(); }, CONFIG.pollMs);
  tick();
  const fleetTick = () => later(async () => {
    try { await loadFleet(); } catch { /* keep the old list */ }
    refreshLive();
    fleetTick();
  }, CONFIG.fleetRefreshMs);
  fleetTick();
}

if (typeof document !== 'undefined' && document.getElementById('main')) boot();
