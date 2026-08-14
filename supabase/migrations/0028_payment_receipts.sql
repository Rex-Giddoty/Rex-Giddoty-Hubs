-- Proof of a transfer, while transfers are how the shop is paid.
--
-- A customer who has sent the money has done their part; making them find the
-- support chat to prove it is asking them to do it twice. The receipt belongs
-- on the order, where whoever confirms it is already looking.

alter table public.orders
  add column if not exists receipt_path text,
  add column if not exists receipt_at   timestamptz;

comment on column public.orders.receipt_path is
  'Object key in the private receipts bucket. Never a public URL — a receipt is a bank statement fragment with a name and an amount on it.';


-- ── the bucket ────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/avif','application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;


-- Whether this person may put a file under this order's folder. Keyed on the
-- first path segment being an order id they own, the same shape the support
-- attachments use.
create or replace function private.receipt_path_ok(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.orders o
     where o.id::text = split_part(p_name, '/', 1)
       and o.user_id = (select auth.uid())
  );
$$;

drop policy if exists receipts_insert_own on storage.objects;
create policy receipts_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'receipts' and private.receipt_path_ok(name));

-- Read is deliberately absent for customers. They have just uploaded it and do
-- not need it back; staff read it through the service role in ops. A private
-- bucket with no select policy is the strongest form of that.
drop policy if exists receipts_read_staff on storage.objects;
create policy receipts_read_staff on storage.objects
  for select to authenticated
  using (bucket_id = 'receipts' and (select private.is_admin()));


-- ── attaching it ──────────────────────────────────────────────────────────
create or replace function public.attach_receipt(p_order uuid, p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;

  -- The path is checked rather than trusted: it has to sit under this order,
  -- and the order has to be theirs.
  if split_part(p_path, '/', 1) <> p_order::text then
    raise exception 'That file does not belong to this order';
  end if;

  update public.orders
     set receipt_path = p_path,
         receipt_at   = now(),
         updated_at   = now()
   where id = p_order
     and user_id = auth.uid()
     and payment_status <> 'paid';

  if not found then
    raise exception 'That order cannot take a receipt';
  end if;
end;
$$;

revoke all on function public.attach_receipt(uuid, text) from public, anon;
grant execute on function public.attach_receipt(uuid, text) to authenticated;


-- ── telling staff ─────────────────────────────────────────────────────────
-- A receipt nobody looks at is the same as no receipt.
create or replace function private.on_receipt_uploaded()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.receipt_path is distinct from old.receipt_path and new.receipt_path is not null then
    perform private.push_to_admins(
      'Receipt uploaded',
      new.order_number || ' — ' ||
        to_char(new.total_minor / 100.0, 'FM999G999G990D00') || ' ' || coalesce(new.currency, 'NGN'),
      '/ops.html');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_receipt_uploaded on public.orders;
create trigger trg_receipt_uploaded
  after update of receipt_path on public.orders
  for each row execute function private.on_receipt_uploaded();
