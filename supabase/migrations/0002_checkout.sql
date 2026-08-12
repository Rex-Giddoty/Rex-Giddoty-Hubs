-- Rex-Giddoty Hubs — order placement
--
-- The browser sends only variant ids and quantities. Every price, the subtotal,
-- the shipping and the total are read from the database here. A tampered cart
-- cannot change what is charged, which is the single most abused hole in a
-- shopping site.
--
-- Stock is decremented in the same transaction as the order, so two people
-- buying the last item cannot both succeed.

create or replace function private.setting_int(p_key text, p_default integer)
returns integer language sql security definer stable set search_path = '' as $$
  select coalesce((select nullif(value,'')::integer from public.site_settings where key = p_key), p_default);
$$;
revoke execute on function private.setting_int(text, integer) from public, anon, authenticated;

create or replace function public.next_order_number()
returns text language sql security definer set search_path = '' as $$
  select 'RG-' || to_char(now(), 'YYMMDD') || '-' ||
         upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 5));
$$;
revoke execute on function public.next_order_number() from public, anon, authenticated;

/* p_items: [{"variant_id":"<uuid>","quantity":2}, ...] */
create or replace function public.place_order(
  p_items    jsonb,
  p_address  jsonb,
  p_email    text default null,
  p_note     text default null
)
returns table(order_id uuid, order_number text, total_minor integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_order     uuid;
  v_number    text;
  v_subtotal  integer := 0;
  v_shipping  integer;
  v_free_over integer;
  v_currency  text;
  it          record;
begin
  if v_uid is null then
    raise exception 'You must be signed in to place an order';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your bag is empty';
  end if;
  if p_address is null or coalesce(p_address->>'line1','') = '' or coalesce(p_address->>'city','') = '' then
    raise exception 'A delivery address is required';
  end if;

  v_currency  := coalesce((select value from public.site_settings where key='currency'), 'NGN');
  v_shipping  := private.setting_int('shipping_flat_minor', 0);
  v_free_over := private.setting_int('free_shipping_over_minor', 0);

  v_number := public.next_order_number();
  insert into public.orders (order_number, user_id, email, currency, shipping_address, note)
  values (v_number, v_uid, p_email, v_currency, p_address, left(coalesce(p_note,''), 500))
  returning id into v_order;

  for it in
    select (e->>'variant_id')::uuid as variant_id,
           greatest(1, least(20, coalesce((e->>'quantity')::integer, 1))) as quantity
    from jsonb_array_elements(p_items) e
  loop
    declare
      v_price integer;
      v_name  text;
      v_opt   text;
      v_pid   uuid;
      v_img   text;
      v_stock integer;
    begin
      /* Lock the variant row so concurrent checkouts cannot both take the
         last unit. Price comes from here, never from the caller. */
      select coalesce(pv.price_minor, p.price_minor),
             p.name,
             nullif(pv.option_name || ' ' || pv.option_value, ' '),
             p.id,
             pv.stock
        into v_price, v_name, v_opt, v_pid, v_stock
        from public.product_variants pv
        join public.products p on p.id = pv.product_id
       where pv.id = it.variant_id
         and pv.is_active
         and p.status = 'published'
       for update of pv;

      if v_price is null then
        raise exception 'An item in your bag is no longer available';
      end if;
      if v_stock < it.quantity then
        raise exception 'Only % left of %', v_stock, v_name;
      end if;

      select path into v_img from public.product_images
       where product_id = v_pid order by position limit 1;

      update public.product_variants
         set stock = stock - it.quantity
       where id = it.variant_id;

      insert into public.order_items (order_id, product_id, variant_id, product_name,
                                      option_label, image_path, unit_price_minor,
                                      quantity, line_total_minor)
      values (v_order, v_pid, it.variant_id, v_name, v_opt, v_img,
              v_price, it.quantity, v_price * it.quantity);

      v_subtotal := v_subtotal + (v_price * it.quantity);
    end;
  end loop;

  if v_free_over > 0 and v_subtotal >= v_free_over then
    v_shipping := 0;
  end if;

  update public.orders
     set subtotal_minor = v_subtotal,
         shipping_minor = v_shipping,
         total_minor    = v_subtotal + v_shipping,
         updated_at     = now()
   where id = v_order;

  /* the bag is now an order */
  delete from public.cart_items ci
   using public.carts c
   where ci.cart_id = c.id and c.user_id = v_uid;

  return query select v_order, v_number, v_subtotal + v_shipping;
end;
$$;

revoke execute on function public.place_order(jsonb,jsonb,text,text) from public, anon;
grant  execute on function public.place_order(jsonb,jsonb,text,text) to authenticated;

-- Cancelling or refunding puts stock back exactly once.
create or replace function public.admin_set_order_status(p_order uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  select status into v_old from public.orders where id = p_order;
  if v_old is null then
    raise exception 'no such order';
  end if;

  if p_status in ('cancelled','refunded') and v_old not in ('cancelled','refunded') then
    update public.product_variants pv
       set stock = pv.stock + oi.quantity
      from public.order_items oi
     where oi.order_id = p_order and oi.variant_id = pv.id;
  end if;

  update public.orders
     set status = p_status,
         payment_status = case when p_status = 'refunded' then 'refunded' else payment_status end,
         updated_at = now()
   where id = p_order;
end; $$;

revoke execute on function public.admin_set_order_status(uuid,text) from public, anon;
grant  execute on function public.admin_set_order_status(uuid,text) to authenticated;
