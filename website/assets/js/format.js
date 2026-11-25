// Text helpers: user-friendly names for identifiers, dates, numbers, HTML escaping and CSV export.

// Words that stay in capitals when an identifier is made readable.
const KEEP_UPPER = new Set(['OEM', 'UUID', 'ID', 'HG', 'CO2', 'LED', 'CSV', 'URL']);

/**
 * Readable text for an identifier: underscores become spaces.
 *   Humanoid_OEM_A_UUID -> "Humanoid OEM A UUID"
 *   FALL_DETECTED -> "Fall detected", in_stock -> "In stock", OEM_A_VARIANT_B -> "OEM A variant B"
 */
export function humanize(id) {
  if (id === null || id === undefined) return '';
  const words = String(id).split(/[_\s]+/).filter(Boolean);
  return words.map((w, i) => {
    const up = w.toUpperCase();
    if (KEEP_UPPER.has(up) || w.length === 1 || /^\d+$/.test(w)) return up;
    if (w !== up && w !== w.toLowerCase()) return w;            // mixed case (Humanoid, Component): keep
    const lower = w.toLowerCase();
    return i === 0 ? lower[0].toUpperCase() + lower.slice(1) : lower;
  }).join(' ');
}

export function escapeHtml(v) {
  return String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

const pad = (n) => String(n).padStart(2, '0');

export function fmtDate(v) {
  if (!v) return '-';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '-';
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function fmtTime(v) {
  if (!v) return '-';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '-';
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export function fmtDateTime(v) {
  return v ? `${fmtDate(v)} ${fmtTime(v)}` : '-';
}

export function fmtHours(h) {
  const n = Number(h);
  if (!Number.isFinite(n)) return '-';
  if (n >= 48) return `${Math.round(n).toLocaleString('en-US')} h (about ${Math.round(n / 24)} days)`;
  return `${n % 1 === 0 ? n : n.toFixed(1)} h`;
}

export function isToday(v, now = new Date()) {
  const d = new Date(v);
  return d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
}

/** Colour class of an event type chip. */
export function typeClass(type) {
  return { KEEP_ALIVE: 'green', ENVIRONMENT_VARIABLE_ALARM: 'yellow', FALL_DETECTED: 'red', EMERGENCY: 'red' }[type] || 'grey';
}

export function flagText(flag) {
  return { green: 'Normal', yellow: 'Action is needed', red: 'Critical' }[flag] || 'Unknown';
}

/** Short text for an event payload (customers only; the logistics feed has none). */
export function payloadText(p) {
  if (!p || typeof p !== 'object') return '';
  const parts = [];
  if (p.question) parts.push(`${p.question}`);
  if (p.answer) parts.push(`Answer: ${humanize(p.answer)}`);
  if (p.step && !p.question) parts.push(`Step: ${humanize(p.step)}`);
  for (const [k, v] of Object.entries(p)) {
    if (['question', 'answer', 'step', 'mode', 'session'].includes(k)) continue;
    parts.push(`${humanize(k)}: ${typeof v === 'object' ? JSON.stringify(v) : v}`);
  }
  return parts.join(' · ');
}

/** CSV with a BOM (opens in Excel); cells that could run as a formula are prefixed with an apostrophe. */
export function toCsv(rows, columns) {
  const cell = (v) => {
    let s = v === null || v === undefined ? '' : String(v);
    if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
    return /[",;\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const lines = [columns.map((c) => cell(c.title)).join(',')];
  for (const r of rows) lines.push(columns.map((c) => cell(typeof c.value === 'function' ? c.value(r) : r[c.value])).join(','));
  return '﻿' + lines.join('\r\n') + '\r\n';
}
