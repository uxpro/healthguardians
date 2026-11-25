// Static demo data shown in the dashboards (mock-ups, not stored in the database).

export const FEATURES = ['FALL_DETECTION', 'CONVERSATIONAL', 'SENTIMENT_ANALYSIS', 'REMINDERS'];

// Event codes (same list as public.hg_event_codes; used for the simulated Central Clinic events).
export const EVENT_CODES = [
  [0, 'KEEP_ALIVE', 'Heartbeat'], [1, 'KEEP_ALIVE', 'Conversation started'], [2, 'KEEP_ALIVE', 'Patient feels good'],
  [3, 'KEEP_ALIVE', 'Patient feels okay'], [4, 'KEEP_ALIVE', 'Medication taken'], [5, 'KEEP_ALIVE', 'Exercise shown'],
  [6, 'KEEP_ALIVE', 'Conversation completed'], [7, 'KEEP_ALIVE', 'Reminder delivered'], [8, 'KEEP_ALIVE', 'Self test passed'],
  [64, 'ENVIRONMENT_VARIABLE_ALARM', 'Room temperature too high'], [65, 'ENVIRONMENT_VARIABLE_ALARM', 'Room temperature too low'],
  [66, 'ENVIRONMENT_VARIABLE_ALARM', 'Humidity too high'], [67, 'ENVIRONMENT_VARIABLE_ALARM', 'Air quality poor (CO2)'],
  [68, 'ENVIRONMENT_VARIABLE_ALARM', 'Floor obstacle detected'],
  [128, 'FALL_DETECTED', 'Fall detected'], [129, 'FALL_DETECTED', 'Fall detected, no movement after 60 s'],
  [130, 'FALL_DETECTED', 'Stumble detected (near fall)'],
  [192, 'EMERGENCY', 'Emergency button pressed'], [200, 'EMERGENCY', 'Patient does not feel well'],
  [201, 'EMERGENCY', 'Patient did not answer'], [202, 'EMERGENCY', 'Medication not taken'], [250, 'EMERGENCY', 'Humanoid critical fault'],
].map(([code, type, name]) => ({ code, type, name }));

export const codeInfo = (code) => EVENT_CODES.find((c) => c.code === code) || { code, type: 'KEEP_ALIVE', name: `Code ${code}` };

// Demo injection buttons (North Clinic, real database events).
export const INJECT_BUTTONS = [
  { code: 128, label: 'Fall detected' },
  { code: 130, label: 'Stumble (near fall)' },
  { code: 64, label: 'Temperature alarm' },
  { code: 67, label: 'Air quality alarm' },
  { code: 192, label: 'Emergency button' },
  { code: 0, label: 'Keep alive' },
];

// Friendly reminders the humanoid gives, by feature.
export const REMINDERS = {
  REMINDERS: [
    { at: '08:30', text: 'Good morning! Time for a glass of water.' },
    { at: '12:00', text: 'Lunch is served in the dining room.' },
    { at: '15:00', text: 'Afternoon tea and a short walk in the corridor.' },
  ],
  FALL_DETECTION: [{ at: '22:00', text: 'Night watch on: I am here if you need to get up.' }],
  CONVERSATIONAL: [{ at: '10:00', text: 'Shall we have our daily chat?' }],
  SENTIMENT_ANALYSIS: [{ at: '18:00', text: 'How was your day? I can call a nurse to talk.' }],
};

// Technicians for the (mock) maintenance request.
export const TECHNICIANS = [
  'Anna Berzina (OEM A, OEM B)', 'Marek Novak (OEM B, OEM D)', 'Liis Tamm (OEM C)', 'Jonas Weber (all OEMs)',
];

// Spare parts per OEM: mostly the same components, a couple differ (mock-up).
const COMMON = [
  ['Component_A', 'Battery pack 48 V'], ['Component_B', 'Depth camera'], ['Component_C', 'Microphone array'],
  ['Component_D', 'Speaker module'], ['Component_E', 'Fall sensor (IMU)'], ['Component_F', 'Charging dock'],
];
const EXTRA = {
  OEM_A: [['Component_G', 'Leg drive motor'], ['Component_H', 'Hand gripper']],
  OEM_B: [['Component_G', 'Leg drive motor'], ['Component_H', 'Face display panel']],
  OEM_C: [['Component_G', 'Drive wheel set'], ['Component_H', 'Lidar module']],
  OEM_D: [['Component_G', 'Leg drive motor'], ['Component_H', 'Head tilt actuator']],
};

function stockFor(oem, comp) {
  // deterministic "random" stock between 0 and 14
  let h = 0;
  for (const ch of oem + comp) h = (h * 31 + ch.charCodeAt(0)) % 9973;
  return h % 15;
}

export function sparePartsFor(oemId) {
  const oem = String(oemId || '').match(/^OEM_[A-Z]$/) ? oemId : 'OEM_A';
  return [...COMMON, ...(EXTRA[oem] || [])].map(([comp, description]) => {
    const id = `Spare_Humanoid_${oem}_${comp}`;
    const inStock = stockFor(oem, comp);
    return { id, oem, description, inStock, reorder: inStock < 3 };
  });
}

// HG warehouse availability (mock-up table).
export const WAREHOUSE_UNITS = [
  { id: 'Humanoid_OEM_A_UUID_3', model: 'OEM_A_VARIANT_A', status: 'in_stock', location: 'Riga warehouse, bay 2' },
  { id: 'Humanoid_OEM_A_UUID_4', model: 'OEM_A_VARIANT_B', status: 'maintenance', location: 'Service lab' },
  { id: 'Humanoid_OEM_B_UUID_4', model: 'OEM_B_VARIANT_A', status: 'in_stock', location: 'Riga warehouse, bay 1' },
  { id: 'Humanoid_OEM_C_UUID_2', model: 'OEM_C_VARIANT_A', status: 'in_stock', location: 'Riga warehouse, bay 3' },
  { id: 'Humanoid_OEM_D_UUID_2', model: 'OEM_D_VARIANT_A', status: 'in_transit', location: 'Truck to warehouse (ETA 2 days)' },
  { id: 'Humanoid_OEM_N_UUID', model: 'OEM_N (next partner)', status: 'ordered', location: 'Supplier' },
];

export function warehouseRows() {
  const rows = WAREHOUSE_UNITS.map((u) => ({ kind: 'Humanoid', id: u.id, detail: u.model, qty: 1, status: u.status, location: u.location }));
  for (const oem of ['OEM_A', 'OEM_B', 'OEM_C', 'OEM_D']) {
    for (const p of sparePartsFor(oem)) {
      rows.push({ kind: 'Spare part', id: p.id, detail: p.description, qty: p.inStock, status: p.reorder ? 'reorder' : 'in_stock', location: 'Riga warehouse, parts shelf' });
    }
  }
  return rows;
}

// The check-in the robotic face runs (same steps and event names as the HealthGuardians phone app).
export const CHECK_IN = [
  { say: 'How are you today?' },
  { ask: 'mood_answer', question: 'How are you today?', options: [['good', 'Good'], ['okay', 'Okay'], ['not_good', 'Not so good']] },
  { say: 'Did you take your daily medication?' },
  { ask: 'medication_answer', question: 'Did you take your daily medication?', options: [['yes', 'Yes'], ['no', 'No']] },
  { say: 'Let me show you these exercises' },
  { action: 'exercise_demo', caption: 'Exercise demo: slowly raise both arms, then lower them', ms: 10000 },
  { say: 'Great you did it!' },
  { finish: true },
];
