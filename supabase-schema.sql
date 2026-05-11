-- =====================================================
-- HITTALAST.SE — Supabase databasschema
-- Kör hela filen i Supabase SQL Editor (Settings → SQL Editor → New query → klistra in → Run)
-- =====================================================

-- Säker grund
create extension if not exists "uuid-ossp";

-- =====================================================
-- 1. PROFILES (utökar auth.users med våra fält)
-- =====================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('akare','chauffor','admin')) default 'akare',
  name text not null,
  phone text,
  company text,
  org_nr text,
  address text,
  contact_person text,
  offices jsonb default '[]'::jsonb,
  -- Faktureringsuppgifter
  invoice_recipient text,
  invoice_address text,
  invoice_email text,
  invoice_gln text,
  invoice_reference text,
  -- Prenumeration
  subscription_active boolean default false,
  subscription_activated_at timestamptz,
  manual_monthly_fee numeric,
  -- Metadata
  created_at timestamptz default now()
);

-- Trigger: skapa profil automatiskt när någon registrerar sig via Supabase Auth
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, role, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'role', 'akare'), coalesce(new.raw_user_meta_data->>'name', ''));
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- =====================================================
-- 2. VEHICLES — åkares bilar
-- =====================================================
create table if not exists public.vehicles (
  id uuid primary key default uuid_generate_v4(),
  hauler_id uuid not null references public.profiles(id) on delete cascade,
  reg_nr text not null,
  model text,
  type text,
  max_weight numeric,
  max_flm numeric,
  adr boolean default false,
  tail_lift boolean default false,
  open_side boolean default false,
  created_at timestamptz default now()
);
create index if not exists vehicles_hauler_idx on public.vehicles(hauler_id);

-- =====================================================
-- 3. DRIVERS — chaufförer kopplade till åkare
-- =====================================================
create table if not exists public.drivers (
  id uuid primary key default uuid_generate_v4(),
  hauler_id uuid not null references public.profiles(id) on delete cascade,
  -- Knyts till profiles om chaufför har eget login (annars null)
  profile_id uuid references public.profiles(id) on delete set null,
  name text not null,
  email text,
  phone text,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  active boolean default true,
  created_at timestamptz default now()
);
create index if not exists drivers_hauler_idx on public.drivers(hauler_id);

-- =====================================================
-- 4. BOOKINGS — körningar
-- =====================================================
create table if not exists public.bookings (
  id uuid primary key default uuid_generate_v4(),
  buyer_id uuid not null references public.profiles(id) on delete cascade,
  hauler_id uuid references public.profiles(id) on delete set null,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  driver_id uuid references public.drivers(id) on delete set null,

  from_location text not null,
  to_location text not null,
  from_postal text,
  to_postal text,
  weight numeric,
  flm numeric,
  pallets integer,

  load_date date,
  load_time time,
  unload_date date,
  unload_time time,

  adr boolean default false,
  tail_lift boolean default false,
  open_side boolean default false,

  price numeric,
  description text,

  -- Bilder läggs i Supabase Storage; här bara URL/path
  booking_image_url text,
  proof_image_url text,

  status text not null check (status in ('open','accepted','completed','cancelled')) default 'open',
  commission numeric default 0,
  contact_visible boolean default false,

  created_at timestamptz default now(),
  accepted_at timestamptz,
  completed_at timestamptz,
  assigned_at timestamptz,
  completed_by_driver_id uuid references public.drivers(id) on delete set null,
  source_ref text  -- för ev. framtida import
);
create index if not exists bookings_buyer_idx on public.bookings(buyer_id);
create index if not exists bookings_hauler_idx on public.bookings(hauler_id);
create index if not exists bookings_status_idx on public.bookings(status);

-- =====================================================
-- 5. BIDS — bud och motbud
-- =====================================================
create table if not exists public.bids (
  id uuid primary key default uuid_generate_v4(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  hauler_id uuid not null references public.profiles(id) on delete cascade,
  -- rounds: [{ by: 'hauler'|'buyer', amount: number, at: iso }]
  rounds jsonb not null default '[]'::jsonb,
  status text not null check (status in ('pending','accepted','rejected','withdrawn')) default 'pending',
  created_at timestamptz default now()
);
create index if not exists bids_booking_idx on public.bids(booking_id);
create index if not exists bids_hauler_idx on public.bids(hauler_id);

-- =====================================================
-- 6. MESSAGES — chatt per (bokning, åkare)
-- =====================================================
create table if not exists public.messages (
  id uuid primary key default uuid_generate_v4(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  -- Hauler-id definierar tråden (en tråd per bjudande åkare)
  hauler_id uuid not null references public.profiles(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  content text not null,
  read boolean default false,
  created_at timestamptz default now()
);
create index if not exists messages_thread_idx on public.messages(booking_id, hauler_id);

-- =====================================================
-- 7. NOTIFICATIONS
-- =====================================================
create table if not exists public.notifications (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,  -- 'new_bid', 'counter', 'accepted', 'completed', etc.
  booking_id uuid references public.bookings(id) on delete cascade,
  bid_id uuid references public.bids(id) on delete cascade,
  message text not null,
  read boolean default false,
  created_at timestamptz default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id);
create index if not exists notifications_unread_idx on public.notifications(user_id, read) where read = false;

-- =====================================================
-- 8. FREE_VEHICLES — lediga bilar som söker last
-- =====================================================
create table if not exists public.free_vehicles (
  id uuid primary key default uuid_generate_v4(),
  hauler_id uuid not null references public.profiles(id) on delete cascade,
  vehicle_id uuid references public.vehicles(id) on delete set null,

  current_location text not null,
  destination text,
  anywhere boolean default false,
  free_flm numeric,
  adr boolean default false,
  tail_lift boolean default false,
  open_side boolean default false,
  reefer boolean default false,
  available_from date,
  available_time time,
  comment text,
  status text not null check (status in ('available','archived')) default 'available',

  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index if not exists free_vehicles_hauler_idx on public.free_vehicles(hauler_id);
create index if not exists free_vehicles_status_idx on public.free_vehicles(status);

-- =====================================================
-- 9. PRICING_TIERS — admin kan ändra prislista
-- =====================================================
create table if not exists public.pricing_tiers (
  id uuid primary key default uuid_generate_v4(),
  min_vehicles integer not null,
  max_vehicles integer not null,
  monthly_price numeric not null,
  created_at timestamptz default now()
);

-- Seedvärden för prislista
insert into public.pricing_tiers (min_vehicles, max_vehicles, monthly_price)
values (1, 5, 995), (6, 15, 1995), (16, 30, 2495)
on conflict do nothing;

-- =====================================================
-- 10. ROW LEVEL SECURITY (RLS) — säkerhetspolicies
-- =====================================================
alter table public.profiles enable row level security;
alter table public.vehicles enable row level security;
alter table public.drivers enable row level security;
alter table public.bookings enable row level security;
alter table public.bids enable row level security;
alter table public.messages enable row level security;
alter table public.notifications enable row level security;
alter table public.free_vehicles enable row level security;
alter table public.pricing_tiers enable row level security;

-- Hjälpfunktion: är användaren admin?
create or replace function public.is_admin()
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- PROFILES: alla inloggade kan se grundinfo (namn/företag), bara ägaren + admin kan redigera
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select using (auth.uid() is not null);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update using (auth.uid() = id or public.is_admin());

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles for insert with check (auth.uid() = id);

drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles for all using (public.is_admin());

-- VEHICLES: bara åkaren själv + admin
drop policy if exists vehicles_owner on public.vehicles;
create policy vehicles_owner on public.vehicles for all using (auth.uid() = hauler_id or public.is_admin());

-- DRIVERS: bara åkaren själv + admin
drop policy if exists drivers_owner on public.drivers;
create policy drivers_owner on public.drivers for all using (auth.uid() = hauler_id or public.is_admin());

-- BOOKINGS: öppna ses av alla inloggade, andra status bara av parterna
drop policy if exists bookings_read on public.bookings;
create policy bookings_read on public.bookings for select using (
  status = 'open'
  or auth.uid() = buyer_id
  or auth.uid() = hauler_id
  or public.is_admin()
);

drop policy if exists bookings_insert on public.bookings;
create policy bookings_insert on public.bookings for insert with check (auth.uid() = buyer_id);

drop policy if exists bookings_update on public.bookings;
create policy bookings_update on public.bookings for update using (
  auth.uid() = buyer_id or auth.uid() = hauler_id or public.is_admin()
);

drop policy if exists bookings_delete on public.bookings;
create policy bookings_delete on public.bookings for delete using (
  auth.uid() = buyer_id or public.is_admin()
);

-- BIDS: ägare till budet + bokningsägaren + admin
drop policy if exists bids_read on public.bids;
create policy bids_read on public.bids for select using (
  auth.uid() = hauler_id
  or exists (select 1 from public.bookings b where b.id = booking_id and b.buyer_id = auth.uid())
  or public.is_admin()
);

drop policy if exists bids_insert on public.bids;
create policy bids_insert on public.bids for insert with check (auth.uid() = hauler_id);

drop policy if exists bids_update on public.bids;
create policy bids_update on public.bids for update using (
  auth.uid() = hauler_id
  or exists (select 1 from public.bookings b where b.id = booking_id and b.buyer_id = auth.uid())
  or public.is_admin()
);

-- MESSAGES: bara avsändare/mottagare i tråden + admin
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select using (
  auth.uid() = sender_id
  or auth.uid() = hauler_id
  or exists (select 1 from public.bookings b where b.id = booking_id and b.buyer_id = auth.uid())
  or public.is_admin()
);

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert with check (auth.uid() = sender_id);

-- NOTIFICATIONS: bara mottagaren + admin
drop policy if exists notifications_owner on public.notifications;
create policy notifications_owner on public.notifications for all using (auth.uid() = user_id or public.is_admin());

-- FREE_VEHICLES: alla inloggade kan se, bara ägaren kan ändra
drop policy if exists free_vehicles_read on public.free_vehicles;
create policy free_vehicles_read on public.free_vehicles for select using (auth.uid() is not null);

drop policy if exists free_vehicles_write on public.free_vehicles;
create policy free_vehicles_write on public.free_vehicles for all using (auth.uid() = hauler_id or public.is_admin());

-- PRICING_TIERS: alla läser, bara admin skriver
drop policy if exists pricing_read on public.pricing_tiers;
create policy pricing_read on public.pricing_tiers for select using (true);

drop policy if exists pricing_admin on public.pricing_tiers;
create policy pricing_admin on public.pricing_tiers for all using (public.is_admin());

-- =====================================================
-- 11. STORAGE BUCKETS för bilder
-- =====================================================
-- Skapa buckets manuellt via Supabase UI eller:
insert into storage.buckets (id, name, public) values ('booking-images', 'booking-images', true) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('proof-images', 'proof-images', false) on conflict (id) do nothing;

-- Policies för bucket-uppladdning (inloggade får ladda upp till sin egen mapp)
drop policy if exists storage_booking_upload on storage.objects;
create policy storage_booking_upload on storage.objects for insert
  with check (bucket_id in ('booking-images','proof-images') and auth.uid() is not null);

drop policy if exists storage_booking_read on storage.objects;
create policy storage_booking_read on storage.objects for select
  using (bucket_id = 'booking-images' or (bucket_id = 'proof-images' and auth.uid() is not null));

-- =====================================================
-- KLART! Schemat är installerat.
-- Nästa steg: skapa admin-användare manuellt:
-- 1. Authentication → Users → Add user → fyll i mejl + lösenord
-- 2. Kör i SQL Editor: update profiles set role='admin' where id = 'USER-UUID-HÄR';
-- =====================================================
