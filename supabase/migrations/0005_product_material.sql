-- Material is its own field rather than a line buried in the details blob, so
-- it can be shown on the product page and, later, filtered on.
alter table public.products
  add column if not exists material text;

-- Below this count the ops list flags the product as running out. Per product,
-- because "low" for a bespoke coat is not "low" for socks.
alter table public.products
  add column if not exists low_stock_at integer not null default 5;

alter table public.products drop constraint if exists products_low_stock_at_sane;
alter table public.products add constraint products_low_stock_at_sane
  check (low_stock_at >= 0 and low_stock_at <= 10000);
