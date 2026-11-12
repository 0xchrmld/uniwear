
-- UniWear initial backend schema. The shipped Flutter source already loads its
-- catalog from Supabase (its old local catalog const is absent in this ZIP).
-- Product/price rows below are the deployed seed and are checked against the
-- supplied PRICING_AND_PHOTOS_AUDIT.md by tool/audit_catalog.py.
create sequence public.order_number_seq as bigint start with 1 increment by 1;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  student_number text not null,
  role text not null default 'student' check (role in ('student', 'admin')),
  created_at timestamptz not null default now()
);

create table public.products (
  id text primary key,
  name text not null,
  section text not null check (section in ('Senior High', 'College', 'Integrated')),
  grp text not null check (grp in ('Female', 'Male', 'Accessories', 'P.E.')),
  image text not null,
  description text not null default '',
  needs_verification boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0
);

create table public.product_prices (
  product_id text not null references public.products(id) on delete cascade,
  size text not null,
  price_php integer not null check (price_php > 0),
  sort_order integer not null default 0,
  primary key (product_id, size)
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  student_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'Pending'
    check (status in ('Pending', 'Confirmed', 'Preparing', 'Ready for Pickup', 'Completed', 'Cancelled')),
  total_php integer not null default 0 check (total_php >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id text not null references public.products(id) on delete restrict,
  size text not null,
  quantity integer not null check (quantity between 1 and 10),
  unit_price_php integer not null check (unit_price_php > 0),
  product_name text not null
);

-- Foreign-key and workload indexes. product_prices PK already indexes product_id.
create index orders_student_id_status_idx on public.orders (student_id, status);
create index order_items_order_id_idx on public.order_items (order_id);
create index order_items_product_id_idx on public.order_items (product_id);

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.product_prices enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- Do not inherit broad default grants on newly created public tables.
revoke all on table public.profiles, public.products, public.product_prices,
  public.orders, public.order_items from public, anon, authenticated;
grant usage on schema public to authenticated;

-- Privileged helper; never trust user-editable signup metadata for authorization.
create or replace function public.is_admin()
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

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Create profile automatically from validated signup metadata.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full_name text;
  v_student_number text;
begin
  v_full_name := nullif(trim(new.raw_user_meta_data ->> 'full_name'), '');
  v_student_number := nullif(trim(new.raw_user_meta_data ->> 'student_number'), '');

  if v_full_name is null or v_student_number is null then
    raise exception 'full_name and student_number are required';
  end if;

  insert into public.profiles (id, full_name, student_number)
  values (new.id, v_full_name, v_student_number);

  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Profile access: role is intentionally not granted as an updatable column.
grant select on public.profiles to authenticated;
grant update (full_name, student_number) on public.profiles to authenticated;

create policy profiles_read_self_or_admin
  on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));

create policy profiles_update_self
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Catalog is visible to signed-in users; admins can also inspect inactive products.
grant select, insert, update, delete on public.products to authenticated;
create policy products_read_active_or_admin
  on public.products for select to authenticated
  using (active or (select public.is_admin()));
create policy products_admin_insert
  on public.products for insert to authenticated
  with check ((select public.is_admin()));
create policy products_admin_update
  on public.products for update to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));
create policy products_admin_delete
  on public.products for delete to authenticated
  using ((select public.is_admin()));

grant select, insert, update, delete on public.product_prices to authenticated;
create policy prices_read_active_or_admin
  on public.product_prices for select to authenticated
  using (
    (select public.is_admin())
    or exists (
      select 1 from public.products p
      where p.id = product_prices.product_id and p.active
    )
  );
create policy prices_admin_insert
  on public.product_prices for insert to authenticated
  with check ((select public.is_admin()));
create policy prices_admin_update
  on public.product_prices for update to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));
create policy prices_admin_delete
  on public.product_prices for delete to authenticated
  using ((select public.is_admin()));

-- Orders are read-only to clients. All writes go through the RPCs below.
grant select on public.orders to authenticated;
create policy orders_read_own
  on public.orders for select to authenticated
  using (student_id = (select auth.uid()));

grant select on public.order_items to authenticated;
create policy order_items_read_own
  on public.order_items for select to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_items.order_id
        and o.student_id = (select auth.uid())
    )
  );

-- SECURITY DEFINER RPCs are exposed only to authenticated users and verify identity.
create or replace function public.place_order(items jsonb)
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
    where p.id = v_product_id
      and p.active
      and pp.size = v_size;

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

  update public.orders
    set total_php = v_total::integer
    where id = v_order_id;

  return jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number);
end;
$$;

create or replace function public.cancel_order(order_id uuid)
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
    where id = cancel_order.order_id
      and student_id = v_user_id
      and status = 'Pending';

  if not found then
    raise exception 'Only the owner may cancel a Pending order';
  end if;
  return true;
end;
$$;

create or replace function public.admin_set_status(order_id uuid, new_status text)
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
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  if new_status not in ('Pending', 'Confirmed', 'Preparing', 'Ready for Pickup', 'Completed', 'Cancelled') then
    raise exception 'Invalid order status';
  end if;

  select o.status into v_current_status
    from public.orders o
    where o.id = admin_set_status.order_id
    for update;

  if not found then
    raise exception 'Order not found';
  end if;

  if v_current_status in ('Completed', 'Cancelled') then
    raise exception 'Completed and Cancelled orders are terminal';
  end if;

  if new_status = 'Cancelled' then
    v_allowed := true;
  elsif (v_current_status = 'Pending' and new_status = 'Confirmed')
     or (v_current_status = 'Confirmed' and new_status = 'Preparing')
     or (v_current_status = 'Preparing' and new_status = 'Ready for Pickup')
     or (v_current_status = 'Ready for Pickup' and new_status = 'Completed') then
    v_allowed := true;
  end if;

  if not v_allowed then
    raise exception 'Invalid order status transition: % -> %', v_current_status, new_status;
  end if;

  update public.orders
    set status = new_status, updated_at = now()
    where id = admin_set_status.order_id;

  return true;
end;
$$;

create or replace function public.admin_list_orders()
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
  if not public.is_admin() then
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

revoke all on function public.place_order(jsonb) from public, anon;
revoke all on function public.cancel_order(uuid) from public, anon;
revoke all on function public.admin_set_status(uuid, text) from public, anon;
revoke all on function public.admin_list_orders() from public, anon;
grant execute on function public.place_order(jsonb) to authenticated;
grant execute on function public.cancel_order(uuid) to authenticated;
grant execute on function public.admin_set_status(uuid, text) to authenticated;
grant execute on function public.admin_list_orders() to authenticated;

revoke all on sequence public.order_number_seq from public, anon, authenticated;

-- Deployed catalog seed: 12 approved entries; College Blouse and Polo with Patch are excluded.

insert into public.products
  (id, name, section, grp, image, description, needs_verification, active, sort_order)
values
  ('shs-f-vest', 'Female SHS Vest', 'Senior High', 'Female', 'female_shs_vest.png', 'Gray sailor-style SHS vest. The reference photo includes its blouse and necktie.', false, true, 1),
  ('shs-m-vest', 'Male SHS Vest', 'Senior High', 'Male', 'male_shs_vest.png', 'Dark gray SHS vest, photographed together with a shirt and maroon necktie.', false, true, 2),
  ('hs-blouse', 'H.S. Blouse', 'Senior High', 'Female', 'hs_blouse.png', 'White short-sleeved blouse with dark piping. Confirm the level-specific style before real sales.', true, true, 3),
  ('neu-skirt', 'NEU Skirt', 'Senior High', 'Female', 'neu_skirt.png', 'Gray pleated skirt with a woven crest pattern. Uses numbered sizes.', true, true, 4),
  ('neu-pants', 'NEU Pants', 'Senior High', 'Male', 'neu_pants.png', 'Dark gray straight-leg uniform pants; choose the numbered waist size.', false, true, 5),
  ('female-tie', 'Female Necktie', 'Senior High', 'Accessories', 'female_necktie_illustration.png', 'One-size necktie listed on the SHS price sheet. The product image is illustrative; the actual tie can be seen with the vest in reference photos.', false, true, 6),
  ('junior-tie', 'Junior Necktie', 'Senior High', 'Accessories', 'junior_necktie_illustration.png', 'One-size junior necktie. Illustration only; confirm the exact style and grade eligibility with the counter.', true, true, 7),
  ('college-polo', 'College Polo', 'College', 'Male', 'college_polo.png', 'White short-sleeved button-up uniform shirt with a dark-trimmed chest pocket.', false, true, 8),
  ('college-pants', 'College Pants', 'College', 'Male', 'neu_pants.png', 'Numbered-size gray uniform pants. The SHS/College photograph match needs supplier confirmation.', true, true, 9),
  ('college-skirt', 'College Skirt', 'College', 'Female', 'college_skirt.png', 'Gray skirt with structured front details. Confirm exact uniform level before real sales.', true, true, 10),
  ('integrated-pe-shirt', 'Integrated P.E. Shirt', 'Integrated', 'P.E.', 'pe_shirt.png', 'White round-neck New Era University Integrated School P.E. shirt. Price was not visible, so ordering is disabled.', false, true, 11),
  ('integrated-pe-pants', 'Integrated P.E. Pants', 'Integrated', 'P.E.', 'pe_pants.png', 'Gray drawstring P.E. pants with Integrated School text. Price was not visible, so ordering is disabled.', false, true, 12);

insert into public.product_prices (product_id, size, price_php, sort_order)
values
  ('shs-f-vest', 'XS', 360, 1),
  ('shs-f-vest', 'S', 360, 2),
  ('shs-f-vest', 'M', 410, 3),
  ('shs-f-vest', 'L', 410, 4),
  ('shs-f-vest', 'XL', 460, 5),
  ('shs-f-vest', '2XL', 460, 6),
  ('shs-f-vest', '3XL', 460, 7),
  ('shs-f-vest', '4XL', 510, 8),
  ('shs-m-vest', 'XS', 380, 1),
  ('shs-m-vest', 'S', 380, 2),
  ('shs-m-vest', 'M', 430, 3),
  ('shs-m-vest', 'L', 430, 4),
  ('shs-m-vest', 'XL', 480, 5),
  ('shs-m-vest', '2XL', 480, 6),
  ('shs-m-vest', '3XL', 480, 7),
  ('shs-m-vest', '4XL', 530, 8),
  ('hs-blouse', 'XS', 365, 1),
  ('hs-blouse', 'S', 375, 2),
  ('hs-blouse', 'M', 385, 3),
  ('hs-blouse', 'L', 395, 4),
  ('hs-blouse', 'XL', 405, 5),
  ('hs-blouse', '2XL', 415, 6),
  ('hs-blouse', '3XL', 415, 7),
  ('hs-blouse', '4XL', 435, 8),
  ('neu-skirt', '#24', 360, 1),
  ('neu-skirt', '#26', 380, 2),
  ('neu-skirt', '#28', 400, 3),
  ('neu-skirt', '#30', 420, 4),
  ('neu-skirt', '#32', 440, 5),
  ('neu-skirt', '#34', 460, 6),
  ('neu-pants', '#26', 360, 1),
  ('neu-pants', '#28', 390, 2),
  ('neu-pants', '#30', 420, 3),
  ('neu-pants', '#32', 450, 4),
  ('neu-pants', '#34', 480, 5),
  ('neu-pants', '#36', 510, 6),
  ('neu-pants', '#38', 540, 7),
  ('neu-pants', '#40', 570, 8),
  ('neu-pants', '#42', 600, 9),
  ('female-tie', 'One Size', 75, 1),
  ('junior-tie', 'One Size', 50, 1),
  ('college-polo', 'XS', 370, 1),
  ('college-polo', 'S', 380, 2),
  ('college-polo', 'M', 390, 3),
  ('college-polo', 'L', 400, 4),
  ('college-polo', 'XL', 410, 5),
  ('college-polo', '2XL', 420, 6),
  ('college-polo', '3XL', 430, 7),
  ('college-pants', '#26', 360, 1),
  ('college-pants', '#28', 390, 2),
  ('college-pants', '#30', 420, 3),
  ('college-pants', '#32', 450, 4),
  ('college-pants', '#34', 480, 5),
  ('college-pants', '#36', 510, 6),
  ('college-pants', '#38', 540, 7),
  ('college-pants', '#40', 570, 8),
  ('college-pants', '#42', 600, 9),
  ('college-skirt', 'XS', 285, 1),
  ('college-skirt', 'S', 295, 2),
  ('college-skirt', 'M', 305, 3),
  ('college-skirt', 'L', 315, 4),
  ('college-skirt', 'XL', 335, 5),
  ('college-skirt', '2XL', 345, 6),
  ('college-skirt', '3XL', 355, 7),
  ('college-skirt', '4XL', 365, 8);
