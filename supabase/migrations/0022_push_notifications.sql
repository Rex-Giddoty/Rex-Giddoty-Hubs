-- Rex-Giddoty Hubs — push notifications
--
-- A phone that has installed the shop can be told things without an email
-- arriving: the order shipped, support replied. The browser hands us an
-- endpoint and two keys; sending to it means signing a VAPID token and
-- encrypting the payload, neither of which SQL can do — so the database calls
-- an edge function, which does.
--
-- One row per device, not per person: the same customer on a phone and a
-- laptop is two subscriptions, and both should ring.

create table if not exists public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);

create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;

-- Your own devices, and nobody else's. Staff have no business reading these
-- either: an endpoint is a capability, and anyone holding one can push to that
-- phone.
drop policy if exists push_own on public.push_subscriptions;
create policy push_own on public.push_subscriptions
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ── the send ─────────────────────────────────────────────────────────────────
-- The keys live in private.app_secrets, which has no grants and no policies, so
-- nothing holding the public anon key can read them.
create or replace function private.push_to_user(
  p_user  uuid,
  p_title text,
  p_body  text,
  p_url   text default '/')
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_url text := private.secret('push_function_url');
  v_key text := private.secret('push_function_key');
begin
  if v_url is null or v_key is null then
    return;             -- not configured yet; never let this break an order
  end if;
  if not exists (select 1 from public.push_subscriptions where user_id = p_user) then
    return;             -- nothing to send to, so nothing to pay for
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_key,
                 'Content-Type',  'application/json'),
    body    := jsonb_build_object(
                 'user_id', p_user,
                 'title',   p_title,
                 'body',    p_body,
                 'url',     p_url));
end; $$;

revoke execute on function private.push_to_user(uuid, text, text, text) from public, anon, authenticated;

-- ── an order moves ───────────────────────────────────────────────────────────
-- The customer already gets an email. This is the same news, faster, and only
-- for the steps that are actually news.
create or replace function private.on_order_push()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_title text; v_body text;
begin
  if new.status is not distinct from old.status or new.user_id is null then
    return new;
  end if;

  select case new.status
           when 'paid'      then 'Payment confirmed'
           when 'packed'    then 'Your order is packed'
           when 'shipped'   then 'Your order is on its way'
           when 'delivered' then 'Delivered'
           when 'cancelled' then 'Order cancelled'
         end into v_title;
  if v_title is null then return new; end if;

  v_body := case new.status
              when 'paid'      then 'We have your transfer for ' || new.order_number || '. Packing starts now.'
              when 'packed'    then new.order_number || ' is boxed and waiting for the rider.'
              when 'shipped'   then new.order_number || ' has left us. The rider will call you.'
              when 'delivered' then new.order_number || ' is with you. Tell us how it went.'
              when 'cancelled' then new.order_number || ' was cancelled. Nothing is owed.'
            end;

  perform private.push_to_user(new.user_id, v_title, v_body,
    '/order.html?n=' || new.order_number);
  return new;
end; $$;

drop trigger if exists trg_order_push on public.orders;
create trigger trg_order_push
  after update of status on public.orders
  for each row execute function private.on_order_push();

-- ── the shop replies ─────────────────────────────────────────────────────────
create or replace function private.on_reply_push()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_user uuid;
begin
  if new.sender_role <> 'staff' then
    return new;
  end if;
  select user_id into v_user from public.support_threads where id = new.thread_id;
  if v_user is null then return new; end if;

  perform private.push_to_user(v_user, 'Rex-Giddoty Hubs replied',
    left(new.body, 120), '/?chat=1');
  return new;
end; $$;

drop trigger if exists trg_reply_push on public.support_messages;
create trigger trg_reply_push
  after insert on public.support_messages
  for each row execute function private.on_reply_push();
