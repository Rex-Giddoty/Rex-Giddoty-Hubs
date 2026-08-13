/* Rex-Giddoty Hubs — shared storefront behaviour (Jumia-style marketplace).
 *
 * The bag lives in localStorage holding nothing but variant ids and quantities.
 * Prices are re-read for display and recomputed by the database at checkout, so
 * a tampered bag changes what a shopper sees and never what they are charged.
 */
(function () {
  const db  = window.RG_DB;
  const M   = window.RG_MONEY;
  const IMG = window.RG_IMG;
  const BAG_KEY = 'rg_bag';

  const esc = s => String(s == null ? '' : s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
  window.RG_ESC = esc;

  /* The shop answers on its own domain, the vercel.app address and any preview
     build. Canonical tags point every one of them at the real domain so search
     engines index it and not a deploy URL. */
  const SITE = 'https://rexgiddotyhubs.shop';
  window.RG_SITE = SITE;

  /* Product media is a mix of photographs and the occasional short clip. Which
     one a row is comes from its extension, which is safe because the uploader
     is what writes the name. One definition, used by the cards, the product
     page and the ops editor alike. */
  const IS_VID = /\.(mp4|mov|m4v|webm|3gp)$/i;
  window.RG_IS_VIDEO = path => IS_VID.test(String(path || ''));

  /* "1.2k sold" rather than "1240 sold": past a thousand the exact figure stops
     being information and starts being noise. Zero shows nothing at all — an
     item nobody has bought yet should not announce it. */
  window.RG_SOLD = n => {
    const v = Number(n || 0);
    if (v <= 0) return '';
    const num = v < 1000 ? String(v)
      : v < 1000000 ? (v / 1000).toFixed(v < 10000 ? 1 : 0).replace(/\.0$/, '') + 'k'
      : (v / 1000000).toFixed(1).replace(/\.0$/, '') + 'm';
    /* The plus says the number is a floor rather than a count anybody is going
       to audit, which is both how these read everywhere else and the honest
       shape for a figure that is typed rather than counted. */
    return num + '+ sold';
  };

  function tag(sel, make) {
    let el = document.head.querySelector(sel);
    if (!el) { el = make(); document.head.appendChild(el); }
    return el;
  }
  function metaProp(p, content) {
    const el = tag(`meta[property="${p}"]`, () => {
      const m = document.createElement('meta'); m.setAttribute('property', p); return m;
    });
    el.setAttribute('content', content);
  }

  function setSEO(title) {
    const q = new URLSearchParams(location.search);
    /* Keep only the parameters that identify a page. Sort order and the like
       would otherwise mint a separate canonical for identical content. */
    const keep = new URLSearchParams();
    ['slug', 'category'].forEach(k => { if (q.get(k)) keep.set(k, q.get(k)); });
    const path = location.pathname.replace(/\/index\.html$/, '/');
    const url = SITE + path + (keep.toString() ? '?' + keep : '');

    tag('link[rel="canonical"]', () => {
      const l = document.createElement('link'); l.rel = 'canonical'; return l;
    }).href = url;

    metaProp('og:url', url);
    metaProp('og:type', 'website');
    metaProp('og:title', title || document.title);
    metaProp('og:image', SITE + '/assets/logo.png');
    const desc = document.head.querySelector('meta[name="description"]');
    if (desc) metaProp('og:description', desc.content);

    /* Search results are endless combinations of the same products; let them be
       followed for discovery but keep them out of the index. */
    if (q.get('q')) {
      tag('meta[name="robots"]', () => {
        const m = document.createElement('meta'); m.name = 'robots'; return m;
      }).setAttribute('content', 'noindex,follow');
    }
  }
  window.RG_SEO = setSEO;

  /* ── bag ── */
  const Bag = {
    read() {
      try {
        const raw = JSON.parse(localStorage.getItem(BAG_KEY) || '[]');
        return Array.isArray(raw)
          ? raw.filter(i => i && i.variant_id).map(i => ({
              variant_id: String(i.variant_id),
              quantity: Math.max(1, Math.min(20, parseInt(i.quantity, 10) || 1)),
            }))
          : [];
      } catch (_) { return []; }
    },
    write(items) {
      try { localStorage.setItem(BAG_KEY, JSON.stringify(items)); } catch (_) {}
      Bag.paint();
      window.dispatchEvent(new CustomEvent('rg:bag'));
    },
    add(variantId, qty) {
      const items = Bag.read();
      const f = items.find(i => i.variant_id === variantId);
      if (f) f.quantity = Math.min(20, f.quantity + (qty || 1));
      else items.push({ variant_id: variantId, quantity: Math.min(20, qty || 1) });
      Bag.write(items);
    },
    setQty(variantId, qty) {
      let items = Bag.read();
      if (qty <= 0) items = items.filter(i => i.variant_id !== variantId);
      else { const f = items.find(i => i.variant_id === variantId); if (f) f.quantity = Math.min(20, qty); }
      Bag.write(items);
    },
    remove(id) { Bag.write(Bag.read().filter(i => i.variant_id !== id)); },
    clear() { Bag.write([]); },
    count() { return Bag.read().reduce((s, i) => s + i.quantity, 0); },
    paint() {
      const n = Bag.count();
      document.querySelectorAll('[data-bag-count]').forEach(el => {
        el.textContent = n;
        el.style.display = n ? '' : 'none';
      });
    },
    async detail() {
      const items = Bag.read();
      if (!items.length) return [];
      const { data } = await db.from('product_variants')
        .select('id,option_name,option_value,price_minor,stock,is_active,products(id,name,slug,price_minor,currency,status,product_images(path,position))')
        .in('id', items.map(i => i.variant_id));
      const out = [];
      for (const it of items) {
        const v = (data || []).find(x => x.id === it.variant_id);
        if (!v || !v.is_active || !v.products || v.products.status !== 'published') continue;
        const imgs = (v.products.product_images || []).sort((a,b) => a.position - b.position)
          .filter(im => !window.RG_IS_VIDEO(im.path));   // the cart line wants a still
        const unit = v.price_minor != null ? v.price_minor : v.products.price_minor;
        const qty  = Math.min(it.quantity, Math.max(0, v.stock));
        out.push({
          variant_id: v.id, quantity: qty, requested: it.quantity, stock: v.stock,
          option: [v.option_name, v.option_value].filter(Boolean).join(' '),
          name: v.products.name, slug: v.products.slug, currency: v.products.currency,
          image: imgs[0] ? imgs[0].path : null,
          unit_minor: unit, line_minor: unit * qty,
        });
      }
      return out;
    },
  };
  window.RG_BAG = Bag;

  /* ── settings & categories ── */
  let _settings = null;
  window.RG_SETTINGS = async function () {
    if (_settings) return _settings;
    try {
      const { data } = await db.from('site_settings').select('key,value');
      _settings = Object.fromEntries((data || []).map(r => [r.key, r.value]));
    } catch (_) { _settings = {}; }
    return _settings;
  };

  let _cats = null;
  window.RG_CATS = async function () {
    if (_cats) return _cats;
    const { data } = await db.from('categories')
      .select('id,slug,name,position,parent_id,image_path').eq('is_active', true).order('position').order('name');
    _cats = data || [];
    return _cats;
  };

  /* Categories are one level deep: top-level entries, each with its children.
     Anything whose parent is missing or hidden is promoted to the top rather
     than disappearing from the menu entirely. */
  window.RG_CAT_TREE = async function () {
    const all = await window.RG_CATS();
    const ids = new Set(all.map(c => c.id));
    const tops = all.filter(c => !c.parent_id || !ids.has(c.parent_id));
    return tops.map(t => ({ ...t, children: all.filter(c => c.parent_id === t.id) }));
  };

  /* ── icons ── */
  const I = {
    account: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7"/></svg>',
    cart:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="9" cy="20" r="1.6"/><circle cx="18" cy="20" r="1.6"/><path d="M2 3h3l2.5 12h11L21 7H6"/></svg>',
    home:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/></svg>',
    grid:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/></svg>',
    menu:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 6h18M3 12h18M3 18h18"/></svg>',
    search:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>',
    help:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="12" r="9"/><path d="M9.6 9.2a2.5 2.5 0 013.9-1.6c1.6 1 .9 2.6-.3 3.3-.8.5-1.2 1-1.2 1.9"/><circle cx="12" cy="17" r=".9" fill="currentColor" stroke="none"/></svg>',
    orders:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M5 4h14v17l-3-2-2 2-2-2-2 2-2-2-3 2z"/><path d="M9 9h6M9 13h6"/></svg>',
    caret:   '<svg class="caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 9l6 6 6-6"/></svg>',
    left:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M15 6l-6 6 6 6"/></svg>',
    right:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 6l6 6-6 6"/></svg>',
    up:      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 15l6-6 6 6"/></svg>',
    phone:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M5 3h4l2 5-2.5 1.5a12 12 0 006 6L16 13l5 2v4a2 2 0 01-2 2A16 16 0 013 5a2 2 0 012-2z"/></svg>',
    truck:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M2 6h11v10H2zM13 10h4l4 3v3h-8z"/><circle cx="7" cy="18" r="1.7"/><circle cx="17" cy="18" r="1.7"/></svg>',
    shield:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/></svg>',
    tag:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M3 12l9-9h8v8l-9 9z"/><circle cx="16.5" cy="7.5" r="1.4"/></svg>',
  };
  window.RG_ICON = I;

  /* ── category icons ──
   * Drawn on one 24×24 grid with a single stroke weight so they sit together
   * evenly in the sidebar. */
  const g = p => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" '
    + 'stroke-linecap="round" stroke-linejoin="round">' + p + '</svg>';

  const CI = {
    collection: g('<path d="M12 7.2V9"/><path d="M12 7.2a2.1 2.1 0 112.1-2.1"/>'
      + '<path d="M12 9l-8 5.6c-.9.6-.5 2 .6 2h14.8c1.1 0 1.5-1.4.6-2L12 9z"/>'),
    tops: g('<path d="M9 3.2L4.2 5.8l1.9 3.9L8 8.8V21h8V8.8l1.9.9 1.9-3.9L15 3.2a3 3 0 01-6 0z"/>'),
    /* Shorts rather than full trousers, so Bottoms stays distinguishable from
       Jeans at 19px where finer detail disappears. */
    bottoms: g('<path d="M5.8 3.4h12.4l.5 3.6-.8 9.6h-4.3L12 10.4l-1.6 6.2H6.1L5.3 7z"/>'
      + '<path d="M6 7.2h12"/>'),
    /* Jeans differ from plain bottoms by the button and pocket seams — without
       them the two silhouettes are identical at 19px. */
    jeans: g('<path d="M6.4 3h11.2l.5 4-1 14h-3.6L12 10.5 10.5 21H6.9l-1-14z"/><path d="M6.7 7h10.6"/>'
      + '<circle cx="12" cy="4.9" r=".75"/>'
      + '<path d="M8.1 8.7L9.6 7.2"/><path d="M15.9 8.7L14.4 7.2"/>'),
    joggers: g('<path d="M6.4 3h11.2l.5 4-1 11.6h-3.6L12 9.6 10.5 18.6H6.9l-1-11.6z"/>'
      + '<path d="M6.9 18.6h3.6V21H6.9zM13.5 18.6h3.6V21h-3.6z"/>'
      + '<path d="M10.5 4.4l1.5 1.3 1.5-1.3"/>'),
    fragrance: g('<rect x="7.2" y="9" width="9.6" height="12" rx="2.2"/>'
      + '<path d="M10.2 9V6.4h3.6V9"/><rect x="10.4" y="2.6" width="3.2" height="2.6" rx=".9"/>'
      + '<path d="M9.7 13.4h4.3"/>'),
    fullfit: g('<path d="M8.5 3.5L12 8l3.5-4.5 4.1 2.1V21H4.4V5.6z"/><path d="M12 8v13"/>'
      + '<path d="M9.7 3.7L12 8l2.3-4.3"/>'),
    bags: g('<path d="M4.6 8h14.8l-1.1 12.2a1 1 0 01-1 .9H6.7a1 1 0 01-1-.9z"/>'
      + '<path d="M8.7 8V6.4a3.3 3.3 0 016.6 0V8"/>'),
    shoes: g('<path d="M2.8 19.2h18.4a.8.8 0 00.8-.8v-.9c0-1.4-1-2.6-2.3-2.9l-4.5-1.1-3.1-2.6a1 1 0 00-.9-.2l-2.7.5-1.1-1.5-2.5.6A2.6 2.6 0 002 12.8v5.6c0 .4.4.8.8.8z"/>'
      + '<path d="M6.9 10.3l1.3 1.9M10 11.1l1.2 1.8"/><path d="M2.2 16.6h19.5"/>'),
    jewellery: g('<path d="M8.6 3h6.8l3.1 4.2L12 15.4 5.5 7.2z"/>'
      + '<path d="M5.6 7.2h12.8M9.4 7.2L12 15.4l2.6-8.2M8.6 3l.8 4.2M15.4 3l-.8 4.2"/>'),
    /* The two Jewellery children. Both would otherwise fall through to the gem
       above and sit under their own parent wearing its icon. */
    watches: g('<circle cx="12" cy="12" r="5.4"/>'
      + '<path d="M9.2 6.9L9.6 3h4.8l.4 3.9M9.2 17.1l.4 3.9h4.8l.4-3.9"/>'
      + '<path d="M12 9.6V12l1.8 1.1"/>'),
    necklaces: g('<path d="M5 4.2a8.6 8.6 0 0014 0"/>'
      + '<path d="M12 12.4l1.9 2.4-1.9 3.6-1.9-3.6z"/><path d="M12 10.6v1.8"/>'),
    decor: g('<path d="M8.4 3.4h7.2l2.8 6.8H5.6z"/><path d="M12 10.2V19"/>'
      + '<path d="M8.6 21h6.8a3.4 3.4 0 00-6.8 0z"/>'),
    accessories: g('<path d="M3.4 15.8c0-4.8 3.9-8.7 8.6-8.7s8.6 3.9 8.6 8.7z"/>'
      + '<path d="M12 7.1V4.6"/><path d="M20.6 15.8c1.3 0 2 .7 2 1.7"/>'),
    news: g('<path d="M11 3.2l1.7 4.6 4.6 1.7-4.6 1.7L11 15.8 9.3 11.2 4.7 9.5l4.6-1.7z"/>'
      + '<path d="M17.8 14.6l.8 2.1 2.1.8-2.1.8-.8 2.1-.8-2.1-2.1-.8 2.1-.8z"/>'),
    deals: g('<path d="M3.6 12.4l8.8-8.8h7.2v7.2l-8.8 8.8a1.6 1.6 0 01-2.3 0l-4.9-4.9a1.6 1.6 0 010-2.3z"/>'
      + '<circle cx="16.4" cy="7.6" r="1.2"/><path d="M9.5 15.1l4.3-4.3"/>'
      + '<circle cx="9.7" cy="11" r=".9"/><circle cx="13.6" cy="14.9" r=".9"/>'),
  };

  /* Matched on slug and name, most specific first, so a category the shop owner
     adds later ("Denim jackets", "Perfume") still lands on a sensible icon
     instead of the generic tag. */
  const CI_MATCH = [
    [/jean|denim/, 'jeans'],
    [/jogger|track|sweat|lounge/, 'joggers'],
    [/bottom|trouser|pant|short|skirt|legging/, 'bottoms'],
    [/fragrance|perfume|scent|cologne|body\s*spray/, 'fragrance'],
    [/full.?fit|suit|outfit|two.?piece|co.?ord/, 'fullfit'],
    [/bag|purse|tote|backpack|luggage/, 'bags'],
    [/shoe|sneaker|footwear|boot|sandal|slipper|trainer/, 'shoes'],
    [/watch|timepiece/, 'watches'],
    [/necklace|pendant|chain|choker/, 'necklaces'],
    [/jewel|ring|earring|bracelet/, 'jewellery'],
    [/cap|hat|accessor|belt|sunglass/, 'accessories'],
    [/decor|lifestyle|home|furniture|lamp|kitchen/, 'decor'],
    [/top|shirt|tee|blouse|hoodie|jacket/, 'tops'],
    [/collection|clothing|clothes|apparel|wear|fashion/, 'collection'],
    [/new|arrival|latest/, 'news'],
    [/deal|sale|discount|offer|clearance|promo/, 'deals'],
  ];

  window.RG_CAT_ICON = function (slug, name) {
    const s = (String(slug || '') + ' ' + String(name || '')).toLowerCase();
    for (const [re, key] of CI_MATCH) if (re.test(s)) return CI[key];
    return I.tag;
  };

  /* ── chrome ── */
  window.RG_CHROME = async function (active) {
    const s = await window.RG_SETTINGS();
    const tree = await window.RG_CAT_TREE();
    const store = s.store_name || 'Rex-Giddoty Hubs';
    document.title = document.title.replace(/Rex-Giddoty Hubs/g, store);
    metaProp('og:site_name', store);
    setSEO();

    const catHref = c => '/shop.html?category=' + encodeURIComponent(c.slug);
    const entries = tree.map(t => ({
      name: t.name, position: t.position, slug: t.slug, href: catHref(t),
      children: (t.children || []).map(c => ({ name: c.name, slug: c.slug, href: catHref(c) })),
    }));
    entries.push({ name: 'New Arrivals', position: 40, href: '/shop.html?new=1', slug: '__new', children: [] });
    entries.push({ name: 'Deals', position: 41, href: '/shop.html?deals=1', slug: '__deals', children: [] });
    entries.sort((a, b) => a.position - b.position);
    window.RG_MENU = entries;

    /* A group opens when it is the page you are on, or holds it. */
    const ico = e => window.RG_CAT_ICON(e.slug, e.name);
    const groupHtml = (e, sub) => {
      if (!e.children || !e.children.length)
        return `<a href="${e.href}" class="${active === e.slug ? 'on' : ''}">${ico(e)}${esc(e.name)}</a>`;
      const open = active === e.slug || e.children.some(c => c.slug === active);
      return `<div class="rail__grp${open ? ' open' : ''}">
        <div class="rail__row">
          <a href="${e.href}" class="${active === e.slug ? 'on' : ''}">${ico(e)}${esc(e.name)}</a>
          <button class="rail__tog" data-tog aria-expanded="${open}" aria-label="Show ${esc(e.name)}">${I.caret}</button>
        </div>
        <div class="rail__sub">${e.children.map(c =>
          `<a href="${c.href}" class="${active === c.slug ? 'on' : ''}">${ico(c)}${esc(c.name)}</a>`).join('')}</div>
      </div>`;
    };

    const q = new URLSearchParams(location.search).get('q') || '';
    const parts = store.split(' ');
    const phone = s.support_phone || '';
    const email = s.support_email || 'support@example.com';

    /* An anonymous session is not a customer — only a real account counts as
       signed in for the purposes of this menu. */
    let session = null;
    try { ({ data: { session } } = await db.auth.getSession()); } catch (_) {}
    const signedIn = !!(session && session.user && !session.user.is_anonymous);
    const firstName = signedIn
      ? String(session.user.user_metadata?.full_name || session.user.email || 'Account').split(/[\s@]/)[0]
      : '';

    const head = document.querySelector('[data-hdr]');
    if (head) {
      head.innerHTML = `
        ${s.promo_strip ? `<div class="promo">${esc(s.promo_strip)}</div>` : ''}
        <div class="vbar"><div class="vbar__in">
          <a href="mailto:${esc(email)}">${I.tag}Sell with us</a>
          <div class="vbar__mid">${esc(store)}</div>
          <a href="/shop.html?deals=1">Today's deals</a>
        </div></div>
        <div class="hdr__main">
          <button class="burger" data-burger aria-label="Menu">${I.menu}</button>
          <a class="logo" href="/" aria-label="${esc(store)}">
            <img class="logo__mark" src="/assets/logo-mark.png" alt=""/>
            <span class="logo__txt"><b>${esc(parts[0])}<em>${esc(parts.slice(1).join(' '))}</em></b><i>Unlimited</i></span>
          </a>
          <form class="search" action="/shop.html" method="get" role="search">
            ${I.search}
            <input name="q" placeholder="Search products, brands and categories" value="${esc(q)}" aria-label="Search"/>
            <button type="submit">Search</button>
          </form>
          <div class="hdr__acts">
            <div class="dpdw">
              <a class="hact" href="${signedIn ? '/account.html' : '/login.html'}">${I.account}<span class="hact--label">${
                signedIn ? esc(firstName) : 'Account'}</span>${I.caret}</a>
              <div class="dpdw__box">
                ${signedIn ? `
                  <div class="lead" style="font-size:13px;">
                    <div style="color:var(--mute);">Signed in as</div>
                    <b style="word-break:break-all;">${esc(session.user.email || '')}</b>
                  </div>
                  <a href="/account.html">My account</a>
                  <a href="/account.html#orders">My orders</a>
                  <a href="/account.html#addresses">Addresses</a>
                  <a href="#" data-signout>Sign out</a>`
                : `
                  <div class="lead"><a class="btn" href="/login.html">Sign in</a></div>
                  <a href="/register.html">Create an account</a>
                  <a href="/account.html#orders">My orders</a>`}
                <a href="/bag.html">Cart</a>
              </div>
            </div>
            <a class="hact" href="/bag.html">${I.cart}<span class="hact--label">Cart</span>
              <span class="cart-badge" data-bag-count style="display:none;">0</span></a>
          </div>
        </div>`;

      const drawer = document.createElement('div');
      drawer.className = 'drawer';
      drawer.innerHTML = `<div class="drawer__bg" data-close></div>
        <div class="drawer__panel">
          <a class="hd" href="/" aria-label="${esc(store)}">
            <img src="/assets/logo.png" alt="${esc(store)}"/>
          </a>
          <a href="/">${I.home}Home</a>
          ${entries.map(e => groupHtml(e, true)).join('')}
          ${signedIn
            ? `<a href="/account.html">${I.account}My account</a>
               <a href="/account.html#orders">${I.orders}My orders</a>`
            : `<a href="/login.html">${I.account}Sign in</a>
               <a href="/register.html">${I.account}Create an account</a>`}
          <a href="/bag.html">${I.cart}My cart</a>
          <a href="/help.html">${I.help}How to shop &amp; delivery</a>
          <a href="mailto:${esc(email)}">${I.tag}Contact us</a>
        </div>`;
      document.body.appendChild(drawer);

      /* ── the drawer, and the thumb that drags it ──
       * .on puts it in the document, .open decides where it sits, and a
       * transition carries it between the two. During a drag the position is
       * set by hand and every transition is off, so the panel tracks the finger
       * instead of easing behind it.
       */
      let hideTimer;
      const setOpen = want => {
        clearTimeout(hideTimer);
        if (want) {
          drawer.classList.add('on');
          /* The panel has to exist at its closed position for one frame or the
             browser has nothing to transition from and it simply appears. */
          void drawer.offsetWidth;
          drawer.classList.remove('closing');
          drawer.classList.add('open');
        } else {
          if (!drawer.classList.contains('on')) return;
          drawer.classList.add('closing');
          drawer.classList.remove('open');
          hideTimer = setTimeout(() => drawer.classList.remove('on', 'closing'), 320);
        }
      };
      const openDrawer = () => setOpen(true);
      const closeDrawer = () => setOpen(false);

      head.querySelector('[data-burger]').onclick = openDrawer;
      drawer.querySelector('[data-close]').onclick = closeDrawer;
      document.addEventListener('keydown', e => { if (e.key === 'Escape') closeDrawer(); });

      /* A strip down the left edge is the only place an opening swipe may begin.
         Anywhere else and it would fight the product rows, which scroll
         sideways on the same axis. */
      const edge = document.querySelector('.edge') || document.createElement('div');
      edge.className = 'edge';
      if (!edge.isConnected) document.body.appendChild(edge);

      const panel = drawer.querySelector('.drawer__panel');
      const veil = drawer.querySelector('.drawer__bg');
      const SLOP = 8;                    // pixels before the axis is decided
      const TAKE = 0.4;                  // how far across counts as "let it open"
      const FLICK = 0.45;                // px per ms that counts as a flick

      let live = false, axis = null, fromOpen = false;
      let x0 = 0, y0 = 0, w = 280, lastX = 0, lastT = 0, vel = 0, moved = false;

      /* 0 is shut, 1 is open. Everything the gesture does is expressed in this. */
      const place = f => {
        panel.style.transform = `translate3d(${(f - 1) * 100}%,0,0)`;
        veil.style.opacity = String(f);
      };
      const release = () => {
        panel.style.transform = '';
        veil.style.opacity = '';
        drawer.classList.remove('dragging');
      };

      const start = e => {
        if (e.touches.length !== 1) return;
        const t = e.touches[0];
        fromOpen = drawer.classList.contains('open');
        /* Opening starts at the edge; closing starts anywhere on the drawer. */
        if (!fromOpen && e.currentTarget !== edge) return;
        live = true; axis = null; moved = false;
        x0 = lastX = t.clientX; y0 = t.clientY;
        lastT = e.timeStamp; vel = 0;
        w = panel.getBoundingClientRect().width || 280;
      };

      const move = e => {
        if (!live || e.touches.length !== 1) return;
        const t = e.touches[0];
        const dx = t.clientX - x0, dy = t.clientY - y0;

        if (!axis) {
          if (Math.abs(dx) < SLOP && Math.abs(dy) < SLOP) return;
          /* Whichever way the first few pixels went is the way this gesture is
             going. A vertical one is the menu or the page scrolling, and is let
             go of entirely. */
          axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y';
          if (axis === 'y') { live = false; return; }
          clearTimeout(hideTimer);
          drawer.classList.add('on', 'dragging');
          drawer.classList.remove('closing');
        }

        moved = true;
        e.preventDefault();                       // the page stays where it is

        const dt = Math.max(1, e.timeStamp - lastT);
        vel = (t.clientX - lastX) / dt;
        lastX = t.clientX; lastT = e.timeStamp;

        const raw = fromOpen ? w + dx : dx;
        place(Math.max(0, Math.min(1, raw / w)));
      };

      const end = () => {
        if (!live) return;
        live = false;
        if (axis !== 'x' || !moved) return;

        const f = Math.max(0, Math.min(1, (fromOpen ? w + (lastX - x0) : lastX - x0) / w));
        /* A flick beats the halfway line: a short fast push should open it even
           though the finger never got far. */
        const want = vel > FLICK ? true : vel < -FLICK ? false : f > TAKE;

        release();
        setOpen(want);
        /* A drag that ends on the backdrop would otherwise be followed by its
           click, shutting what was just opened. */
        if (want) {
          const eat = ev => { ev.stopPropagation(); ev.preventDefault(); };
          drawer.addEventListener('click', eat, { capture: true, once: true });
          setTimeout(() => drawer.removeEventListener('click', eat, true), 350);
        }
      };

      for (const el of [edge, drawer]) {
        el.addEventListener('touchstart', start, { passive: true });
        el.addEventListener('touchmove', move, { passive: false });
        el.addEventListener('touchend', end, { passive: true });
        el.addEventListener('touchcancel', () => { if (live) { live = false; release(); setOpen(fromOpen); } },
          { passive: true });
      }
    }

    const rail = document.querySelector('[data-rail]');
    if (rail) {
      /* The full logo goes on a dark cap: its wordmark is white, so on the
         sidebar's own white it would simply not be there. */
      rail.innerHTML = `
        <a class="rail__logo" href="/" aria-label="${esc(store)}">
          <img src="/assets/logo.png" alt="${esc(store)}"/>
        </a>
        <div class="box__hd">Categories</div>
        <div class="rail">${entries.map(e => groupHtml(e, false)).join('')}</div>`;
    }

    /* Social links come from settings, so they are changed in ops rather than in
       the code. An icon with no address behind it is worse than no icon, so a
       blank setting simply drops it. */
    const SOCIAL = [
      ['social_instagram', 'Instagram',
       '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4"/><circle cx="17.5" cy="6.5" r="1" fill="currentColor"/></svg>'],
      ['social_facebook', 'Facebook',
       '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M13 22v-8h3l.5-3H13V9.2c0-.9.3-1.5 1.6-1.5H17V5.1A22 22 0 0014.6 5C12.2 5 10.5 6.5 10.5 9v2H8v3h2.5v8z"/></svg>'],
      ['social_x', 'X',
       '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M17.5 3h3l-6.6 7.5L21.7 21h-5.9l-4.3-5.6L6.4 21H3.3l7-8L2.6 3h6l3.9 5.2zm-1 16h1.7L8 4.7H6.2z"/></svg>'],
    ];
    /* A handle typed without https:// would otherwise resolve against our own
       domain and 404. */
    const asUrl = v => {
      const t = String(v || '').trim();
      if (!t) return '';
      return /^https?:\/\//i.test(t) ? t : 'https://' + t.replace(/^\/+/, '');
    };
    const socialLinks = SOCIAL
      .map(([key, label, svg]) => ({ href: asUrl(s[key]), label, svg }))
      .filter(x => x.href);
    const socialHtml = socialLinks.length
      ? socialLinks.map(x => `<a href="${esc(x.href)}" aria-label="${x.label}" target="_blank" rel="noopener noreferrer">${x.svg}</a>`).join('')
      : `<span style="font-size:12px;color:#9a9a9a;">Coming soon</span>`;

    const foot = document.querySelector('[data-foot]');
    if (foot) {
      foot.innerHTML = `
        <div class="foot__news"><div class="in">
          <div>
            <!-- the full logo is white-on-transparent, so it only works here on the dark panel -->
            <img src="/assets/logo.png" alt="${esc(store)}" style="width:190px;max-width:100%;height:auto;margin:-14px 0 -6px -10px;"/>
            <p style="margin:6px 0 0;">Everyday essentials and standout pieces, delivered nationwide.</p>
          </div>
          <div>
            <div class="foot__t">NEW TO ${esc(store.toUpperCase())}?</div>
            Subscribe to hear about new arrivals and price drops first.
            <form class="foot__form" data-news>
              <input type="email" required placeholder="Enter e-mail address" aria-label="E-mail"/>
              <button type="submit">Subscribe</button>
            </form>
          </div>
        </div></div>

        <div class="foot__grid">
          <div><h4>Need help?</h4>
            <a href="mailto:${esc(email)}">Contact us</a>
            ${phone ? `<a href="tel:${esc(phone.replace(/\s/g,''))}">${esc(phone)}</a>` : ''}
            <a href="/help.html">How to shop</a>
            <a href="/help.html#delivery">Delivery &amp; payment</a>
            <a href="/account.html#orders">Track an order</a>
            <a href="/privacy.html">Privacy policy</a>
          </div>
          <div><h4>About us</h4>
            <a href="/">Our store</a>
            <a href="/shop.html">All products</a>
            <a href="/shop.html?new=1">New arrivals</a>
            <a href="/shop.html?deals=1">Deals</a>
          </div>
          <div><h4>Shop</h4>${entries.slice(0,6).map(e => `<a href="${e.href}">${esc(e.name)}</a>`).join('')}</div>
          <div><h4>Account</h4>
            <a href="/account.html">My account</a>
            <a href="/account.html#orders">My orders</a>
            <a href="/bag.html">My cart</a>
          </div>
        </div>

        <div class="foot__pay">
          <div><h4 style="color:#fff;font-size:13px;text-transform:uppercase;margin-bottom:11px;">Join us on</h4>
            <div class="foot__ic">${socialHtml}</div>
          </div>
          <div><h4 style="color:#fff;font-size:13px;text-transform:uppercase;margin-bottom:11px;">Payment methods</h4>
            <div class="foot__ic">
              <span>Bank transfer</span><span>Card on request</span>
            </div>
          </div>
        </div>

        <div class="foot__base">© ${new Date().getFullYear()} ${esc(store)} · Payment confirmed before dispatch · Nationwide delivery</div>`;

      const nf = foot.querySelector('[data-news]');
      if (nf) nf.onsubmit = e => { e.preventDefault(); nf.reset(); window.RG_TOAST('Thanks — you are subscribed'); };
    }

    const bar = document.querySelector('[data-tabbar]');
    if (bar) {
      const page = location.pathname.replace(/^\//,'') || 'index.html';
      const on = p => page.startsWith(p) ? 'on' : '';
      bar.innerHTML = `
        <a href="/" class="${page==='index.html'||page===''?'on':''}">${I.home}Home</a>
        <a href="/shop.html" class="${on('shop')}">${I.grid}Categories</a>
        <a href="/account.html" class="${on('account')}">${I.account}Account</a>
        <a href="/bag.html" class="${on('bag')}">${I.cart}Cart<span class="cart-badge" data-bag-count style="display:none;">0</span></a>`;
    }

    /* Signing out from the header, wherever the header happens to be. */
    document.querySelectorAll('[data-signout]').forEach(a => a.addEventListener('click', async e => {
      e.preventDefault();
      await db.auth.signOut();
      location.href = '/';
    }));

    mountBackToTop();
    Bag.paint();
    /* Not awaited: the chat bubble is the last thing anyone needs on arrival,
       and its own queries should not hold up the header. */
    chatMount();
  };

  /* ── product card ── */
  window.RG_CARD = function (p) {
    /* Videos are filtered out rather than played here: forty autoplaying clips
       in a grid is a different website. The card shows the first photograph. */
    const imgs  = (p.product_images || []).sort((a,b) => a.position - b.position)
                    .filter(im => !window.RG_IS_VIDEO(im.path));
    const stock = (p.product_variants || []).reduce((s,v) => s + (v.stock || 0), 0);
    const firstV = (p.product_variants || []).find(v => (v.stock || 0) > 0);
    /* Derive the discount rather than store it, so the badge can never disagree
       with the prices printed next to it. */
    const off = (p.compare_at_minor && p.compare_at_minor > p.price_minor)
      ? Math.round((1 - p.price_minor / p.compare_at_minor) * 100) : 0;
    const rating = p.rating_avg ? Number(p.rating_avg) : 0;
    const full = Math.round(rating);
    /* Jumia shows the meter against a nominal batch of 50, which is what makes a
       low count read as urgent rather than as an arbitrary bar. */
    const meter = stock > 0 && stock <= 50 ? Math.max(6, Math.round(stock / 50 * 100)) : 0;
    /* Pairings can cost different amounts, so the card shows the cheapest one a
       shopper could actually buy and says "from" when they differ — a price no
       variant has is worse than no price at all. */
    const prices = (p.product_variants || [])
      .map(v => v.price_minor != null ? v.price_minor : p.price_minor)
      .filter(n => n != null);
    const lowest = prices.length ? Math.min(...prices) : p.price_minor;
    const sold = window.RG_SOLD(p.sold_count);

    return `<div class="pcard">
      <a href="/product.html?slug=${encodeURIComponent(p.slug)}">
        <div class="pcard__media">
          ${imgs[0] ? `<img src="${esc(IMG(imgs[0].path))}" alt="${esc(p.name)}" loading="lazy"/>`
                    : '<div class="skeleton" style="width:100%;height:100%;"></div>'}
          ${p.badge ? `<span class="pcard__badge">${esc(p.badge)}</span>` : ''}
          ${off ? `<span class="pcard__off">-${off}%</span>` : ''}
          ${stock === 0 ? '<div class="pcard__out">Out of stock</div>' : ''}
        </div>
        <div class="pcard__name">${esc(p.name)}</div>
        <div>
          <span class="pcard__price">${lowest === p.price_minor ? '' : 'from '}${M.fmt(lowest, p.currency)}</span>
          ${off ? `<span class="pcard__was">${M.fmt(p.compare_at_minor, p.currency)}</span>` : ''}
        </div>
        ${rating ? `<div class="stars"><i>${'★'.repeat(full)}${'☆'.repeat(5-full)}</i>(${p.rating_count || 0})</div>` : ''}
        ${sold ? `<div class="sold"><span>🔥</span>${sold}</div>` : ''}
        ${meter ? `<div class="left-note">${stock} items left</div><div class="bar"><span style="width:${meter}%"></span></div>` : ''}
      </a>
      <button class="pcard__add" ${firstV ? `data-add="${firstV.id}"` : 'disabled'}>
        ${firstV ? 'Add to cart' : 'Out of stock'}
      </button>
    </div>`;
  };

  /* ── carousel ──
   * One scroller with snap points; the arrows page it by a whole viewport so a
   * click always lands on a card boundary rather than mid-image. */
  window.RG_CRS = function (cards, opts) {
    const o = opts || {};
    return `<div class="crs">
      <button class="crs__nav _p" data-crs="-1" aria-label="Previous">${I.left}</button>
      <div class="crs__track"${o.id ? ` id="${o.id}"` : ''}>${cards}</div>
      <button class="crs__nav _n" data-crs="1" aria-label="Next">${I.right}</button>
    </div>`;
  };

  /* Expand/collapse a category group. Delegated, so it works for the sidebar
     and the mobile drawer without either knowing about the other. */
  document.addEventListener('click', e => {
    const t = e.target.closest('[data-tog]');
    if (!t) return;
    e.preventDefault();
    const grp = t.closest('.rail__grp');
    if (!grp) return;
    const open = grp.classList.toggle('open');
    t.setAttribute('aria-expanded', String(open));
  });

  /* Touch has no hover, so the card is lit for as long as a finger is on it.
     A :hover rule cannot do this job — on a touch screen it latches after the
     tap and the card stays lit until something else is pressed. Delegated once
     for every grid and carousel on the page. */
  (function cardTouch() {
    let lit = null, fade;
    const off = () => {
      clearTimeout(fade);
      if (lit) { lit.classList.remove('is-lit'); lit = null; }
    };
    document.addEventListener('pointerdown', e => {
      if (e.pointerType === 'mouse') return;      // the mouse has :hover already
      const card = e.target.closest('.pcard');
      off();
      if (card) { lit = card; card.classList.add('is-lit'); }
    }, { passive: true });
    /* A tap is over in a moment, so the light lingers afterwards — long enough
       to be seen, short enough not to look stuck. */
    document.addEventListener('pointerup', () => {
      if (lit) { clearTimeout(fade); fade = setTimeout(off, 900); }
    }, { passive: true, capture: true });
    /* Dragging a carousel is not a press, so the light drops the moment the
       finger starts to travel. */
    ['pointercancel', 'touchmove', 'scroll'].forEach(ev =>
      document.addEventListener(ev, off, { passive: true, capture: true }));
  })();

  document.addEventListener('click', e => {
    const nav = e.target.closest('[data-crs]');
    if (!nav) return;
    const track = nav.parentElement.querySelector('.crs__track');
    if (track) track.scrollBy({ left: Number(nav.dataset.crs) * track.clientWidth * 0.9, behavior: 'smooth' });
  });

  /* A row with only a couple of items has nothing to scroll, and the arrows then
     just sit on top of the cards hiding their names. Rows are filled after the
     data arrives, so watch for that rather than checking once at load. */
  function syncCarousels() {
    document.querySelectorAll('.crs').forEach(c => {
      const t = c.querySelector('.crs__track');
      if (t) c.classList.toggle('crs--static', t.scrollWidth <= t.clientWidth + 2);
    });
  }
  window.RG_CRS_SYNC = syncCarousels;

  if (window.MutationObserver) {
    let timer;
    const mo = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(syncCarousels, 80); });
    const start = () => mo.observe(document.body, { childList: true, subtree: true });
    if (document.body) start();
    else document.addEventListener('DOMContentLoaded', start);
  }
  window.addEventListener('resize', () => { clearTimeout(window.__crsT); window.__crsT = setTimeout(syncCarousels, 120); });

  /* One listener for every grid rather than one per card. */
  document.addEventListener('click', e => {
    const b = e.target.closest('[data-add]');
    if (!b) return;
    e.preventDefault();
    Bag.add(b.dataset.add, 1);
    window.RG_TOAST('Added to cart');
  });

  /* ── password visibility ──
   * Typing a password blind on a phone keyboard is where most sign-in failures
   * come from, so every password field gets a reveal. */
  const EYE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">'
    + '<path d="M2.2 12S5.8 5.6 12 5.6 21.8 12 21.8 12 18.2 18.4 12 18.4 2.2 12 2.2 12z"/>'
    + '<circle cx="12" cy="12" r="3.1"/></svg>';
  const EYE_OFF = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">'
    + '<path d="M9.9 5.9A9.6 9.6 0 0112 5.6c6.2 0 9.8 6.4 9.8 6.4a17 17 0 01-3.3 4"/>'
    + '<path d="M6.3 7.7A17 17 0 002.2 12S5.8 18.4 12 18.4c1.6 0 3-.4 4.2-1"/>'
    + '<path d="M9.9 9.9a3.1 3.1 0 004.3 4.3"/><path d="M3.5 3.5l17 17"/></svg>';

  window.RG_PEEK = function (inputId, buttonId) {
    const input = document.getElementById(inputId);
    const btn = document.getElementById(buttonId);
    if (!input || !btn) return;
    btn.innerHTML = EYE;
    btn.onclick = () => {
      const shown = input.type === 'text';
      input.type = shown ? 'password' : 'text';
      btn.innerHTML = shown ? EYE : EYE_OFF;
      btn.setAttribute('aria-label', shown ? 'Show password' : 'Hide password');
      input.focus();
    };
  };

  /* ── back to top ── */
  function mountBackToTop() {
    if (document.querySelector('.b2top')) return;
    const b = document.createElement('button');
    b.className = 'b2top';
    b.setAttribute('aria-label', 'Back to top');
    b.innerHTML = I.up;
    b.onclick = () => window.scrollTo({ top: 0, behavior: 'smooth' });
    document.body.appendChild(b);
    const sync = () => b.classList.toggle('on', window.scrollY > 600);
    window.addEventListener('scroll', sync, { passive: true });
    sync();
  }

  let toastTimer;
  window.RG_TOAST = function (msg) {
    let t = document.querySelector('.toast');
    if (!t) { t = document.createElement('div'); t.className = 'toast'; document.body.appendChild(t); }
    t.textContent = msg;
    requestAnimationFrame(() => t.classList.add('show'));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 2400);
  };

  /* ── support chat ──
   * A bubble on every page. Signed-in customers get the conversation; everyone
   * else gets a way in, because a message we cannot attach to an account is a
   * message we cannot answer.
   *
   * Writes go through send_support_message rather than an insert, so the shop
   * side of a conversation cannot be forged from a browser console. */
  const CHAT_I = {
    bubble: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">'
      + '<path d="M21 11.5a8.4 8.4 0 01-9 8.4 9.5 9.5 0 01-2.9-.4L4 21l1.4-3.9A8.2 8.2 0 013 11.5 8.4 8.4 0 0112 3a8.4 8.4 0 019 8.5z"/></svg>',
    close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">'
      + '<path d="M6 6l12 12M18 6L6 18"/></svg>',
    send: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">'
      + '<path d="M4 12l16-8-6 8 6 8z"/></svg>',
    clip: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">'
      + '<path d="M20 11.5l-7.8 7.8a4.6 4.6 0 01-6.5-6.5l8.2-8.2a3.1 3.1 0 014.4 4.4l-8.2 8.2a1.5 1.5 0 01-2.2-2.2l7.4-7.4"/></svg>',
    file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">'
      + '<path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8z"/><path d="M14 3v5h5"/></svg>',
  };

  /* Attachments. The bucket is private, so every file is fetched through a
     signed URL — one round trip per panel-load, cached for the session. */
  const FILE_OK  = /^(image\/(jpeg|png|webp|avif|gif|heic)|application\/pdf|video\/(mp4|quicktime|webm|3gpp))$/;
  const FILE_MAX = 10 * 1024 * 1024;        // photos and documents
  const VID_MAX  = 25 * 1024 * 1024;        // a short clip
  const VID_SECS = 60;
  const fileUrls = new Map();

  /* Length is read from the file itself before anything is uploaded, so a long
     clip costs the sender nothing but a moment. The server can only police the
     size, which is why the size ceiling is the one that really holds. */
  const videoSeconds = file => new Promise(resolve => {
    const v = document.createElement('video');
    v.preload = 'metadata';
    const url = URL.createObjectURL(file);
    const done = secs => { URL.revokeObjectURL(url); resolve(secs); };
    v.onloadedmetadata = () => done(v.duration);
    v.onerror = () => done(null);          // unreadable here; let the size rule decide
    v.src = url;
  });

  const fileSize = n => n >= 1048576
    ? (n / 1048576).toFixed(1) + ' MB'
    : Math.max(1, Math.round(n / 1024)) + ' KB';

  async function chatSignFiles(root) {
    const need = [...root.querySelectorAll('[data-file]')]
      .map(el => el.dataset.file).filter(p => !fileUrls.has(p));
    if (need.length) {
      const { data } = await db.storage.from('support-files')
        .createSignedUrls([...new Set(need)], 3600);
      (data || []).forEach(r => { if (r.signedUrl) fileUrls.set(r.path, r.signedUrl); });
    }
    root.querySelectorAll('[data-file]').forEach(el => {
      const url = fileUrls.get(el.dataset.file);
      if (!url) return;
      if (el.tagName === 'IMG' || el.tagName === 'VIDEO') el.src = url; else el.href = url;
    });
  }

  function chatFileHtml(m) {
    if (!m.file_path) return '';
    const name = esc(m.file_name || 'Attachment');
    if ((m.file_type || '').startsWith('image/')) {
      return `<a class="cfile cfile--img" data-file="${esc(m.file_path)}" target="_blank" rel="noopener">
                <img data-file="${esc(m.file_path)}" alt="${name}" loading="lazy"/></a>`;
    }
    if ((m.file_type || '').startsWith('video/')) {
      return `<video class="cfile--vid" data-file="${esc(m.file_path)}" controls preload="metadata"
                playsinline></video>`;
    }
    return `<a class="cfile" data-file="${esc(m.file_path)}" target="_blank" rel="noopener">
              ${CHAT_I.file}<span><b>${name}</b>${m.file_size ? '<i>' + fileSize(m.file_size) + '</i>' : ''}</span></a>`;
  }

  const chat = {
    el: null, list: null, thread: null, msgs: [], sub: null, open: false, poll: 0, me: null, pending: null,
  };

  const chatTime = t => new Date(t).toLocaleTimeString('en-NG',
    { hour: '2-digit', minute: '2-digit' });

  function chatPaintBadge(n) {
    const b = chat.el && chat.el.querySelector('[data-chat-badge]');
    if (!b) return;
    b.textContent = n > 9 ? '9+' : String(n);
    b.style.display = n > 0 ? '' : 'none';
  }

  function chatRender() {
    if (!chat.list) return;
    const atBottom = chat.list.scrollHeight - chat.list.scrollTop - chat.list.clientHeight < 60;

    chat.list.innerHTML = chat.msgs.length
      ? chat.msgs.map(m => `
          <div class="cmsg cmsg--${m.sender_role === 'staff' ? 'them' : 'me'}">
            ${chatFileHtml(m)}
            ${m.body ? `<div class="cmsg__b">${esc(m.body).replace(/\n/g, '<br/>')}</div>` : ''}
            <div class="cmsg__t">${m.sender_role === 'staff' ? 'Rex-Giddoty Hubs · ' : ''}${chatTime(m.created_at)}</div>
          </div>`).join('')
      : `<div class="cempty">
           <b>Ask us anything</b>
           <span>Sizes, delivery, an order you have already placed — we answer
           during working hours and you will see the reply right here.</span>
         </div>`;

    if (atBottom || chat.msgs.length <= 1) chat.list.scrollTop = chat.list.scrollHeight;
    chatSignFiles(chat.list);
  }

  async function chatLoad() {
    const { data: t } = await db.from('support_threads')
      .select('id,status,customer_unread').eq('status', 'open').maybeSingle();
    chat.thread = t ? t.id : null;
    chatPaintBadge(t ? t.customer_unread : 0);

    if (!chat.thread) { chat.msgs = []; chatRender(); return; }
    const { data: m } = await db.from('support_messages')
      .select('id,body,sender_role,created_at,file_path,file_name,file_type,file_size')
      .eq('thread_id', chat.thread).order('created_at').limit(200);
    chat.msgs = m || [];
    chatRender();
  }

  /* Realtime carries the reply the moment it is sent; the poll is there for the
     phone that has been asleep in a pocket and missed the socket entirely. */
  function chatWatch() {
    if (chat.sub || !chat.thread) return;
    chat.sub = db.channel('support:' + chat.thread)
      .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'support_messages',
          filter: 'thread_id=eq.' + chat.thread },
        p => {
          if (chat.msgs.some(x => x.id === p.new.id)) return;
          chat.msgs.push(p.new);
          chatRender();
          if (chat.open) chatMarkRead();
          else if (p.new.sender_role === 'staff') {
            chatPaintBadge(1);
            window.RG_TOAST('Rex-Giddoty Hubs replied');
          }
        })
      .subscribe();
  }

  async function chatMarkRead() {
    if (!chat.thread) return;
    chatPaintBadge(0);
    await db.rpc('mark_support_read', { p_thread: chat.thread });
  }

  /* Uploaded when it is picked rather than when Send is pressed, so a slow
     connection does its waiting while the message is still being typed. */
  async function chatAttach(file) {
    const isVideo = file.type.startsWith('video/');
    if (!FILE_OK.test(file.type)) { window.RG_TOAST('Photos, short videos and PDFs only'); return; }
    if (file.size > (isVideo ? VID_MAX : FILE_MAX)) {
      window.RG_TOAST(isVideo ? 'That video is over 25MB' : 'That file is over 10MB');
      return;
    }
    if (isVideo) {
      const secs = await videoSeconds(file);
      if (secs && secs > VID_SECS + 1) {
        window.RG_TOAST('Videos need to be under a minute');
        return;
      }
    }

    chat.pending = { name: file.name, size: file.size, type: file.type, path: null };
    chatPaintPending('Uploading…');

    if (!chat.thread) {
      const { data, error } = await db.rpc('my_support_thread');
      if (error) { chat.pending = null; chatPaintPending(); return window.RG_TOAST(error.message); }
      chat.thread = data;
      chatWatch();
    }

    const ext = (file.name.match(/\.[A-Za-z0-9]+$/) || [''])[0].toLowerCase();
    const path = chat.thread + '/' + (crypto.randomUUID ? crypto.randomUUID() : Date.now()) + ext;
    const { error } = await db.storage.from('support-files')
      .upload(path, file, { contentType: file.type, upsert: false });
    if (error) {
      chat.pending = null; chatPaintPending();
      return window.RG_TOAST(error.message || 'That did not upload');
    }
    chat.pending.path = path;
    chatPaintPending();
  }

  function chatPaintPending(note) {
    const box = chat.el && chat.el.querySelector('[data-chat-pending]');
    if (!box) return;
    if (!chat.pending) { box.hidden = true; box.innerHTML = ''; return; }
    box.hidden = false;
    box.innerHTML = `${CHAT_I.file}
      <span><b>${esc(chat.pending.name)}</b><i>${note || fileSize(chat.pending.size)}</i></span>
      <button type="button" data-chat-drop aria-label="Remove">${CHAT_I.close}</button>`;
    box.querySelector('[data-chat-drop]').onclick = () => { chat.pending = null; chatPaintPending(); };
  }

  async function chatSend(input) {
    const body = input.value.trim();
    const file = chat.pending && chat.pending.path ? chat.pending : null;
    if (!body && !file) return;
    if (chat.pending && !chat.pending.path) return window.RG_TOAST('Still uploading…');

    input.value = '';
    input.style.height = '';
    chat.pending = null;
    chatPaintPending();

    /* Shown straight away under its own temporary id. If the send fails it is
       taken back out, so the panel never claims to have sent something twice. */
    const temp = {
      id: 'tmp-' + Date.now(), body, sender_role: 'customer',
      created_at: new Date().toISOString(),
      file_path: file ? file.path : null, file_name: file ? file.name : null,
      file_type: file ? file.type : null, file_size: file ? file.size : null,
    };
    chat.msgs.push(temp);
    chatRender();

    const { data, error } = await db.rpc('send_support_message', {
      p_body: body,
      p_file_path: file ? file.path : null,
      p_file_name: file ? file.name : null,
      p_file_type: file ? file.type : null,
      p_file_size: file ? file.size : null,
    });
    if (error) {
      chat.msgs = chat.msgs.filter(m => m.id !== temp.id);
      chatRender();
      window.RG_TOAST(error.message || 'That did not send');
      input.value = body;
      if (file) { chat.pending = file; chatPaintPending(); }
      return;
    }
    if (!chat.thread) { chat.thread = data; chatWatch(); }
    await chatLoad();
  }

  async function chatMount() {
    /* Everywhere on the shop, checkout included — a question at the payment
       step is the one most worth answering. The console is the exception. */
    if (document.querySelector('.chat') || /^\/ops/.test(location.pathname)) return;

    let session = null;
    try { ({ data: { session } } = await db.auth.getSession()); } catch (_) {}
    const signedIn = !!(session && session.user && !session.user.is_anonymous);
    /* Staff answer from the console; a bubble on the shop would only give them
       a second inbox that nobody watches. */
    if (signedIn) {
      const { data: admin } = await db.from('admin_users').select('id').eq('id', session.user.id).maybeSingle();
      if (admin) return;
    }
    chat.me = signedIn ? session.user : null;

    const el = document.createElement('div');
    el.className = 'chat';
    el.innerHTML = `
      <div class="chat__panel" hidden>
        <div class="chat__hd">
          <div>
            <b>Support</b>
            <span>We reply during working hours</span>
          </div>
          <button class="chat__x" data-chat-close aria-label="Close">${CHAT_I.close}</button>
        </div>
        <div class="chat__body" data-chat-list></div>
        ${signedIn ? `
          <div class="chat__pend" data-chat-pending hidden></div>
          <form class="chat__form" data-chat-form>
            <input type="file" hidden data-chat-file
              accept="image/jpeg,image/png,image/webp,image/avif,image/gif,image/heic,application/pdf,video/mp4,video/quicktime,video/webm,video/3gpp"/>
            <button type="button" class="chat__clip" data-chat-pick aria-label="Attach a file">${CHAT_I.clip}</button>
            <textarea rows="1" placeholder="Type a message…" maxlength="4000"
              aria-label="Message" data-chat-input></textarea>
            <button type="submit" aria-label="Send">${CHAT_I.send}</button>
          </form>`
        : `<div class="chat__gate">
             <p>Sign in and we can tie your question to your orders — and you get
             the answer here rather than hoping an email arrives.</p>
             <a class="btn btn--full" href="/login.html?next=${encodeURIComponent(location.pathname)}">Sign in</a>
             <a class="btn btn--ghost btn--full" href="/register.html" style="margin-top:7px;">Create an account</a>
           </div>`}
      </div>
      <button class="chat__fab" data-chat-fab aria-label="Support chat">
        ${CHAT_I.bubble}<span class="chat__badge" data-chat-badge style="display:none;">0</span>
      </button>`;
    document.body.appendChild(el);
    chat.el = el;
    chat.list = el.querySelector('[data-chat-list]');

    const panel = el.querySelector('.chat__panel');
    const toggle = async () => {
      chat.open = !chat.open;
      panel.hidden = !chat.open;
      el.classList.toggle('chat--open', chat.open);
      if (!chat.open) return;
      if (signedIn) { await chatLoad(); chatWatch(); await chatMarkRead(); }
      const i = el.querySelector('[data-chat-input]');
      if (i && window.matchMedia('(hover:hover)').matches) i.focus();
    };
    el.querySelector('[data-chat-fab]').onclick = toggle;
    el.querySelector('[data-chat-close]').onclick = toggle;

    if (!signedIn) { chatRender(); return; }

    const form = el.querySelector('[data-chat-form]');
    const input = el.querySelector('[data-chat-input]');
    form.onsubmit = e => { e.preventDefault(); chatSend(input); };
    /* Enter sends, Shift+Enter makes a new line — except on a phone, where
       Enter is the only way to get one. */
    input.onkeydown = e => {
      if (e.key !== 'Enter' || e.shiftKey) return;
      if (!window.matchMedia('(hover:hover)').matches) return;
      e.preventDefault();
      chatSend(input);
    };
    input.oninput = () => {
      input.style.height = 'auto';
      input.style.height = Math.min(110, input.scrollHeight) + 'px';
    };

    const picker = el.querySelector('[data-chat-file]');
    el.querySelector('[data-chat-pick]').onclick = () => picker.click();
    picker.onchange = () => {
      const f = picker.files && picker.files[0];
      picker.value = '';          // so the same file can be picked twice running
      if (f) chatAttach(f);
    };

    await chatLoad();
    chatWatch();
    chat.poll = setInterval(() => { if (document.visibilityState === 'visible') chatLoad(); }, 20000);
  }
  window.RG_CHAT_MOUNT = chatMount;

  /* Registered here rather than in supabase.js because only the shop pages load
     this file. The console loads supabase.js too, and staff software should not
     be installable or served from a cache. */
  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    });
  }

  Bag.paint();
})();
