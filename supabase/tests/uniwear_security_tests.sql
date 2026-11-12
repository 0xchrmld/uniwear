-- Run with a Supabase SQL Editor connection as postgres.
-- All test users/orders are rolled back at the end; this does not persist test data.
begin;

do $$
declare
  v_student_a uuid := gen_random_uuid();
  v_student_b uuid := gen_random_uuid();
begin
  perform set_config('uniwear.test_student_a', v_student_a::text, true);
  perform set_config('uniwear.test_student_b', v_student_b::text, true);

  insert into auth.users
    (id, aud, role, email, encrypted_password, email_confirmed_at,
     raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (v_student_a, 'authenticated', 'authenticated',
     'uniwear-test-a-' || v_student_a::text || '@example.invalid',
     '', now(), '{"provider":"email","providers":["email"]}',
     '{"full_name":"UniWear Test A","student_number":"TEST-A"}', now(), now()),
    (v_student_b, 'authenticated', 'authenticated',
     'uniwear-test-b-' || v_student_b::text || '@example.invalid',
     '', now(), '{"provider":"email","providers":["email"]}',
     '{"full_name":"UniWear Test B","student_number":"TEST-B"}', now(), now());
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('uniwear.test_student_a'), true);
select set_config('request.jwt.claims',
  jsonb_build_object('sub', current_setting('uniwear.test_student_a'),
                     'role', 'authenticated')::text, true);

-- A client-supplied price is ignored; College Polo M is seeded at PHP 390.
select set_config(
  'uniwear.test_order_id',
  public.place_order('[{"product_id":"college-polo","size":"M","quantity":1,"price_php":1}]')->>'order_id',
  true
);

do $$
begin
  if (select total_php from public.orders
      where id = current_setting('uniwear.test_order_id')::uuid) <> 390 then
    raise exception 'FAIL: place_order accepted a tampered client price';
  end if;
end;
$$;

-- Switch to student B: A's order must be invisible.
select set_config('request.jwt.claim.sub', current_setting('uniwear.test_student_b'), true);
select set_config('request.jwt.claims',
  jsonb_build_object('sub', current_setting('uniwear.test_student_b'),
                     'role', 'authenticated')::text, true);

do $$
begin
  if exists (select 1 from public.orders
             where id = current_setting('uniwear.test_order_id')::uuid) then
    raise exception 'FAIL: student can read another student order';
  end if;
  if exists (select 1 from public.order_items
             where order_id = current_setting('uniwear.test_order_id')::uuid) then
    raise exception 'FAIL: student can read another student order items';
  end if;

  begin
    insert into public.orders (order_number, student_id, total_php)
    values ('UW-999998', current_setting('uniwear.test_student_b')::uuid, 100);
    raise exception 'FAIL: student inserted directly into orders';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.order_items
      (order_id, product_id, size, quantity, unit_price_php, product_name)
    values (current_setting('uniwear.test_order_id')::uuid,
            'college-polo', 'M', 1, 1, 'Tampered');
    raise exception 'FAIL: student inserted directly into order_items';
  exception when insufficient_privilege then
    null;
  end;

  begin
    update public.profiles set role = 'admin'
    where id = current_setting('uniwear.test_student_b')::uuid;
    raise exception 'FAIL: student changed their role';
  exception when insufficient_privilege then
    null;
  end;

  begin
    perform public.admin_set_status(
      current_setting('uniwear.test_order_id')::uuid, 'Confirmed');
    raise exception 'FAIL: non-admin changed order status';
  exception when raise_exception then
    if sqlerrm <> 'Admin access required' then raise; end if;
  end;
end;
$$;

reset role;

-- Make the order Confirmed as the database owner, then prove the owner cannot cancel it.
update public.orders
set status = 'Confirmed'
where id = current_setting('uniwear.test_order_id')::uuid;

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('uniwear.test_student_a'), true);
select set_config('request.jwt.claims',
  jsonb_build_object('sub', current_setting('uniwear.test_student_a'),
                     'role', 'authenticated')::text, true);

do $$
begin
  begin
    perform public.cancel_order(current_setting('uniwear.test_order_id')::uuid);
    raise exception 'FAIL: student cancelled a Confirmed order';
  exception when raise_exception then
    if sqlerrm <> 'Only the owner may cancel a Pending order' then raise; end if;
  end;

  begin
    perform public.place_order(
      '[{"product_id":"integrated-pe-shirt","size":"One Size","quantity":1}]'
    );
    raise exception 'FAIL: view-only P.E. item was orderable';
  exception when raise_exception then
    if sqlerrm not like 'Product is inactive, view-only, or size is unavailable:%' then raise; end if;
  end;
end;
$$;

rollback;
