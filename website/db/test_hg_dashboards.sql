-- Tests for hg_dashboards.sql. Runs on a local copy of the production schema (see website/db/README.md).
-- Accounts: Central Clinic user, North Clinic user, HG admin, an outsider and a banned member.
insert into auth.users (id, email, raw_user_meta_data) values
  ('a0000000-0000-0000-0000-0000000000c1', 'cc@hg.com',      '{}'),
  ('a0000000-0000-0000-0000-0000000000c2', 'nc@hg.com',      '{}'),
  ('a0000000-0000-0000-0000-0000000000a1', 'admin@hg.com',   '{}'),
  ('a0000000-0000-0000-0000-0000000000f1', 'stranger@example.org', '{}'),
  ('a0000000-0000-0000-0000-0000000000b1', 'banned@hg.com',  '{}');

select test.assert((select public.hg_link_demo_accounts()) = '{"cc@hg.com": true, "nc@hg.com": true, "admin@hg.com": true}'::jsonb,
                   'demo accounts linked');
insert into public.hg_members (user_id, hg_role, customer_id) values ('a0000000-0000-0000-0000-0000000000b1', 'user', 'north-clinic');
update public.profiles set status = 'banned' where id = 'a0000000-0000-0000-0000-0000000000b1';
select test.assert((select linked_user_id from public.hg_humanoids where label = 'Humanoid_OEM_B_UUID')
                   = 'a0000000-0000-0000-0000-0000000000c2', 'Humanoid OEM B linked to nc@hg.com');
select test.assert((select count(*) from public.hg_humanoids) = 12, '12 humanoids');
select test.assert((select count(*) from public.hg_humanoids where customer_id = 'central-clinic') = 4, 'Central Clinic has 4');
select test.assert((select count(*) from public.hg_humanoids where customer_id = 'north-clinic') = 3, 'North Clinic has 3');
select test.assert((select count(*) from public.hg_humanoids where demo_patient_uuid is not null) = 7, 'every deployed humanoid has its own patient');

-- -------------------------------------------------------------- constraints
select test.expect_error($$insert into public.hg_event_codes values (10, 'EMERGENCY', 'wrong range')$$, 'check constraint');
select test.expect_error($$insert into public.hg_event_codes values (256, 'EMERGENCY', 'too big')$$, 'check constraint');
select test.expect_error($$insert into public.hg_members (user_id, hg_role) values ('a0000000-0000-0000-0000-0000000000f1', 'user')$$, 'check constraint');
select test.expect_error($$insert into public.hg_members (user_id, hg_role, customer_id) values ('a0000000-0000-0000-0000-0000000000f1', 'owner', 'north-clinic')$$, 'check constraint');
select test.expect_error($$update public.hg_humanoids set customer_id = null where label = 'Humanoid_OEM_B_UUID'$$, 'check constraint');
select test.expect_error($$update public.hg_humanoids set label = 'robot; drop table x' where label = 'Humanoid_OEM_B_UUID'$$, 'check constraint');

-- -------------------------------------------------------------- anonymous: nothing
select test.login(null);
set role anon;
select test.expect_error($$select public.hg_whoami()$$, 'permission denied');
select test.expect_error($$select public.hg_fleet()$$, 'permission denied');
select test.expect_error($$select * from public.hg_feed()$$, 'permission denied');
select test.expect_error($$select * from public.hg_humanoids$$, 'permission denied');
select test.expect_error($$select public.hg_link_demo_accounts()$$, 'permission denied');
reset role;

-- -------------------------------------------------------------- outsider (signed in, no membership)
select test.login('a0000000-0000-0000-0000-0000000000f1');
set role authenticated;
select test.assert(public.hg_whoami() is null, 'outsider: whoami is null');
select test.expect_error($$select public.hg_fleet()$$, 'hg_access_denied');
select test.expect_error($$select * from public.hg_feed()$$, 'hg_access_denied');
select test.expect_error($$select public.hg_audit()$$, 'hg_access_denied');
select test.expect_error($$select public.hg_log_action('view', '{}')$$, 'hg_access_denied');
select test.expect_error($$select * from public.hg_members$$, 'permission denied');
select test.expect_error($$select * from public.hg_robot_events$$, 'permission denied');
select test.expect_error($$select * from public.hg_audit_log$$, 'permission denied');
select test.expect_error($$insert into public.hg_robot_events (humanoid_id, code) values ('b2d4f6a8-0c1e-4f3a-9b5d-7e9f1a3c5e55', 0)$$, 'permission denied');
select test.expect_error($$select public.hg_link_demo_accounts()$$, 'permission denied');
reset role;

-- -------------------------------------------------------------- banned member: nothing
select test.login('a0000000-0000-0000-0000-0000000000b1');
set role authenticated;
select test.assert(public.hg_whoami() is null, 'banned: whoami is null');
select test.expect_error($$select public.hg_fleet()$$, 'hg_access_denied');
reset role;

-- -------------------------------------------------------------- North Clinic user (live)
select test.login('a0000000-0000-0000-0000-0000000000c2');
set role authenticated;
select test.assert(public.hg_whoami() ->> 'role' = 'user', 'nc: role user');
select test.assert(public.hg_whoami() -> 'customer' ->> 'name' = 'North Clinic', 'nc: customer North Clinic');
select test.assert(public.hg_whoami() -> 'customer' ->> 'use_case' = 'conversation_support', 'nc: conversation support');
select test.assert(jsonb_array_length(public.hg_fleet()) = 3, 'nc sees its 3 humanoids');
select test.assert((select bool_and(x ->> 'customer_id' = 'north-clinic') from jsonb_array_elements(public.hg_fleet()) x), 'nc sees only North Clinic');
select test.assert((select count(*) from jsonb_array_elements(public.hg_fleet()) x where x ? 'demo_patient_uuid') = 3, 'nc sees the linked patients');
select test.assert((select count(*) from jsonb_array_elements(public.hg_fleet()) x where (x ->> 'live')::boolean) = 1, 'one live humanoid');
select test.assert(not exists (select 1 from jsonb_array_elements(public.hg_fleet()) x where x ? 'history'), 'nc does not get the service history');
select test.assert((select count(*) from public.hg_feed(now() - interval '2 days')) = 7, 'nc: 7 seeded events in 2 days');

-- the phone app (or the web face) logs a check-in as nc -> shown as Humanoid OEM B events
insert into public.hg_events (session_id, event_type, mode) values ('bbbbbbbb-0000-0000-0000-000000000001', 'session_started', 'idle');
insert into public.hg_events (session_id, event_type, mode, question, answer)
  values ('bbbbbbbb-0000-0000-0000-000000000001', 'mood_answer', 'listening', 'How are you today?', 'not_good');
insert into public.hg_events (session_id, event_type, mode, question, answer)
  values ('bbbbbbbb-0000-0000-0000-000000000001', 'medication_answer', 'listening', 'Did you take your daily medication?', 'no_answer');
select test.assert((select count(*) from public.hg_feed(now() - interval '1 minute')) = 3, 'app events appear in the feed');
select test.assert((select string_agg(code::text || ':' || type, ',' order by code) from public.hg_feed(now() - interval '1 minute'))
                   = '1:KEEP_ALIVE,200:EMERGENCY,201:EMERGENCY', 'app answers mapped to codes');
select test.assert((select bool_and(label = 'Humanoid_OEM_B_UUID' and source = 'app') from public.hg_feed(now() - interval '1 minute')),
                   'app events belong to Humanoid OEM B');
select test.assert((select payload ->> 'answer' from public.hg_feed(now() - interval '1 minute') where code = 200) = 'not_good',
                   'customer sees the payload');
select test.assert((select (x ->> 'events_today')::int from jsonb_array_elements(public.hg_fleet()) x where x ->> 'label' = 'Humanoid_OEM_B_UUID') >= 3,
                   'events today counted');

-- demo injection on its own humanoid
select test.assert(public.hg_inject_event('b2d4f6a8-0c1e-4f3a-9b5d-7e9f1a3c5e55', 128, 'Bathroom') ? 'event_id', 'nc injects a fall');
select test.assert((select type from public.hg_feed(now() - interval '1 minute') where code = 128) = 'FALL_DETECTED', 'injected fall in feed');
select test.assert((select payload ->> 'note' from public.hg_feed(now() - interval '1 minute') where code = 128) = 'Bathroom', 'note kept');
select test.expect_error($$select public.hg_inject_event('3f6c2a1e-8b4d-4c2a-9e51-7a0d2c4b6e11', 128)$$, 'hg_unknown_humanoid');  -- Central Clinic
select test.expect_error($$select public.hg_inject_event('e8b0c2d4-6a7f-4c8d-8e9f-1b3d5f7a9c88', 128)$$, 'hg_unknown_humanoid');  -- warehouse
select test.expect_error($$select public.hg_inject_event('b2d4f6a8-0c1e-4f3a-9b5d-7e9f1a3c5e55', 99)$$, 'hg_unknown_code');
select test.expect_error($$select public.hg_inject_event('b2d4f6a8-0c1e-4f3a-9b5d-7e9f1a3c5e55', 128, repeat('x', 141))$$, 'hg_note_too_long');
select test.assert((select count(*) from public.hg_feed(null, 'c4f6a8b0-2e3d-4a5b-8c7d-9f1b3d5f7a66')) = 2, 'feed filtered by humanoid');
select test.assert(jsonb_array_length(public.hg_event_catalogue()) = 22, 'event catalogue');

-- account details
select test.assert(public.hg_update_account('  Nurse station 2 ', '+371 2000 0000') ->> 'display_name' = 'Nurse station 2', 'account updated');
select test.expect_error($$select public.hg_update_account('x', 'call me; maybe')$$, 'check constraint');
select test.expect_error($$select public.hg_update_account(repeat('x', 81), '')$$, 'check constraint');
select test.expect_error($$select public.hg_audit()$$, 'hg_access_denied');
select public.hg_log_action('open_view', '{"view":"overview"}');
select test.expect_error($$select public.hg_log_action('Drop Table', '{}')$$, 'check constraint');
select test.expect_error($$select public.hg_log_action('x', '[]')$$, 'check constraint');
reset role;

-- -------------------------------------------------------------- Central Clinic user
select test.login('a0000000-0000-0000-0000-0000000000c1');
set role authenticated;
select test.assert(public.hg_whoami() -> 'customer' ->> 'use_case' = 'fall_detection', 'cc: fall detection');
select test.assert((public.hg_whoami() -> 'customer' ->> 'simulated')::boolean, 'cc: simulated decoy');
select test.assert(jsonb_array_length(public.hg_fleet()) = 4, 'cc sees its 4 humanoids');
select test.assert((select count(*) from jsonb_array_elements(public.hg_fleet()) x where x ->> 'model_id' = 'OEM_A_VARIANT_A') = 2, 'cc: two of the same model');
select test.assert((select count(*) from public.hg_feed(now() - interval '30 days')) = 0, 'cc does not see North Clinic events');
select test.expect_error($$select public.hg_inject_event('b2d4f6a8-0c1e-4f3a-9b5d-7e9f1a3c5e55', 128)$$, 'hg_unknown_humanoid');
reset role;

-- -------------------------------------------------------------- admin (logistics)
select test.login('a0000000-0000-0000-0000-0000000000a1');
set role authenticated;
select test.assert(public.hg_whoami() ->> 'role' = 'admin', 'admin role');
select test.assert(public.hg_whoami() -> 'customer' = 'null'::jsonb, 'admin has no customer');
select test.assert(jsonb_array_length(public.hg_fleet()) = 12, 'admin sees the whole fleet');
select test.assert(not exists (select 1 from jsonb_array_elements(public.hg_fleet()) x where x ? 'demo_patient_uuid'), 'admin never sees patients');
select test.assert((select (x ->> 'in_stock_same_model')::int from jsonb_array_elements(public.hg_fleet()) x where x ->> 'label' = 'Humanoid_OEM_B_UUID') = 1,
                   'in stock count of the same model');
select test.assert((select jsonb_array_length(x -> 'history') from jsonb_array_elements(public.hg_fleet()) x where x ->> 'label' = 'Humanoid_OEM_A_UUID_2') = 3,
                   'service history for admin');
select test.assert((select count(*) from public.hg_feed(now() - interval '1 minute')) = 4, 'admin sees every event');
select test.assert((select bool_and(payload = '{}'::jsonb) from public.hg_feed(now() - interval '2 days')), 'admin never sees payloads');
select test.assert((select count(*) from jsonb_array_elements(public.hg_audit()) x where x ->> 'action' in ('inject_event', 'update_account', 'open_view')) = 3,
                   'admin reads the audit log');
select test.assert((select x ->> 'email' from jsonb_array_elements(public.hg_audit()) x where x ->> 'action' = 'inject_event') = 'nc@hg.com',
                   'audit log names the account');
select test.assert(public.hg_inject_event('3f6c2a1e-8b4d-4c2a-9e51-7a0d2c4b6e11', 0) ? 'event_id', 'admin may inject anywhere');
reset role;

-- -------------------------------------------------------------- rate limits
select test.login('a0000000-0000-0000-0000-0000000000c2');
set role authenticated;
do $$ begin
  for i in 1..19 loop perform public.hg_inject_event('c4f6a8b0-2e3d-4a5b-8c7d-9f1b3d5f7a66', 0); end loop;
end $$;
select test.expect_error($$select public.hg_inject_event('c4f6a8b0-2e3d-4a5b-8c7d-9f1b3d5f7a66', 0)$$, 'hg_rate_limited');
reset role;

-- -------------------------------------------------------------- deleting accounts
delete from auth.users where email = 'nc@hg.com';
select test.assert(not exists (select 1 from public.hg_members where hg_role = 'user' and customer_id = 'north-clinic'
                                and user_id = 'a0000000-0000-0000-0000-0000000000c2'), 'membership removed with the account');
select test.assert((select linked_user_id from public.hg_humanoids where label = 'Humanoid_OEM_B_UUID') is null, 'link cleared');
select test.assert(exists (select 1 from public.hg_audit_log where email = 'nc@hg.com' and user_id is null), 'audit lines kept');
