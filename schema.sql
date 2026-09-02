-- ADbridge schema
-- Run this in the Supabase SQL editor (Project → SQL Editor → New query).
-- Safe to run top-to-bottom on a fresh project.

-- Needed for gen_random_uuid(). Usually already enabled on Supabase, but
-- this is a no-op if it is.
create extension if not exists pgcrypto;

-- =========================================================
-- products — items an advertiser lists for earners to promote
-- =========================================================
create table if not exists public.products (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references auth.users (id) on delete cascade,
  name             text not null check (char_length(name) between 1 and 120),
  description      text not null check (char_length(description) between 1 and 1000),
  price            numeric(12,2) not null check (price >= 0),
  commission_rate  numeric(5,2) not null check (commission_rate >= 0 and commission_rate <= 100),
  product_url      text not null,
  image_url        text,
  status           text not null default 'active' check (status in ('active', 'paused')),
  created_at       timestamptz not null default now()
);

create index if not exists products_owner_id_idx on public.products (owner_id);
create index if not exists products_status_idx on public.products (status);

alter table public.products enable row level security;

-- Anyone signed in can see active products (needed for browse.html),
-- and owners can always see their own regardless of status.
create policy "products_select" on public.products
  for select
  to authenticated
  using (status = 'active' or owner_id = auth.uid());

-- You can only list products under your own account.
create policy "products_insert_own" on public.products
  for insert
  to authenticated
  with check (owner_id = auth.uid());

-- You can only edit/pause your own listings.
create policy "products_update_own" on public.products
  for update
  to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy "products_delete_own" on public.products
  for delete
  to authenticated
  using (owner_id = auth.uid());


-- =========================================================
-- campaigns — an earner choosing to promote a product
-- =========================================================
create table if not exists public.campaigns (
  id          uuid primary key default gen_random_uuid(),
  earner_id   uuid not null references auth.users (id) on delete cascade,
  product_id  uuid not null references public.products (id) on delete cascade,
  status      text not null default 'active' check (status in ('active', 'completed')),
  created_at  timestamptz not null default now(),

  -- an earner can only promote a given product once
  unique (earner_id, product_id)
);

create index if not exists campaigns_earner_id_idx on public.campaigns (earner_id);
create index if not exists campaigns_product_id_idx on public.campaigns (product_id);

alter table public.campaigns enable row level security;

-- Earners can see their own campaigns; product owners can see who is
-- promoting their product.
create policy "campaigns_select" on public.campaigns
  for select
  to authenticated
  using (
    earner_id = auth.uid()
    or exists (
      select 1 from public.products p
      where p.id = campaigns.product_id
        and p.owner_id = auth.uid()
    )
  );

-- You can only create a campaign as yourself, and only against a product
-- that's actually active.
create policy "campaigns_insert_own" on public.campaigns
  for insert
  to authenticated
  with check (
    earner_id = auth.uid()
    and exists (
      select 1 from public.products p
      where p.id = product_id
        and p.status = 'active'
    )
  );

-- Earners can update (e.g. mark completed) only their own campaigns.
create policy "campaigns_update_own" on public.campaigns
  for update
  to authenticated
  using (earner_id = auth.uid())
  with check (earner_id = auth.uid());

create policy "campaigns_delete_own" on public.campaigns
  for delete
  to authenticated
  using (earner_id = auth.uid());


-- =========================================================
-- payouts — wallet transactions behind the dashboard balance
-- =========================================================
create table if not exists public.payouts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  campaign_id uuid references public.campaigns (id) on delete set null,
  amount      numeric(12,2) not null check (amount >= 0),
  status      text not null default 'pending' check (status in ('pending', 'approved')),
  created_at  timestamptz not null default now()
);

create index if not exists payouts_user_id_idx on public.payouts (user_id);
create index if not exists payouts_status_idx on public.payouts (status);

alter table public.payouts enable row level security;

-- Users can only ever see their own payout rows.
create policy "payouts_select_own" on public.payouts
  for select
  to authenticated
  using (user_id = auth.uid());

-- No insert/update/delete policies for regular users on purpose — payouts
-- should only be written by a trusted backend process (e.g. a Supabase
-- Edge Function or the service_role key), not directly from the browser.
-- If you need an admin to manage payouts from the SQL editor or a
-- service-role script, that bypasses RLS automatically.
