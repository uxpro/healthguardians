-- Optional check, run any time after hg_dashboards.sql: is everything in place, and are the app's events arriving?
select to_regclass('public.hg_events')    as events_table,      -- must not be null
       to_regclass('public.hg_humanoids') as dashboards_tables, -- must not be null
       (select count(*) from public.hg_members) as hg_members,  -- 3 when all demo accounts are linked
       (select label from public.hg_humanoids where linked_user_id =
          (select id from auth.users where lower(email) = 'nc@hg.com')) as live_humanoid; -- Humanoid_OEM_B_UUID

-- Latest check-in steps the app sent (newest first)
select e.created_at, u.email, e.event_type, e.answer
from public.hg_events e join auth.users u on u.id = e.user_id
order by e.created_at desc limit 10;
