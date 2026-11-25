// Simulations for the demo: Central Clinic events (decoy, browser only), room climate and humanoid reliability.
import { codeInfo, REMINDERS } from './data.js';

/** Small seeded random generator (mulberry32), so the simulated history looks the same on every load. */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function weighted(rand, items) {
  const total = items.reduce((s, [, w]) => s + w, 0);
  let x = rand() * total;
  for (const [v, w] of items) { x -= w; if (x <= 0) return v; }
  return items[items.length - 1][0];
}

const ROOMS = ['1.04', '1.12', '2.03', '2.07', '3.01'];

function codeFor(rand, humanoid) {
  const fault = humanoid.integrity_flag === 'red' ? 4 : humanoid.integrity_flag === 'yellow' ? 1.5 : 0.4;
  return weighted(rand, [
    [0, 30], [7, 14], [8, 8],
    [64, 4], [65, 2], [66, 3], [67, 4], [68, 3],
    [128, 6], [129, 2], [130, 6],
    [192, 1.5], [250, fault],
  ]);
}

function payloadFor(rand, code, humanoid, idx) {
  const room = ROOMS[idx % ROOMS.length];
  switch (code) {
    case 7: {
      const list = (humanoid.features || []).flatMap((f) => REMINDERS[f] || []);
      return { note: list.length ? list[Math.floor(rand() * list.length)].text : 'Reminder delivered', room };
    }
    case 8: return { note: 'Daily self test', battery: `${Math.round(55 + rand() * 45)} %` };
    case 64: return { room, value: `${(26.5 + rand() * 2).toFixed(1)} °C` };
    case 65: return { room, value: `${(16 + rand() * 1.5).toFixed(1)} °C` };
    case 66: return { room, value: `${Math.round(68 + rand() * 12)} % RH` };
    case 67: return { room, value: `${Math.round(1250 + rand() * 600)} ppm CO2` };
    case 68: return { room, note: 'Object on the floor near the bed' };
    case 128: case 129: case 130: return { room, confidence: (0.82 + rand() * 0.17).toFixed(2) };
    case 192: return { room };
    case 250: return { note: 'Battery cell temperature out of range' };
    default: return {};
  }
}

/**
 * Central Clinic decoy: events are generated in the browser only (never stored).
 * history(hours) returns a deterministic past; next() returns one new event "now".
 */
export function createCentralSimulator(humanoids, { seed = 20261125, now = () => Date.now() } = {}) {
  const units = humanoids.filter((h) => h.instance_status === 'deployed');
  const rand = rng(seed);
  let n = 0;

  function make(at) {
    const idx = (n + Math.floor(rand() * 2)) % units.length;     // spread over all humanoids
    const h = units[idx];
    const code = codeFor(rand, h);
    const info = codeInfo(code);
    n += 1;
    return {
      event_id: `s${seed}-${n}`, humanoid_id: h.id, label: h.label, code, type: info.type, name: info.name,
      payload: payloadFor(rand, code, h, idx), source: 'simulated', created_at: new Date(at).toISOString(),
    };
  }

  return {
    get size() { return units.length; },
    history(hours = 24) {
      if (!units.length) return [];
      const end = now();
      const out = [];
      let t = end - hours * 3600e3;
      while (true) {
        t += (12 + rand() * 24) * 60e3;            // one event every 12-36 minutes
        if (t >= end - 60e3) break;
        out.push(make(t));
      }
      return out.reverse();                         // newest first, like the server feed
    },
    next() { return units.length ? make(now()) : null; },
    /** Delay before the next live event (ms). */
    nextDelay() { return 7000 + Math.floor(rand() * 9000); },
  };
}

/** Room climate for one humanoid: hourly points of the last `hours` hours plus the current reading. */
export function environment(index, { hours = 24, now = Date.now() } = {}) {
  const r = rng(1000 + index);
  const off = r() * 6;
  const points = [];
  for (let i = hours; i >= 0; i -= 1) {
    const t = now - i * 3600e3;
    const hourOfDay = new Date(t).getHours() + off;
    const wave = Math.sin((hourOfDay / 24) * Math.PI * 2);
    points.push({
      t,
      temperature: +(22 + 1.6 * wave + (r() - 0.5) * 0.6).toFixed(1),
      humidity: Math.round(47 + 6 * Math.cos((hourOfDay / 24) * Math.PI * 2) + (r() - 0.5) * 4),
      co2: Math.round(620 + 260 * Math.max(0, wave) + r() * 90),
    });
  }
  return { points, current: points[points.length - 1] };
}

/**
 * Simulated reliability R(t) = exp(-(t/eta)^beta) (Weibull). eta is chosen so that R reaches the threshold
 * at operating_hours + time_to_failure, i.e. when the estimated time to failure runs out.
 */
export function reliability(operatingHours, timeToFailureH, { beta = 2.2, threshold = 0.8, steps = 60 } = {}) {
  const op = Math.max(0, Number(operatingHours) || 0);
  const ttf = Math.max(0, Number(timeToFailureH) || 0);
  const failAt = op + ttf;
  const eta = failAt > 0 ? failAt / Math.pow(-Math.log(threshold), 1 / beta) : 1;
  const R = (t) => Math.exp(-Math.pow(Math.max(0, t) / eta, beta));
  const end = Math.max(failAt * 1.35, 100);
  const series = [];
  for (let i = 0; i <= steps; i += 1) {
    const t = (end * i) / steps;
    series.push({ t, r: R(t) });
  }
  return { eta, beta, threshold, failAt, end, current: { t: op, r: R(op) }, series, R };
}
