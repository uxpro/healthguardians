// Small SVG charts in the dashboard style: thick ink lines, mint areas, no library needed.
import { escapeHtml } from './format.js';

const INK = '#1d2125';

function niceTicks(min, max, count = 5) {
  if (!(max > min)) return [min];
  const span = max - min;
  const step0 = span / count;
  const mag = Math.pow(10, Math.floor(Math.log10(step0)));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => span / s <= count) || mag * 10;
  const out = [];
  for (let v = Math.ceil(min / step) * step; v <= max + 1e-9; v += step) out.push(+v.toFixed(10));
  return out;
}

/**
 * Line chart. series: [{ name, color, fill, points: [{x, y}] }]; x and y are numbers.
 * Options: xFormat, yFormat, yMin, yMax, hLines [{y, label, color}], vLines [{x, label}], marks [{x, y, label}].
 */
export function lineChart({ series, width = 640, height = 240, xFormat = String, yFormat = String,
  yMin, yMax, hLines = [], vLines = [], marks = [], title = '' }) {
  const pad = { l: 46, r: 16, t: 14, b: 30 };
  const all = series.flatMap((s) => s.points);
  if (!all.length) return `<div class="empty">No data yet</div>`;
  const xs = all.map((p) => p.x);
  const ys = all.map((p) => p.y).concat(hLines.map((h) => h.y));
  const x0 = Math.min(...xs), x1 = Math.max(...xs);
  const y0 = yMin ?? Math.min(...ys), y1 = yMax ?? Math.max(...ys);
  const yLo = y0 === y1 ? y0 - 1 : y0, yHi = y0 === y1 ? y1 + 1 : y1;
  const W = width - pad.l - pad.r, H = height - pad.t - pad.b;
  const sx = (x) => pad.l + (x1 === x0 ? W / 2 : ((x - x0) / (x1 - x0)) * W);
  const sy = (y) => pad.t + H - ((y - yLo) / (yHi - yLo)) * H;
  const parts = [];
  for (const t of niceTicks(yLo, yHi, 4)) {
    parts.push(`<line x1="${pad.l}" x2="${width - pad.r}" y1="${sy(t)}" y2="${sy(t)}" stroke="${INK}" stroke-opacity=".15" stroke-width="1.5"/>`,
      `<text x="${pad.l - 6}" y="${sy(t) + 4}" text-anchor="end">${escapeHtml(yFormat(t))}</text>`);
  }
  const xt = niceTicks(x0, x1, 5);
  for (const t of xt) parts.push(`<text x="${sx(t)}" y="${height - 8}" text-anchor="middle">${escapeHtml(xFormat(t))}</text>`);
  for (const s of series) {
    const pts = [...s.points].sort((a, b) => a.x - b.x);
    const d = pts.map((p, i) => `${i ? 'L' : 'M'}${sx(p.x).toFixed(1)},${sy(p.y).toFixed(1)}`).join(' ');
    if (s.fill) parts.push(`<path d="${d} L${sx(pts[pts.length - 1].x)},${sy(yLo)} L${sx(pts[0].x)},${sy(yLo)} Z" fill="${s.fill}" fill-opacity=".75"/>`);
    parts.push(`<path d="${d}" fill="none" stroke="${s.color || INK}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>`);
  }
  for (const h of hLines) {
    parts.push(`<line x1="${pad.l}" x2="${width - pad.r}" y1="${sy(h.y)}" y2="${sy(h.y)}" stroke="${h.color || '#f2545b'}" stroke-width="3" stroke-dasharray="8 6"/>`,
      `<text x="${width - pad.r - 4}" y="${sy(h.y) - 6}" text-anchor="end" font-weight="700">${escapeHtml(h.label || '')}</text>`);
  }
  for (const v of vLines) {
    parts.push(`<line x1="${sx(v.x)}" x2="${sx(v.x)}" y1="${pad.t}" y2="${pad.t + H}" stroke="${v.color || INK}" stroke-width="2.5" stroke-dasharray="4 4"/>`,
      `<text x="${sx(v.x) + 5}" y="${pad.t + 12}" font-weight="700">${escapeHtml(v.label || '')}</text>`);
  }
  for (const m of marks) {
    parts.push(`<circle cx="${sx(m.x)}" cy="${sy(m.y)}" r="7" fill="${m.color || '#ffd23f'}" stroke="${INK}" stroke-width="3"/>`,
      `<text x="${sx(m.x) + 10}" y="${sy(m.y) + 18}" font-weight="700">${escapeHtml(m.label || '')}</text>`);
  }
  parts.push(`<line x1="${pad.l}" x2="${pad.l}" y1="${pad.t}" y2="${pad.t + H}" stroke="${INK}" stroke-width="3"/>`,
    `<line x1="${pad.l}" x2="${width - pad.r}" y1="${pad.t + H}" y2="${pad.t + H}" stroke="${INK}" stroke-width="3"/>`);
  return `<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="${escapeHtml(title)}"><g class="axis">${parts.join('')}</g></svg>`;
}

/** Bars: [{ label, value, color }]. */
export function barChart(bars, { width = 640, height = 200, title = '' } = {}) {
  if (!bars.length) return `<div class="empty">No data yet</div>`;
  const pad = { l: 34, r: 8, t: 10, b: 26 };
  const W = width - pad.l - pad.r, H = height - pad.t - pad.b;
  const max = Math.max(1, ...bars.map((b) => b.value));
  const bw = W / bars.length;
  const parts = [];
  for (const t of niceTicks(0, max, 3)) {
    const y = pad.t + H - (t / max) * H;
    parts.push(`<line x1="${pad.l}" x2="${width - pad.r}" y1="${y}" y2="${y}" stroke="${INK}" stroke-opacity=".15"/>`,
      `<text x="${pad.l - 5}" y="${y + 4}" text-anchor="end">${t}</text>`);
  }
  bars.forEach((b, i) => {
    const h = (b.value / max) * H;
    const x = pad.l + i * bw + bw * 0.15;
    if (b.value > 0) parts.push(`<rect x="${x}" y="${pad.t + H - h}" width="${bw * 0.7}" height="${h}" fill="${b.color || '#1dbf73'}" stroke="${INK}" stroke-width="2"/>`);
    if (b.label) parts.push(`<text x="${x + bw * 0.35}" y="${height - 8}" text-anchor="middle">${escapeHtml(b.label)}</text>`);
  });
  parts.push(`<line x1="${pad.l}" x2="${width - pad.r}" y1="${pad.t + H}" y2="${pad.t + H}" stroke="${INK}" stroke-width="3"/>`);
  return `<svg viewBox="0 0 ${width} ${height}" role="img" aria-label="${escapeHtml(title)}"><g class="axis">${parts.join('')}</g></svg>`;
}

/** Events per hour for the last 24 hours, stacked by severity (alerts red, keep alive green). */
export function eventsPerHour(events, now = Date.now()) {
  const bars = [];
  const startHour = Math.floor(now / 3600e3) - 23;
  for (let i = 0; i < 24; i += 1) {
    const h = startHour + i;
    const inHour = events.filter((e) => Math.floor(new Date(e.created_at).getTime() / 3600e3) === h);
    const alerts = inHour.filter((e) => e.type !== 'KEEP_ALIVE').length;
    const label = i % 4 === 3 ? `${String(new Date(h * 3600e3).getHours()).padStart(2, '0')}h` : '';
    bars.push({ label, value: inHour.length, color: alerts ? '#f2545b' : '#1dbf73' });
  }
  return bars;
}
