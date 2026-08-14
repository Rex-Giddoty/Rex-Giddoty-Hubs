-- Telling the shop's staff, not just its customers.
--
-- Until now the only thing that reached staff was email, throttled to one
-- message every twenty minutes so a busy hour would not fill an inbox. That is
-- the right shape for email and the wrong shape for a shop: an order placed at
-- eleven at night is worth knowing about at eleven at night.

create or replace function private.push_to_admins(
  p_title text, p_body text, p_url text default '/ops.html')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select id from public.admin_users loop
    perform private.push_to_user(r.id, p_title, p_body, p_url);
  end loop;
end;
$$;


-- ── a new order ───────────────────────────────────────────────────────────
create or replace function private.on_order_staff_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.push_to_admins(
    'New order',
    new.order_number || ' — ' ||
      -- minor units, the way the rest of the shop stores money
      to_char(new.total_minor / 100.0, 'FM999G999G990D00') ||
      ' ' || coalesce(new.currency, 'NGN'),
    '/ops.html');
  return new;
end;
$$;

drop trigger if exists trg_order_staff_push on public.orders;
create trigger trg_order_staff_push
  after insert on public.orders
  for each row execute function private.on_order_staff_push();


-- ── a customer writing in ─────────────────────────────────────────────────
-- Every message, not one every twenty minutes: a customer waiting on an answer
-- is the one case where being interrupted is the point. Staff replies are
-- excluded, or answering somebody would notify the person answering.
create or replace function private.on_support_staff_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.sender_role = 'staff' then
    return new;
  end if;

  perform private.push_to_admins(
    'New message',
    -- Enough to judge whether it can wait, not the whole conversation.
    left(coalesce(new.body, 'Sent an attachment'), 90),
    '/ops.html');
  return new;
end;
$$;

drop trigger if exists trg_support_staff_push on public.support_messages;
create trigger trg_support_staff_push
  after insert on public.support_messages
  for each row execute function private.on_support_staff_push();
