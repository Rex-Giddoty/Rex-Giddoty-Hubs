-- Rex-Giddoty Hubs — a proper sign-off and footer
--
-- Mail goes out from no-reply@, so the old "just reply to this email" line was
-- an invitation into a black hole. It is replaced by a do-not-reply notice and
-- a real contact address, then a dark footer band carrying the brand.
--
-- stable rather than immutable: the copyright year comes from now().

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

  --  header band — dark, so the white wordmark in the logo is legible
  || '<tr><td align="center" style="background:#282828;padding:26px 20px;">'
  || '<img src="https://rexgiddotyhubs.shop/assets/logo.png" width="190" '
  ||   'alt="Rex Giddoty Hub$ UNLIMITED" '
  ||   'style="display:block;border:0;width:190px;max-width:70%;height:auto;"/>'
  || '</td></tr>'

  --  body
  || '<tr><td style="padding:26px 24px 8px;">'
  || '<h1 style="margin:0 0 14px;font:600 19px Arial,Helvetica,sans-serif;color:#282828;">'
  || p_title || '</h1>'
  || p_body
  || '</td></tr>'

  --  sign-off
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

  --  footer band
  || '<tr><td align="center" style="background:#282828;padding:20px 24px;">'
  || '<p style="margin:0 0 6px;font:13px Arial,Helvetica,sans-serif;color:#c9c9c9;">'
  || 'Rex Giddoty Hubs Unlimited &middot; Clothing, Bags, Shoes &amp; Accessories</p>'
  || '<p style="margin:0 0 6px;font:13px Arial,Helvetica,sans-serif;color:#c9c9c9;">'
  || '<a href="https://rexgiddotyhubs.shop" style="color:#f68b1e;text-decoration:none;">'
  || 'rexgiddotyhubs.shop</a>'
  || ' &nbsp;&middot;&nbsp; '
  || '<a href="mailto:rexgiddotyhubs@gmail.com" style="color:#c9c9c9;text-decoration:none;">'
  || 'Contact us</a></p>'
  || '<p style="margin:0;font:12px Arial,Helvetica,sans-serif;color:#8a8a8a;">'
  || '&copy; ' || to_char(now(), 'YYYY') || ' Rex Giddoty Hubs. All rights reserved.</p>'
  || '</td></tr>'

  || '</table></td></tr></table></body></html>';
$$;
