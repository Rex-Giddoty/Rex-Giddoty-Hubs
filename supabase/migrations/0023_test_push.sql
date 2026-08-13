-- A way to prove notifications work without placing an order to find out.
--
-- "I don't see push notifications" has three quite different causes — no
-- subscription on this device, a subscription the push service has retired, or
-- a delivery that failed — and from the outside they look identical. This
-- separates the first from the rest: it says plainly whether the shop has a
-- device to send to, and if it has, it sends to it.

create or replace function public.send_test_push()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  if auth.uid() is null then
    raise exception 'Sign in first.';
  end if;

  select count(*) into n
    from public.push_subscriptions
   where user_id = auth.uid();

  -- Not an error: it is the commonest answer, and the caller needs to tell it
  -- apart from a send that failed.
  if n = 0 then
    return 'no-device';
  end if;

  -- Worded like a real message rather than like a test. Chrome runs an
  -- on-device classifier over notification content and replaces anything it
  -- thinks is spam with a "Possible spam" card of its own — and a notification
  -- whose title is only the site's name, whose body says "test", and which is a
  -- brand new origin's very first send, is close to the shape it looks for.
  -- Everything the shop sends in earnest already names an order and a status;
  -- this now matches.
  perform private.push_to_user(
    auth.uid(),
    'Notifications are on',
    'You will hear from us when an order is packed, shipped and delivered.',
    '/account.html');

  return 'sent';
end
$$;

revoke all on function public.send_test_push() from public, anon;
grant execute on function public.send_test_push() to authenticated;
