-- Staff confirming a transfer.
--
-- admin_set_order_status moves an order along its journey but only ever touches
-- payment_status to record a refund. So there was no way to say "the money
-- arrived" — which is the single most important thing to record while the shop
-- is paid by transfer, and the thing every other status depends on.

create or replace function public.admin_mark_paid(p_order uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o record;
begin
  if not private.is_admin() then
    raise exception 'not authorised';
  end if;

  select * into o from public.orders where id = p_order for update;
  if not found then
    raise exception 'no such order';
  end if;

  if o.payment_status = 'paid' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  update public.orders
     set payment_status   = 'paid',
         payment_provider = coalesce(o.payment_provider, 'transfer'),
         -- Only moves a pending order forward. An order already packed or
         -- shipped keeps where it is; confirming late must not send it
         -- backwards.
         status           = case when o.status = 'pending' then 'paid' else o.status end,
         updated_at       = now()
   where id = p_order;

  -- Who said so, and when. A transfer confirmed by hand has no provider record
  -- behind it, so this is the only trace it happened.
  insert into private.payment_events(id, provider, event, reference, order_id, amount_minor, payload)
  values (p_order::text || ':manual:' || extract(epoch from now())::bigint,
          'transfer', 'manual.confirmed', o.payment_ref, p_order, o.total_minor,
          jsonb_build_object('by', auth.uid(), 'note', p_note))
  on conflict (id) do nothing;

  return jsonb_build_object('ok', true, 'order_number', o.order_number);
end;
$$;

revoke all on function public.admin_mark_paid(uuid, text) from public, anon;
grant execute on function public.admin_mark_paid(uuid, text) to authenticated;
