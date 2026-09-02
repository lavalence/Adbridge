-- ============================================================================
-- ADbridge schema: products, campaigns, payouts
-- Run this in the Supabase SQL editor (or via `supabase db push`).
-- ============================================================================

create extension if not exists "pgcrypto"; -- for gen_random_uuid()

-- ----------------------------------------------------------------------------
-- products
-- ----------------------------------------------------------------------------
create table if not exists public.products (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references auth.users(id) on delete cascade,
  name              text not null,
  description       text,
  price             numeric,
  earning_type      text not null check (earning_type in ('fixed', 'commission')),
  fixed_rate        numeric check (fixed_rate is null or fixed_rate >= 0),
  commission_rate   numeric check (commission_rate is null or commission_rate >= 0),
  image_url         text,
  status            text not null default 'active' check (status in ('active', 'paused')),
  created_at        timestamptz not null default now(),

  -- a fixed-interest product must have a rate, a commission product must have a rate
  constraint products_rate_matches_type check (
    (earning_type = 'fixed'      and fixed_rate      is not null) or
    (earning_type = 'commission' and commission_rate  is not null)
  )
);

create index if not exists products_owner_id_idx on public.products (owner_id);
create index if not exists products_status_idx    on public.products (status);

-- ----------------------------------------------------------------------------
-- campaigns  (one row per "user X is promoting product Y with budget Z")
-- ----------------------------------------------------------------------------
create table if not exists public.campaigns (
  id                 uuid primary key default gen_random_uuid(),
  earner_id          uuid not null references auth.users(id) on delete cascade,
  product_id         uuid not null references public.products(id) on delete cascade,
  status             text not null default 'active' check (status in ('active', 'paused', 'completed')),
  budget             numeric not null check (budget >= 2000 and budget <= 100000),
  payment_reference  text unique,  -- Paystack transaction reference; unique = idempotency guard
  created_at         timestamptz not null default now()
);

create index if not exists campaigns_earner_id_idx  on public.campaigns (earner_id);
create index if not exists campaigns_product_id_idx on public.campaigns (product_id);

-- ----------------------------------------------------------------------------
-- payouts  (wallet ledger: approved = withdrawable, pending = awaiting review)
-- ----------------------------------------------------------------------------
create table if not exists public.payouts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  amount      numeric not null check (amount >= 0),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reference   text,  -- Paystack reference this payout originated from, if any
  created_at  timestamptz not null default now()
);

create index if not exists payouts_user_id_idx  on public.payouts (user_id);
create index if not exists payouts_status_idx   on public.payouts (status);

-- ============================================================================
-- Row Level Security
-- ============================================================================

alter table public.products  enable row level security;
alter table public.campaigns enable row level security;
alter table public.payouts   enable row level security;

-- ---- products ----
-- Anyone logged in can see active products (for the "browse" page) plus their own.
drop policy if exists "products_select" on public.products;
create policy "products_select"
  on public.products for select
  to authenticated
  using (status = 'active' or owner_id = auth.uid());

-- Users can only list products they own.
drop policy if exists "products_insert" on public.products;
create policy "products_insert"
  on public.products for insert
  to authenticated
  with check (owner_id = auth.uid());

-- Users can only edit their own products.
drop policy if exists "products_update" on public.products;
create policy "products_update"
  on public.products for update
  to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- Users can delete their own products. The client also checks for existing
-- campaigns before attempting this (so a promoter's paid-into campaign can't
-- vanish out from under them), but campaigns.product_id -> products.id is
-- ON DELETE CASCADE, so enforce the same rule here as a backstop: block the
-- delete at the database level if any campaign still references the product.
drop policy if exists "products_delete" on public.products;
create policy "products_delete"
  on public.products for delete
  to authenticated
  using (
    owner_id = auth.uid()
    and not exists (
      select 1 from public.campaigns c where c.product_id = products.id
    )
  );

-- ---- campaigns ----
-- Users can see their own campaigns (for the dashboard).
drop policy if exists "campaigns_select" on public.campaigns;
create policy "campaigns_select"
  on public.campaigns for select
  to authenticated
  using (earner_id = auth.uid());

-- Deliberately NO insert/update policy for the `authenticated` role.
-- Campaigns are only ever created by the verify-payment Edge Function,
-- which uses the service-role key and bypasses RLS. This guarantees a
-- campaign can't exist without a Paystack-verified payment behind it.

-- ---- payouts ----
-- Users can see their own payouts (wallet balance / pending review on the dashboard).
drop policy if exists "payouts_select" on public.payouts;
create policy "payouts_select"
  on public.payouts for select
  to authenticated
  using (user_id = auth.uid());

-- Deliberately NO insert/update policy for `authenticated`, same reasoning as
-- campaigns — only the Edge Function (service role) writes payouts. This is
-- what stops a user from crediting their own wallet from devtools.
