// RobotHack jury access. The sign-in page reveals this read-only password until the end of 7 December 2026
// (Riga time); at the same moment the database switches the jury account off (hg_members.access_until),
// so the published password stops working.
export const JURY = {
  email: 'jury@hg.com',
  password: 'Ro6o.hack2026',
  until: '2026-12-08T00:00:00+02:00',
  untilText: '7 December 2026',
};

export function juryOpen(now = new Date()) {
  return now.getTime() < new Date(JURY.until).getTime();
}
