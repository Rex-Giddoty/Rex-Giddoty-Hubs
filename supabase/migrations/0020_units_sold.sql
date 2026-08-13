-- Rex-Giddoty Hubs — units sold, shown on the item
--
-- Typed by the shop rather than counted from orders, deliberately: a shop like
-- this sells across a counter, on Instagram and through here, and the number a
-- shopper cares about is how many of the thing have gone, not how many went
-- through this particular till. The ops editor shows the count from real orders
-- beside the field so the two can be compared.

alter table public.products
  add column if not exists sold_count integer not null default 0;

alter table public.products drop constraint if exists products_sold_count_sane;
alter table public.products add constraint products_sold_count_sane
  check (sold_count >= 0 and sold_count <= 100000000);
