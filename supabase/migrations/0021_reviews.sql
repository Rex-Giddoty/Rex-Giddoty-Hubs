-- Rex-Giddoty Hubs — reviews, from people who actually bought the thing
--
-- rating_avg and rating_count already exist on products and are already shown
-- as stars. Until now nothing wrote them. Reviews do, through a trigger, so the
-- stars and the reviews underneath them can never disagree.
--
-- Eligibility is the whole point: a review can only be written by someone with
-- an order line for that product, and only once per product per customer. Both
-- are enforced in the database rather than in the page, so neither depends on
-- what a browser chose to send.

create table if not exists public.product_reviews (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  order_id   uuid references public.orders(id) on delete set null,
  rating     integer not null check (rating between 1 and 5),
  body       text check (body is null or length(btrim(body)) <= 2000),
  is_visible boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One voice per customer per product. Changing your mind edits the review you
-- already left rather than adding a second one.
create unique index if not exists product_reviews_one_each
  on public.product_reviews (product_id, user_id);
create index if not exists product_reviews_product
  on public.product_reviews (product_id, created_at desc);

alter table public.product_reviews enable row level security;

-- Everyone reads the visible ones — reviews are the point of reviews. A
-- customer also sees their own while it is hidden, so it does not appear to
-- have vanished; staff see everything.
drop policy if exists product_reviews_read on public.product_reviews;
create policy product_reviews_read on public.product_reviews
  for select to anon, authenticated
  using (is_visible
         or user_id = (select auth.uid())
         or (select private.is_admin()));

-- No insert or update policy: writing goes through the function below, which
-- is what makes "only if you bought it" true rather than merely intended.

-- ── has this person bought it ────────────────────────────────────────────────
create or replace function public.can_review(p_product uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where oi.product_id = p_product
       and o.user_id = (select auth.uid())
       and o.status <> 'cancelled'
  );
$$;

revoke execute on function public.can_review(uuid) from public, anon;
grant  execute on function public.can_review(uuid) to authenticated;

-- ── writing one ──────────────────────────────────────────────────────────────
/* p_body defaults, so a call that omits it still resolves rather than looking
   like a missing function. */
create or replace function public.submit_review(p_product uuid, p_rating integer, p_body text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := (select auth.uid());
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
  v_ord  uuid;
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'You must be signed in to leave a review';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'Choose a rating from 1 to 5 stars';
  end if;
  if length(coalesce(v_body, '')) > 2000 then
    raise exception 'That review is too long';
  end if;

  /* The order is recorded on the review so a "verified purchase" mark means
     something specific rather than being taken on trust. */
  select o.id into v_ord
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
   where oi.product_id = p_product
     and o.user_id = v_uid
     and o.status <> 'cancelled'
   order by o.placed_at
   limit 1;

  if v_ord is null then
    raise exception 'Reviews are for items you have bought from us';
  end if;

  insert into public.product_reviews (product_id, user_id, order_id, rating, body)
  values (p_product, v_uid, v_ord, p_rating, v_body)
  on conflict (product_id, user_id) do update
    set rating = excluded.rating,
        body = excluded.body,
        updated_at = now()
  returning id into v_id;

  return v_id;
end; $$;

revoke execute on function public.submit_review(uuid, integer, text) from public, anon;
grant  execute on function public.submit_review(uuid, integer, text) to authenticated;

create or replace function public.delete_my_review(p_product uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.product_reviews
   where product_id = p_product and user_id = (select auth.uid());
$$;

revoke execute on function public.delete_my_review(uuid) from public, anon;
grant  execute on function public.delete_my_review(uuid) to authenticated;

-- ── the stars follow the reviews ─────────────────────────────────────────────
-- Recomputed from scratch rather than nudged up and down: an average kept by
-- arithmetic on every change drifts, and this runs on a handful of rows.
create or replace function private.recount_reviews()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_pid uuid := coalesce(new.product_id, old.product_id);
begin
  update public.products p
     set rating_avg = r.avg_rating,
         rating_count = r.n
    from (select round(avg(rating)::numeric, 1) as avg_rating, count(*)::integer as n
            from public.product_reviews
           where product_id = v_pid and is_visible) r
   where p.id = v_pid;

  /* No visible reviews means no stars at all, rather than a stale average from
     the ones that were hidden. */
  update public.products
     set rating_avg = null, rating_count = 0
   where id = v_pid
     and not exists (select 1 from public.product_reviews
                      where product_id = v_pid and is_visible);
  return null;
end; $$;

drop trigger if exists trg_reviews_recount on public.product_reviews;
create trigger trg_reviews_recount
  after insert or update or delete on public.product_reviews
  for each row execute function private.recount_reviews();

-- ── what the shop and the shopper read ───────────────────────────────────────
-- Reviews carry a user_id, and profiles are readable only by their owner and by
-- staff, so a name has to be joined on this side of the fence. First name only:
-- a review is not a reason to publish somebody's full name to the internet.
create or replace function public.product_reviews_public(p_product uuid)
returns table(
  id uuid, rating integer, body text, created_at timestamptz,
  author text, verified boolean, mine boolean
)
language sql stable security definer set search_path = '' as $$
  select r.id, r.rating, r.body, r.created_at,
         coalesce(nullif(split_part(coalesce(p.full_name, ''), ' ', 1), ''), 'Customer'),
         (r.order_id is not null),
         (r.user_id = (select auth.uid()))
    from public.product_reviews r
    left join public.profiles p on p.id = r.user_id
   where r.product_id = p_product
     and (r.is_visible or r.user_id = (select auth.uid()))
   order by (r.user_id = (select auth.uid())) desc, r.created_at desc;
$$;

grant execute on function public.product_reviews_public(uuid) to anon, authenticated;

-- ── the shop's side ──────────────────────────────────────────────────────────
create or replace function public.admin_list_reviews()
returns table(
  id uuid, product_id uuid, product_name text, product_slug text,
  rating integer, body text, created_at timestamptz,
  is_visible boolean, author text, email text
)
language sql stable security definer set search_path = '' as $$
  select r.id, r.product_id, pr.name, pr.slug, r.rating, r.body, r.created_at,
         r.is_visible, coalesce(p.full_name, 'Customer'), p.email
    from public.product_reviews r
    join public.products pr on pr.id = r.product_id
    left join public.profiles p on p.id = r.user_id
   where (select private.is_admin())
   order by r.created_at desc;
$$;

revoke execute on function public.admin_list_reviews() from public, anon;
grant  execute on function public.admin_list_reviews() to authenticated;

create or replace function public.admin_set_review_visible(p_review uuid, p_visible boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  update public.product_reviews set is_visible = p_visible, updated_at = now()
   where id = p_review;
end; $$;

revoke execute on function public.admin_set_review_visible(uuid, boolean) from public, anon;
grant  execute on function public.admin_set_review_visible(uuid, boolean) to authenticated;

-- ── tell the shop a review landed ────────────────────────────────────────────
create or replace function private.on_review_created()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_alert text;
  v_name  text;
  v_prod  text;
begin
  select value into v_alert from public.site_settings where key = 'order_alert_email';
  if coalesce(v_alert, '') = '' then
    select value into v_alert from public.site_settings where key = 'support_email';
  end if;

  select coalesce(p.full_name, p.email, 'A customer') into v_name
    from public.profiles p where p.id = new.user_id;
  select name into v_prod from public.products where id = new.product_id;

  perform private.send_email(v_alert,
    repeat('★', new.rating) || ' review — ' || coalesce(v_prod, 'an item'),
    private.email_shell('A customer left a review',
         '<p style="margin:0 0 16px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
      || '<b>' || coalesce(v_name, 'A customer') || '</b> rated <b>'
      || coalesce(v_prod, 'an item') || '</b> ' || new.rating || ' out of 5.</p>'
      || case when new.body is null then '' else
           '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
        || 'style="background:#f6f2fb;border-left:3px solid #9030d0;border-radius:0 4px 4px 0;">'
        || '<tr><td style="padding:13px 15px;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.6;">'
        || replace(replace(replace(new.body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
        || '</td></tr></table>' end
      || '<p style="margin:16px 0 0;font:14px Arial,Helvetica,sans-serif;color:#282828;line-height:1.7;">'
      || 'It is live on the item now. Hide it from the Reviews tab if it should not be.</p>'));
  return new;
end; $$;

drop trigger if exists trg_review_created on public.product_reviews;
create trigger trg_review_created
  after insert on public.product_reviews
  for each row execute function private.on_review_created();
