-- Store balance.
--
-- Money the shop is holding is the one thing here that must never be wrong, so
-- there is no balance column anywhere. There is a ledger of entries that are
-- only ever inserted, and the balance is their sum. A stored number can drift
-- from its history — through a failed update, a race, a well-meaning fix — and
-- once it has, there is no way to tell which of the two is lying.
--
-- Credit spends here and nowhere else. Nothing withdraws it, so the shop owes
-- goods rather than money, which is a very different thing to be holding.

create table if not exists public.wallet_entries (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  -- Positive puts money in, negative takes it out. One column, so a balance is
  -- a sum and can never disagree with itself about direction.
  amount_minor bigint not null,
  kind         text not null check (kind in ('topup','spend','refund','adjustment')),
  order_id     uuid references public.orders(id) on delete set null,
  reference    text,
  note         text,
  created_by   uuid,                       -- staff, for an adjustment
  created_at   timestamptz not null default now(),

  constraint wallet_amount_not_zero check (amount_minor <> 0),
  -- Direction has to match the kind, or a "topup" could quietly take money out.
  constraint wallet_direction check (
    (kind in ('topup','refund')     and amount_minor > 0) or
    (kind = 'spend'                 and amount_minor < 0) or
    (kind = 'adjustment')
  )
);

create index if not exists wallet_entries_user_idx on public.wallet_entries(user_id, created_at desc);
-- One spend per order, enforced by the database rather than by remembering to
-- check: paying the same order from the balance twice is the expensive mistake.
create unique index if not exists wallet_one_spend_per_order
  on public.wallet_entries(order_id) where kind = 'spend';

alter table public.wallet_entries enable row level security;

-- Read your own. Nobody writes directly — every entry comes from a function
-- below, so there is no path where a browser decides its own balance.
drop policy if exists wallet_read_own on public.wallet_entries;
create policy wallet_read_own on public.wallet_entries
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));


-- ── the balance ───────────────────────────────────────────────────────────
create or replace function private.wallet_balance(p_user uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(amount_minor), 0)::bigint
    from public.wallet_entries where user_id = p_user;
$$;

create or replace function public.my_balance()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select private.wallet_balance((select auth.uid()));
$$;

revoke all on function public.my_balance() from public, anon;
grant execute on function public.my_balance() to authenticated;


-- ── spending it ───────────────────────────────────────────────────────────
create or replace function public.pay_order_from_balance(p_order uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  o     record;
  bal   bigint;
begin
  if v_uid is null then
    raise exception 'You must be signed in';
  end if;

  -- Taken before the balance is read, and held to the end of the transaction.
  -- Two taps on a slow connection would otherwise both read the same balance
  -- and both decide there was enough.
  perform pg_advisory_xact_lock(hashtext('wallet:' || v_uid::text));

  select * into o from public.orders where id = p_order for update;
  if not found or o.user_id <> v_uid then
    raise exception 'No such order';
  end if;
  if o.payment_status = 'paid' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if o.status in ('cancelled','refunded') then
    raise exception 'That order is closed';
  end if;

  bal := private.wallet_balance(v_uid);
  if bal < o.total_minor then
    return jsonb_build_object('ok', false, 'why', 'not enough',
                              'balance', bal, 'needed', o.total_minor);
  end if;

  insert into public.wallet_entries(user_id, amount_minor, kind, order_id, note)
  values (v_uid, -o.total_minor, 'spend', o.id, 'Order ' || o.order_number);

  update public.orders
     set payment_status   = 'paid',
         payment_provider = 'balance',
         status           = case when status = 'pending' then 'paid' else status end,
         updated_at       = now()
   where id = o.id;

  return jsonb_build_object('ok', true, 'order_number', o.order_number,
                            'balance', private.wallet_balance(v_uid));
end;
$$;

revoke all on function public.pay_order_from_balance(uuid) from public, anon;
grant execute on function public.pay_order_from_balance(uuid) to authenticated;


-- ── putting money in ──────────────────────────────────────────────────────
-- Staff credit a balance once they have seen the transfer land. The same
-- function is what Paystack will call later; only who is trusted to call it
-- changes, not what it does.
create or replace function public.admin_credit_balance(
  p_user uuid, p_amount_minor bigint, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'Amount must be more than zero';
  end if;

  insert into public.wallet_entries(user_id, amount_minor, kind, note, created_by)
  values (p_user, p_amount_minor, 'topup', p_note, (select auth.uid()));

  return jsonb_build_object('ok', true, 'balance', private.wallet_balance(p_user));
end;
$$;

revoke all on function public.admin_credit_balance(uuid, bigint, text) from public, anon;
grant execute on function public.admin_credit_balance(uuid, bigint, text) to authenticated;


-- Taking it back off, for a mistake or a chargeback. Allowed to send a balance
-- negative rather than refusing: pretending it did not happen would leave the
-- shop's books saying something untrue.
create or replace function public.admin_debit_balance(
  p_user uuid, p_amount_minor bigint, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'Amount must be more than zero';
  end if;

  insert into public.wallet_entries(user_id, amount_minor, kind, note, created_by)
  values (p_user, -p_amount_minor, 'adjustment', p_note, (select auth.uid()));

  return jsonb_build_object('ok', true, 'balance', private.wallet_balance(p_user));
end;
$$;

revoke all on function public.admin_debit_balance(uuid, bigint, text) from public, anon;
grant execute on function public.admin_debit_balance(uuid, bigint, text) to authenticated;


-- ── a cancelled order gives the money back ────────────────────────────────
-- Only what was actually taken from the balance, and only once.
create or replace function private.on_order_refund_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_spent bigint;
begin
  if new.status not in ('cancelled','refunded') or old.status in ('cancelled','refunded') then
    return new;
  end if;

  select -amount_minor into v_spent
    from public.wallet_entries
   where order_id = new.id and kind = 'spend';

  if v_spent is null then
    return new;                       -- it was not paid from the balance
  end if;

  if exists (select 1 from public.wallet_entries
              where order_id = new.id and kind = 'refund') then
    return new;                       -- already given back
  end if;

  insert into public.wallet_entries(user_id, amount_minor, kind, order_id, note)
  values (new.user_id, v_spent, 'refund', new.id,
          'Refund for ' || new.order_number);

  return new;
end;
$$;

drop trigger if exists trg_order_refund_balance on public.orders;
create trigger trg_order_refund_balance
  after update of status on public.orders
  for each row execute function private.on_order_refund_balance();
