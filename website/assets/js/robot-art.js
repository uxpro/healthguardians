// Placeholder humanoid pictures (flat SVG), one look per OEM. Real model photos will replace them later.
const INK = '#1d2125';
const LOOK = {
  OEM_A: { body: '#1dbf73', head: 'rect' },
  OEM_B: { body: '#5aa7ea', head: 'screen' },
  OEM_C: { body: '#ffd23f', head: 'dome' },
  OEM_D: { body: '#9b7bf2', head: 'tall' },
};
const LED = { green: '#1dbf73', yellow: '#ffd23f', red: '#f2545b' };

export function robotSvg({ oem_id: oem = 'OEM_A', locomotion = 'legs', integrity_flag: flag = 'green', label = '' } = {}) {
  const look = LOOK[oem] || LOOK.OEM_A;
  const s = `stroke="${INK}" stroke-width="5" stroke-linejoin="round"`;
  let head;
  if (look.head === 'screen') {
    head = `<rect x="62" y="20" width="96" height="74" rx="36" fill="#fbf9f2" ${s}/>
      <rect x="76" y="36" width="68" height="42" rx="18" fill="#0b0d10" ${s}/>
      <circle cx="96" cy="57" r="8" fill="#5aa7ea"/><circle cx="124" cy="57" r="8" fill="#5aa7ea"/>`;
  } else if (look.head === 'dome') {
    head = `<path d="M66 92 Q66 24 110 24 Q154 24 154 92 Z" fill="#fbf9f2" ${s}/>
      <rect x="98" y="10" width="24" height="14" rx="4" fill="${look.body}" ${s}/>
      <rect x="82" y="56" width="56" height="16" rx="8" fill="${INK}"/>`;
  } else if (look.head === 'tall') {
    head = `<rect x="74" y="12" width="72" height="84" rx="10" fill="#fbf9f2" ${s}/>
      <rect x="86" y="42" width="48" height="12" rx="6" fill="${INK}"/><rect x="96" y="68" width="28" height="6" rx="3" fill="${INK}"/>`;
  } else {
    head = `<rect x="64" y="22" width="92" height="72" rx="14" fill="#fbf9f2" ${s}/>
      <circle cx="94" cy="56" r="9" fill="${INK}"/><circle cx="126" cy="56" r="9" fill="${INK}"/>
      <path d="M110 22 V8" ${s}/><circle cx="110" cy="8" r="5" fill="${look.body}" ${s}/>`;
  }
  const base = locomotion === 'wheels'
    ? `<rect x="70" y="214" width="80" height="26" rx="8" fill="#fbf9f2" ${s}/>
       <circle cx="86" cy="248" r="14" fill="${INK}"/><circle cx="134" cy="248" r="14" fill="${INK}"/>`
    : `<rect x="80" y="214" width="22" height="42" rx="6" fill="#fbf9f2" ${s}/><rect x="118" y="214" width="22" height="42" rx="6" fill="#fbf9f2" ${s}/>
       <rect x="72" y="250" width="34" height="12" rx="4" fill="${INK}"/><rect x="114" y="250" width="34" height="12" rx="4" fill="${INK}"/>`;
  return `<svg viewBox="0 0 220 270" width="200" height="245" role="img" aria-label="Picture of ${oem.replace('_', ' ')} humanoid ${label.replace(/_/g, ' ')}">
    ${base}
    <rect x="70" y="100" width="80" height="118" rx="14" fill="${look.body}" ${s}/>
    <path d="M70 118 L38 176" ${s} stroke-linecap="round"/><path d="M150 118 L182 176" ${s} stroke-linecap="round"/>
    <circle cx="38" cy="180" r="9" fill="#fbf9f2" ${s}/><circle cx="182" cy="180" r="9" fill="#fbf9f2" ${s}/>
    <rect x="86" y="124" width="48" height="30" rx="6" fill="#fbf9f2" ${s}/>
    <circle cx="110" cy="139" r="7" fill="${LED[flag] || LED.green}" stroke="${INK}" stroke-width="3"/>
    ${head}
  </svg>`;
}
