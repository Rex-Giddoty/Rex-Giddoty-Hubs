-- Rex-Giddoty Hubs — customer administration
--
-- profiles is readable by its owner and by staff, but the things ops actually
-- needs — last sign-in, whether an account is blocked — live in auth.users,
-- which PostgREST will not expose. These definer functions are the seam.

-- ── the list ─────────────────────────────────────────────────────────────────
create or replace function public.admin_list_customers()
returns table(
  id                 uuid,
  email              text,
  full_name          text,
  phone              text,
  created_at         timestamptz,
  last_sign_in_at    timestamptz,
  email_confirmed    boolean,
  is_blocked         boolean,
  is_staff           boolean,
  orders_count       integer,
  orders_total_minor bigint,
  last_order_at      timestamptz,
  addresses_count    integer
)
language sql security definer stable set search_path = '' as $$
  select
    p.id,
    p.email,
    p.full_name,
    p.phone,
    p.created_at,
    u.last_sign_in_at,
    (u.email_confirmed_at is not null),
    (u.banned_until is not null and u.banned_until > now()),
    exists (select 1 from public.admin_users a where a.id = p.id),
    coalesce(o.cnt, 0)::integer,
    coalesce(o.total, 0)::bigint,
    o.last_at,
    coalesce(ad.cnt, 0)::integer
  from public.profiles p
  join auth.users u on u.id = p.id
  left join lateral (
    /* Cancelled orders are excluded from the spend so the number means money
       actually committed, not gestures. */
    select count(*) as cnt, sum(total_minor) as total, max(placed_at) as last_at
      from public.orders
     where user_id = p.id and status <> 'cancelled'
  ) o on true
  left join lateral (
    select count(*) as cnt from public.addresses where user_id = p.id
  ) ad on true
  where (select private.is_admin())     -- non-staff simply get an empty list
  order by p.created_at desc;
$$;

revoke execute on function public.admin_list_customers() from public, anon;
grant  execute on function public.admin_list_customers() to authenticated;

-- ── blocking ─────────────────────────────────────────────────────────────────
-- banned_until is what Supabase itself checks, so this refuses a sign-in rather
-- than just hiding a flag in our own tables. Live sessions are dropped too, or
-- a blocked customer would keep browsing until their token expired.
create or replace function public.admin_set_customer_blocked(p_user uuid, p_blocked boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  if p_user = (select auth.uid()) then
    raise exception 'You cannot block your own account';
  end if;
  if exists (select 1 from public.admin_users where id = p_user) then
    raise exception 'That account is staff. Remove their admin access first';
  end if;

  update auth.users
     set banned_until = case when p_blocked then now() + interval '100 years' else null end
   where id = p_user;

  if not found then
    raise exception 'No such customer';
  end if;

  if p_blocked then
    delete from auth.sessions where user_id = p_user;
  end if;
end; $$;

revoke execute on function public.admin_set_customer_blocked(uuid, boolean) from public, anon;
grant  execute on function public.admin_set_customer_blocked(uuid, boolean) to authenticated;

-- ── deleting ─────────────────────────────────────────────────────────────────
-- orders.user_id is SET NULL, so the order history survives the customer with
-- its own email and address snapshots. Everything personal — profile, saved
-- addresses, cart, sessions — cascades away.
create or replace function public.admin_delete_customer(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  if p_user = (select auth.uid()) then
    raise exception 'You cannot delete your own account';
  end if;
  if exists (select 1 from public.admin_users where id = p_user) then
    raise exception 'That account is staff. Remove their admin access first';
  end if;

  delete from auth.users where id = p_user;

  if not found then
    raise exception 'No such customer';
  end if;
end; $$;

revoke execute on function public.admin_delete_customer(uuid) from public, anon;
grant  execute on function public.admin_delete_customer(uuid) to authenticated;
