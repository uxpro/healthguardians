/// Backend settings: the Fluffy Bytes PRODUCTION project, the same one the FluffyPaw app uses,
/// so the same accounts and JWTs work here. The publishable key is meant for apps (Row Level
/// Security decides what each account may do); never put a secret / service_role key here.
class AppConfig {
  static const String supabaseUrl = 'https://czrynqwimujjpijosqfg.supabase.co';
  static const String supabasePublishableKey = 'sb_publishable_5N7QYMzEKYInc0TZIWrtEQ_Y1SN4fiJ';

  /// Table written by the event log (db/prod migration 20261125000100 in uxpro/fluffybyteswebsite).
  static const String eventsTable = 'hg_events';
}
