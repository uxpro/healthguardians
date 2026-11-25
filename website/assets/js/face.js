// Robotic virtual face (web version of the HealthGuardians app face) and the check-in conversation it runs.
// Modes: idle (grey), speaking (blue), listening (purple), action (yellow). Eyes are honeycombs of hexagons whose
// size follows a wave: inward when speaking, outward when listening, sweeping when idle, organic in action mode.
import { CHECK_IN } from './data.js';

export const MODES = {
  idle: { color: [154, 160, 166], label: 'Idling' },
  speaking: { color: [47, 140, 255], label: 'Speaking' },
  listening: { color: [155, 92, 255], label: 'Listening' },
  action: { color: [255, 201, 60], label: 'Action' },
};

function hexCells(rings) {
  const cells = [];
  for (let q = -rings; q <= rings; q += 1) {
    for (let r = Math.max(-rings, -q - rings); r <= Math.min(rings, -q + rings); r += 1) {
      cells.push({ x: Math.sqrt(3) * (q + r / 2), y: 1.5 * r, d: Math.max(Math.abs(q), Math.abs(r), Math.abs(-q - r)), ph: Math.random() * 6.28 });
    }
  }
  return cells;
}

export function createFace(canvas, { reducedMotion = false } = {}) {
  const ctx = canvas.getContext('2d');
  const cells = hexCells(4);
  let mode = 'idle';
  let modeSince = performance.now();
  let level = 0;            // loudness 0..1 (simulated while speaking)
  let raf = 0;
  let alive = true;

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = canvas.clientWidth || 600, h = canvas.clientHeight || 280;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function hex(x, y, size, rgb, alpha) {
    ctx.beginPath();
    for (let i = 0; i < 6; i += 1) {
      const a = (Math.PI / 3) * i + Math.PI / 6;
      const px = x + size * Math.cos(a), py = y + size * Math.sin(a);
      if (i) ctx.lineTo(px, py); else ctx.moveTo(px, py);
    }
    ctx.closePath();
    const g = ctx.createRadialGradient(x, y, 0, x, y, size);
    g.addColorStop(0, `rgba(${rgb.join(',')},${alpha})`);
    g.addColorStop(1, `rgba(${rgb.join(',')},${alpha * 0.25})`);
    ctx.fillStyle = g;
    ctx.fill();
  }

  function frame(now) {
    if (!alive) return;
    const w = canvas.clientWidth || 600, h = canvas.clientHeight || 280;
    const t = reducedMotion ? 0 : (now - modeSince) / 1000;
    const rgb = MODES[mode].color;
    if (mode === 'speaking') level = 0.55 + 0.45 * Math.abs(Math.sin(t * 7.3) * Math.sin(t * 2.1));
    else if (mode === 'listening') level = 0.35 + 0.15 * Math.sin(t * 3);
    else level = 0.18 + 0.06 * Math.sin(t * 1.2);

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = '#0b0d10';
    ctx.fillRect(0, 0, w, h);

    // eyes move together when speaking (collide in the middle), apart when listening
    const cell = Math.min(w, h) / 30;
    const gap = w * 0.18;
    let offset = 0;
    if (mode === 'speaking') offset = -gap * Math.max(0, Math.sin(Math.min(t, 6.28) * 1.6)) * 0.85;
    if (mode === 'listening') offset = gap * 0.35 * Math.max(0, Math.sin(Math.min(t, 3.14) * 1.2));
    const cy = h * 0.46;
    const eyes = [w / 2 - gap - offset, w / 2 + gap + offset];

    // aura
    for (const ex of eyes) {
      const g = ctx.createRadialGradient(ex, cy, 0, ex, cy, cell * 11);
      g.addColorStop(0, `rgba(${rgb.join(',')},${0.28 * level + 0.08})`);
      g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g;
      ctx.fillRect(ex - cell * 11, cy - cell * 11, cell * 22, cell * 22);
    }
    // honeycomb eyes
    for (const [i, ex] of eyes.entries()) {
      for (const c of cells) {
        let wave;
        if (mode === 'speaking') wave = Math.sin(c.d * 1.2 + t * 6);          // inward
        else if (mode === 'listening') wave = Math.sin(c.d * 1.2 - t * 6);     // outward
        else if (mode === 'action') wave = Math.sin(t * 1.4 + c.ph);           // organic
        else wave = Math.sin((c.x + (i ? 8 : 0)) * 0.6 - t * 1.1);             // sweep left to right
        const size = cell * (0.55 + 0.35 * (0.5 + 0.5 * wave) * (0.6 + level));
        hex(ex + c.x * cell, cy + c.y * cell, size, rgb, 0.55 + 0.45 * level);
      }
    }
    // energy beam (mouth)
    const bw = w * 0.22 * (0.5 + level);
    ctx.fillStyle = `rgba(${rgb.join(',')},${0.35 + 0.5 * level})`;
    ctx.fillRect(w / 2 - bw / 2, h * 0.8, bw, 4);
    raf = requestAnimationFrame(frame);
  }

  resize();
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(resize) : null;
  ro?.observe(canvas);
  raf = requestAnimationFrame(frame);

  return {
    get mode() { return mode; },
    setMode(m) { if (MODES[m] && m !== mode) { mode = m; modeSince = performance.now(); } },
    destroy() { alive = false; cancelAnimationFrame(raf); ro?.disconnect(); },
  };
}

/**
 * Runs the check-in script. log(eventType, mode, extra) writes one public.hg_events row (as the app does).
 * onState({ mode, caption, options, running }) updates the UI. Answer with answer(value).
 */
export function createCheckIn({ log, onState, speak = null, wait = (ms) => new Promise((r) => setTimeout(r, ms)),
  answerTimeoutMs = 20000, script = CHECK_IN, sayMs = (text) => Math.max(2200, text.split(' ').length * 420) }) {
  let running = false;
  let token = 0;
  let resolveAnswer = null;

  const state = (s) => onState({ running, options: null, caption: '', ...s });

  async function say(text, my) {
    state({ mode: 'speaking', caption: text });
    if (speak) {
      try { await Promise.race([speak(text), wait(sayMs(text) + 4000)]); } catch { await wait(sayMs(text)); }
    } else {
      await wait(sayMs(text));
    }
    return my === token;
  }

  async function run() {
    if (running) return;
    running = true;
    const my = ++token;
    const sessionId = (globalThis.crypto?.randomUUID?.() ?? fallbackUuid());
    const ok = () => my === token;
    try {
      await log('session_started', 'idle', { session_id: sessionId });
      for (const step of script) {
        if (!ok()) return;
        if (step.say) {
          if (!(await say(step.say, my))) return;
        } else if (step.ask) {
          state({ mode: 'listening', caption: step.question, options: step.options });
          const answer = await Promise.race([
            new Promise((r) => { resolveAnswer = r; }),
            wait(answerTimeoutMs).then(() => 'no_answer'),
          ]);
          resolveAnswer = null;
          if (!ok()) return;
          await log(step.ask, 'listening', { session_id: sessionId, question: step.question, answer });
        } else if (step.action) {
          state({ mode: 'action', caption: step.caption });
          await wait(step.ms);
          if (!ok()) return;
          await log(step.action, 'action', { session_id: sessionId, details: { duration_ms: step.ms, completed: true } });
        } else if (step.finish) {
          await log('session_completed', 'idle', { session_id: sessionId, details: { steps: script.length } });
        }
      }
    } finally {
      if (my === token) {
        running = false;
        state({ mode: 'idle', caption: 'Tap "Start check-in" to talk to the patient.' });
      }
    }
  }

  return {
    get running() { return running; },
    start: run,
    answer(value) { if (resolveAnswer) resolveAnswer(value); },
    stop() {
      token += 1;
      running = false;
      if (resolveAnswer) resolveAnswer('no_answer');
      state({ mode: 'idle', caption: 'Check-in stopped.' });
    },
  };
}

function fallbackUuid() {
  const b = new Uint8Array(16);
  for (let i = 0; i < 16; i += 1) b[i] = Math.floor(Math.random() * 256);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** Browser speech, if available and switched on. */
export function browserSpeak(text) {
  return new Promise((resolve) => {
    const synth = globalThis.speechSynthesis;
    if (!synth) { resolve(); return; }
    const u = new SpeechSynthesisUtterance(text);
    u.rate = 0.95; u.pitch = 0.8;
    u.onend = resolve; u.onerror = resolve;
    synth.cancel();
    synth.speak(u);
  });
}
