-- Jewellery gains children, the same way Collection did in 0004.
--
-- Nothing structural changes here: the tree, the sidebar drop-down and the ops
-- parent picker are all generic, so a parent_id is the whole feature.

do $$
declare
  v_parent uuid;
  v_pos    integer;
  v_child  text;
  v_names  text[] := array['Watches','Necklaces'];
begin
  select id, position into v_parent, v_pos
    from public.categories where slug = 'jewellery';

  if v_parent is null then
    raise exception 'No jewellery category to hang these under';
  end if;

  foreach v_child in array v_names loop
    insert into public.categories (slug, name, parent_id, position, is_active)
    values (
      regexp_replace(lower(v_child), '[^a-z0-9]+', '-', 'g'),
      v_child,
      v_parent,
      -- 50 → 501, 502, matching the 10 → 101… numbering Collection already uses
      v_pos * 10 + array_position(v_names, v_child),
      true
    )
    on conflict (slug) do update
      set parent_id = excluded.parent_id,
          name      = excluded.name;
  end loop;
end $$;
