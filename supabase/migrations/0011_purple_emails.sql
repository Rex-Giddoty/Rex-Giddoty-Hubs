-- Rex-Giddoty Hubs — the emails follow the site to purple
--
-- Only the two accent colours change: buttons and the footer link. Everything
-- structural stays as it was, so this is a recolour rather than a rewrite.

create or replace function private.email_shell(p_title text, p_body text)
returns text language sql stable set search_path = '' as $$
  select
     '<!DOCTYPE html><html><head><meta charset="utf-8"/>'
  || '<meta name="viewport" content="width=device-width,initial-scale=1"/>'
  || '<title>' || p_title || '</title></head>'
  || '<body style="margin:0;padding:0;background:#f1f1f2;">'
  || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
  ||   'style="background:#f1f1f2;padding:24px 12px;">'
  || '<tr><td align="center">'
  || '<table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" '
  ||   'style="width:100%;max-width:560px;background:#ffffff;border-radius:8px;overflow:hidden;">'

  || '<tr><td align="center" style="background:#282828;padding:26px 20px;">'
  || '<img src="https://rexgiddotyhubs.shop/assets/logo.png" width="190" '
  ||   'alt="Rex Giddoty Hub$ UNLIMITED" '
  ||   'style="display:block;border:0;width:190px;max-width:70%;height:auto;"/>'
  || '</td></tr>'

  || '<tr><td style="padding:26px 24px 8px;">'
  || '<h1 style="margin:0 0 14px;font:600 19px Arial,Helvetica,sans-serif;color:#282828;">'
  || p_title || '</h1>'
  || p_body
  || '</td></tr>'

  || '<tr><td style="padding:18px 24px 24px;">'
  || '<p style="margin:0 0 16px;font:13px Arial,Helvetica,sans-serif;color:#7a7a7a;line-height:1.6;">'
  || 'This is an automatic email from Rex Giddoty Hubs. Please do not reply to this email. '
  || 'You can contact us at '
  || '<a href="mailto:rexgiddotyhubs@gmail.com" style="color:#9030d0;text-decoration:none;">'
  || 'rexgiddotyhubs@gmail.com</a>.</p>'
  || '<p style="margin:0;font:13px Arial,Helvetica,sans-serif;color:#7a7a7a;line-height:1.7;">'
  || 'Warm regards,<br/>'
  || '<b style="color:#282828;font-size:14px;">Rex Giddoty Hubs</b><br/>'
  || 'Customer Care</p>'
  || '</td></tr>'

  || '<tr><td align="center" style="background:#282828;padding:20px 24px;">'
  || '<p style="margin:0 0 6px;font:13px Arial,Helvetica,sans-serif;color:#c9c9c9;">'
  || 'Rex Giddoty Hubs Unlimited &middot; Clothing, Bags, Shoes &amp; Accessories</p>'
  || '<p style="margin:0 0 6px;font:13px Arial,Helvetica,sans-serif;color:#c9c9c9;">'
  --  purple reads well enough on the dark band, and now matches the site
  || '<a href="https://rexgiddotyhubs.shop" style="color:#b06ae0;text-decoration:none;">'
  || 'rexgiddotyhubs.shop</a>'
  || ' &nbsp;&middot;&nbsp; '
  || '<a href="mailto:rexgiddotyhubs@gmail.com" style="color:#c9c9c9;text-decoration:none;">'
  || 'Contact us</a></p>'
  || '<p style="margin:0;font:12px Arial,Helvetica,sans-serif;color:#8a8a8a;">'
  || '&copy; ' || to_char(now(), 'YYYY') || ' Rex Giddoty Hubs. All rights reserved.</p>'
  || '</td></tr>'

  || '</table></td></tr></table></body></html>';
$$;

-- The call-to-action buttons live inside the trigger functions, so they are
-- swapped with a straight replace on the stored source rather than by pasting
-- both functions out again.
do $$
declare
  v_src text;
begin
  foreach v_src in array array['private.on_order_placed()', 'private.on_order_status()'] loop
    execute replace(
      pg_get_functiondef((v_src)::regprocedure),
      'background:#f68b1e', 'background:#9030d0');
  end loop;
end $$;
