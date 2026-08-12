// Rex-Giddoty Hubs — Supabase client
const SUPABASE_URL  = 'https://ttlhbmkzhbhflsuisskp.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR0bGhibWt6aGJoZmxzdWlzc2twIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY1MzE0NzMsImV4cCI6MjEwMjEwNzQ3M30.nz6xIJF-Vbh-gXXweqRmx-hdKkDYF6uS1xh3sx1dgiA';

window.RG_URL  = SUPABASE_URL;
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
