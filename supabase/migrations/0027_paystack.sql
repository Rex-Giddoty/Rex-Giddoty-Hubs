-- Paystack: taking the money, and believing it only when the bank says so.
--
-- Nothing a browser sends is trusted here. The amount is read from the order in
-- this database, the confirmation is checked against Paystack's own signature,
-- and settling is done inside one locked statement so the same payment arriving
-- twice cannot be counted twice. A webhook is retried by Paystack until it gets
-- a 200, so "twice" is the normal case, not the edge case.

create table if not exists private.payment_events (
  id           text primary key,      -- provider's event id, or reference+event
  provider     text not null default 'paystack',
  event        text not null,
  reference    text,
  order_id     uuid,
  amount_minor bigint,
  payload      jsonb,
  received_at  timestamptz not null default now()
);

comment on table private.payment_events is
  'Every provider callback, kept for audit and to make settling idempotent. In private: it holds customer emails and provider payloads, and nothing carrying the anon key may read it.';

create index if not exists payment_events_ref_idx on private.payment_events(reference);


-- ── settling ──────────────────────────────────────────────────────────────
-- Called only by the edge function, which holds the service role. Returns what
-- happened rather than raising, so a webhook can be answered 200 and not
-- retried for ever over a decision that will never change.
create or replace function public.paystack_settle(
  p_reference    text,
  p_amount_minor bigint,
  p_currency     text,
  p_event_id     text default null,
  p_payload      jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o record;
begin
  -- Locked, so two copies of the same webhook cannot both decide to update.
  select * into o
    from public.orders
   where payment_ref = p_reference
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'why', 'no order for that reference');
  end if;

  -- Recorded whatever we decide next, including the refusals: a mismatched
  -- amount is the one thing worth being able to look up later.
  insert into private.payment_events(id, provider, event, reference, order_id, amount_minor, payload)
  values (coalesce(p_event_id, p_reference || ':settle'), 'paystack', 'charge.success',
          p_reference, o.id, p_amount_minor, p_payload)
  on conflict (id) do nothing;

  if o.payment_status = 'paid' then
    -- Already done. Not an error: Paystack retries until it is told 200, and
    -- the customer's own return from the payment page settles it too.
    return jsonb_build_object('ok', true, 'already', true, 'order_number', o.order_number);
  end if;

  if upper(coalesce(p_currency, '')) <> upper(coalesce(o.currency, 'NGN')) then
    return jsonb_build_object('ok', false, 'why', 'currency mismatch');
  end if;

  -- Underpaid stays unpaid. Overpaid is accepted — refunding a customer who
  -- sent too much is a conversation, not a reason to hold their order.
  if p_amount_minor < o.total_minor then
    return jsonb_build_object('ok', false, 'why', 'amount short',
                              'expected', o.total_minor, 'got', p_amount_minor);
  end if;

  update public.orders
     set payment_status   = 'paid',
         payment_provider = 'paystack',
         status           = case when status in ('pending') then 'paid' else status end,
         updated_at       = now()
   where id = o.id;

  return jsonb_build_object('ok', true, 'order_number', o.order_number, 'order_id', o.id);
end;
$$;

-- The service role only. Nothing carrying the anon key may settle its own order.
revoke all on function public.paystack_settle(text, bigint, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.paystack_settle(text, bigint, text, text, jsonb) to service_role;


-- ── starting ──────────────────────────────────────────────────────────────
-- Attaches the reference the provider will quote back at us. Same restriction:
-- the edge function does this, never the browser.
create or replace function public.paystack_attach_ref(p_order uuid, p_ref text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.orders
     set payment_ref = p_ref, payment_provider = 'paystack', updated_at = now()
   where id = p_order and payment_status <> 'paid';
$$;

revoke all on function public.paystack_attach_ref(uuid, text) from public, anon, authenticated;
grant execute on function public.paystack_attach_ref(uuid, text) to service_role;


-- ── every reference an order has ever had ─────────────────────────────────
-- Paystack refuses a repeated reference, so a customer who abandons a payment
-- and starts again gets a new one. Keeping only the latest on the order would
-- orphan a payment made against the earlier one — the money arrives and nothing
-- matches it. Every reference issued is remembered and any of them settles.
create table if not exists private.payment_refs (
  reference  text primary key,
  order_id   uuid not null references public.orders(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists payment_refs_order_idx on private.payment_refs(order_id);

create or replace function public.paystack_attach_ref(p_order uuid, p_ref text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.payment_refs(reference, order_id)
  values (p_ref, p_order)
  on conflict (reference) do nothing;

  update public.orders
     set payment_ref = p_ref, payment_provider = 'paystack', updated_at = now()
   where id = p_order and payment_status <> 'paid';
end;
$$;

revoke all on function public.paystack_attach_ref(uuid, text) from public, anon, authenticated;
grant execute on function public.paystack_attach_ref(uuid, text) to service_role;

create or replace function public.paystack_settle(
  p_reference    text,
  p_amount_minor bigint,
  p_currency     text,
  p_event_id     text default null,
  p_payload      jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o record;
begin
  -- Any reference this order has ever been issued, not only its latest.
  select ord.* into o
    from public.orders ord
   where ord.id = (select r.order_id from private.payment_refs r where r.reference = p_reference)
      or ord.payment_ref = p_reference
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'why', 'no order for that reference');
  end if;

  insert into private.payment_events(id, provider, event, reference, order_id, amount_minor, payload)
  values (coalesce(p_event_id, p_reference || ':settle'), 'paystack', 'charge.success',
          p_reference, o.id, p_amount_minor, p_payload)
  on conflict (id) do nothing;

  if o.payment_status = 'paid' then
    return jsonb_build_object('ok', true, 'already', true, 'order_number', o.order_number);
  end if;

  if upper(coalesce(p_currency, '')) <> upper(coalesce(o.currency, 'NGN')) then
    return jsonb_build_object('ok', false, 'why', 'currency mismatch');
  end if;

  if p_amount_minor < o.total_minor then
    return jsonb_build_object('ok', false, 'why', 'amount short',
                              'expected', o.total_minor, 'got', p_amount_minor);
  end if;

  update public.orders
     set payment_status   = 'paid',
         payment_provider = 'paystack',
         status           = case when status in ('pending') then 'paid' else status end,
         updated_at       = now()
   where id = o.id;

  return jsonb_build_object('ok', true, 'order_number', o.order_number, 'order_id', o.id);
end;
$$;

revoke all on function public.paystack_settle(text, bigint, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.paystack_settle(text, bigint, text, text, jsonb) to service_role;
