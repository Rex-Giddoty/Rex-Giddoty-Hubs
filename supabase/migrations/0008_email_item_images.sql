-- Rex-Giddoty Hubs — show the product photo on each line of an order email
--
-- Images are referenced by public URL. Email clients will not load anything
-- behind auth, and the product-images bucket is public read already, so the
-- same URL the shop uses works here.

create or replace function private.image_url(p_path text)
returns text language sql immutable set search_path = '' as $$
  select case
    when coalesce(p_path,'') = '' then null
    else 'https://ttlhbmkzhbhflsuisskp.supabase.co/storage/v1/object/public/product-images/' || p_path
  end;
$$;

create or replace function private.order_items_html(p_order uuid, p_currency text)
returns text language sql stable set search_path = '' as $$
  select coalesce(string_agg(
       '<tr>'
       -- the thumbnail. Height is left to the browser: object-fit is ignored by
       -- most mail clients, so forcing a square would squash the photo instead.
    || '<td width="68" valign="top" style="padding:12px 12px 12px 0;">'
    || case
         when private.image_url(oi.image_path) is null then
           '<div style="width:56px;height:56px;background:#f4f4f4;border:1px solid #eeeeee;'
           || 'border-radius:4px;"></div>'
         else
           '<img src="' || private.image_url(oi.image_path) || '" width="56" '
           || 'alt="' || replace(coalesce(oi.product_name,''), '"', '') || '" '
           || 'style="display:block;width:56px;height:auto;border:1px solid #eeeeee;'
           || 'border-radius:4px;background:#ffffff;"/>'
       end
    || '</td>'
       -- name, option and quantity
    || '<td valign="top" style="padding:12px 0;border-bottom:1px solid #eeeeee;'
    || 'font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.45;">'
    ||   coalesce(oi.product_name,'')
    ||   coalesce('<br/><span style="color:#7a7a7a;font-size:13px;">' || oi.option_label || '</span>', '')
    ||   '<br/><span style="color:#7a7a7a;font-size:13px;">Qty ' || oi.quantity || '</span>'
    || '</td>'
       -- line total
    || '<td valign="top" align="right" style="padding:12px 0;border-bottom:1px solid #eeeeee;'
    || 'font:700 14px Arial,Helvetica,sans-serif;color:#282828;white-space:nowrap;">'
    ||   private.money(oi.line_total_minor, p_currency)
    || '</td>'
    || '</tr>', '' order by oi.id), '')
  from public.order_items oi
  where oi.order_id = p_order;
$$;

/* The totals rows that follow the items now sit in a three-column table, so
   they have to span the thumbnail column or the labels land under the photos. */
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
       '<p style="margin:0 0 16px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
    || 'Thank you — your order <b>#' || new.order_number || '</b> is in, and your items are reserved.</p>'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">'
    || private.order_items_html(new.id, new.currency)
    || '<tr><td colspan="2" style="padding:12px 0 0;font:14px Arial,Helvetica,sans-serif;color:#7a7a7a;">Delivery</td>'
    || '<td align="right" style="padding:12px 0 0;font:14px Arial,Helvetica,sans-serif;color:#7a7a7a;white-space:nowrap;">'
    || case when coalesce(new.shipping_minor,0) = 0 then 'Free'
            else private.money(new.shipping_minor, new.currency) end || '</td></tr>'
    || '<tr><td colspan="2" style="padding:6px 0;font:700 17px Arial,Helvetica,sans-serif;color:#282828;">Total</td>'
    || '<td align="right" style="padding:6px 0;font:700 17px Arial,Helvetica,sans-serif;color:#282828;white-space:nowrap;">'
    || private.money(new.total_minor, new.currency) || '</td></tr></table>'
    || case when v_bank = '' then ''
       else '<div style="background:#fafafa;border:1px solid #eeeeee;border-radius:5px;padding:14px;margin-top:18px;'
            || 'font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.7;">'
            || '<b>To pay</b><br/>' || v_bank
            || '<br/>Reference: <b>' || new.order_number || '</b></div>' end
    || '<p style="margin:16px 0 0;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">Delivering to:<br/>'
    || coalesce(a->>'full_name','') || '<br/>' || coalesce(a->>'line1','')
    || coalesce('<br/>' || nullif(a->>'line2',''), '')
    || '<br/>' || coalesce(a->>'city','') || coalesce(', ' || nullif(a->>'state',''), '') || '</p>'
    || '<p style="margin:20px 0 0;"><a href="https://rexgiddotyhubs.shop/order.html?n='
    || new.order_number || '" style="background:#f68b1e;color:#ffffff;text-decoration:none;'
    || 'font:600 15px Arial,Helvetica,sans-serif;padding:13px 26px;border-radius:4px;display:inline-block;">'
    || 'View your order</a></p>';

  perform private.send_email(new.email,
    'Your order ' || new.order_number || ' — Rex-Giddoty Hubs',
    private.email_shell('Order received', v_body));

  select value into v_alert from public.site_settings where key = 'order_alert_email';
  if coalesce(v_alert,'') = '' then
    select value into v_alert from public.site_settings where key = 'support_email';
  end if;

  perform private.send_email(v_alert,
    'New order ' || new.order_number || ' — ' || private.money(new.total_minor, new.currency),
    private.email_shell('New order',
         '<p style="margin:0 0 16px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
      || '<b>#' || new.order_number || '</b> from ' || coalesce(new.email,'a customer')
      || ' for <b>' || private.money(new.total_minor, new.currency) || '</b>.</p>'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">'
      || private.order_items_html(new.id, new.currency) || '</table>'
      || '<p style="margin:16px 0 0;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
      || coalesce(a->>'full_name','') || '<br/>' || coalesce(a->>'line1','')
      || '<br/>' || coalesce(a->>'city','')
      || coalesce('<br/>' || nullif(a->>'phone',''), '') || '</p>'
      || case when coalesce(new.note,'') = '' then ''
              else '<p style="margin:12px 0 0;font:14px Arial,Helvetica,sans-serif;color:#7a7a7a;">Note: '
                   || new.note || '</p>' end));

  return new;
end; $$;
