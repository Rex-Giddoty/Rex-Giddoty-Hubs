-- Every wallet path, against a throwaway order, with triggers off so no
-- customer is notified about a test. Rolled back at the end: nothing here
-- should survive.
begin;
set local session_replication_role = replica;
-- auth.uid() reads this; without it every function here refuses the caller.
set local request.jwt.claims = '{"sub":"ae39e4af-57b9-4beb-9583-6413cd5bb6da","role":"authenticated"}';

create temp table res(step text, got jsonb) on commit drop;

-- a disposable order for the test account
insert into public.orders(order_number, user_id, email, status, payment_status, currency,
                          subtotal_minor, shipping_minor, total_minor, shipping_address, placed_at)
values ('TEST-WALLET-1', 'ae39e4af-57b9-4beb-9583-6413cd5bb6da', 'jaygrey797@gmail.com',
        'pending', 'unpaid', 'NGN', 500000, 0, 500000, '{}'::jsonb, now());

insert into res
select 'balance starts at', to_jsonb(private.wallet_balance('ae39e4af-57b9-4beb-9583-6413cd5bb6da'));

-- not enough money
insert into res
select 'pay with empty balance', public.pay_order_from_balance(
  (select id from public.orders where order_number='TEST-WALLET-1'));

-- put some in, but not enough
insert into public.wallet_entries(user_id, amount_minor, kind, note)
values ('ae39e4af-57b9-4beb-9583-6413cd5bb6da', 300000, 'topup', 'test');

insert into res
select 'pay with 3,000 of 5,000', public.pay_order_from_balance(
  (select id from public.orders where order_number='TEST-WALLET-1'));

-- top up the rest
insert into public.wallet_entries(user_id, amount_minor, kind, note)
values ('ae39e4af-57b9-4beb-9583-6413cd5bb6da', 250000, 'topup', 'test');

insert into res
select 'balance now', to_jsonb(private.wallet_balance('ae39e4af-57b9-4beb-9583-6413cd5bb6da'));

insert into res
select 'pay with 5,500', public.pay_order_from_balance(
  (select id from public.orders where order_number='TEST-WALLET-1'));

insert into res
select 'balance after paying', to_jsonb(private.wallet_balance('ae39e4af-57b9-4beb-9583-6413cd5bb6da'));

insert into res
select 'order state', to_jsonb(row(o.status, o.payment_status, o.payment_provider))
  from public.orders o where o.order_number='TEST-WALLET-1';

-- paying again must not take the money twice
insert into res
select 'pay the same order again', public.pay_order_from_balance(
  (select id from public.orders where order_number='TEST-WALLET-1'));

insert into res
select 'balance unchanged', to_jsonb(private.wallet_balance('ae39e4af-57b9-4beb-9583-6413cd5bb6da'));

-- cancelling gives it back, once
set local session_replication_role = default;   -- the refund trigger must fire
update public.orders set status='cancelled' where order_number='TEST-WALLET-1';
set local session_replication_role = replica;

insert into res
select 'balance after cancelling', to_jsonb(private.wallet_balance('ae39e4af-57b9-4beb-9583-6413cd5bb6da'));

insert into res
select 'refund entries', to_jsonb(count(*))
  from public.wallet_entries w
  join public.orders o on o.id = w.order_id
 where o.order_number='TEST-WALLET-1' and w.kind='refund';

-- and a second cancel must not refund again
set local session_replication_role = default;
update public.orders set status='refunded' where order_number='TEST-WALLET-1';
set local session_replication_role = replica;

insert into res
select 'balance after second close', to_jsonb(private.wallet_balance('ae39e4af-57b9-4beb-9583-6413cd5bb6da'));

select step, got from res;
rollback;
