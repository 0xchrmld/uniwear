-- Harden the exposed RPC surface: public functions are invoker wrappers;
-- their SECURITY DEFINER implementations live in the non-exposed private schema.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin'
  );
$$;
revoke all on function private.is_admin() from public, anon;
grant execute on function private.is_admin() to authenticated;

-- Keep the policy helper in public as an invoker wrapper, not a privileged API.
create or replace function public.is_admin()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select private.is_admin();
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

create or replace function private.place_order(items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_order_id uuid;
  v_order_number text;
  v_sequence_value bigint;
  v_item jsonb;
  v_product_id text;
  v_size text;
  v_quantity integer;
  v_unit_price integer;
  v_product_name text;
  v_total bigint := 0;
  v_count integer := 0;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if items is null or jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then
    raise exception 'Cart cannot be empty';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_user_id) then
    raise exception 'Profile not found';
  end if;

  v_sequence_value := nextval('public.order_number_seq');
  v_order_number := 'UW-' || lpad(
    v_sequence_value::text,
    greatest(6, length(v_sequence_value::text)),
    '0'
  );
  insert into public.orders (order_number, student_id, total_php)
  values (v_order_number, v_user_id, 0)
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(items)
  loop
    v_count := v_count + 1;
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'Each cart item must be an object';
    end if;
    v_product_id := nullif(v_item ->> 'product_id', '');
    v_size := nullif(v_item ->> 'size', '');
    if v_product_id is null or v_size is null
       or coalesce(v_item ->> 'quantity', '') !~ '^[0-9]+$' then
      raise exception 'Invalid cart item';
    end if;
    v_quantity := (v_item ->> 'quantity')::integer;
    if v_quantity < 1 or v_quantity > 10 then
      raise exception 'Quantity must be between 1 and 10';
    end if;

    select p.name, pp.price_php
      into v_product_name, v_unit_price
    from public.products p
    join public.product_prices pp on pp.product_id = p.id
    where p.id = v_product_id and p.active and pp.size = v_size;
    if not found then
      raise exception 'Product is inactive, view-only, or size is unavailable: % / %',
        v_product_id, v_size;
    end if;

    insert into public.order_items
      (order_id, product_id, size, quantity, unit_price_php, product_name)
    values
      (v_order_id, v_product_id, v_size, v_quantity, v_unit_price, v_product_name);
    v_total := v_total + (v_unit_price::bigint * v_quantity);
    if v_total > 2147483647 then
      raise exception 'Order total exceeds supported limit';
    end if;
  end loop;

  if v_count = 0 then
    raise exception 'Cart cannot be empty';
  end if;
  update public.orders set total_php = v_total::integer where id = v_order_id;
  return jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number);
end;
$$;
revoke all on function private.place_order(jsonb) from public, anon;
grant execute on function private.place_order(jsonb) to authenticated;

create or replace function private.cancel_order(p_order_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  update public.orders
    set status = 'Cancelled', updated_at = now()
    where id = p_order_id
      and student_id = v_user_id
      and status = 'Pending';
  if not found then
    raise exception 'Only the owner may cancel a Pending order';
  end if;
  return true;
end;
$$;
revoke all on function private.cancel_order(uuid) from public, anon;
grant execute on function private.cancel_order(uuid) to authenticated;

create or replace function private.admin_set_status(p_order_id uuid, p_new_status text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_status text;
  v_user_id uuid;
  v_allowed boolean := false;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if not private.is_admin() then
    raise exception 'Admin access required';
  end if;
  if p_new_status not in ('Pending', 'Confirmed', 'Preparing', 'Ready for Pickup', 'Completed', 'Cancelled') then
    raise exception 'Invalid order status';
  end if;

  select o.status into v_current_status
    from public.orders o
    where o.id = p_order_id
    for update;
  if not found then
    raise exception 'Order not found';
  end if;
  if v_current_status in ('Completed', 'Cancelled') then
    raise exception 'Completed and Cancelled orders are terminal';
  end if;

  if p_new_status = 'Cancelled' then
    v_allowed := true;
  elsif (v_current_status = 'Pending' and p_new_status = 'Confirmed')
     or (v_current_status = 'Confirmed' and p_new_status = 'Preparing')
     or (v_current_status = 'Preparing' and p_new_status = 'Ready for Pickup')
     or (v_current_status = 'Ready for Pickup' and p_new_status = 'Completed') then
    v_allowed := true;
  end if;
  if not v_allowed then
    raise exception 'Invalid order status transition: % -> %', v_current_status, p_new_status;
  end if;

  update public.orders
    set status = p_new_status, updated_at = now()
    where id = p_order_id;
  return true;
end;
$$;
revoke all on function private.admin_set_status(uuid, text) from public, anon;
grant execute on function private.admin_set_status(uuid, text) to authenticated;

create or replace function private.admin_list_orders()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := (select auth.uid());
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if not private.is_admin() then
    raise exception 'Admin access required';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', o.id,
        'order_number', o.order_number,
        'student_id', o.student_id,
        'student_name', p.full_name,
        'student_number', p.student_number,
        'status', o.status,
        'total_php', o.total_php,
        'created_at', o.created_at,
        'updated_at', o.updated_at,
        'items', coalesce(item_data.items, '[]'::jsonb)
      ) order by o.created_at desc
    ),
    '[]'::jsonb
  )
  into v_result
  from public.orders o
  join public.profiles p on p.id = o.student_id
  left join lateral (
    select jsonb_agg(
      jsonb_build_object(
        'id', oi.id,
        'product_id', oi.product_id,
        'product_name', oi.product_name,
        'size', oi.size,
        'quantity', oi.quantity,
        'unit_price_php', oi.unit_price_php
      ) order by oi.id
    ) as items
    from public.order_items oi
    where oi.order_id = o.id
  ) item_data on true;
  return v_result;
end;
$$;
revoke all on function private.admin_list_orders() from public, anon;
grant execute on function private.admin_list_orders() to authenticated;

-- Public Data API RPC endpoints are invoker wrappers with a fixed empty path.
create or replace function public.place_order(items jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;
  return private.place_order(items);
end;
$$;

create or replace function public.cancel_order(order_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;
  return private.cancel_order(order_id);
end;
$$;

create or replace function public.admin_set_status(order_id uuid, new_status text)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;
  return private.admin_set_status(order_id, new_status);
end;
$$;

create or replace function public.admin_list_orders()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;
  return private.admin_list_orders();
end;
$$;

revoke all on function public.place_order(jsonb) from public, anon;
revoke all on function public.cancel_order(uuid) from public, anon;
revoke all on function public.admin_set_status(uuid, text) from public, anon;
revoke all on function public.admin_list_orders() from public, anon;
grant execute on function public.place_order(jsonb) to authenticated;
grant execute on function public.cancel_order(uuid) to authenticated;
grant execute on function public.admin_set_status(uuid, text) to authenticated;
grant execute on function public.admin_list_orders() to authenticated;
