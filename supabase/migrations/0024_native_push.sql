-- Native push, for the Android app.
--
-- The web notification and the native one are different animals. A web push
-- goes to the browser, which posts it and stamps the site's origin underneath —
-- unavoidably, it is an anti-spoofing rule. A native push goes to the app,
-- which posts it itself: the app's name, the app's icon, nothing else attached.
-- Firebase Cloud Messaging carries the second, so a device that has the app
-- registers an FCM token here instead of a push subscription.

create table if not exists public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  -- FCM rotates a token when the app is reinstalled or its data cleared, and
  -- hands the same token to nobody else — so it is the natural key, and a
  -- device signing in as somebody new moves its row rather than duplicating it.
  token      text not null unique,
  platform   text not null default 'android',
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists device_tokens_user_idx on public.device_tokens(user_id);

alter table public.device_tokens enable row level security;

drop policy if exists device_tokens_own on public.device_tokens;
create policy device_tokens_own on public.device_tokens
  for all
  using      (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));


-- ── the sender ────────────────────────────────────────────────────────────
-- App first, browser second, never both. Somebody with the app installed and
-- an old browser subscription still live on the same phone would otherwise be
-- told everything twice, which is a fast way to get an app muted.
-- p_url keeps its default: replacing a function may not drop one, and the
-- callers that rely on it are already in the database.
create or replace function private.push_to_user(
  p_user uuid, p_title text, p_body text, p_url text default '/')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_key text;
  v_native boolean;
begin
  v_native := exists (select 1 from public.device_tokens where user_id = p_user);

  if v_native then
    v_url := private.secret('fcm_function_url');
    v_key := private.secret('fcm_function_key');
  else
    if not exists (select 1 from public.push_subscriptions where user_id = p_user) then
      return;           -- nothing to send to, so nothing to pay for
    end if;
    v_url := private.secret('push_function_url');
    v_key := private.secret('push_function_key');
  end if;

  if v_url is null or v_key is null then
    return;             -- not configured yet; never let this break an order
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_key,
                 'Content-Type',  'application/json'),
    body    := jsonb_build_object(
                 'user_id', p_user,
                 'title',   p_title,
                 'body',    p_body,
                 'url',     p_url));
end;
$$;


-- ── the test button ───────────────────────────────────────────────────────
-- Now that a device can be registered either way, "no device" has to mean
-- neither, or the app would be told it is not set up while it plainly is.
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

  select (select count(*) from public.push_subscriptions where user_id = auth.uid())
       + (select count(*) from public.device_tokens      where user_id = auth.uid())
    into n;

  if n = 0 then
    return 'no-device';
  end if;

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
