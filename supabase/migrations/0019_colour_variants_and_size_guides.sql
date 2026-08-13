-- Rex-Giddoty Hubs — colour becomes a real choice, and items get size guides
--
-- Until now a variant was one dimension: a size with a stock count. A shop
-- selling the same bag in red and black could only hold one number for "M",
-- which is wrong the moment one colour sells out before the other. So colour
-- joins size on the variant, and a variant is now a (colour, size) pair with
-- its own stock.
--
-- Colour is nullable, and null means "Default" — the item that does not come
-- in colours at all. Every variant that exists today becomes a Default variant
-- without being touched, so no cart and no order changes meaning.

-- ── colour on the variant ────────────────────────────────────────────────────
alter table public.product_variants
  add column if not exists color text;

/* One row per pairing. coalesce rather than a plain unique index because null
   is not equal to itself in SQL, and two Default rows for the same size is
   exactly the mistake worth refusing. */
drop index if exists product_variants_combo;
create unique index product_variants_combo
  on public.product_variants (product_id, coalesce(color, ''), option_value);

create index if not exists product_variants_color_idx
  on public.product_variants (product_id, color);

-- ── colour on the media ──────────────────────────────────────────────────────
-- A photo belongs to a colour, or to none. Media with no colour is the item's
-- general photography: it shows whatever the shopper has picked, which is what
-- makes a mixed set (three studio shots plus a red close-up) behave sensibly.
alter table public.product_images
  add column if not exists color text;

create index if not exists product_images_color_idx
  on public.product_images (product_id, color, position);

-- ── the old free-text colour goes ────────────────────────────────────────────
-- It shipped an hour ago and no product carries one. Two sources of truth for
-- the same fact is worse than none, and the variants are now the truth.
alter table public.products drop column if exists color;

-- ── size guides ──────────────────────────────────────────────────────────────
-- One jsonb rather than six columns: the shape differs between an uploaded
-- chart and a typed table, and a guide is read whole or not at all.
--
--   { "kind": "table",
--     "units": "cm",
--     "columns": ["Chest","Length"],
--     "rows": [["S","96","68"], ["M","101","70"]],
--     "note": "Measured flat" }
--
--   { "kind": "image", "image_path": "size-guides/tops-1699.jpg", "note": "" }
--
-- Set on the category and inherited by everything under it; an item that
-- disagrees carries its own, and its own wins.
alter table public.categories add column if not exists size_guide jsonb;
alter table public.products   add column if not exists size_guide jsonb;

-- ── the order remembers the colour ───────────────────────────────────────────
-- option_label is a snapshot printed on the order page, the packing list and
-- the emails, so it has to name the colour or the wrong bag gets packed. The
-- line's photograph now prefers one of that colour too.
-- Taken from the function as it actually stands and edited in place, rather
-- than rewritten: the column names and the order-number call are not things
-- to reconstruct from memory.
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
      v_color text;
    begin
      /* Lock the variant row so concurrent checkouts cannot both take the
         last unit. Price comes from here, never from the caller. */
      select coalesce(pv.price_minor, p.price_minor),
             p.name,
             /* "Red · Size M", or just "Size M" when the item has no colours. */
             nullif(btrim(concat_ws(' · ', nullif(pv.color,''),
               nullif(btrim(concat_ws(' ', pv.option_name, pv.option_value)), ''))), ''),
             p.id,
             pv.stock,
             pv.color
        into v_price, v_name, v_opt, v_pid, v_stock, v_color
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

      /* A photograph of the colour actually bought, falling back to the item's
         general photography when that colour has none of its own. */
      select path into v_img from public.product_images
       where product_id = v_pid and color is not distinct from v_color
       order by position limit 1;

      if v_img is null then
        select path into v_img from public.product_images
         where product_id = v_pid and color is null order by position limit 1;
      end if;

      if v_img is null then
        select path into v_img from public.product_images
         where product_id = v_pid order by position limit 1;
      end if;

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

revoke execute on function public.place_order(jsonb, jsonb, text, text) from public, anon;
grant  execute on function public.place_order(jsonb, jsonb, text, text) to authenticated;
