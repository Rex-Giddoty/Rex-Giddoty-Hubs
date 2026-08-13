-- Rex-Giddoty Hubs — customers cancel their own pending orders, and the shop
-- hears about registrations and cancellations.

-- ── 1. cancelling ────────────────────────────────────────────────────────────
-- Only while the order is still pending: once we have taken payment, unwinding
-- it is a refund decision, not something a button should do. The row is locked
-- and the status re-checked inside the lock, so two taps cannot restock twice.
create or replace function public.cancel_my_order(p_order uuid)
returns table(order_number text, status text)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_status text;
  v_number text;
begin
  if v_uid is null then
    raise exception 'You must be signed in to cancel an order';
  end if;

  select o.status, o.order_number
    into v_status, v_number
    from public.orders o
   where o.id = p_order and o.user_id = v_uid
   for update;

  if v_status is null then
    raise exception 'We could not find that order on your account';
  end if;
  if v_status = 'cancelled' then
    raise exception 'That order is already cancelled';
  end if;
  if v_status <> 'pending' then
    raise exception 'This order is already being processed, so it can no longer be cancelled here. Contact us and we will sort it out';
  end if;

  update public.product_variants pv
     set stock = pv.stock + oi.quantity
    from public.order_items oi
   where oi.order_id = p_order and oi.variant_id = pv.id;

  update public.orders
     set status = 'cancelled', updated_at = now()
   where id = p_order;

  return query select v_number, 'cancelled'::text;
end; $$;

revoke execute on function public.cancel_my_order(uuid) from public, anon;
grant  execute on function public.cancel_my_order(uuid) to authenticated;

-- ── 2. tell the shop when someone registers ──────────────────────────────────
-- Hung off profiles rather than auth.users: handle_new_user already skips
-- anonymous sessions, so a profile row means a real person signed up.
create or replace function private.on_profile_created()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_alert text;
begin
  select value into v_alert from public.site_settings where key = 'order_alert_email';
  if coalesce(v_alert,'') = '' then
    select value into v_alert from public.site_settings where key = 'support_email';
  end if;

  perform private.send_email(v_alert,
    'New customer — ' || coalesce(new.full_name, new.email, 'someone'),
    private.email_shell('New customer registered',
         '<p style="margin:0 0 16px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
      || '<b>' || coalesce(new.full_name, '—') || '</b> just created an account.</p>'
      || '<p style="margin:0;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.7;">'
      || 'Email: <b>' || coalesce(new.email,'—') || '</b>'
      || coalesce('<br/>Phone: <b>' || nullif(new.phone,'') || '</b>', '') || '</p>'));
  return new;
end; $$;

drop trigger if exists trg_profile_created on public.profiles;
create trigger trg_profile_created
  after insert on public.profiles
  for each row execute function private.on_profile_created();

-- ── 3. tell the shop when an order is cancelled ──────────────────────────────
-- The customer already gets their own note from on_order_status; this is the
-- shop's copy, because a cancellation means stock has just come back.
create or replace function private.on_order_cancelled()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_alert text;
begin
  if new.status is not distinct from old.status or new.status <> 'cancelled' then
    return new;
  end if;

  select value into v_alert from public.site_settings where key = 'order_alert_email';
  if coalesce(v_alert,'') = '' then
    select value into v_alert from public.site_settings where key = 'support_email';
  end if;

  perform private.send_email(v_alert,
    'Order cancelled — ' || new.order_number,
    private.email_shell('Order cancelled',
         '<p style="margin:0 0 16px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
      || 'Order <b>#' || new.order_number || '</b> from ' || coalesce(new.email,'a customer')
      || ' was cancelled. The stock has been returned.</p>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">'
      || private.order_items_html(new.id, new.currency) || '</table>'
      || '<p style="margin:16px 0 0;font:14px Arial,Helvetica,sans-serif;color:#7a7a7a;">'
      || 'Order value was ' || private.money(new.total_minor, new.currency) || '.</p>'));
  return new;
end; $$;

drop trigger if exists trg_order_cancelled on public.orders;
create trigger trg_order_cancelled
  after update of status on public.orders
  for each row execute function private.on_order_cancelled();

-- ── 4. the shop's own address ────────────────────────────────────────────────
insert into public.site_settings (key, value)
values ('order_alert_email', 'rexgiddotyhubs@gmail.com')
on conflict (key) do update set value = excluded.value;

-- ── 5. Bottoms is really Shorts ──────────────────────────────────────────────
update public.categories
   set name = 'Shorts', slug = 'shorts'
 where slug = 'bottoms';
