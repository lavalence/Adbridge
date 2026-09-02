-- ADbridge schema update 2
-- Run this in the Supabase SQL editor AFTER schema-update.sql.
-- Changes:
--   1. fixed_amount (₦) -> fixed_rate (%), same 0-100 range as commission_rate
--   2. product_url becomes optional
--   3. image_url becomes required

-- =========================================================
-- 1. fixed_amount -> fixed_rate, now a percentage like commission_rate
-- =========================================================

alter table public.products
  add column if not exists fixed_rate numeric(5,2);

update public.products
  set fixed_rate = fixed_amount
  where fixed_rate is null and fixed_amount is not null;

alter table public.products
  drop constraint if exists products_fixed_amount_check;

alter table public.products
  add constraint products_fixed_rate_check
    check (fixed_rate is null or (fixed_rate >= 0 and fixed_rate <= 100));

-- Re-point the earning-value check at fixed_rate instead of fixed_amount.
alter table public.products
  drop constraint if exists products_earning_value_check;

alter table public.products
  add constraint products_earning_value_check
    check (
      (earning_type = 'fixed' and fixed_rate is not null and commission_rate is null)
      or
      (earning_type = 'commission' and commission_rate is not null and fixed_rate is null)
    );

alter table public.products
  drop column if exists fixed_amount;


-- =========================================================
-- 2. product_url becomes optional
-- =========================================================

alter table public.products
  alter column product_url drop not null;


-- =========================================================
-- 3. image_url becomes required
-- =========================================================
-- If any existing rows have no image yet, set a placeholder first so this
-- doesn't fail — replace the URL below with a real placeholder image if
-- you have one, or delete/update those rows manually before running this.

update public.products
  set image_url = 'https://via.placeholder.com/400'
  where image_url is null;

alter table public.products
  alter column image_url set not null;
