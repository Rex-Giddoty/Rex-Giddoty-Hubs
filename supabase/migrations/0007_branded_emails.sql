-- Rex-Giddoty Hubs — put the logo on the emails
--
-- logo.png has a white wordmark, so it only reads on a dark background. The
-- header band is therefore dark by necessity, not decoration. Alt text carries
-- the brand name for the many clients that block images by default.
--
-- Layout is tables with inline styles: Outlook ignores most of a stylesheet and
-- has no flexbox, so anything cleverer would arrive broken.

create or replace function private.email_shell(p_title text, p_body text)
returns text language sql immutable set search_path = '' as $$
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

  --  header band — dark so the white wordmark in the logo is legible
  || '<tr><td align="center" style="background:#282828;padding:26px 20px;">'
  || '<img src="https://rexgiddotyhubs.shop/assets/logo.png" width="190" '
  ||   'alt="Rex-Giddoty Hub$ UNLIMITED" '
  ||   'style="display:block;border:0;width:190px;max-width:70%;height:auto;"/>'
  || '</td></tr>'

  --  body
  || '<tr><td style="padding:26px 24px;">'
  || '<h1 style="margin:0 0 14px;font:600 19px Arial,Helvetica,sans-serif;color:#282828;">'
  || p_title || '</h1>'
  || p_body
  || '</td></tr>'

  --  footer
  || '<tr><td style="background:#fafafa;border-top:1px solid #eeeeee;padding:16px 24px;">'
  || '<p style="margin:0 0 4px;font:12px Arial,Helvetica,sans-serif;color:#7a7a7a;">'
  || 'Questions? Just reply to this email.</p>'
  || '<p style="margin:0;font:12px Arial,Helvetica,sans-serif;color:#9a9a9a;">'
  || '<a href="https://rexgiddotyhubs.shop" style="color:#9030d0;text-decoration:none;">'
  || 'rexgiddotyhubs.shop</a> &middot; Nationwide delivery &middot; Pay on confirmation</p>'
  || '</td></tr>'

  || '</table></td></tr></table></body></html>';
$$;
