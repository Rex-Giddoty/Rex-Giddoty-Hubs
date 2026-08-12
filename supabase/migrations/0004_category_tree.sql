-- Categories become one level deep: a parent may hold children ("Collection"
-- holds Tops, Bottoms, Jeans, …). One level is deliberate — it is what the
-- sidebar can show without turning into a tree widget.

alter table public.categories
  add column if not exists parent_id uuid references public.categories(id) on delete set null;

create index if not exists categories_parent_idx on public.categories (parent_id);

/* A category cannot be its own parent. Deeper cycles are impossible while the
   UI only ever offers top-level categories as parents, and a self-reference is
   the one case a stray UPDATE could actually produce. */
alter table public.categories drop constraint if exists categories_parent_not_self;
alter table public.categories add constraint categories_parent_not_self
  check (parent_id is null or parent_id <> id);

do $$
declare
  v_parent uuid;
  v_pos    integer;
  v_child  text;
  v_names  text[] := array['Tops','Bottoms','Jeans','Joggers','Fragrance','Full Fit'];
begin
  /* "Clothes" becomes "Collection" rather than being dropped and recreated, so
     every product already filed under it keeps its category. */
  update public.categories
     set name = 'Collection', slug = 'collection'
   where slug = 'clothes'
   returning id, position into v_parent, v_pos;

  if v_parent is null then
    select id, position into v_parent, v_pos from public.categories where slug = 'collection';
  end if;

  if v_parent is null then
    insert into public.categories (slug, name, position, is_active)
    values ('collection', 'Collection', 1, true)
    returning id, position into v_parent, v_pos;
  end if;

  v_pos := coalesce(v_pos, 1);

  foreach v_child in array v_names loop
    insert into public.categories (slug, name, parent_id, position, is_active)
    values (
      regexp_replace(lower(v_child), '[^a-z0-9]+', '-', 'g'),
      v_child,
      v_parent,
      v_pos * 10 + array_position(v_names, v_child),
      true
    )
    on conflict (slug) do update
      set parent_id = excluded.parent_id,
          name      = excluded.name;
  end loop;
end $$;
