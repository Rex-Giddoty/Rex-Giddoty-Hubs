// Rex-Giddoty Hubs — Supabase client
const SUPABASE_URL  = 'https://ttlhbmkzhbhflsuisskp.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR0bGhibWt6aGJoZmxzdWlzc2twIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY1MzE0NzMsImV4cCI6MjEwMjEwNzQ3M30.nz6xIJF-Vbh-gXXweqRmx-hdKkDYF6uS1xh3sx1dgiA';

window.RG_URL  = SUPABASE_URL;
/* Edge functions live here. Written once, so a page that calls one cannot
   quietly drift onto a different project. */
window.RG_FN   = SUPABASE_URL + '/functions/v1';
window.RG_ANON = SUPABASE_ANON;
window.RG_DB   = supabase.createClient(SUPABASE_URL, SUPABASE_ANON);

/* Money is stored in minor units everywhere. These are the only two places
   that convert, so a stray divide-by-100 cannot creep in. */
window.RG_MONEY = {
  fmt(minor, currency) {
    const cur = currency || 'NGN';
    const sym = { NGN: '₦', USD: '$', EUR: '€', GBP: '£' }[cur] || (cur + ' ');
    return sym + (Number(minor || 0) / 100).toLocaleString('en-NG', {
      minimumFractionDigits: 2, maximumFractionDigits: 2,
    });
  },
  toMinor(text) {
    const n = parseFloat(String(text).replace(/[^0-9.]/g, ''));
    return Number.isFinite(n) ? Math.round(n * 100) : 0;
  },
  toMajor(minor) {
    return (Number(minor || 0) / 100).toFixed(2);
  },
};

window.RG_IMG = path =>
  path ? `${SUPABASE_URL}/storage/v1/object/public/product-images/${path}` : '';

/* ── the busy veil ──────────────────────────────────────────────────────────
 * Blurs the page behind a small panel while something is in flight, so a save
 * that takes three seconds looks like work rather than like nothing happening.
 *
 * It carries its own stylesheet rather than living in site.css or ops.css: the
 * same widget has to sit on the dark console and the light shop, and one
 * self-contained neutral panel is less to keep in step than two copies.
 *
 * Percentages here are always real — bytes actually sent, or steps actually
 * completed. A bar that invents its own progress teaches people to distrust it.
 */
(function () {
  const CSS = `
  .rgbusy{position:fixed;inset:0;z-index:9999;display:none;align-items:center;justify-content:center;
    padding:20px;background:rgba(18,18,20,.42);-webkit-backdrop-filter:blur(7px);backdrop-filter:blur(7px);
    font-family:Inter,Roboto,system-ui,sans-serif;}
  .rgbusy.on{display:flex;animation:rgbusy-in .18s ease both;}
  @keyframes rgbusy-in{from{opacity:0;}}
  .rgbusy__card{background:#fff;color:#282828;border-radius:14px;padding:26px 28px;width:100%;
    max-width:330px;text-align:center;box-shadow:0 18px 50px rgba(0,0,0,.3);}
  .rgbusy__ring{width:44px;height:44px;margin:0 auto 15px;border-radius:50%;
    border:3px solid #ece0f7;border-top-color:#9030d0;animation:rgbusy-spin .8s linear infinite;}
  @keyframes rgbusy-spin{to{transform:rotate(360deg);}}
  .rgbusy__label{font-size:14.5px;font-weight:600;}
  .rgbusy__sub{font-size:12.5px;color:#7a7a7a;margin-top:4px;min-height:16px;}
  .rgbusy__bar{height:6px;border-radius:3px;background:#eee;overflow:hidden;margin-top:15px;display:none;}
  .rgbusy--pct .rgbusy__bar{display:block;}
  .rgbusy__bar i{display:block;height:100%;width:0;background:#9030d0;border-radius:3px;
    transition:width .25s ease;}
  .rgbusy__pct{font-size:20px;font-weight:700;margin-top:9px;display:none;
    font-variant-numeric:tabular-nums;}
  .rgbusy--pct .rgbusy__pct{display:block;}
  @media (prefers-reduced-motion:reduce){
    .rgbusy__ring{animation-duration:2s;} .rgbusy.on{animation:none;}
  }`;

  let el = null;

  function build() {
    if (el) return el;
    const style = document.createElement('style');
    style.textContent = CSS;
    document.head.appendChild(style);

    el = document.createElement('div');
    el.className = 'rgbusy';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    el.innerHTML = `<div class="rgbusy__card">
      <div class="rgbusy__ring"></div>
      <div class="rgbusy__label" data-l>Working…</div>
      <div class="rgbusy__sub" data-s></div>
      <div class="rgbusy__bar"><i data-b></i></div>
      <div class="rgbusy__pct" data-p>0%</div>
    </div>`;
    document.body.appendChild(el);
    return el;
  }

  window.RG_BUSY = {
    /* withPct opens the bar. Leave it off for work whose length is unknowable —
       a spinner is honest there, a percentage would not be. */
    show(label, withPct) {
      const b = build();
      b.querySelector('[data-l]').textContent = label || 'Working…';
      b.querySelector('[data-s]').textContent = '';
      b.classList.toggle('rgbusy--pct', !!withPct);
      if (withPct) this.pct(0);
      b.classList.add('on');
    },
    pct(n, sub) {
      if (!el) return;
      const v = Math.max(0, Math.min(100, Math.round(n)));
      el.querySelector('[data-b]').style.width = v + '%';
      el.querySelector('[data-p]').textContent = v + '%';
      if (sub != null) el.querySelector('[data-s]').textContent = sub;
    },
    note(sub) { if (el) el.querySelector('[data-s]').textContent = sub || ''; },
    /* A moment at 100% before it goes, or the number never actually gets seen. */
    async done(hold) {
      if (!el) return;
      if (el.classList.contains('rgbusy--pct')) this.pct(100);
      await new Promise(r => setTimeout(r, hold == null ? 320 : hold));
      el.classList.remove('on');
    },
    hide() { if (el) el.classList.remove('on'); },
  };
})();

/* Uploads through XHR rather than supabase-js, which reports nothing until it
   finishes. The bytes on the wire are the only honest source for a percentage,
   and this is where they are. */
window.RG_UPLOAD = async function (bucket, path, file, onProgress) {
  const { data: { session } } = await window.RG_DB.auth.getSession();
  const token = session ? session.access_token : SUPABASE_ANON;

  return new Promise(resolve => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `${SUPABASE_URL}/storage/v1/object/${bucket}/${path}`);
    xhr.setRequestHeader('apikey', SUPABASE_ANON);
    xhr.setRequestHeader('Authorization', 'Bearer ' + token);
    xhr.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
    xhr.setRequestHeader('x-upsert', 'false');

    if (onProgress) xhr.upload.onprogress = e => {
      if (e.lengthComputable) onProgress(e.loaded / e.total);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) return resolve({ error: null });
      let msg = 'Upload failed (' + xhr.status + ')';
      try { msg = JSON.parse(xhr.responseText).message || msg; } catch (_) {}
      resolve({ error: { message: msg } });
    };
    xhr.onerror = () => resolve({ error: { message: 'Network error while uploading' } });
    xhr.send(file);
  });
};
