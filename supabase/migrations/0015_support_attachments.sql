-- Rex-Giddoty Hubs — attachments in support chat
--
-- Mostly this is people sending transfer receipts and photos of what arrived,
-- which is exactly the evidence a conversation about an order needs.
--
-- The bucket is private. Product images are public because they are meant to be
-- seen by everyone; a receipt with somebody's bank details is not, so reading
-- one goes through a signed URL that only the two people in the conversation
-- can ask for.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('support-files', 'support-files', false, 10485760, array[
  'image/jpeg','image/png','image/webp','image/avif','image/gif','image/heic',
  'application/pdf'
])
on conflict (id) do update
  set public            = false,
      file_size_limit   = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ── who may touch a file ─────────────────────────────────────────────────────
-- Every object lives under its thread id: "<thread>/<random>.jpg". So the
-- question "may I read this file" is the same question as "may I read this
-- conversation", and the policy asks it of support_threads rather than keeping
-- a second set of rules that could drift.
create or replace function private.support_file_ok(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.support_threads t
     where t.id::text = split_part(p_name, '/', 1)
       and (t.user_id = (select auth.uid()) or (select private.is_admin()))
  );
$$;

revoke execute on function private.support_file_ok(text) from public, anon;
grant  execute on function private.support_file_ok(text) to authenticated;

drop policy if exists support_files_read  on storage.objects;
drop policy if exists support_files_write on storage.objects;

create policy support_files_read on storage.objects
  for select to authenticated
  using (bucket_id = 'support-files' and private.support_file_ok(name));

create policy support_files_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'support-files' and private.support_file_ok(name));

-- Nobody edits or deletes an attachment. A conversation is a record, and the
-- customer deleting the receipt they sent is not something to build a button for.

-- ── the message carries it ───────────────────────────────────────────────────
alter table public.support_messages
  add column if not exists file_path text,
  add column if not exists file_name text,
  add column if not exists file_type text,
  add column if not exists file_size integer;

-- Body was required. A message that is just a photo is still a message, so now
-- one of the two has to be present rather than both.
alter table public.support_messages drop constraint if exists support_messages_body_check;
alter table public.support_messages drop constraint if exists support_messages_has_content;
alter table public.support_messages add constraint support_messages_has_content
  check (length(btrim(coalesce(body, ''))) between 1 and 4000 or file_path is not null);
alter table public.support_messages alter column body drop not null;

-- ── sending ──────────────────────────────────────────────────────────────────
create or replace function public.send_support_message(
  p_body text,
  p_file_path text default null,
  p_file_name text default null,
  p_file_type text default null,
  p_file_size integer default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := (select auth.uid());
  v_body   text := btrim(coalesce(p_body, ''));
  v_thread uuid;
begin
  if v_uid is null then
    raise exception 'You must be signed in to send a message';
  end if;
  if v_body = '' and p_file_path is null then
    raise exception 'Type a message first';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That message is too long';
  end if;
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

  /* The file was uploaded before this call, so the path is checked here rather
     than trusted: it has to sit under a thread this person owns. */
  if p_file_path is not null and split_part(p_file_path, '/', 1) <> v_thread::text then
    raise exception 'That file does not belong to this conversation';
  end if;

  insert into public.support_messages
    (thread_id, sender_id, sender_role, body, file_path, file_name, file_type, file_size)
  values (v_thread, v_uid, 'customer', nullif(v_body, ''),
          p_file_path, p_file_name, p_file_type, p_file_size);

  update public.support_threads
     set last_message_at = now(),
         last_sender     = 'customer',
         last_preview    = left(coalesce(nullif(v_body, ''), '📎 ' || coalesce(p_file_name, 'Attachment')), 140),
         staff_unread    = staff_unread + 1
   where id = v_thread;

  return v_thread;
end; $$;

revoke execute on function public.send_support_message(text, text, text, text, integer) from public, anon;
grant  execute on function public.send_support_message(text, text, text, text, integer) to authenticated;
drop function if exists public.send_support_message(text);

create or replace function public.staff_reply(
  p_thread uuid,
  p_body text,
  p_file_path text default null,
  p_file_name text default null,
  p_file_type text default null,
  p_file_size integer default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := (select auth.uid());
  v_body text := btrim(coalesce(p_body, ''));
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  if v_body = '' and p_file_path is null then
    raise exception 'Type a reply first';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That reply is too long';
  end if;
  if not exists (select 1 from public.support_threads where id = p_thread) then
    raise exception 'No such conversation';
  end if;
  if p_file_path is not null and split_part(p_file_path, '/', 1) <> p_thread::text then
    raise exception 'That file does not belong to this conversation';
  end if;

  insert into public.support_messages
    (thread_id, sender_id, sender_role, body, file_path, file_name, file_type, file_size)
  values (p_thread, v_uid, 'staff', nullif(v_body, ''),
          p_file_path, p_file_name, p_file_type, p_file_size);

  update public.support_threads
     set last_message_at = now(),
         last_sender     = 'staff',
         last_preview    = left(coalesce(nullif(v_body, ''), '📎 ' || coalesce(p_file_name, 'Attachment')), 140),
         customer_unread = customer_unread + 1,
         staff_unread    = 0,
         status          = 'open'
   where id = p_thread;

  return p_thread;
end; $$;

revoke execute on function public.staff_reply(uuid, text, text, text, text, integer) from public, anon;
grant  execute on function public.staff_reply(uuid, text, text, text, text, integer) to authenticated;
drop function if exists public.staff_reply(uuid, text);

-- ── a thread to upload into before the first message exists ──────────────────
-- Attaching a file is a decision made before the message is sent, and the path
-- needs a thread id. This hands back the open one, opening it if there is none.
create or replace function public.my_support_thread()
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := (select auth.uid());
  v_thread uuid;
begin
  if v_uid is null then
    raise exception 'You must be signed in';
  end if;
  if exists (select 1 from public.admin_users where id = v_uid) then
    raise exception 'Staff accounts reply from the operations console';
  end if;

  select id into v_thread from public.support_threads
   where user_id = v_uid and status = 'open';

  if v_thread is null then
    insert into public.support_threads (user_id) values (v_uid) returning id into v_thread;
  end if;
  return v_thread;
end; $$;

revoke execute on function public.my_support_thread() from public, anon;
grant  execute on function public.my_support_thread() to authenticated;

-- ── the alert says so ────────────────────────────────────────────────────────
create or replace function private.on_support_message()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_alert text;
  v_prev  timestamptz;
  v_name  text;
  v_email text;
begin
  if new.sender_role <> 'customer' then
    return new;
  end if;

  select max(m.created_at) into v_prev
    from public.support_messages m
   where m.thread_id = new.thread_id and m.id <> new.id;

  if v_prev is not null and v_prev > now() - interval '20 minutes' then
    return new;
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
      || coalesce(replace(replace(replace(new.body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                  '<i>(no message)</i>')
      /* The file itself is not attached — it sits behind a signed URL that only
         the console can ask for, which is the point of a private bucket. */
      || coalesce('<br/><br/>📎 Attached: <b>'
           || replace(replace(new.file_name, '<', '&lt;'), '>', '&gt;') || '</b>', '')
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
