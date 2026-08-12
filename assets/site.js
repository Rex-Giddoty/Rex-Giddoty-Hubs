/* Rex-Giddoty Hubs — shared storefront behaviour.
 *
 * The bag lives in localStorage while browsing, holding nothing but variant ids
 * and quantities. Prices are looked up fresh for display and recomputed by the
 * database at checkout, so a tampered bag changes what you see, never what you
 * are charged.
 */
(function () {
  const db  = window.RG_DB;
  const M   = window.RG_MONEY;
  const IMG = window.RG_IMG;
  const BAG_KEY = 'rg_bag';

  /* ── bag ── */
  const Bag = {
    read() {
      try {
        const raw = JSON.parse(localStorage.getItem(BAG_KEY) || '[]');
        return Array.isArray(raw)
          ? raw.filter(i => i && i.variant_id)
               .map(i => ({ variant_id: String(i.variant_id),
                            quantity: Math.max(1, Math.min(20, parseInt(i.quantity, 10) || 1)) }))
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
      const found = items.find(i => i.variant_id === variantId);
      if (found) found.quantity = Math.min(20, found.quantity + (qty || 1));
      else items.push({ variant_id: variantId, quantity: Math.min(20, qty || 1) });
      Bag.write(items);
    },
    setQty(variantId, qty) {
      let items = Bag.read();
      if (qty <= 0) items = items.filter(i => i.variant_id !== variantId);
      else {
        const f = items.find(i => i.variant_id === variantId);
        if (f) f.quantity = Math.min(20, qty);
      }
      Bag.write(items);
    },
    remove(variantId) { Bag.write(Bag.read().filter(i => i.variant_id !== variantId)); },
    clear() { Bag.write([]); },
    count() { return Bag.read().reduce((s, i) => s + i.quantity, 0); },
    paint() {
      const n = Bag.count();
      document.querySelectorAll('[data-bag-count]').forEach(el => {
        el.textContent = n;
        el.style.display = n ? '' : 'none';
      });
    },
    /* Re-reads the current price and stock for everything in the bag. Never
       trusts anything cached in the browser. */
    async detail() {
      const items = Bag.read();
      if (!items.length) return [];
      const ids = items.map(i => i.variant_id);
      const { data, error } = await db
        .from('product_variants')
        .select('id,option_name,option_value,price_minor,stock,is_active,products(id,name,slug,price_minor,currency,status,product_images(path,position))')
        .in('id', ids);
      if (error) return [];

      const out = [];
      for (const it of items) {
        const v = (data || []).find(x => x.id === it.variant_id);
        if (!v || !v.is_active || !v.products || v.products.status !== 'published') continue;
        const imgs = (v.products.product_images || []).sort((a, b) => a.position - b.position);
        const unit = v.price_minor != null ? v.price_minor : v.products.price_minor;
        out.push({
          variant_id: v.id,
          quantity: Math.min(it.quantity, Math.max(0, v.stock)),
          requested: it.quantity,
          stock: v.stock,
          option: [v.option_name, v.option_value].filter(Boolean).join(' '),
          name: v.products.name,
          slug: v.products.slug,
          currency: v.products.currency,
          image: imgs[0] ? imgs[0].path : null,
          unit_minor: unit,
          line_minor: unit * Math.min(it.quantity, Math.max(0, v.stock)),
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

  /* ── chrome ── */
  window.RG_CHROME = async function () {
    const s = await window.RG_SETTINGS();
    const store = s.store_name || 'Rex-Giddoty Hubs';
    document.title = document.title.replace(/Rex-Giddoty Hubs/g, store);

    const { data: cats } = await db.from('categories')
      .select('slug,name,position').eq('is_active', true).order('position').order('name');

    /* New Arrivals is a view, not a category. Tagging pieces by hand to keep it
       current would go stale the first busy week, so it lists whatever was
       published most recently and takes care of itself. */
    const entries = (cats || []).map(c => ({
      name: c.name, position: c.position,
      href: '/shop.html?category=' + encodeURIComponent(c.slug),
    }));
    entries.push({ name: 'New Arrivals', position: 40, href: '/shop.html?new=1' });
    entries.sort((a, b) => a.position - b.position);

    const links = entries.map(e => `<a href="${e.href}">${esc(e.name)}</a>`).join('');

    const nav = document.querySelector('[data-nav]');
    if (nav) {
      nav.innerHTML = `
        <div class="nav__inner">
          <button class="burger" aria-label="Menu" data-burger><span></span><span></span><span></span></button>
          <a class="nav__brand" href="/">${esc(store)}</a>
          <nav class="nav__links">
            <a href="/shop.html">All</a>${links}
          </nav>
          <div class="nav__acts">
            <a href="/account.html">Account</a>
            <a href="/bag.html">Bag<span class="bag-count" data-bag-count style="display:none;">0</span></a>
          </div>
        </div>`;
      const drawer = document.createElement('div');
      drawer.className = 'drawer';
      drawer.innerHTML = `<a href="/shop.html">All</a>${links}<a href="/account.html">Account</a><a href="/bag.html">Bag</a>`;
      document.body.appendChild(drawer);
      nav.querySelector('[data-burger]').onclick = () => drawer.classList.toggle('open');
    }

    const foot = document.querySelector('[data-foot]');
    if (foot) {
      foot.innerHTML = `
        <div class="wrap">
          <div class="foot__grid">
            <div>
              <div class="nav__brand" style="font-size:18px;margin-bottom:12px;">${esc(store)}</div>
              <p class="note" style="max-width:280px;">Considered pieces, made to be kept. Delivered across Nigeria.</p>
            </div>
            <div><h4>Shop</h4><a href="/shop.html">All pieces</a>${links}</div>
            <div><h4>Account</h4><a href="/account.html">My orders</a><a href="/login.html">Sign in</a><a href="/register.html">Create account</a></div>
            <div><h4>Help</h4><a href="/bag.html">My bag</a><a href="mailto:${esc(s.support_email || 'support@example.com')}">Contact us</a></div>
          </div>
          <div class="foot__base">
            <span>© ${new Date().getFullYear()} ${esc(store)}</span>
            <span>Payment on confirmation · Nationwide delivery</span>
          </div>
        </div>`;
    }
    Bag.paint();
  };

  /* ── helpers ── */
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  window.RG_ESC = esc;

  let toastTimer;
  window.RG_TOAST = function (msg) {
    let t = document.querySelector('.toast');
    if (!t) { t = document.createElement('div'); t.className = 'toast'; document.body.appendChild(t); }
    t.textContent = msg;
    requestAnimationFrame(() => t.classList.add('show'));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 2600);
  };

  window.RG_CARD = function (p) {
    const imgs = (p.product_images || []).sort((a, b) => a.position - b.position);
    const stock = (p.product_variants || []).reduce((s, v) => s + (v.stock || 0), 0);
    return `<a class="product-card" href="/product.html?slug=${encodeURIComponent(p.slug)}">
      <div class="card__media">
        ${imgs[0] ? `<img src="${esc(IMG(imgs[0].path))}" alt="${esc(p.name)}" loading="lazy"/>` : '<div class="skeleton" style="width:100%;height:100%;"></div>'}
        ${stock === 0 ? '<span class="card__flag">Sold out</span>' : ''}
      </div>
      <div class="card__name">${esc(p.name)}</div>
      <div class="card__price">${M.fmt(p.price_minor, p.currency)}</div>
    </a>`;
  };

  Bag.paint();
})();
