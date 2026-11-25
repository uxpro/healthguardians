// localStorage that never throws (private mode, blocked storage): falls back to memory.
const memory = new Map();

function ls() {
  try {
    const s = globalThis.localStorage;
    if (!s) return null;
    const k = '__hg_probe__';
    s.setItem(k, '1');
    s.removeItem(k);
    return s;
  } catch {
    return null;
  }
}

export const storage = {
  get(key) {
    const s = ls();
    try { return s ? s.getItem(key) : (memory.has(key) ? memory.get(key) : null); } catch { return memory.get(key) ?? null; }
  },
  set(key, value) {
    const s = ls();
    try { if (s) s.setItem(key, value); else memory.set(key, value); } catch { memory.set(key, value); }
  },
  remove(key) {
    const s = ls();
    try { if (s) s.removeItem(key); } catch { /* ignore */ }
    memory.delete(key);
  },
};
