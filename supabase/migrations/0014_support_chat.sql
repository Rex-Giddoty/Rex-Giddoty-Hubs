-- Rex-Giddoty Hubs — support chat
--
-- One running conversation per customer rather than a pile of tickets: a shop
-- this size is talking to a person, not tracking cases. A thread can be closed
-- when it is finished, and the next message opens a fresh one.
--
-- Clients never insert rows directly. Both sides go through definer functions,
-- which is what makes sender_role trustworthy — a customer cannot post a
-- message that claims to be from the shop.

-- ── tables ───────────────────────────────────────────────────────────────────
create table if not exists public.support_threads (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  status           text not null default 'open' check (status in ('open','closed')),
  created_at       timestamptz not null default now(),
  last_message_at  timestamptz not null default now(),
  last_sender      text check (last_sender in ('customer','staff')),
  last_preview     text,
  customer_unread  integer not null default 0,
  staff_unread     integer not null default 0
);

-- At most one open thread each, so "my conversation" is never ambiguous.
create unique index if not exists support_threads_one_open
  on public.support_threads (user_id) where status = 'open';
create index if not exists support_threads_recent
  on public.support_threads (last_message_at desc);

create table if not exists public.support_messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.support_threads(id) on delete cascade,
  sender_id   uuid references auth.users(id) on delete set null,
  sender_role text not null check (sender_role in ('customer','staff')),
  body        text not null check (length(btrim(body)) between 1 and 4000),
  created_at  timestamptz not null default now()
);
create index if not exists support_messages_thread
  on public.support_messages (thread_id, created_at);

alter table public.support_threads  enable row level security;
alter table public.support_messages enable row level security;

-- ── policies ─────────────────────────────────────────────────────────────────
-- Read only. Every write goes through the functions below, so there is no
-- insert or update policy to get wrong.
drop policy if exists support_threads_read on public.support_threads;
create policy support_threads_read on public.support_threads
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

drop policy if exists support_messages_read on public.support_messages;
create policy support_messages_read on public.support_messages
  for select to authenticated
  using (exists (select 1 from public.support_threads t
                  where t.id = thread_id
                    and (t.user_id = (select auth.uid()) or (select private.is_admin()))));

-- ── a customer writes ────────────────────────────────────────────────────────
create or replace function public.send_support_message(p_body text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := (select auth.uid());
  v_body   text := btrim(coalesce(p_body, ''));
  v_thread uuid;
begin
  if v_uid is null then
    raise exception 'You must be signed in to send a message';
  end if;
  if v_body = '' then
    raise exception 'Type a message first';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That message is too long';
  end if;

  /* Staff replying to themselves would land in the customer list, so the shop's
     own accounts are kept out of it. */
  if exists (select 1 from public.admin_users where id = v_uid) then
    raise exception 'Staff accounts reply from the operations console';
  end if;

  select id into v_thread
    from public.support_threads
   where user_id = v_uid and status = 'open'
   for update;

  if v_thread is null then
    insert into public.support_threads (user_id) values (v_uid) returning id into v_thread;
  end if;

  insert into public.support_messages (thread_id, sender_id, sender_role, body)
  values (v_thread, v_uid, 'customer', v_body);

  update public.support_threads
     set last_message_at = now(),
         last_sender     = 'customer',
         last_preview    = left(v_body, 140),
         staff_unread    = staff_unread + 1
   where id = v_thread;

  return v_thread;
end; $$;

revoke execute on function public.send_support_message(text) from public, anon;
grant  execute on function public.send_support_message(text) to authenticated;

-- ── the shop writes ──────────────────────────────────────────────────────────
create or replace function public.staff_reply(p_thread uuid, p_body text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := (select auth.uid());
  v_body text := btrim(coalesce(p_body, ''));
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  if v_body = '' then
    raise exception 'Type a reply first';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That reply is too long';
  end if;
  if not exists (select 1 from public.support_threads where id = p_thread) then
    raise exception 'No such conversation';
  end if;

  insert into public.support_messages (thread_id, sender_id, sender_role, body)
  values (p_thread, v_uid, 'staff', v_body);

  /* Replying reopens a closed thread: the customer will see the answer, and
     they should be able to answer it back. */
  update public.support_threads
     set last_message_at = now(),
         last_sender     = 'staff',
         last_preview    = left(v_body, 140),
         customer_unread = customer_unread + 1,
         staff_unread    = 0,
         status          = 'open'
   where id = p_thread;

  return p_thread;
end; $$;

revoke execute on function public.staff_reply(uuid, text) from public, anon;
grant  execute on function public.staff_reply(uuid, text) to authenticated;

-- ── reading ──────────────────────────────────────────────────────────────────
-- Whose counter is cleared depends on who is asking, so one function serves
-- both sides and neither can clear the other's badge.
create or replace function public.mark_support_read(p_thread uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then return; end if;

  if private.is_admin() then
    update public.support_threads set staff_unread = 0 where id = p_thread;
  else
    update public.support_threads set customer_unread = 0
     where id = p_thread and user_id = v_uid;
  end if;
end; $$;

revoke execute on function public.mark_support_read(uuid) from public, anon;
grant  execute on function public.mark_support_read(uuid) to authenticated;

create or replace function public.close_support_thread(p_thread uuid, p_closed boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  update public.support_threads
     set status = case when p_closed then 'closed' else 'open' end
   where id = p_thread;
end; $$;

revoke execute on function public.close_support_thread(uuid, boolean) from public, anon;
grant  execute on function public.close_support_thread(uuid, boolean) to authenticated;

-- ── the ops list ─────────────────────────────────────────────────────────────
-- profiles is readable by staff already, but joining it here saves the console
-- a second round trip per conversation and keeps the ordering in one place.
create or replace function public.admin_list_threads()
returns table(
  id              uuid,
  user_id         uuid,
  full_name       text,
  email           text,
  phone           text,
  status          text,
  created_at      timestamptz,
  last_message_at timestamptz,
  last_sender     text,
  last_preview    text,
  staff_unread    integer,
  message_count   integer
)
language sql security definer stable set search_path = '' as $$
  select t.id, t.user_id, p.full_name, p.email, p.phone, t.status,
         t.created_at, t.last_message_at, t.last_sender, t.last_preview,
         t.staff_unread,
         (select count(*) from public.support_messages m where m.thread_id = t.id)::integer
    from public.support_threads t
    left join public.profiles p on p.id = t.user_id
   where (select private.is_admin())
   order by t.last_message_at desc;
$$;

revoke execute on function public.admin_list_threads() from public, anon;
grant  execute on function public.admin_list_threads() to authenticated;

-- ── tell the shop a customer is waiting ──────────────────────────────────────
-- Only for the first message of a lull. Somebody typing four short lines in a
-- row is one conversation, not four emails.
create or replace function private.on_support_message()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_alert  text;
  v_prev   timestamptz;
  v_name   text;
  v_email  text;
begin
  if new.sender_role <> 'customer' then
    return new;
  end if;

  select max(m.created_at) into v_prev
    from public.support_messages m
   where m.thread_id = new.thread_id and m.id <> new.id;

  if v_prev is not null and v_prev > now() - interval '20 minutes' then
    return new;                       -- already told them about this conversation
  end if;

  select value into v_alert from public.site_settings where key = 'order_alert_email';
  if coalesce(v_alert,'') = '' then
    select value into v_alert from public.site_settings where key = 'support_email';
  end if;

  select p.full_name, p.email into v_name, v_email
    from public.support_threads t
    left join public.profiles p on p.id = t.user_id
   where t.id = new.thread_id;

  perform private.send_email(v_alert,
    'Support message — ' || coalesce(v_name, v_email, 'a customer'),
    private.email_shell('A customer is waiting',
         '<p style="margin:0 0 16px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
      || '<b>' || coalesce(v_name, v_email, 'A customer') || '</b> sent a message in support chat.</p>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
      ||   'style="background:#f6f2fb;border-left:3px solid #9030d0;border-radius:0 4px 4px 0;">'
      || '<tr><td style="padding:13px 15px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
      || replace(replace(replace(new.body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
      || '</td></tr></table>'
      || '<p style="margin:16px 0 0;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.7;">'
      || coalesce('From: <b>' || v_email || '</b><br/>', '')
      || 'Reply from the Support tab in your operations console.</p>'
      || '<p style="margin:20px 0 0;">'
      || '<a href="https://rexgiddotyhubs.shop/ops.html" '
      ||   'style="background:#9030d0;color:#fff;text-decoration:none;border-radius:4px;'
      ||   'display:inline-block;padding:11px 22px;font:600 14px Arial,Helvetica,sans-serif;">'
      || 'Open support</a></p>'));
  return new;
end; $$;

drop trigger if exists trg_support_message on public.support_messages;
create trigger trg_support_message
  after insert on public.support_messages
  for each row execute function private.on_support_message();

-- ── live updates ─────────────────────────────────────────────────────────────
-- Realtime filters change feeds through the same policies above, so a customer
-- is only ever pushed rows from their own thread.
alter table public.support_messages replica identity full;
alter table public.support_threads  replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'support_messages') then
    alter publication supabase_realtime add table public.support_messages;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'support_threads') then
    alter publication supabase_realtime add table public.support_threads;
  end if;
end $$;
