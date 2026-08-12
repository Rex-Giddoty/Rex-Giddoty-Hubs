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
        const imgs = (v.products.product_images || []).sort((a,b) => a.position - b.position);
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
      .select('id,slug,name,position,parent_id').eq('is_active', true).order('position').order('name');
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

  /* ── chrome ── */
  window.RG_CHROME = async function (active) {
    const s = await window.RG_SETTINGS();
    const tree = await window.RG_CAT_TREE();
    const store = s.store_name || 'Rex-Giddoty Hubs';
    document.title = document.title.replace(/Rex-Giddoty Hubs/g, store);

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
    const groupHtml = (e, sub) => {
      if (!e.children || !e.children.length)
        return `<a href="${e.href}" class="${active === e.slug ? 'on' : ''}">${I.tag}${esc(e.name)}</a>`;
      const open = active === e.slug || e.children.some(c => c.slug === active);
      return `<div class="rail__grp${open ? ' open' : ''}">
        <div class="rail__row">
          <a href="${e.href}" class="${active === e.slug ? 'on' : ''}">${I.tag}${esc(e.name)}</a>
          <button class="rail__tog" data-tog aria-expanded="${open}" aria-label="Show ${esc(e.name)}">${I.caret}</button>
        </div>
        <div class="rail__sub">${e.children.map(c =>
          `<a href="${c.href}" class="${active === c.slug ? 'on' : ''}">${sub ? I.tag : ''}${esc(c.name)}</a>`).join('')}</div>
      </div>`;
    };

    const q = new URLSearchParams(location.search).get('q') || '';
    const parts = store.split(' ');
    const phone = s.support_phone || '';
    const email = s.support_email || 'support@example.com';

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
          <a class="logo" href="/">${esc(parts[0])}<span>${esc(parts.slice(1).join(' '))}</span></a>
          <form class="search" action="/shop.html" method="get" role="search">
            ${I.search}
            <input name="q" placeholder="Search products, brands and categories" value="${esc(q)}" aria-label="Search"/>
            <button type="submit">Search</button>
          </form>
          <div class="hdr__acts">
            <div class="dpdw">
              <a class="hact" href="/account.html">${I.account}<span class="hact--label">Account</span>${I.caret}</a>
              <div class="dpdw__box">
                <div class="lead"><a class="btn" href="/account.html">Sign in</a></div>
                <a href="/account.html">${'My account'}</a>
                <a href="/account.html#orders">Orders</a>
                <a href="/bag.html">Cart</a>
              </div>
            </div>
            <div class="dpdw">
              <a class="hact" href="mailto:${esc(email)}">${I.help}<span class="hact--label">Help</span>${I.caret}</a>
              <div class="dpdw__box">
                <a href="mailto:${esc(email)}">Contact us</a>
                ${phone ? `<a href="tel:${esc(phone.replace(/\s/g,''))}">Call ${esc(phone)}</a>` : ''}
                <a href="/shop.html">How to shop</a>
                <a href="/shop.html">Delivery &amp; payment</a>
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
          <div class="hd">${esc(store)}</div>
          <a href="/">${I.home}Home</a>
          ${entries.map(e => groupHtml(e, true)).join('')}
          <a href="/account.html">${I.account}My account</a>
          <a href="/bag.html">${I.cart}My cart</a>
          <a href="mailto:${esc(email)}">${I.help}Help</a>
        </div>`;
      document.body.appendChild(drawer);
      head.querySelector('[data-burger]').onclick = () => drawer.classList.add('open');
      drawer.querySelector('[data-close]').onclick = () => drawer.classList.remove('open');
    }

    const rail = document.querySelector('[data-rail]');
    if (rail) {
      rail.innerHTML = `<div class="box__hd">Categories</div><div class="rail">` +
        entries.map(e => groupHtml(e, false)).join('') + `</div>`;
    }

    const foot = document.querySelector('[data-foot]');
    if (foot) {
      foot.innerHTML = `
        <div class="foot__news"><div class="in">
          <div>
            <div class="logo" style="font-size:22px;">${esc(parts[0])}<span style="color:#fff;">${esc(parts.slice(1).join(' '))}</span></div>
            <p style="margin:10px 0 0;">Everyday essentials and standout pieces, delivered nationwide.</p>
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
            <a href="/shop.html">How to shop</a>
            <a href="/account.html">Track an order</a>
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
            <div class="foot__ic">
              <a href="#" aria-label="Facebook"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M13 22v-8h3l.5-3H13V9.2c0-.9.3-1.5 1.6-1.5H17V5.1A22 22 0 0014.6 5C12.2 5 10.5 6.5 10.5 9v2H8v3h2.5v8z"/></svg></a>
              <a href="#" aria-label="Instagram"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4"/><circle cx="17.5" cy="6.5" r="1" fill="currentColor"/></svg></a>
              <a href="#" aria-label="X"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M17.5 3h3l-6.6 7.5L21.7 21h-5.9l-4.3-5.6L6.4 21H3.3l7-8L2.6 3h6l3.9 5.2zm-1 16h1.7L8 4.7H6.2z"/></svg></a>
            </div>
          </div>
          <div><h4 style="color:#fff;font-size:13px;text-transform:uppercase;margin-bottom:11px;">Payment methods</h4>
            <div class="foot__ic">
              <span>Bank transfer</span><span>Pay on delivery</span><span>Card on request</span>
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

    mountBackToTop();
    Bag.paint();
  };

  /* ── product card ── */
  window.RG_CARD = function (p) {
    const imgs  = (p.product_images || []).sort((a,b) => a.position - b.position);
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
          <span class="pcard__price">${M.fmt(p.price_minor, p.currency)}</span>
          ${off ? `<span class="pcard__was">${M.fmt(p.compare_at_minor, p.currency)}</span>` : ''}
        </div>
        ${rating ? `<div class="stars"><i>${'★'.repeat(full)}${'☆'.repeat(5-full)}</i>(${p.rating_count || 0})</div>` : ''}
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

  document.addEventListener('click', e => {
    const nav = e.target.closest('[data-crs]');
    if (!nav) return;
    const track = nav.parentElement.querySelector('.crs__track');
    if (track) track.scrollBy({ left: Number(nav.dataset.crs) * track.clientWidth * 0.9, behavior: 'smooth' });
  });

  /* One listener for every grid rather than one per card. */
  document.addEventListener('click', e => {
    const b = e.target.closest('[data-add]');
    if (!b) return;
    e.preventDefault();
    Bag.add(b.dataset.add, 1);
    window.RG_TOAST('Added to cart');
  });

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

  Bag.paint();
})();
