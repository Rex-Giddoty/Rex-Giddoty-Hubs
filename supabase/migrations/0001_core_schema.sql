-- Rex-Giddoty Hubs — core commerce schema
--
-- Money is stored as integer minor units (kobo/cents), never floats. Payment
-- processors take amounts in minor units too, so this avoids a rounding class
-- of bug entirely and matches what we will send to the gateway.
--
-- Order lines snapshot the name and price at purchase time, so editing a
-- product later never rewrites what somebody was charged.

create schema if not exists private;

-- ── who is staff ─────────────────────────────────────────────────────────────
create table if not exists public.admin_users (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  role       text not null default 'admin' check (role in ('admin','owner')),
  created_at timestamptz not null default now()
);
alter table public.admin_users enable row level security;

create or replace function private.is_admin()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (select 1 from public.admin_users where id = (select auth.uid()));
$$;
revoke execute on function private.is_admin() from public;
/* anon needs EXECUTE too: the public catalogue policies call this function, and
   a policy is evaluated as the querying role. For a signed-out visitor it simply
   returns false, so granting it exposes nothing. */
grant  execute on function private.is_admin() to anon, authenticated;
grant  usage   on schema private to anon, authenticated;

drop policy if exists admin_users_self on public.admin_users;
create policy admin_users_self on public.admin_users
  for select to authenticated
  using (id = (select auth.uid()) or (select private.is_admin()));
grant select on public.admin_users to authenticated;

-- ── customers ────────────────────────────────────────────────────────────────
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  phone      text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select private.is_admin()));

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated
  using      (id = (select auth.uid()) or (select private.is_admin()))
  with check (id = (select auth.uid()) or (select private.is_admin()));

grant select, update on public.profiles to authenticated;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(new.is_anonymous, false) then
    return new;
  end if;
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── catalogue ────────────────────────────────────────────────────────────────
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  name        text not null,
  description text,
  image_path  text,
  position    integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,
  name         text not null,
  subtitle     text,
  description  text,
  details      text,
  currency     text not null default 'NGN' check (char_length(currency) = 3),
  price_minor  integer not null check (price_minor >= 0),
  status       text not null default 'draft' check (status in ('draft','published','archived')),
  is_featured  boolean not null default false,
  position     integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists products_status_idx   on public.products (status, position);
create index if not exists products_featured_idx on public.products (is_featured) where is_featured;

create table if not exists public.product_images (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  path       text not null,
  alt        text,
  position   integer not null default 0
);
create index if not exists product_images_product_idx on public.product_images (product_id, position);

-- Every product has at least one variant, even if it is just "One Size".
-- Stock lives here so a sold-out size does not take the whole product down.
create table if not exists public.product_variants (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references public.products(id) on delete cascade,
  sku          text unique,
  option_name  text not null default 'Size',
  option_value text not null default 'One Size',
  price_minor  integer check (price_minor >= 0),   -- null = use the product price
  stock        integer not null default 0 check (stock >= 0),
  position     integer not null default 0,
  is_active    boolean not null default true
);
create index if not exists product_variants_product_idx on public.product_variants (product_id, position);

create table if not exists public.product_categories (
  product_id  uuid not null references public.products(id)   on delete cascade,
  category_id uuid not null references public.categories(id) on delete cascade,
  primary key (product_id, category_id)
);
create index if not exists product_categories_category_idx on public.product_categories (category_id);

alter table public.categories        enable row level security;
alter table public.products          enable row level security;
alter table public.product_images    enable row level security;
alter table public.product_variants  enable row level security;
alter table public.product_categories enable row level security;

-- Shoppers see the published catalogue without signing in; staff see everything.
drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories
  for select to anon, authenticated
  using (is_active or (select private.is_admin()));

drop policy if exists products_read on public.products;
create policy products_read on public.products
  for select to anon, authenticated
  using (status = 'published' or (select private.is_admin()));

drop policy if exists product_images_read on public.product_images;
create policy product_images_read on public.product_images
  for select to anon, authenticated
  using (exists (select 1 from public.products p
                 where p.id = product_id and (p.status = 'published' or (select private.is_admin()))));

drop policy if exists product_variants_read on public.product_variants;
create policy product_variants_read on public.product_variants
  for select to anon, authenticated
  using (exists (select 1 from public.products p
                 where p.id = product_id and (p.status = 'published' or (select private.is_admin()))));

drop policy if exists product_categories_read on public.product_categories;
create policy product_categories_read on public.product_categories
  for select to anon, authenticated
  using (true);

-- Staff write everything in the catalogue.
do $$
declare t text;
begin
  foreach t in array array['categories','products','product_images','product_variants','product_categories']
  loop
    execute format('drop policy if exists %I_admin_write on public.%I', t, t);
    execute format($f$
      create policy %I_admin_write on public.%I
        for all to authenticated
        using ((select private.is_admin()))
        with check ((select private.is_admin()))
    $f$, t, t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('grant select on public.%I to anon', t);
  end loop;
end $$;

-- ── addresses ────────────────────────────────────────────────────────────────
create table if not exists public.addresses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  label       text,
  full_name   text not null,
  phone       text,
  line1       text not null,
  line2       text,
  city        text not null,
  state       text,
  postal_code text,
  country     text not null default 'NG',
  is_default  boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists addresses_user_idx on public.addresses (user_id);
alter table public.addresses enable row level security;

drop policy if exists addresses_own on public.addresses;
create policy addresses_own on public.addresses
  for all to authenticated
  using      (user_id = (select auth.uid()) or (select private.is_admin()))
  with check (user_id = (select auth.uid()));
grant select, insert, update, delete on public.addresses to authenticated;

-- ── cart ─────────────────────────────────────────────────────────────────────
-- Signed-in carts only. Guests keep a cart in the browser and it is merged on
-- login, which avoids granting anonymous visitors write access to any table.
create table if not exists public.carts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null unique references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.cart_items (
  id         uuid primary key default gen_random_uuid(),
  cart_id    uuid not null references public.carts(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  quantity   integer not null default 1 check (quantity > 0 and quantity <= 20),
  added_at   timestamptz not null default now(),
  unique (cart_id, variant_id)
);
create index if not exists cart_items_cart_idx on public.cart_items (cart_id);

alter table public.carts      enable row level security;
alter table public.cart_items enable row level security;

drop policy if exists carts_own on public.carts;
create policy carts_own on public.carts
  for all to authenticated
  using      (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists cart_items_own on public.cart_items;
create policy cart_items_own on public.cart_items
  for all to authenticated
  using      (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())))
  with check (exists (select 1 from public.carts c where c.id = cart_id and c.user_id = (select auth.uid())));

grant select, insert, update, delete on public.carts      to authenticated;
grant select, insert, update, delete on public.cart_items to authenticated;

-- ── orders ───────────────────────────────────────────────────────────────────
create table if not exists public.orders (
  id               uuid primary key default gen_random_uuid(),
  order_number     text not null unique,
  user_id          uuid references auth.users(id) on delete set null,
  email            text,
  status           text not null default 'pending'
                   check (status in ('pending','paid','packed','shipped','delivered','cancelled','refunded')),
  payment_status   text not null default 'unpaid'
                   check (payment_status in ('unpaid','paid','failed','refunded')),
  payment_ref      text,
  payment_provider text,
  currency         text not null default 'NGN',
  subtotal_minor   integer not null default 0 check (subtotal_minor >= 0),
  shipping_minor   integer not null default 0 check (shipping_minor >= 0),
  total_minor      integer not null default 0 check (total_minor >= 0),
  shipping_address jsonb,
  note             text,
  placed_at        timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists orders_user_idx   on public.orders (user_id, placed_at desc);
create index if not exists orders_status_idx on public.orders (status, placed_at desc);

create table if not exists public.order_items (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.orders(id) on delete cascade,
  product_id       uuid references public.products(id)         on delete set null,
  variant_id       uuid references public.product_variants(id) on delete set null,
  product_name     text not null,          -- snapshot
  option_label     text,                   -- snapshot
  image_path       text,                   -- snapshot
  unit_price_minor integer not null check (unit_price_minor >= 0),
  quantity         integer not null check (quantity > 0),
  line_total_minor integer not null check (line_total_minor >= 0)
);
create index if not exists order_items_order_idx on public.order_items (order_id);

alter table public.orders      enable row level security;
alter table public.order_items enable row level security;

-- A customer reads their own orders and never writes them; orders are created
-- by a function that prices them from the database.
drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

drop policy if exists orders_admin_write on public.orders;
create policy orders_admin_write on public.orders
  for update to authenticated
  using      ((select private.is_admin()))
  with check ((select private.is_admin()));

drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items
  for select to authenticated
  using (exists (select 1 from public.orders o
                 where o.id = order_id
                   and (o.user_id = (select auth.uid()) or (select private.is_admin()))));

grant select, update on public.orders      to authenticated;
grant select          on public.order_items to authenticated;

-- ── site settings ────────────────────────────────────────────────────────────
create table if not exists public.site_settings (
  key        text primary key,
  value      text,
  updated_at timestamptz not null default now()
);
alter table public.site_settings enable row level security;

drop policy if exists site_settings_read on public.site_settings;
create policy site_settings_read on public.site_settings
  for select to anon, authenticated using (true);

drop policy if exists site_settings_write on public.site_settings;
create policy site_settings_write on public.site_settings
  for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

grant select on public.site_settings to anon, authenticated;
grant insert, update, delete on public.site_settings to authenticated;

insert into public.site_settings (key, value) values
  ('store_name',       'Rex-Giddoty Hubs'),
  ('currency',         'NGN'),
  ('shipping_flat_minor', '500000'),
  ('free_shipping_over_minor', '20000000'),
  ('hero_heading',     'The New Collection'),
  ('hero_subheading',  'Crafted without compromise'),
  ('maintenance_mode', 'false')
on conflict (key) do nothing;

-- ── product images bucket ────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images','product-images', true, 10485760,
        array['image/jpeg','image/png','image/webp','image/avif'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists product_images_public_read on storage.objects;
create policy product_images_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'product-images');

drop policy if exists product_images_admin_write on storage.objects;
create policy product_images_admin_write on storage.objects
  for all to authenticated
  using      (bucket_id = 'product-images' and (select private.is_admin()))
  with check (bucket_id = 'product-images' and (select private.is_admin()));
