-- ADbridge schema update
-- Run this in the Supabase SQL editor AFTER your original schema.sql.
-- Brings `products` in line with the fixed-interest/commission toggle
-- and file-upload image picker added to product.html.

-- =========================================================
-- products — split commission_rate into earning_type + two nullable amounts
-- =========================================================

-- Add the new columns (nullable for now so this doesn't fail on existing rows).
alter table public.products
  add column if not exists earning_type text,
  add column if not exists fixed_amount numeric(12,2);

-- Backfill existing rows: everything that had a commission_rate before
-- becomes earning_type = 'commission'.
update public.products
  set earning_type = 'commission'
  where earning_type is null;

-- Now that every row has a value, enforce it going forward.
alter table public.products
  alter column earning_type set not null,
  add constraint products_earning_type_check
    check (earning_type in ('fixed', 'commission'));

-- commission_rate is no longer required on every row (only when
-- earning_type = 'commission'), so drop the old not-null constraint
-- and re-add the range check as a nullable-aware one.
alter table public.products
  alter column commission_rate drop not null;

alter table public.products
  drop constraint if exists products_commission_rate_check;

alter table public.products
  add constraint products_commission_rate_check
    check (commission_rate is null or (commission_rate >= 0 and commission_rate <= 100)),
  add constraint products_fixed_amount_check
    check (fixed_amount is null or fixed_amount >= 0);

-- Make sure exactly the right field is populated for each earning type.
alter table public.products
  add constraint products_earning_value_check
    check (
      (earning_type = 'fixed' and fixed_amount is not null and commission_rate is null)
      or
      (earning_type = 'commission' and commission_rate is not null and fixed_amount is null)
    );


-- =========================================================
-- storage — product-images bucket for the gallery image picker
-- =========================================================

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

-- Anyone can view images (bucket is public, needed for browse.html cards).
create policy "product_images_public_read"
  on storage.objects
  for select
  to public
  using (bucket_id = 'product-images');

-- Signed-in users can only upload into a folder named after their own
-- user id (matches the `${currentUser.id}/...` path used in product.html).
create policy "product_images_insert_own"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Owners can delete/replace their own uploaded images.
create policy "product_images_delete_own"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
