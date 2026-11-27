-- HealthGuardians: complete setup for the production project, in one paste.
-- Creates the app's event log (hg_events) and then the dashboards. Safe to run again.
-- Create cc@hg.com, nc@hg.com and admin@hg.com first (Authentication -> Users), or run
-- select public.hg_link_demo_accounts(); afterwards.

-- ===== Part 1: event log the app writes =====

create table if not exists public.hg_events (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  session_id  uuid not null,
  event_type  text not null check (event_type in
                ('session_started', 'mood_answer', 'medication_answer', 'exercise_demo', 'session_completed')),
  mode        text check (mode in ('idle', 'speaking', 'listening', 'action')),
  question    text check (char_length(question) <= 200),
  answer      text check (char_length(answer) <= 100),
  details     jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object' and pg_column_size(details) <= 4096),
  client_time timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists hg_events_user_time on public.hg_events (user_id, created_at desc);
create index if not exists hg_events_session on public.hg_events (session_id);

alter table public.hg_events enable row level security;
revoke all on public.hg_events from anon, authenticated;
grant select, insert on public.hg_events to authenticated;

drop policy if exists hg_events_insert_own on public.hg_events;
create policy hg_events_insert_own on public.hg_events for insert to authenticated
  with check (user_id = auth.uid() and public.current_app_role() is not null);   -- banned accounts: no role

drop policy if exists hg_events_read_own on public.hg_events;
create policy hg_events_read_own on public.hg_events for select to authenticated
  using ((user_id = auth.uid() and public.current_app_role() is not null) or public.is_admin());

-- ===== Part 2: dashboards =====
-- Health Guardian dashboards: fleet, events, audit log and demo data.
-- Paste into the SQL editor of the PRODUCTION project (the one the HealthGuardians app uses) and run.
-- One transaction: if anything fails, nothing changes. Safe to run again (it updates the demo data).
--
-- Access model
--   * Health Guardian access comes only from public.hg_members (role 'user' = customer, 'admin' = HG staff).
--     It does not change any existing role in public.profiles.
--   * Every hg_* table has Row Level Security on and no direct grants: the website reads and writes only
--     through the hg_* functions below, which check the caller's JWT (auth.uid()).
--   * Accounts without an active profile (banned) get nothing, as everywhere else in the project.
--   * The phone app keeps writing public.hg_events as before. Events of the account linked to a humanoid
--     (nc@hg.com -> Humanoid_OEM_B_UUID) are shown as that humanoid's events.
begin;

-- ------------------------------------------------------------------------------------------------ tables
create table if not exists public.hg_customers (
  id          text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  name        text not null check (char_length(name) <= 80),
  unique_id   text not null unique check (unique_id ~ '^[A-Z0-9_]{2,40}$'),
  use_case    text not null check (use_case in ('fall_detection', 'conversation_support')),
  simulated   boolean not null default false          -- true: events are simulated in the browser only
);

create table if not exists public.hg_members (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  hg_role      text not null check (hg_role in ('user', 'admin')),
  customer_id  text references public.hg_customers (id),
  display_name text check (char_length(display_name) <= 80),
  phone        text check (phone ~ '^[0-9 +()/-]{0,25}$'),
  created_at   timestamptz not null default now(),
  constraint hg_members_customer check ((hg_role = 'user') = (customer_id is not null))
);

create table if not exists public.hg_oems (
  id      text primary key check (id ~ '^OEM_[A-Z]$'),
  name    text not null,
  country text not null
);

create table if not exists public.hg_models (
  id          text primary key check (id ~ '^OEM_[A-Z]_VARIANT_[A-Z]$'),
  oem_id      text not null references public.hg_oems (id),
  name        text not null,
  locomotion  text not null check (locomotion in ('legs', 'wheels')),
  features    text[] not null check (features <@ array['FALL_DETECTION', 'CONVERSATIONAL', 'SENTIMENT_ANALYSIS', 'REMINDERS']
                                     and cardinality(features) between 1 and 4)
);

create table if not exists public.hg_humanoids (
  id                 uuid primary key,
  label              text not null unique check (label ~ '^Humanoid_OEM_[A-Z]_UUID(_[0-9]{1,3})?$'),
  model_id           text not null references public.hg_models (id),
  customer_id        text references public.hg_customers (id),
  instance_status    text not null check (instance_status in ('deployed', 'in_stock', 'maintenance', 'in_transit')),
  time_to_failure_h  integer not null check (time_to_failure_h between 0 and 100000),
  integrity_flag     text not null check (integrity_flag in ('green', 'yellow', 'red')),
  battery_autonomy_h numeric(4, 1) not null check (battery_autonomy_h between 0 and 99),
  operating_hours    integer not null check (operating_hours >= 0),
  system_test        text not null check (system_test in ('passed', 'passed_with_warnings', 'failed')),
  system_test_on     date not null,
  next_maintenance   date,
  demo_patient_uuid  uuid unique,
  linked_user_id     uuid references auth.users (id) on delete set null,
  constraint hg_humanoids_deployed check ((instance_status = 'deployed') = (customer_id is not null)),
  constraint hg_humanoids_patient  check (demo_patient_uuid is null or instance_status = 'deployed')
);

create table if not exists public.hg_event_codes (
  code  smallint primary key check (code between 0 and 255),
  type  text not null check (type in ('KEEP_ALIVE', 'ENVIRONMENT_VARIABLE_ALARM', 'FALL_DETECTED', 'EMERGENCY')),
  name  text not null,
  -- the code range decides the type: 0-63 keep alive, 64-127 environment, 128-191 fall, 192-255 emergency
  constraint hg_event_codes_range check (
       (type = 'KEEP_ALIVE'                 and code between   0 and  63)
    or (type = 'ENVIRONMENT_VARIABLE_ALARM' and code between  64 and 127)
    or (type = 'FALL_DETECTED'              and code between 128 and 191)
    or (type = 'EMERGENCY'                  and code between 192 and 255))
);

create table if not exists public.hg_robot_events (
  id          bigint generated always as identity primary key,
  humanoid_id uuid not null references public.hg_humanoids (id) on delete cascade,
  code        smallint not null references public.hg_event_codes (code),
  payload     jsonb not null default '{}'::jsonb
                check (jsonb_typeof(payload) = 'object' and pg_column_size(payload) <= 2048),
  source      text not null default 'robot' check (source in ('robot', 'demo')),
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists hg_robot_events_time on public.hg_robot_events (created_at desc);
create index if not exists hg_robot_events_humanoid on public.hg_robot_events (humanoid_id, created_at desc);

create table if not exists public.hg_maintenance_history (
  id          bigint generated always as identity primary key,
  humanoid_id uuid not null references public.hg_humanoids (id) on delete cascade,
  done_on     date not null,
  action      text not null,
  parts       text not null default ''
);

create table if not exists public.hg_audit_log (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users (id) on delete set null,
  email      text,
  hg_role    text,
  action     text not null check (action ~ '^[a-z_]{2,40}$'),
  details    jsonb not null default '{}'::jsonb
               check (jsonb_typeof(details) = 'object' and pg_column_size(details) <= 2048),
  created_at timestamptz not null default now()
);
create index if not exists hg_audit_log_time on public.hg_audit_log (created_at desc);

-- No direct access: everything goes through the functions below.
do $$
declare t text;
begin
  foreach t in array array['hg_customers', 'hg_members', 'hg_oems', 'hg_models', 'hg_humanoids', 'hg_event_codes',
                           'hg_robot_events', 'hg_maintenance_history', 'hg_audit_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ------------------------------------------------------------------------------------------------ helpers
-- The caller's membership (null when not a member, or when the account is banned).
create or replace function public.hg_me()
returns public.hg_members
language sql stable security definer set search_path = ''
as $$
  select m.* from public.hg_members m
  where m.user_id = auth.uid() and public.current_app_role() is not null
$$;

-- Event code of one step of the phone app's check-in (public.hg_events).
create or replace function public.hg_app_event_code(p_event_type text, p_answer text)
returns smallint
language sql immutable set search_path = ''
as $$
  select (case
    when p_event_type = 'session_started'   then 1
    when p_event_type = 'mood_answer'       and p_answer = 'good'     then 2
    when p_event_type = 'mood_answer'       and p_answer = 'okay'     then 3
    when p_event_type = 'medication_answer' and p_answer = 'yes'      then 4
    when p_event_type = 'exercise_demo'     then 5
    when p_event_type = 'session_completed' then 6
    when p_event_type = 'mood_answer'       and p_answer = 'not_good' then 200
    when p_event_type = 'medication_answer' and p_answer = 'no'       then 202
    when p_event_type in ('mood_answer', 'medication_answer')         then 201   -- no_answer or unknown
    else 0 end)::smallint
$$;

-- Every event: the humanoids' own events plus the check-in steps of the linked app accounts.
create or replace function public.hg_all_events(p_since timestamptz)
returns table (event_id text, humanoid_id uuid, code smallint, payload jsonb, source text, created_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select 'r' || e.id, e.humanoid_id, e.code, e.payload, e.source, e.created_at
  from public.hg_robot_events e
  where e.created_at > p_since
  union all
  select 'a' || a.id, h.id, public.hg_app_event_code(a.event_type, a.answer),
         jsonb_strip_nulls(jsonb_build_object('step', a.event_type, 'question', a.question, 'answer', a.answer,
                                              'mode', a.mode, 'session', a.session_id)),
         'app', a.created_at
  from public.hg_events a
  join public.hg_humanoids h on h.linked_user_id = a.user_id
  where a.created_at > p_since
$$;

-- ------------------------------------------------------------------------------------------------ API
-- Who is signed in: role, customer and account details. Null for accounts without Health Guardian access.
create or replace function public.hg_whoami()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'email', u.email, 'role', m.hg_role, 'display_name', m.display_name, 'phone', m.phone,
    'member_since', m.created_at,
    'customer', case when c.id is null then null else
      jsonb_build_object('id', c.id, 'name', c.name, 'unique_id', c.unique_id, 'use_case', c.use_case,
                         'simulated', c.simulated) end)
  from public.hg_me() m
  join auth.users u on u.id = m.user_id
  left join public.hg_customers c on c.id = m.customer_id
  where m.user_id is not null
$$;

-- Humanoids the caller may see. Customers: their own, with the linked demo patient.
-- Admins (logistics): every humanoid, without patients or use cases.
create or replace function public.hg_fleet()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  me public.hg_members := public.hg_me();
  v_admin boolean := me.hg_role = 'admin';
  v_result jsonb;
begin
  if me.user_id is null then
    raise exception 'hg_access_denied' using errcode = '42501';
  end if;
  with ev as (
    select e.humanoid_id,
           count(*) filter (where c.type <> 'KEEP_ALIVE') as incidents,
           count(*) filter (where e.created_at >= date_trunc('day', now())) as today,
           max(e.created_at) as last_event
    from public.hg_all_events(now() - interval '30 days') e
    join public.hg_event_codes c on c.code = e.code
    group by e.humanoid_id
  ), stock as (
    select model_id, count(*) as n from public.hg_humanoids where instance_status = 'in_stock' group by model_id
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', h.id, 'label', h.label, 'oem_id', mo.oem_id, 'oem_name', o.name, 'model_id', mo.id, 'model_name', mo.name,
      'locomotion', mo.locomotion, 'features', to_jsonb(mo.features),
      'instance_status', h.instance_status, 'time_to_failure_h', h.time_to_failure_h,
      'integrity_flag', h.integrity_flag, 'battery_autonomy_h', h.battery_autonomy_h,
      'operating_hours', h.operating_hours, 'system_test', h.system_test, 'system_test_on', h.system_test_on,
      'next_maintenance', h.next_maintenance,
      'incidents_30d', coalesce(ev.incidents, 0), 'events_today', coalesce(ev.today, 0), 'last_event', ev.last_event,
      'customer_id', h.customer_id, 'customer_name', cu.name,
      'live', h.linked_user_id is not null,
      'demo_patient_uuid', case when v_admin then null else h.demo_patient_uuid end,
      'in_stock_same_model', case when v_admin then coalesce(st.n, 0) end,
      'history', case when v_admin then (
         select coalesce(jsonb_agg(jsonb_build_object('done_on', mh.done_on, 'action', mh.action, 'parts', mh.parts)
                                   order by mh.done_on desc), '[]'::jsonb)
         from public.hg_maintenance_history mh where mh.humanoid_id = h.id) end
    )) order by h.label), '[]'::jsonb)
  into v_result
  from public.hg_humanoids h
  join public.hg_models mo on mo.id = h.model_id
  join public.hg_oems o on o.id = mo.oem_id
  left join public.hg_customers cu on cu.id = h.customer_id
  left join ev on ev.humanoid_id = h.id
  left join stock st on st.model_id = h.model_id
  where v_admin or h.customer_id = me.customer_id;
  return v_result;
end $$;

-- Events newer than p_since (default: last 24 hours), newest first. Polled by the dashboards.
-- Customers get their humanoids' events with the payload; admins get every event without the payload
-- (the logistics dashboard tracks availability, not what happens with the patient).
create or replace function public.hg_feed(p_since timestamptz default null, p_humanoid uuid default null,
                                          p_limit integer default 200)
returns table (event_id text, humanoid_id uuid, label text, code smallint, type text, name text,
               payload jsonb, source text, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare
  me public.hg_members := public.hg_me();
begin
  if me.user_id is null then
    raise exception 'hg_access_denied' using errcode = '42501';
  end if;
  return query
    select e.event_id, e.humanoid_id, h.label, e.code, c.type, c.name,
           case when me.hg_role = 'admin' then '{}'::jsonb else e.payload end,
           e.source, e.created_at
    from public.hg_all_events(greatest(coalesce(p_since, now() - interval '24 hours'), now() - interval '30 days')) e
    join public.hg_humanoids h on h.id = e.humanoid_id
    join public.hg_event_codes c on c.code = e.code
    where (me.hg_role = 'admin' or h.customer_id = me.customer_id)
      and (p_humanoid is null or e.humanoid_id = p_humanoid)
    order by e.created_at desc, e.event_id desc
    limit least(greatest(coalesce(p_limit, 200), 1), 500);
end $$;

-- Event code list (for the demo injection buttons and the legend).
create or replace function public.hg_event_catalogue()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (public.hg_me()).user_id is null then
    raise exception 'hg_access_denied' using errcode = '42501';
  end if;
  return (select jsonb_agg(jsonb_build_object('code', code, 'type', type, 'name', name) order by code)
          from public.hg_event_codes);
end $$;

-- Writes one line in the audit log (every dashboard action). Members only.
create or replace function public.hg_log_action(p_action text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
declare
  me public.hg_members := public.hg_me();
begin
  if me.user_id is null then
    raise exception 'hg_access_denied' using errcode = '42501';
  end if;
  if (select count(*) from public.hg_audit_log
      where user_id = me.user_id and created_at > now() - interval '1 minute') >= 60 then
    raise exception 'hg_rate_limited' using errcode = '54000';
  end if;
  insert into public.hg_audit_log (user_id, email, hg_role, action, details)
  values (me.user_id, (select email from auth.users where id = me.user_id), me.hg_role, p_action,
          coalesce(p_details, '{}'::jsonb));
end $$;

-- Demo data injection: records one event for a humanoid the caller may see.
create or replace function public.hg_inject_event(p_humanoid uuid, p_code integer, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  me public.hg_members := public.hg_me();
  v_id bigint;
begin
  if me.user_id is null then
    raise exception 'hg_access_denied' using errcode = '42501';
  end if;
  if not exists (select 1 from public.hg_humanoids h
                 where h.id = p_humanoid and h.instance_status = 'deployed'
                   and (me.hg_role = 'admin' or h.customer_id = me.customer_id)) then
    raise exception 'hg_unknown_humanoid' using errcode = '42501';
  end if;
  if not exists (select 1 from public.hg_event_codes where code = p_code) then
    raise exception 'hg_unknown_code' using errcode = '22023';
  end if;
  if char_length(p_note) > 140 then
    raise exception 'hg_note_too_long' using errcode = '22001';
  end if;
  if (select count(*) from public.hg_robot_events
      where created_by = me.user_id and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'hg_rate_limited' using errcode = '54000';
  end if;
  insert into public.hg_robot_events (humanoid_id, code, payload, source, created_by)
  values (p_humanoid, p_code, jsonb_strip_nulls(jsonb_build_object('note', nullif(btrim(p_note), ''))), 'demo', me.user_id)
  returning id into v_id;
  perform public.hg_log_action('inject_event', jsonb_build_object('humanoid', p_humanoid, 'code', p_code));
  return jsonb_build_object('event_id', 'r' || v_id);
end $$;

-- Account details: the only form with a real effect.
create or replace function public.hg_update_account(p_display_name text, p_phone text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  me public.hg_members := public.hg_me();
begin
  if me.user_id is null then
    raise exception 'hg_access_denied' using errcode = '42501';
  end if;
  update public.hg_members
  set display_name = nullif(btrim(p_display_name), ''), phone = nullif(btrim(p_phone), '')
  where user_id = me.user_id;
  perform public.hg_log_action('update_account', '{}'::jsonb);
  return public.hg_whoami();
end $$;

-- Audit log (admins only), newest first.
create or replace function public.hg_audit(p_limit integer default 200)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if (public.hg_me()).hg_role is distinct from 'admin' then
    raise exception 'hg_access_denied' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'email', email, 'role', hg_role, 'action', action,
                                                       'details', details, 'created_at', created_at)
                                    order by created_at desc, id desc), '[]'::jsonb)
          from (select * from public.hg_audit_log
                order by created_at desc, id desc
                limit least(greatest(coalesce(p_limit, 200), 1), 1000)) a);
end $$;

-- Links the three demo accounts once they exist (Authentication -> Users). Run again after creating them.
create or replace function public.hg_link_demo_accounts()
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_cc uuid := (select id from auth.users where lower(email) = 'cc@hg.com');
  v_nc uuid := (select id from auth.users where lower(email) = 'nc@hg.com');
  v_ad uuid := (select id from auth.users where lower(email) = 'admin@hg.com');
begin
  if v_cc is not null then
    insert into public.hg_members (user_id, hg_role, customer_id, display_name)
    values (v_cc, 'user', 'central-clinic', 'Central Clinic operations')
    on conflict (user_id) do update set hg_role = 'user', customer_id = 'central-clinic';
  end if;
  if v_nc is not null then
    insert into public.hg_members (user_id, hg_role, customer_id, display_name)
    values (v_nc, 'user', 'north-clinic', 'North Clinic operations')
    on conflict (user_id) do update set hg_role = 'user', customer_id = 'north-clinic';
  end if;
  if v_ad is not null then
    insert into public.hg_members (user_id, hg_role, customer_id, display_name)
    values (v_ad, 'admin', null, 'HG logistics')
    on conflict (user_id) do update set hg_role = 'admin', customer_id = null;
  end if;
  update public.hg_humanoids set linked_user_id = v_nc where label = 'Humanoid_OEM_B_UUID';
  return jsonb_build_object('cc@hg.com', v_cc is not null, 'nc@hg.com', v_nc is not null,
                            'admin@hg.com', v_ad is not null);
end $$;

-- Functions: only the API is callable, and only with a signed-in account.
revoke all on function public.hg_me(), public.hg_app_event_code(text, text), public.hg_all_events(timestamptz),
  public.hg_whoami(), public.hg_fleet(), public.hg_feed(timestamptz, uuid, integer), public.hg_event_catalogue(),
  public.hg_log_action(text, jsonb), public.hg_inject_event(uuid, integer, text),
  public.hg_update_account(text, text), public.hg_audit(integer), public.hg_link_demo_accounts()
  from public, anon, authenticated;
grant execute on function public.hg_whoami(), public.hg_fleet(), public.hg_feed(timestamptz, uuid, integer),
  public.hg_event_catalogue(), public.hg_log_action(text, jsonb), public.hg_inject_event(uuid, integer, text),
  public.hg_update_account(text, text), public.hg_audit(integer)
  to authenticated;

-- ------------------------------------------------------------------------------------------------ demo data
insert into public.hg_customers (id, name, unique_id, use_case, simulated) values
  ('central-clinic', 'Central Clinic', 'CUSTOMER_UNIQUE_ID_X', 'fall_detection',       true),
  ('north-clinic',   'North Clinic',   'CUSTOMER_UNIQUE_ID_Y', 'conversation_support', false)
on conflict (id) do update set name = excluded.name, unique_id = excluded.unique_id,
  use_case = excluded.use_case, simulated = excluded.simulated;

insert into public.hg_oems (id, name, country) values
  ('OEM_A', 'OEM A', 'Germany'), ('OEM_B', 'OEM B', 'Japan'), ('OEM_C', 'OEM C', 'South Korea'), ('OEM_D', 'OEM D', 'Estonia')
on conflict (id) do update set name = excluded.name, country = excluded.country;

insert into public.hg_models (id, oem_id, name, locomotion, features) values
  ('OEM_A_VARIANT_A', 'OEM_A', 'OEM A Variant A', 'legs',   array['FALL_DETECTION', 'CONVERSATIONAL', 'SENTIMENT_ANALYSIS', 'REMINDERS']),
  ('OEM_A_VARIANT_B', 'OEM_A', 'OEM A Variant B', 'wheels', array['FALL_DETECTION', 'REMINDERS']),
  ('OEM_B_VARIANT_A', 'OEM_B', 'OEM B Variant A', 'legs',   array['FALL_DETECTION', 'CONVERSATIONAL', 'SENTIMENT_ANALYSIS', 'REMINDERS']),
  ('OEM_C_VARIANT_A', 'OEM_C', 'OEM C Variant A', 'wheels', array['FALL_DETECTION', 'SENTIMENT_ANALYSIS', 'REMINDERS']),
  ('OEM_D_VARIANT_A', 'OEM_D', 'OEM D Variant A', 'legs',   array['FALL_DETECTION', 'CONVERSATIONAL', 'REMINDERS'])
on conflict (id) do update set oem_id = excluded.oem_id, name = excluded.name, locomotion = excluded.locomotion,
  features = excluded.features;

insert into public.hg_event_codes (code, type, name) values
  (  0, 'KEEP_ALIVE', 'Heartbeat'),
  (  1, 'KEEP_ALIVE', 'Conversation started'),
  (  2, 'KEEP_ALIVE', 'Patient feels good'),
  (  3, 'KEEP_ALIVE', 'Patient feels okay'),
  (  4, 'KEEP_ALIVE', 'Medication taken'),
  (  5, 'KEEP_ALIVE', 'Exercise shown'),
  (  6, 'KEEP_ALIVE', 'Conversation completed'),
  (  7, 'KEEP_ALIVE', 'Reminder delivered'),
  (  8, 'KEEP_ALIVE', 'Self test passed'),
  ( 64, 'ENVIRONMENT_VARIABLE_ALARM', 'Room temperature too high'),
  ( 65, 'ENVIRONMENT_VARIABLE_ALARM', 'Room temperature too low'),
  ( 66, 'ENVIRONMENT_VARIABLE_ALARM', 'Humidity too high'),
  ( 67, 'ENVIRONMENT_VARIABLE_ALARM', 'Air quality poor (CO2)'),
  ( 68, 'ENVIRONMENT_VARIABLE_ALARM', 'Floor obstacle detected'),
  (128, 'FALL_DETECTED', 'Fall detected'),
  (129, 'FALL_DETECTED', 'Fall detected, no movement after 60 s'),
  (130, 'FALL_DETECTED', 'Stumble detected (near fall)'),
  (192, 'EMERGENCY', 'Emergency button pressed'),
  (200, 'EMERGENCY', 'Patient does not feel well'),
  (201, 'EMERGENCY', 'Patient did not answer'),
  (202, 'EMERGENCY', 'Medication not taken'),
  (250, 'EMERGENCY', 'Humanoid critical fault')
on conflict (code) do update set type = excluded.type, name = excluded.name;

insert into public.hg_humanoids (id, label, model_id, customer_id, instance_status, time_to_failure_h, integrity_flag,
                                 battery_autonomy_h, operating_hours, system_test, system_test_on, next_maintenance,
                                 demo_patient_uuid) values
  -- Central Clinic: two of the same model, two other models (events simulated in the browser)
  ('3f6c2a1e-8b4d-4c2a-9e51-7a0d2c4b6e11', 'Humanoid_OEM_A_UUID',   'OEM_A_VARIANT_A', 'central-clinic', 'deployed', 2140, 'green',  9.5, 1820, 'passed',               current_date - 3,  current_date + 41, '8e2b7c90-1d4f-4a6b-b3c5-0f9e8d7c6a51'),
  ('5a9d4e2b-1c7f-4d3e-8a62-9b1e0f3c5d22', 'Humanoid_OEM_A_UUID_2', 'OEM_A_VARIANT_A', 'central-clinic', 'deployed',  640, 'yellow', 7.0, 4310, 'passed_with_warnings', current_date - 1,  current_date + 6,  '2c4e6a8b-0d1f-4e3a-9b5c-7d9e1f3a5b62'),
  ('7c1e5f3a-2d8b-4e4f-9b73-0c2f1a4d6e33', 'Humanoid_OEM_C_UUID',   'OEM_C_VARIANT_A', 'central-clinic', 'deployed', 3380, 'green', 11.0,  960, 'passed',               current_date - 6,  current_date + 70, '4e6a8c0d-2f1b-4a5c-8d7e-9f1a3b5c7d73'),
  ('9e3a7b5c-4f0d-4a6b-8c84-1d3a2b5e7f44', 'Humanoid_OEM_D_UUID',   'OEM_D_VARIANT_A', 'central-clinic', 'deployed',   72, 'red',    3.5, 6020, 'failed',               current_date,      current_date + 1,  '6a8c0e2f-4b3d-4c7e-9f1a-1b3c5d7e9f84'),
  -- North Clinic: three OEM B humanoids; Humanoid_OEM_B_UUID is live (linked to nc@hg.com)
  ('b2d4f6a8-0c1e-4f3a-9b5d-7e9f1a3c5e55', 'Humanoid_OEM_B_UUID',   'OEM_B_VARIANT_A', 'north-clinic',   'deployed', 2870, 'green', 10.5, 1240, 'passed',               current_date - 2,  current_date + 55, 'd1e3f5a7-9b2c-4d6e-8f0a-2c4e6a8b0d95'),
  ('c4f6a8b0-2e3d-4a5b-8c7d-9f1b3d5f7a66', 'Humanoid_OEM_B_UUID_2', 'OEM_B_VARIANT_A', 'north-clinic',   'deployed', 1960, 'green',  9.0, 2150, 'passed',               current_date - 4,  current_date + 33, 'e3f5a7b9-1d4e-4f8a-9b2c-4e6a8c0e2f06'),
  ('d6a8b0c2-4f5e-4b6c-9d8e-0a2c4e6a8b77', 'Humanoid_OEM_B_UUID_3', 'OEM_B_VARIANT_A', 'north-clinic',   'deployed',  410, 'yellow', 6.5, 5480, 'passed_with_warnings', current_date - 1,  current_date + 4,  'f5a7b9c1-3e6f-4a0b-8c4d-6e8a0c2e4f17'),
  -- HG warehouse and service
  ('e8b0c2d4-6a7f-4c8d-8e9f-1b3d5f7a9c88', 'Humanoid_OEM_A_UUID_3', 'OEM_A_VARIANT_A', null, 'in_stock',    4200, 'green', 10.0,    0, 'passed',               current_date - 12, null,              null),
  ('f0c2d4e6-8b9a-4d0e-9f1a-2c4e6a8c0d99', 'Humanoid_OEM_A_UUID_4', 'OEM_A_VARIANT_B', null, 'maintenance',  180, 'red',    4.0, 7120, 'failed',               current_date - 2,  current_date + 2,  null),
  ('0a2c4e6f-9d1b-4e2f-8a3b-4d6f8a0c2eaa', 'Humanoid_OEM_B_UUID_4', 'OEM_B_VARIANT_A', null, 'in_stock',    4380, 'green', 11.0,   35, 'passed',               current_date - 9,  null,              null),
  ('1b3d5f7a-0e2c-4f3a-9b4c-5e7a9b1d3fbb', 'Humanoid_OEM_C_UUID_2', 'OEM_C_VARIANT_A', null, 'in_stock',    3900, 'green', 11.5,   12, 'passed',               current_date - 20, null,              null),
  ('2c4e6a8b-1f3d-4a4b-8c5d-6f8b0c2e4acc', 'Humanoid_OEM_D_UUID_2', 'OEM_D_VARIANT_A', null, 'in_transit',  3650, 'green',  9.0,  210, 'passed',               current_date - 5,  null,              null)
on conflict (id) do update set label = excluded.label, model_id = excluded.model_id, customer_id = excluded.customer_id,
  instance_status = excluded.instance_status, time_to_failure_h = excluded.time_to_failure_h,
  integrity_flag = excluded.integrity_flag, battery_autonomy_h = excluded.battery_autonomy_h,
  operating_hours = excluded.operating_hours, system_test = excluded.system_test,
  system_test_on = excluded.system_test_on, next_maintenance = excluded.next_maintenance,
  demo_patient_uuid = excluded.demo_patient_uuid;

delete from public.hg_maintenance_history;
insert into public.hg_maintenance_history (humanoid_id, done_on, action, parts)
select h.id, current_date - d.days_ago, d.action, d.parts
from (values
  ('Humanoid_OEM_A_UUID',   210, 'Commissioning and safety check',  ''),
  ('Humanoid_OEM_A_UUID',    95, 'Scheduled service',               'Battery pack'),
  ('Humanoid_OEM_A_UUID_2', 330, 'Commissioning and safety check',  ''),
  ('Humanoid_OEM_A_UUID_2',  60, 'Knee joint noise',                'Leg drive motor (left)'),
  ('Humanoid_OEM_A_UUID_2',  12, 'Scheduled service',               'Hand gripper'),
  ('Humanoid_OEM_C_UUID',    80, 'Commissioning and safety check',  ''),
  ('Humanoid_OEM_D_UUID',   400, 'Commissioning and safety check',  ''),
  ('Humanoid_OEM_D_UUID',   150, 'Wheel base vibration',            'Drive wheel set'),
  ('Humanoid_OEM_D_UUID',     1, 'System test failed: battery cell', ''),
  ('Humanoid_OEM_B_UUID',   120, 'Commissioning and safety check',  ''),
  ('Humanoid_OEM_B_UUID',    30, 'Firmware update 4.2',             ''),
  ('Humanoid_OEM_B_UUID_2', 180, 'Commissioning and safety check',  ''),
  ('Humanoid_OEM_B_UUID_3', 365, 'Commissioning and safety check',  ''),
  ('Humanoid_OEM_B_UUID_3',  45, 'Microphone dropouts',             'Microphone array'),
  ('Humanoid_OEM_A_UUID_4',   3, 'Returned for repair',             'Battery pack, Depth camera'),
  ('Humanoid_OEM_D_UUID_2',   5, 'Factory acceptance test',         '')
) as d(label, days_ago, action, parts)
join public.hg_humanoids h on h.label = d.label;

-- A little history for the live North Clinic humanoids (only when there is none yet).
insert into public.hg_robot_events (humanoid_id, code, payload, source, created_at)
select h.id, d.code, d.payload::jsonb, 'robot', now() - d.ago
from (values
  ('Humanoid_OEM_B_UUID',   8,  '{"note":"Daily self test"}',          interval '20 hours'),
  ('Humanoid_OEM_B_UUID',   7,  '{"note":"Hydration reminder"}',       interval '6 hours'),
  ('Humanoid_OEM_B_UUID',   0,  '{}',                                  interval '3 hours'),
  ('Humanoid_OEM_B_UUID_2', 8,  '{"note":"Daily self test"}',          interval '19 hours'),
  ('Humanoid_OEM_B_UUID_2', 64, '{"value":"27.4 °C"}',                 interval '5 hours'),
  ('Humanoid_OEM_B_UUID_3', 0,  '{}',                                  interval '2 hours'),
  ('Humanoid_OEM_B_UUID_3', 130,'{"note":"Patient steadied himself"}', interval '26 hours')
) as d(label, code, payload, ago)
join public.hg_humanoids h on h.label = d.label
where not exists (select 1 from public.hg_robot_events);

select public.hg_link_demo_accounts();
commit;
