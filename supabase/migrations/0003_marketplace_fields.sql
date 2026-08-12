-- Marketplace-style product fields.
-- compare_at_minor is the "was" price: the discount percentage is derived from
-- it rather than stored, so the two can never disagree.
alter table public.products
  add column if not exists compare_at_minor integer check (compare_at_minor is null or compare_at_minor >= 0),
  add column if not exists brand            text,
  add column if not exists rating_avg       numeric(2,1) check (rating_avg is null or (rating_avg >= 0 and rating_avg <= 5)),
  add column if not exists rating_count     integer not null default 0 check (rating_count >= 0),
  add column if not exists badge            text;

create index if not exists products_created_idx on public.products (created_at desc);

insert into public.site_settings (key, value) values
  ('promo_strip',      'Free delivery on orders over ₦200,000 · Pay on confirmation'),
  ('hero_banner_path', ''),
  ('flash_title',      'Flash Sales'),
  ('flash_ends_at',    '')
on conflict (key) do nothing;
