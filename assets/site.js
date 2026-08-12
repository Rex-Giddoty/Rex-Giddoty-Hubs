/* Rex-Giddoty Hubs — shared storefront behaviour (marketplace interface).
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

  /* ── settings ── */
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
      .select('slug,name,position').eq('is_active', true).order('position').order('name');
    _cats = data || [];
    return _cats;
  };

  const ICON = {
    account: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7"/></svg>',
    cart:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="9" cy="20" r="1.6"/><circle cx="18" cy="20" r="1.6"/><path d="M2 3h3l2.5 12h11L21 7H6"/></svg>',
    home:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/></svg>',
    grid:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/></svg>',
    menu:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 6h18M3 12h18M3 18h18"/></svg>',
  };

  /* ── chrome ── */
  window.RG_CHROME = async function (active) {
    const s = await window.RG_SETTINGS();
    const cats = await window.RG_CATS();
    const store = s.store_name || 'Rex-Giddoty Hubs';
    document.title = document.title.replace(/Rex-Giddoty Hubs/g, store);

    const entries = cats.map(c => ({ name: c.name, position: c.position,
      href: '/shop.html?category=' + encodeURIComponent(c.slug), slug: c.slug }));
    entries.push({ name: 'New Arrivals', position: 40, href: '/shop.html?new=1', slug: '__new' });
    entries.sort((a, b) => a.position - b.position);
    window.RG_MENU = entries;

    const q = new URLSearchParams(location.search).get('q') || '';
    const parts = store.split(' ');
    const head = document.querySelector('[data-hdr]');
    if (head) {
      head.innerHTML = `
        ${s.promo_strip ? `<div class="promo">${esc(s.promo_strip)}</div>` : ''}
        <div class="hdr__main">
          <button class="burger" data-burger aria-label="Menu">${ICON.menu}</button>
          <a class="logo" href="/">${esc(parts[0])}<span>${esc(parts.slice(1).join(' '))}</span></a>
          <form class="search" action="/shop.html" method="get">
            <input name="q" placeholder="Search products, brands and categories" value="${esc(q)}" aria-label="Search"/>
            <button type="submit">Search</button>
          </form>
          <div class="hdr__acts">
            <a class="hact" href="/account.html">${ICON.account}<span class="hact--label">Account</span></a>
            <a class="hact" href="/bag.html">${ICON.cart}<span class="hact--label">Cart</span>
              <span class="cart-badge" data-bag-count style="display:none;">0</span></a>
          </div>
        </div>`;

      const drawer = document.createElement('div');
      drawer.className = 'drawer';
      drawer.innerHTML = `<div class="drawer__bg" data-close></div>
        <div class="drawer__panel">
          <div class="hd">${esc(store)}</div>
          <a href="/">Home</a>
          ${entries.map(e => `<a href="${e.href}">${esc(e.name)}</a>`).join('')}
          <a href="/account.html">My account</a>
          <a href="/bag.html">My cart</a>
        </div>`;
      document.body.appendChild(drawer);
      head.querySelector('[data-burger]').onclick = () => drawer.classList.add('open');
      drawer.querySelector('[data-close]').onclick = () => drawer.classList.remove('open');
    }

    const rail = document.querySelector('[data-rail]');
    if (rail) {
      rail.innerHTML = `<div class="box__hd">Categories</div><div class="rail">` +
        entries.map(e => `<a href="${e.href}" class="${active === e.slug ? 'on' : ''}">${esc(e.name)}</a>`).join('') +
        `</div>`;
    }

    const foot = document.querySelector('[data-foot]');
    if (foot) {
      foot.innerHTML = `
        <div class="foot__grid">
          <div><h4>${esc(store)}</h4><p style="font-size:12.5px;">Everyday essentials and standout pieces, delivered across Nigeria.</p></div>
          <div><h4>Shop</h4>${entries.map(e => `<a href="${e.href}">${esc(e.name)}</a>`).join('')}</div>
          <div><h4>Account</h4><a href="/account.html">My account</a><a href="/account.html">Orders</a><a href="/bag.html">Cart</a></div>
          <div><h4>Help</h4><a href="/shop.html">All products</a><a href="mailto:${esc(s.support_email || 'support@example.com')}">Contact us</a></div>
        </div>
        <div class="foot__base">© ${new Date().getFullYear()} ${esc(store)} · Pay on confirmation · Nationwide delivery</div>`;
    }

    const bar = document.querySelector('[data-tabbar]');
    if (bar) {
      const page = location.pathname.replace(/^\//,'') || 'index.html';
      const on = p => page.startsWith(p) ? 'on' : '';
      bar.innerHTML = `
        <a href="/" class="${page==='index.html'||page===''?'on':''}">${ICON.home}Home</a>
        <a href="/shop.html" class="${on('shop')}">${ICON.grid}Categories</a>
        <a href="/account.html" class="${on('account')}">${ICON.account}Account</a>
        <a href="/bag.html" class="${on('bag')}">${ICON.cart}Cart<span class="cart-badge" data-bag-count style="display:none;">0</span></a>`;
    }
    Bag.paint();
  };

  /* ── product card ── */
  window.RG_CARD = function (p) {
    const imgs  = (p.product_images || []).sort((a,b) => a.position - b.position);
    const stock = (p.product_variants || []).reduce((s,v) => s + (v.stock || 0), 0);
    const firstV = (p.product_variants || []).find(v => (v.stock || 0) > 0);
    /* Derive the discount rather than store it, so the badge can never disagree
       with the prices next to it. */
    const off = (p.compare_at_minor && p.compare_at_minor > p.price_minor)
      ? Math.round((1 - p.price_minor / p.compare_at_minor) * 100) : 0;
    const rating = p.rating_avg ? Number(p.rating_avg) : 0;
    const full = Math.round(rating);

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
        ${stock > 0 && stock <= 5 ? `<div class="bar"><span style="width:${Math.max(12, stock*18)}%"></span></div><div class="left-note">${stock} left</div>` : ''}
      </a>
      <button class="pcard__add" ${firstV ? `data-add="${firstV.id}"` : 'disabled'}>
        ${firstV ? 'Add to cart' : 'Out of stock'}
      </button>
    </div>`;
  };

  /* One listener for the whole grid rather than one per card. */
  document.addEventListener('click', e => {
    const b = e.target.closest('[data-add]');
    if (!b) return;
    e.preventDefault();
    Bag.add(b.dataset.add, 1);
    window.RG_TOAST('Added to cart');
  });

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
