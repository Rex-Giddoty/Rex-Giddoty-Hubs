-- Telling a customer their balance moved.
--
-- Money going into an account is the one change here that happens without the
-- customer doing anything — staff credit it after a transfer lands, or Paystack
-- will later. Nobody refreshes a balance page hoping. So it says so.
--
-- Spending is deliberately silent: they were standing at the checkout when it
-- happened and the order tells them anyway.

create or replace function private.on_wallet_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sym text;
  v_bal bigint;
  v_amt text;
  v_now text;
begin
  if new.kind = 'spend' then
    return new;
  end if;

  select case value when 'NGN' then '₦' when 'USD' then '$' when 'GBP' then '£'
                    when 'EUR' then '€' else coalesce(value, '') || ' ' end
    into v_sym
    from public.site_settings where key = 'currency';
  v_sym := coalesce(v_sym, '₦');

  v_bal := private.wallet_balance(new.user_id);
  v_amt := v_sym || to_char(abs(new.amount_minor) / 100.0, 'FM999G999G990D00');
  v_now := v_sym || to_char(v_bal / 100.0, 'FM999G999G990D00');

  if new.amount_minor > 0 then
    perform private.push_to_user(
      new.user_id,
      case new.kind
        when 'refund' then 'Refunded to your balance'
        else 'Money added to your balance'
      end,
      v_amt || ' added. Your balance is now ' || v_now || '.',
      '/account.html#balance');
  else
    -- Money coming off is worth saying plainly rather than hoping it is not
    -- noticed. A customer who finds out by discovering they cannot buy
    -- something has been told the worst possible way.
    perform private.push_to_user(
      new.user_id,
      'Your balance was adjusted',
      v_amt || ' taken off. Your balance is now ' || v_now || '.',
      '/account.html#balance');
  end if;

  return new;
end;
$$;

drop trigger if exists trg_wallet_entry on public.wallet_entries;
create trigger trg_wallet_entry
  after insert on public.wallet_entries
  for each row execute function private.on_wallet_entry();
