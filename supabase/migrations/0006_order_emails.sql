-- Rex-Giddoty Hubs — order emails
--
-- Sent by the database rather than the browser, for two reasons: the Resend key
-- must never reach a client, and an email that depends on the shopper's tab
-- staying open is an email that sometimes does not arrive. A trigger fires
-- whatever caused the change — checkout, ops, or a hand-written UPDATE.

create extension if not exists pg_net with schema extensions;

-- ── secret storage ───────────────────────────────────────────────────────────
-- site_settings is readable by anyone holding the public anon key, so the API
-- key lives here instead: no policies, no grants, reachable only by definer
-- functions owned by postgres.
create table if not exists private.app_secrets (
  key   text primary key,
  value text not null
);
revoke all on private.app_secrets from public, anon, authenticated;

/* Run once with the real key:
     insert into private.app_secrets (key, value)
     values ('resend_api_key', 're_...')
     on conflict (key) do update set value = excluded.value;
*/

create or replace function private.secret(p_key text)
returns text language sql security definer stable set search_path = '' as $$
  select value from private.app_secrets where key = p_key;
$$;
revoke execute on function private.secret(text) from public, anon, authenticated;

-- ── the sender ───────────────────────────────────────────────────────────────
create or replace function private.send_email(p_to text, p_subject text, p_html text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_key  text := private.secret('resend_api_key');
  v_from text := coalesce(private.secret('email_from'),
                          'Rex-Giddoty Hubs <no-reply@rexgiddotyhubs.shop>');
begin
  if v_key is null or coalesce(p_to, '') = '' then
    return;   -- not configured yet, or nobody to send to; never block the order
  end if;

  /* pg_net is registered against the extensions schema but installs its
     functions into net, and search_path is empty here, so this has to be the
     schema the functions actually live in rather than the extension's. */
  perform net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_key,
                 'Content-Type',  'application/json'),
    body    := jsonb_build_object(
                 'from',    v_from,
                 'to',      jsonb_build_array(p_to),
                 'subject', p_subject,
                 'html',    p_html)
  );
end; $$;
revoke execute on function private.send_email(text,text,text) from public, anon, authenticated;

-- ── shared pieces ────────────────────────────────────────────────────────────
create or replace function private.money(p_minor integer, p_currency text)
returns text language sql immutable set search_path = '' as $$
  select case coalesce(p_currency,'NGN')
           when 'NGN' then '₦' when 'USD' then '$'
           when 'EUR' then '€' when 'GBP' then '£'
           else coalesce(p_currency,'') || ' '
         end || to_char(coalesce(p_minor,0)::numeric / 100, 'FM999,999,999,990.00');
$$;

create or replace function private.order_items_html(p_order uuid, p_currency text)
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(
    '<tr>'
    || '<td style="padding:8px 0;border-bottom:1px solid #eee;font:14px Arial,sans-serif;color:#282828">'
    ||   coalesce(oi.product_name,'')
    ||   coalesce(' &middot; ' || oi.option_label, '')
    ||   ' <span style="color:#7a7a7a">&times; ' || oi.quantity || '</span></td>'
    || '<td align="right" style="padding:8px 0;border-bottom:1px solid #eee;font:14px Arial,sans-serif;color:#282828;white-space:nowrap">'
    ||   private.money(oi.line_total_minor, p_currency) || '</td>'
    || '</tr>', '' order by oi.id), '')
  from public.order_items oi
  where oi.order_id = p_order;
$$;

create or replace function private.email_shell(p_title text, p_body text)
returns text language sql immutable set search_path = '' as $$
  select '<div style="background:#f1f1f2;padding:24px 12px">'
      || '<div style="max-width:560px;margin:0 auto;background:#fff;border-radius:6px;padding:26px 24px">'
      || '<div style="font:800 20px Arial,sans-serif;color:#9030d0;margin-bottom:2px">'
      || 'Rex-Giddoty Hub$ <span style="color:#282828">UNLIMITED</span></div>'
      || '<div style="font:12px Arial,sans-serif;color:#7a7a7a;margin-bottom:20px">rexgiddotyhubs.shop</div>'
      || '<h1 style="font:600 19px Arial,sans-serif;color:#282828;margin:0 0 14px">' || p_title || '</h1>'
      || p_body
      || '<div style="border-top:1px solid #eee;margin-top:22px;padding-top:14px;'
      || 'font:12px Arial,sans-serif;color:#7a7a7a">'
      || 'Questions? Just reply to this email.</div>'
      || '</div></div>';
$$;

-- ── 1. confirmation, once the order has its totals ───────────────────────────
-- place_order inserts the order, then the items, then sets the totals. Firing on
-- that last update is what guarantees the items exist by the time we read them.
create or replace function private.on_order_placed()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_bank  text := '';
  v_alert text;
  v_body  text;
  a       jsonb := coalesce(new.shipping_address, '{}'::jsonb);
begin
  if new.total_minor is null or new.total_minor <= 0
     or coalesce(old.total_minor, 0) = new.total_minor then
    return new;
  end if;

  select coalesce(
    string_agg(x.label || ': <b>' || x.val || '</b>', '<br/>' order by x.ord), '')
    into v_bank
  from (
    select 1 as ord, 'Bank' as label, value as val from public.site_settings where key='bank_name'
    union all
    select 2, 'Account name', value from public.site_settings where key='bank_account_name'
    union all
    select 3, 'Account number', value from public.site_settings where key='bank_account_number'
  ) x
  where coalesce(x.val,'') <> '';

  v_body :=
       '<p style="font:14px Arial,sans-serif;color:#282828;line-height:1.6">Thank you — your order '
    || '<b>#' || new.order_number || '</b> is in, and your items are reserved.</p>'
    || '<table width="100%" cellpadding="0" cellspacing="0">'
    || private.order_items_html(new.id, new.currency)
    || '<tr><td style="padding:10px 0 0;font:14px Arial,sans-serif;color:#7a7a7a">Delivery</td>'
    || '<td align="right" style="padding:10px 0 0;font:14px Arial,sans-serif;color:#7a7a7a">'
    || case when coalesce(new.shipping_minor,0) = 0 then 'Free'
            else private.money(new.shipping_minor, new.currency) end || '</td></tr>'
    || '<tr><td style="padding:6px 0;font:700 16px Arial,sans-serif;color:#282828">Total</td>'
    || '<td align="right" style="padding:6px 0;font:700 16px Arial,sans-serif;color:#282828">'
    || private.money(new.total_minor, new.currency) || '</td></tr></table>'
    || case when v_bank = '' then ''
       else '<div style="background:#fafafa;border:1px solid #eee;border-radius:5px;padding:14px;margin-top:18px;'
            || 'font:14px Arial,sans-serif;color:#282828;line-height:1.7">'
            || '<b>To pay</b><br/>' || v_bank
            || '<br/>Reference: <b>' || new.order_number || '</b></div>' end
    || '<p style="font:14px Arial,sans-serif;color:#282828;line-height:1.6">Delivering to:<br/>'
    || coalesce(a->>'full_name','') || '<br/>' || coalesce(a->>'line1','')
    || coalesce('<br/>' || nullif(a->>'line2',''), '')
    || '<br/>' || coalesce(a->>'city','') || coalesce(', ' || nullif(a->>'state',''), '') || '</p>'
    || '<p style="margin-top:20px"><a href="https://rexgiddotyhubs.shop/order.html?n='
    || new.order_number || '" style="background:#f68b1e;color:#fff;text-decoration:none;'
    || 'font:600 14px Arial,sans-serif;padding:12px 20px;border-radius:4px;display:inline-block">'
    || 'View your order</a></p>';

  perform private.send_email(new.email,
    'Your order ' || new.order_number || ' — Rex-Giddoty Hubs',
    private.email_shell('Order received', v_body));

  -- and tell the shop
  select value into v_alert from public.site_settings where key = 'order_alert_email';
  if coalesce(v_alert,'') = '' then
    select value into v_alert from public.site_settings where key = 'support_email';
  end if;

  perform private.send_email(v_alert,
    'New order ' || new.order_number || ' — ' || private.money(new.total_minor, new.currency),
    private.email_shell('New order',
         '<p style="font:14px Arial,sans-serif;color:#282828;line-height:1.6">'
      || '<b>#' || new.order_number || '</b> from ' || coalesce(new.email,'a customer')
      || ' for <b>' || private.money(new.total_minor, new.currency) || '</b>.</p>'
      || '<table width="100%" cellpadding="0" cellspacing="0">'
      || private.order_items_html(new.id, new.currency) || '</table>'
      || '<p style="font:14px Arial,sans-serif;color:#282828;line-height:1.6">'
      || coalesce(a->>'full_name','') || '<br/>' || coalesce(a->>'line1','')
      || '<br/>' || coalesce(a->>'city','')
      || coalesce('<br/>' || nullif(a->>'phone',''), '') || '</p>'
      || case when coalesce(new.note,'') = '' then ''
              else '<p style="font:14px Arial,sans-serif;color:#7a7a7a">Note: '
                   || new.note || '</p>' end));

  return new;
end; $$;

drop trigger if exists trg_order_placed on public.orders;
create trigger trg_order_placed
  after update of total_minor on public.orders
  for each row execute function private.on_order_placed();

-- ── 2. status changes ────────────────────────────────────────────────────────
create or replace function private.on_order_status()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_title text;
  v_line  text;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- Only the transitions a customer cares about. Internal shuffling stays quiet.
  case new.status
    when 'paid'      then v_title := 'Payment confirmed';
                          v_line  := 'We have received your payment. Your order is now being prepared.';
    when 'packed'    then v_title := 'Your order is packed';
                          v_line  := 'Everything is boxed up and waiting for the courier.';
    when 'shipped'   then v_title := 'Your order is on its way';
                          v_line  := 'Your order has left us and is heading to your address.';
    when 'delivered' then v_title := 'Delivered';
                          v_line  := 'Your order has been delivered. We hope you love it.';
    when 'cancelled' then v_title := 'Order cancelled';
                          v_line  := 'Your order has been cancelled and any reserved stock released.';
    when 'refunded'  then v_title := 'Refund issued';
                          v_line  := 'Your refund has been issued. It may take a few days to appear.';
    else return new;
  end case;

  perform private.send_email(new.email,
    v_title || ' — order ' || new.order_number,
    private.email_shell(v_title,
         '<p style="font:14px Arial,sans-serif;color:#282828;line-height:1.6">' || v_line || '</p>'
      || '<p style="font:14px Arial,sans-serif;color:#7a7a7a">Order <b>#' || new.order_number
      || '</b> &middot; ' || private.money(new.total_minor, new.currency) || '</p>'
      || '<p style="margin-top:18px"><a href="https://rexgiddotyhubs.shop/order.html?n='
      || new.order_number || '" style="background:#f68b1e;color:#fff;text-decoration:none;'
      || 'font:600 14px Arial,sans-serif;padding:12px 20px;border-radius:4px;display:inline-block">'
      || 'View your order</a></p>'));

  return new;
end; $$;

drop trigger if exists trg_order_status on public.orders;
create trigger trg_order_status
  after update of status on public.orders
  for each row execute function private.on_order_status();
