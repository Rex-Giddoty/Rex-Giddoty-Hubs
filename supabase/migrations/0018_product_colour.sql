-- Colour joins material as a field of its own rather than a line buried in the
-- details blob, for the same reason: it can then be shown in its own right,
-- searched on, and one day filtered on.
--
-- Free text, not a fixed list. A shop that sells "Sand", "Off-white" and
-- "Wine" should not have to argue with a dropdown to say so.

alter table public.products
  add column if not exists color text;
