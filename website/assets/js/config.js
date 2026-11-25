// Backend settings: the same production Supabase project the HealthGuardians app uses.
// The publishable key is meant for browsers and apps; Row Level Security and the hg_* functions decide what each
// signed-in account may see. Never put a secret or service_role key here.
export const CONFIG = Object.freeze({
  supabaseUrl: 'https://czrynqwimujjpijosqfg.supabase.co',
  supabaseKey: 'sb_publishable_5N7QYMzEKYInc0TZIWrtEQ_Y1SN4fiJ',
  pollMs: 3000,          // event feed polling interval
  fleetRefreshMs: 30000, // fleet counters refresh
});
