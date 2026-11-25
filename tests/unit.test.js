// Unit tests for the browser modules (node --test, no dependencies).
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { humanize, escapeHtml, toCsv, payloadText, fmtHours, typeClass, flagText, isToday } from '../assets/js/format.js';
import { createApi, errorText } from '../assets/js/api.js';
import { loadSession, saveSession, clearSession, hasSession } from '../assets/js/session.js';
import { createCentralSimulator, reliability, environment, rng } from '../assets/js/sim.js';
import { createCheckIn } from '../assets/js/face.js';
import { lineChart, barChart, eventsPerHour } from '../assets/js/charts.js';
import { sparePartsFor, warehouseRows, EVENT_CODES, CHECK_IN, codeInfo } from '../assets/js/data.js';
import { robotSvg } from '../assets/js/robot-art.js';
import { eventsCsv } from '../assets/js/dashboard.js';

// ---------------------------------------------------------------- format
test('humanize makes identifiers readable', () => {
  assert.equal(humanize('Humanoid_OEM_A_UUID'), 'Humanoid OEM A UUID');
  assert.equal(humanize('Humanoid_OEM_N_UUID'), 'Humanoid OEM N UUID');
  assert.equal(humanize('Humanoid_OEM_B_UUID_2'), 'Humanoid OEM B UUID 2');
  assert.equal(humanize('Spare_Humanoid_OEM_A_Component_A'), 'Spare Humanoid OEM A Component A');
  assert.equal(humanize('FALL_DETECTED'), 'Fall detected');
  assert.equal(humanize('ENVIRONMENT_VARIABLE_ALARM'), 'Environment variable alarm');
  assert.equal(humanize('KEEP_ALIVE'), 'Keep alive');
  assert.equal(humanize('in_stock'), 'In stock');
  assert.equal(humanize('OEM_A_VARIANT_B'), 'OEM A variant B');
  assert.equal(humanize('CUSTOMER_UNIQUE_ID_X'), 'Customer unique ID X');
  assert.equal(humanize('Demo_Patient_UUID'), 'Demo Patient UUID');
  assert.equal(humanize('not_good'), 'Not good');
  assert.equal(humanize(null), '');
  assert.equal(humanize(''), '');
});

test('escapeHtml escapes markup', () => {
  assert.equal(escapeHtml('<img src=x onerror="a">&\''), '&lt;img src=x onerror=&quot;a&quot;&gt;&amp;&#39;');
  assert.equal(escapeHtml(undefined), '');
});

test('toCsv: BOM, quoting and no formula injection', () => {
  const csv = toCsv([{ a: '=1+2', b: 'x,"y"' }, { a: '-cmd', b: null }], [{ title: 'A', value: 'a' }, { title: 'B', value: (r) => r.b }]);
  assert.ok(csv.startsWith('﻿A,B\r\n'));
  assert.ok(csv.includes("'=1+2,\"x,\"\"y\"\"\""));
  assert.ok(csv.includes("'-cmd,\r\n"));
});

test('payloadText and other formatters', () => {
  assert.equal(payloadText({ question: 'How are you today?', answer: 'not_good', mode: 'listening', session: 'x' }),
    'How are you today? · Answer: Not good');
  assert.equal(payloadText({ room: '1.04', confidence: '0.91' }), 'Room: 1.04 · Confidence: 0.91');
  assert.equal(payloadText(null), '');
  assert.equal(fmtHours(72), '72 h (about 3 days)');
  assert.equal(fmtHours(9.5), '9.5 h');
  assert.equal(fmtHours('x'), '-');
  assert.equal(typeClass('FALL_DETECTED'), 'red');
  assert.equal(typeClass('nope'), 'grey');
  assert.equal(flagText('yellow'), 'Action is needed');
  assert.ok(isToday(new Date()));
  assert.ok(!isToday('2001-01-01T00:00:00Z'));
});

// ---------------------------------------------------------------- api (fake fetch)
function fakeFetch(handler) {
  const calls = [];
  const fn = async (url, init = {}) => {
    calls.push({ url, init, body: init.body ? JSON.parse(init.body) : null });
    const r = await handler(url, init, calls.length);
    return {
      ok: r.status >= 200 && r.status < 300, status: r.status,
      json: async () => r.body, text: async () => (r.body === undefined ? '' : JSON.stringify(r.body)),
    };
  };
  fn.calls = calls;
  return fn;
}
const cfg = { supabaseUrl: 'https://example.supabase.co/', supabaseKey: 'pk_test' };

test('signIn stores the session; rpc sends the JWT and the key', async () => {
  clearSession();
  const f = fakeFetch((url) => {
    if (url.includes('grant_type=password')) return { status: 200, body: { access_token: 'A1', refresh_token: 'R1', expires_in: 3600, user: { id: 'u1', email: 'nc@hg.com' } } };
    if (url.endsWith('/rest/v1/rpc/hg_whoami')) return { status: 200, body: { role: 'user' } };
    return { status: 404, body: {} };
  });
  const api = createApi({ fetchImpl: f, config: cfg, now: () => 1_000_000 });
  await api.signIn(' nc@hg.com ', 'pw');
  assert.equal(f.calls[0].url, 'https://example.supabase.co/auth/v1/token?grant_type=password');
  assert.deepEqual(f.calls[0].body, { email: 'nc@hg.com', password: 'pw' });
  assert.equal(loadSession().access_token, 'A1');
  assert.equal(loadSession().email, 'nc@hg.com');
  assert.equal(loadSession().expires_at, 1000 + 3600);
  assert.deepEqual(await api.rpc('hg_whoami'), { role: 'user' });
  const h = f.calls[1].init.headers;
  assert.equal(h.Authorization, 'Bearer A1');
  assert.equal(h.apikey, 'pk_test');
  assert.ok(hasSession());
});

test('expiring tokens are refreshed before the call', async () => {
  saveSession({ access_token: 'OLD', refresh_token: 'R1', expires_at: 1000 + 30 });
  const f = fakeFetch((url) => {
    if (url.includes('grant_type=refresh_token')) return { status: 200, body: { access_token: 'NEW', refresh_token: 'R2', expires_in: 3600 } };
    return { status: 200, body: [] };
  });
  const api = createApi({ fetchImpl: f, config: cfg, now: () => 1_000_000 });
  await api.rpc('hg_fleet');
  assert.match(f.calls[0].url, /refresh_token/);
  assert.deepEqual(f.calls[0].body, { refresh_token: 'R1' });
  assert.equal(f.calls[1].init.headers.Authorization, 'Bearer NEW');
  assert.equal(loadSession().refresh_token, 'R2');
});

test('a 401 triggers one refresh and a retry; a failed refresh ends the session', async () => {
  saveSession({ access_token: 'A', refresh_token: 'R', expires_at: 999999 });
  let rpcCalls = 0;
  const f = fakeFetch((url) => {
    if (url.includes('refresh_token')) return { status: 200, body: { access_token: 'B', refresh_token: 'R2', expires_in: 3600 } };
    rpcCalls += 1;
    return rpcCalls === 1 ? { status: 401, body: { message: 'JWT expired' } } : { status: 200, body: { ok: 1 } };
  });
  const api = createApi({ fetchImpl: f, config: cfg, now: () => 1_000_000 });
  assert.deepEqual(await api.rpc('hg_whoami'), { ok: 1 });

  saveSession({ access_token: 'A', refresh_token: 'R', expires_at: 999999 });
  const g = fakeFetch((url) => (url.includes('refresh_token') ? { status: 400, body: { error: 'invalid_grant' } } : { status: 401, body: {} }));
  const api2 = createApi({ fetchImpl: g, config: cfg, now: () => 1_000_000 });
  await assert.rejects(api2.rpc('hg_whoami'), /session_expired/);
  assert.equal(hasSession(), false);
});

test('database errors keep their message; insert asks for no body', async () => {
  saveSession({ access_token: 'A', refresh_token: 'R', expires_at: 999999 });
  const f = fakeFetch((url) => (url.includes('/rpc/') ? { status: 400, body: { code: '42501', message: 'hg_access_denied' } } : { status: 201, body: undefined }));
  const api = createApi({ fetchImpl: f, config: cfg, now: () => 1_000_000 });
  await assert.rejects(api.rpc('hg_fleet'), (err) => err.message === 'hg_access_denied' && err.code === '42501' && err.status === 400);
  assert.equal(await api.insert('hg_events', { event_type: 'session_started' }), null);
  assert.equal(f.calls[1].init.headers.Prefer, 'return=minimal');
  assert.match(f.calls[1].url, /\/rest\/v1\/hg_events$/);
});

test('signOut clears the session even when the network fails', async () => {
  saveSession({ access_token: 'A', refresh_token: 'R', expires_at: 999999 });
  const api = createApi({ fetchImpl: async () => { throw new TypeError('Failed to fetch'); }, config: cfg });
  await api.signOut();
  assert.equal(hasSession(), false);
});

test('errorText gives friendly messages', () => {
  assert.match(errorText(new Error('Invalid login credentials')), /not correct/);
  assert.match(errorText(new Error('hg_rate_limited')), /Too many/);
  assert.match(errorText(new TypeError('Failed to fetch')), /No connection/);
  assert.match(errorText(new Error('weird')), /went wrong/);
});

// ---------------------------------------------------------------- simulation
const central = [
  { id: 'h1', label: 'Humanoid_OEM_A_UUID', instance_status: 'deployed', integrity_flag: 'green', features: ['FALL_DETECTION', 'REMINDERS'] },
  { id: 'h2', label: 'Humanoid_OEM_D_UUID', instance_status: 'deployed', integrity_flag: 'red', features: ['FALL_DETECTION'] },
  { id: 'h3', label: 'Humanoid_OEM_C_UUID_2', instance_status: 'in_stock', integrity_flag: 'green', features: [] },
];

test('Central Clinic simulator: deterministic history of valid events for deployed humanoids only', () => {
  const now = Date.UTC(2026, 10, 25, 12);
  const a = createCentralSimulator(central, { now: () => now }).history(24);
  const b = createCentralSimulator(central, { now: () => now }).history(24);
  assert.deepEqual(a, b);
  assert.ok(a.length >= 30 && a.length <= 120, `history length ${a.length}`);
  const per = a.reduce((m, x) => ({ ...m, [x.humanoid_id]: (m[x.humanoid_id] || 0) + 1 }), {});
  assert.ok(per.h1 >= 10 && per.h2 >= 10, `spread ${JSON.stringify(per)}`);
  for (const ev of a) {
    assert.ok(['h1', 'h2'].includes(ev.humanoid_id));
    assert.equal(ev.source, 'simulated');
    assert.ok(ev.code >= 0 && ev.code <= 255);
    assert.equal(codeInfo(ev.code).type, ev.type);
    assert.ok(new Date(ev.created_at).getTime() < now && new Date(ev.created_at).getTime() > now - 24 * 3600e3);
  }
  for (let i = 1; i < a.length; i += 1) assert.ok(a[i - 1].created_at >= a[i].created_at, 'newest first');
  assert.equal(new Set(a.map((x) => x.event_id)).size, a.length);
  const sim = createCentralSimulator(central, { now: () => now });
  const next = sim.next();
  assert.equal(next.created_at, new Date(now).toISOString());
  const d = sim.nextDelay();
  assert.ok(d >= 7000 && d <= 16000);
  assert.equal(createCentralSimulator([], {}).next(), null);
});

test('reliability crosses the threshold when the time to failure runs out', () => {
  const rel = reliability(4310, 640);
  assert.equal(rel.failAt, 4950);
  assert.ok(Math.abs(rel.R(rel.failAt) - 0.8) < 1e-9);
  assert.ok(rel.current.r > 0.8);
  assert.ok(rel.series[0].r === 1 && rel.series.at(-1).r < 0.8);
  for (let i = 1; i < rel.series.length; i += 1) assert.ok(rel.series[i].r <= rel.series[i - 1].r);
  assert.ok(reliability(0, 0).series.length > 0);
});

test('environment readings are plausible', () => {
  const env = environment(2, { now: Date.UTC(2026, 10, 25, 12) });
  assert.equal(env.points.length, 25);
  for (const p of env.points) {
    assert.ok(p.temperature > 18 && p.temperature < 26);
    assert.ok(p.humidity > 30 && p.humidity < 65);
    assert.ok(p.co2 > 500 && p.co2 < 1000);
  }
  const r = rng(1);
  const v = r();
  assert.ok(v >= 0 && v < 1);
});

// ---------------------------------------------------------------- check-in
test('check-in logs the same steps as the phone app', async () => {
  const logs = [];
  const states = [];
  let ci;
  const wait = () => Promise.resolve();
  ci = createCheckIn({
    wait, answerTimeoutMs: 1e9,
    log: async (type, mode, extra) => { logs.push({ type, mode, answer: extra.answer ?? null, session: extra.session_id }); },
    onState: (s) => {
      states.push(s);
      if (s.mode === 'listening') {
        const v = s.options[0][0] === 'good' ? 'not_good' : 'no';
        queueMicrotask(() => ci.answer(v));
      }
    },
  });
  await ci.start();
  assert.deepEqual(logs.map((l) => `${l.type}:${l.mode}:${l.answer ?? ''}`), [
    'session_started:idle:', 'mood_answer:listening:not_good', 'medication_answer:listening:no',
    'exercise_demo:action:', 'session_completed:idle:',
  ]);
  assert.equal(new Set(logs.map((l) => l.session)).size, 1);
  assert.match(logs[0].session, /^[0-9a-f-]{36}$/);
  assert.ok(states.some((s) => s.mode === 'speaking'));
  assert.equal(states.at(-1).mode, 'idle');
  assert.equal(ci.running, false);
});

test('no answer within the time limit is logged as no_answer', async () => {
  const logs = [];
  const ci = createCheckIn({
    wait: () => Promise.resolve(), answerTimeoutMs: 0,
    log: async (type, mode, extra) => { logs.push(`${type}:${extra.answer ?? ''}`); },
    onState: () => {},
  });
  await ci.start();
  assert.ok(logs.includes('mood_answer:no_answer'));
  assert.ok(logs.includes('medication_answer:no_answer'));
});

test('stop ends the check-in without further events', async () => {
  const logs = [];
  let ci;
  ci = createCheckIn({
    wait: () => new Promise((r) => setTimeout(r, 1)), answerTimeoutMs: 1e9,
    log: async (type) => { logs.push(type); },
    onState: (s) => { if (s.mode === 'listening') ci.stop(); },
  });
  await ci.start();
  assert.deepEqual(logs, ['session_started']);
  assert.equal(ci.running, false);
});

test('the script matches the app script', () => {
  assert.deepEqual(CHECK_IN.filter((s) => s.ask).map((s) => s.options.map((o) => o[0])), [['good', 'okay', 'not_good'], ['yes', 'no']]);
});

// ---------------------------------------------------------------- charts, data, art, export
test('charts render SVG and handle empty data', () => {
  const svg = lineChart({ series: [{ points: [{ x: 0, y: 1 }, { x: 1, y: 3 }] }], hLines: [{ y: 2, label: '<b>' }] });
  assert.match(svg, /^<svg/);
  assert.ok(svg.includes('&lt;b&gt;'));
  assert.match(lineChart({ series: [{ points: [] }] }), /No data/);
  assert.match(barChart([{ label: 'a', value: 0 }]), /^<svg/);
  const now = Date.UTC(2026, 10, 25, 12, 30);
  const bars = eventsPerHour([{ created_at: new Date(now - 60e3).toISOString(), type: 'FALL_DETECTED' }], now);
  assert.equal(bars.length, 24);
  assert.equal(bars[23].value, 1);
  assert.equal(bars[23].color, '#f2545b');
});

test('spare parts: same components, a couple differ per OEM', () => {
  const a = sparePartsFor('OEM_A'), c = sparePartsFor('OEM_C');
  assert.equal(a.length, 8);
  assert.equal(a[0].id, 'Spare_Humanoid_OEM_A_Component_A');
  const da = a.map((p) => p.description), dc = c.map((p) => p.description);
  assert.equal(da.filter((d) => !dc.includes(d)).length, 2);
  assert.deepEqual(sparePartsFor('bad'), sparePartsFor('OEM_A'));
  const rows = warehouseRows();
  assert.ok(rows.some((r) => r.id === 'Humanoid_OEM_N_UUID'));
  assert.equal(rows.filter((r) => r.kind === 'Spare part').length, 32);
  assert.equal(EVENT_CODES.length, 22);
  for (const c2 of EVENT_CODES) {
    const t = c2.code < 64 ? 'KEEP_ALIVE' : c2.code < 128 ? 'ENVIRONMENT_VARIABLE_ALARM' : c2.code < 192 ? 'FALL_DETECTED' : 'EMERGENCY';
    assert.equal(c2.type, t, `code ${c2.code}`);
  }
});

test('robot pictures for every OEM and both kinds of locomotion', () => {
  for (const oem of ['OEM_A', 'OEM_B', 'OEM_C', 'OEM_D', 'OEM_Z']) {
    for (const loc of ['legs', 'wheels']) {
      const s = robotSvg({ oem_id: oem, locomotion: loc, integrity_flag: 'red', label: 'Humanoid_OEM_A_UUID' });
      assert.match(s, /^<svg/);
      assert.ok(s.includes('Humanoid OEM A UUID'));
    }
  }
});

test('event export: customers get the payload, logistics does not', () => {
  const ev = [{ created_at: '2026-11-25T10:00:00Z', label: 'Humanoid_OEM_B_UUID', humanoid_id: 'x', code: 200, type: 'EMERGENCY',
    name: 'Patient does not feel well', source: 'app', payload: { answer: 'not_good' } }];
  const user = eventsCsv(ev, { admin: false });
  const admin = eventsCsv(ev, { admin: true });
  assert.ok(user.includes('Answer: Not good'));
  assert.ok(user.includes('Humanoid OEM B UUID'));
  assert.ok(!admin.includes('Payload'));
  assert.ok(!admin.includes('not_good'));
});
