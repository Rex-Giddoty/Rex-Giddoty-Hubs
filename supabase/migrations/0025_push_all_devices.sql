-- Every device a person is signed in on, not just the best one.
--
-- 0024 sent to the app if there was an app and to the browser otherwise. That
-- was aimed at one specific nuisance: a phone that has the Android app *and*
-- an old Chrome subscription of its own gets told everything twice. But it
-- solved that by silencing whole devices — an iPhone on the Home Screen goes
-- through the browser path, so the moment the same account registered the
-- Android app, the iPhone went quiet.
--
-- Silencing a real device to avoid a duplicate on another one is the worse
-- trade. Both channels now fire. The original nuisance is dealt with where it
-- actually lives: turn notifications off in Chrome on the phone that also has
-- the app, once, from Account — which deletes that subscription for good.

create or replace function private.push_to_user(
  p_user uuid, p_title text, p_body text, p_url text default '/')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url  text;
  v_key  text;
  v_body jsonb;
begin
  v_body := jsonb_build_object(
              'user_id', p_user,
              'title',   p_title,
              'body',    p_body,
              'url',     p_url);

  -- the app, through Firebase
  if exists (select 1 from public.device_tokens where user_id = p_user) then
    v_url := private.secret('fcm_function_url');
    v_key := private.secret('fcm_function_key');
    if v_url is not null and v_key is not null then
      perform net.http_post(
        url     := v_url,
        headers := jsonb_build_object(
                     'Authorization', 'Bearer ' || v_key,
                     'Content-Type',  'application/json'),
        body    := v_body);
    end if;
  end if;

  -- the browser, and an iPhone on the Home Screen, through Web Push
  if exists (select 1 from public.push_subscriptions where user_id = p_user) then
    v_url := private.secret('push_function_url');
    v_key := private.secret('push_function_key');
    if v_url is not null and v_key is not null then
      perform net.http_post(
        url     := v_url,
        headers := jsonb_build_object(
                     'Authorization', 'Bearer ' || v_key,
                     'Content-Type',  'application/json'),
        body    := v_body);
    end if;
  end if;
end;
$$;
