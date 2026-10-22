-- =====================================================================
-- OKADA: initial schema, security (RLS) and ride-matching functions
-- Destination: supabase/migrations/20261021200000_init_schema.sql
--
-- Design rules:
--   * Clients can only write harmless columns (column-level grants + RLS).
--   * Anything sensitive (ride status, matching, approvals, payments)
--     goes through SECURITY DEFINER functions or the service role.
--   * To create your first admin, run once in the SQL editor:
--       update public.profiles set role = 'admin' where phone = '233XXXXXXXXX';
-- =====================================================================

create extension if not exists postgis with schema extensions;

-- ---------- Enums ----------------------------------------------------
create type public.user_role      as enum ('customer', 'rider', 'admin');
create type public.rider_status   as enum ('pending', 'approved', 'rejected', 'suspended');
create type public.doc_type       as enum ('national_id', 'drivers_license', 'vehicle_registration', 'insurance', 'photo');
create type public.doc_status     as enum ('pending', 'verified', 'rejected');
create type public.ride_status    as enum ('requested', 'assigned', 'arriving', 'in_progress', 'completed', 'cancelled', 'no_rider_found');
create type public.payment_status as enum ('pending', 'paid', 'failed', 'refunded');
create type public.complaint_status as enum ('open', 'in_review', 'resolved');

-- ---------- Helpers --------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------- Tables ---------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  role         public.user_role not null default 'customer',
  full_name    text,
  phone        text,
  avatar_url   text,
  is_suspended boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create table public.riders (
  id            uuid primary key default auth.uid() references public.profiles(id) on delete cascade,
  status        public.rider_status not null default 'pending',
  vehicle_make  text,
  vehicle_color text,
  plate_number  text,
  is_online     boolean not null default false,
  rating_avg    numeric(3,2) not null default 0,
  rating_count  integer not null default 0,
  approved_at   timestamptz,
  approved_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.rider_documents (
  id          uuid primary key default gen_random_uuid(),
  rider_id    uuid not null default auth.uid() references public.riders(id) on delete cascade,
  type        public.doc_type not null,
  file_path   text not null,               -- path inside the private 'rider-documents' bucket
  status      public.doc_status not null default 'pending',
  notes       text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at  timestamptz not null default now()
);

create table public.rider_locations (
  rider_id   uuid primary key references public.riders(id) on delete cascade,
  location   extensions.geography(Point, 4326) not null,
  heading    real,
  updated_at timestamptz not null default now()
);

-- Single-row table the admin can edit (values below are placeholders)
create table public.fare_settings (
  id              smallint primary key default 1 check (id = 1),
  base_fare       numeric(10,2) not null default 1.50,
  per_km          numeric(10,2) not null default 0.80,
  per_min         numeric(10,2) not null default 0.10,
  min_fare        numeric(10,2) not null default 4.00,
  commission_rate numeric(4,3)  not null default 0.150 check (commission_rate between 0 and 1),
  updated_at      timestamptz not null default now()
);
insert into public.fare_settings (id) values (1);

create table public.rides (
  id                uuid primary key default gen_random_uuid(),
  customer_id       uuid not null references public.profiles(id),
  rider_id          uuid references public.riders(id),
  status            public.ride_status not null default 'requested',
  pickup_address    text,
  pickup_location   extensions.geography(Point, 4326) not null,
  dropoff_address   text,
  dropoff_location  extensions.geography(Point, 4326) not null,
  distance_km       numeric(8,2) not null check (distance_km > 0),
  duration_min      numeric(8,2) not null check (duration_min > 0),
  fare_estimate     numeric(10,2) not null check (fare_estimate >= 0),
  fare_final        numeric(10,2),
  commission_rate   numeric(4,3) not null,
  commission_amount numeric(10,2),
  rider_amount      numeric(10,2),
  requested_at      timestamptz not null default now(),
  assigned_at       timestamptz,
  started_at        timestamptz,
  completed_at      timestamptz,
  cancelled_at      timestamptz,
  cancel_reason     text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- One row per request sent to a rider (matching + timeout/retry)
create table public.ride_offers (
  id         uuid primary key default gen_random_uuid(),
  ride_id    uuid not null references public.rides(id) on delete cascade,
  rider_id   uuid not null references public.riders(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (ride_id, rider_id)
);

create table public.payments (
  id                 uuid primary key default gen_random_uuid(),
  ride_id            uuid not null references public.rides(id),
  customer_id        uuid not null references public.profiles(id),
  amount             numeric(10,2) not null check (amount >= 0),
  network            text check (network in ('mtn', 'telecel', 'airteltigo')),
  payer_phone        text,
  provider           text,
  provider_reference text unique,
  status             public.payment_status not null default 'pending',
  paid_at            timestamptz,
  created_at         timestamptz not null default now()
);

-- Raw provider webhooks. RLS on, no policies: service role only.
create table public.payment_events (
  id                 uuid primary key default gen_random_uuid(),
  provider_reference text,
  payload            jsonb not null,
  created_at         timestamptz not null default now()
);

create table public.ratings (
  id         uuid primary key default gen_random_uuid(),
  ride_id    uuid not null references public.rides(id) on delete cascade,
  rater_id   uuid not null default auth.uid() references public.profiles(id),
  ratee_id   uuid not null references public.profiles(id),
  score      smallint not null check (score between 1 and 5),
  comment    text,
  created_at timestamptz not null default now(),
  unique (ride_id, rater_id)
);

create table public.complaints (
  id               uuid primary key default gen_random_uuid(),
  ride_id          uuid references public.rides(id),
  reporter_id      uuid not null default auth.uid() references public.profiles(id),
  against_id       uuid references public.profiles(id),
  category         text not null,
  description      text not null,
  status           public.complaint_status not null default 'open',
  resolution_notes text,
  resolved_at      timestamptz,
  created_at       timestamptz not null default now()
);

create table public.audit_logs (
  id         uuid primary key default gen_random_uuid(),
  actor_id   uuid,
  action     text not null,
  entity     text not null,
  entity_id  uuid,
  details    jsonb,
  created_at timestamptz not null default now()
);

-- ---------- Indexes --------------------------------------------------
create index on public.rider_locations using gist (location);
create index on public.rides (customer_id, created_at desc);
create index on public.rides (rider_id, status);
create index on public.rides (status);
create index on public.ride_offers (rider_id, status);
create index on public.ride_offers (ride_id);
create index on public.rider_documents (rider_id);
create index on public.payments (ride_id);
create index on public.ratings (ratee_id);
create index on public.complaints (status);

-- ---------- Triggers -------------------------------------------------
create trigger trg_profiles_updated  before update on public.profiles        for each row execute function public.set_updated_at();
create trigger trg_riders_updated    before update on public.riders          for each row execute function public.set_updated_at();
create trigger trg_rides_updated     before update on public.rides           for each row execute function public.set_updated_at();
create trigger trg_fares_updated     before update on public.fare_settings   for each row execute function public.set_updated_at();
-- Server decides "last seen" so clients cannot fake a fresh location
create trigger trg_locations_updated before insert or update on public.rider_locations for each row execute function public.set_updated_at();

-- New auth user -> profile
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, phone, full_name)
  values (new.id, new.phone, new.raw_user_meta_data ->> 'full_name');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- New rider row -> flip profile role to 'rider'
create or replace function public.handle_new_rider()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set role = 'rider' where id = new.id and role = 'customer';
  return new;
end $$;
create trigger on_rider_created after insert on public.riders for each row execute function public.handle_new_rider();

-- Keep rider rating average up to date
create or replace function public.update_rider_rating()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.riders r
     set rating_count = (select count(*) from public.ratings where ratee_id = new.ratee_id),
         rating_avg   = (select coalesce(round(avg(score), 2), 0) from public.ratings where ratee_id = new.ratee_id)
   where r.id = new.ratee_id;
  return new;
end $$;
create trigger on_rating_created after insert on public.ratings for each row execute function public.update_rider_rating();

-- Internal audit helper (not callable by clients)
create or replace function public.log_audit(p_action text, p_entity text, p_entity_id uuid, p_details jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs (actor_id, action, entity, entity_id, details)
  values (auth.uid(), p_action, p_entity, p_entity_id, p_details);
$$;

-- ---------- Row Level Security ---------------------------------------
alter table public.profiles        enable row level security;
alter table public.riders          enable row level security;
alter table public.rider_documents enable row level security;
alter table public.rider_locations enable row level security;
alter table public.fare_settings   enable row level security;
alter table public.rides           enable row level security;
alter table public.ride_offers     enable row level security;
alter table public.payments        enable row level security;
alter table public.payment_events  enable row level security;
alter table public.ratings         enable row level security;
alter table public.complaints      enable row level security;
alter table public.audit_logs      enable row level security;

-- profiles: own row, admin, or the other person on one of my rides
create policy profiles_select on public.profiles for select to authenticated using (
  id = auth.uid() or public.is_admin() or exists (
    select 1 from public.rides r
    where (r.customer_id = auth.uid() and r.rider_id = profiles.id)
       or (r.rider_id = auth.uid() and r.customer_id = profiles.id)
  )
);
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- riders
create policy riders_select on public.riders for select to authenticated using (
  id = auth.uid() or public.is_admin() or exists (
    select 1 from public.rides r where r.rider_id = riders.id and r.customer_id = auth.uid()
  )
);
create policy riders_insert_own on public.riders for insert to authenticated
  with check (id = auth.uid());
create policy riders_update_own on public.riders for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and (is_online = false or status = 'approved'));

-- rider_documents (review happens via review_document())
create policy docs_select on public.rider_documents for select to authenticated
  using (rider_id = auth.uid() or public.is_admin());
create policy docs_insert_own on public.rider_documents for insert to authenticated
  with check (rider_id = auth.uid());

-- rider_locations
create policy loc_select on public.rider_locations for select to authenticated using (
  rider_id = auth.uid() or public.is_admin() or exists (
    select 1 from public.rides r
    where r.rider_id = rider_locations.rider_id
      and r.customer_id = auth.uid()
      and r.status in ('assigned', 'arriving', 'in_progress')
  )
);
create policy loc_insert_own on public.rider_locations for insert to authenticated
  with check (rider_id = auth.uid() and exists (select 1 from public.riders where id = auth.uid() and status = 'approved'));
create policy loc_update_own on public.rider_locations for update to authenticated
  using (rider_id = auth.uid()) with check (rider_id = auth.uid());

-- fare_settings: everyone signed in can read, admin edits
create policy fares_select on public.fare_settings for select to authenticated using (true);
create policy fares_update_admin on public.fare_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- rides: read-only for clients; changes go through functions
create policy rides_select on public.rides for select to authenticated
  using (customer_id = auth.uid() or rider_id = auth.uid() or public.is_admin());
create policy rides_select_offered on public.rides for select to authenticated using (
  exists (select 1 from public.ride_offers o
          where o.ride_id = rides.id and o.rider_id = auth.uid()
            and o.status = 'pending' and o.expires_at > now())
);

-- ride_offers
create policy offers_select on public.ride_offers for select to authenticated
  using (rider_id = auth.uid() or public.is_admin());

-- payments: written only by the payment webhook (service role)
create policy payments_select on public.payments for select to authenticated
  using (customer_id = auth.uid() or public.is_admin());

-- ratings
create policy ratings_select on public.ratings for select to authenticated
  using (rater_id = auth.uid() or ratee_id = auth.uid() or public.is_admin());
create policy ratings_insert on public.ratings for insert to authenticated with check (
  rater_id = auth.uid() and exists (
    select 1 from public.rides r
    where r.id = ratings.ride_id and r.status = 'completed'
      and ((r.customer_id = auth.uid() and r.rider_id = ratings.ratee_id)
        or (r.rider_id = auth.uid() and r.customer_id = ratings.ratee_id))
  )
);

-- complaints
create policy complaints_select on public.complaints for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin());
create policy complaints_insert on public.complaints for insert to authenticated
  with check (reporter_id = auth.uid());
create policy complaints_update_admin on public.complaints for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- audit_logs: admin read only
create policy audit_select_admin on public.audit_logs for select to authenticated
  using (public.is_admin());

-- ---------- Table privileges (least privilege) -----------------------
revoke all on all tables in schema public from anon, authenticated;
grant select on public.profiles, public.riders, public.rider_documents, public.rider_locations,
                public.fare_settings, public.rides, public.ride_offers, public.payments,
                public.ratings, public.complaints, public.audit_logs to authenticated;

grant update (full_name, avatar_url)                                   on public.profiles        to authenticated;
grant insert (id, vehicle_make, vehicle_color, plate_number)           on public.riders          to authenticated;
grant update (is_online, vehicle_make, vehicle_color, plate_number)    on public.riders          to authenticated;
grant insert (rider_id, type, file_path)                               on public.rider_documents to authenticated;
grant insert (rider_id, location, heading)                             on public.rider_locations to authenticated;
grant update (rider_id, location, heading)                             on public.rider_locations to authenticated;
grant update (base_fare, per_km, per_min, min_fare, commission_rate)   on public.fare_settings   to authenticated;
grant insert (ride_id, ratee_id, score, comment)                       on public.ratings         to authenticated;
grant insert (ride_id, against_id, category, description)              on public.complaints      to authenticated;
grant update (status, resolution_notes, resolved_at)                   on public.complaints      to authenticated;

-- ---------- Storage: private bucket for rider documents --------------
insert into storage.buckets (id, name, public) values ('rider-documents', 'rider-documents', false)
on conflict (id) do nothing;

-- Upload path must be: <rider uid>/<filename>
create policy "riders upload own documents" on storage.objects for insert to authenticated
  with check (bucket_id = 'rider-documents' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "riders and admins read documents" on storage.objects for select to authenticated
  using (bucket_id = 'rider-documents' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- =====================================================================
-- Functions (called from the apps with supabase.rpc(...))
-- =====================================================================

-- Customer: create a ride. Fare is calculated on the server from fare_settings.
create or replace function public.request_ride(
  p_pickup_lat double precision, p_pickup_lng double precision, p_pickup_address text,
  p_dropoff_lat double precision, p_dropoff_lng double precision, p_dropoff_address text,
  p_distance_km numeric, p_duration_min numeric
) returns public.rides
language plpgsql security definer set search_path = public, extensions as $$
declare
  fs public.fare_settings;
  fare numeric;
  r public.rides;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from public.profiles where id = auth.uid() and is_suspended) then
    raise exception 'Account suspended';
  end if;
  if exists (select 1 from public.rides where customer_id = auth.uid()
             and status in ('requested', 'assigned', 'arriving', 'in_progress')) then
    raise exception 'You already have an active ride';
  end if;
  if p_distance_km is null or p_distance_km < 0.1 or p_distance_km > 100
     or p_duration_min is null or p_duration_min <= 0 then
    raise exception 'Invalid trip distance or duration';
  end if;

  select * into fs from public.fare_settings where id = 1;
  fare := round(greatest(fs.min_fare, fs.base_fare + fs.per_km * p_distance_km + fs.per_min * p_duration_min), 2);

  insert into public.rides (customer_id, pickup_address, pickup_location, dropoff_address, dropoff_location,
                            distance_km, duration_min, fare_estimate, commission_rate)
  values (auth.uid(), p_pickup_address, ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
          p_dropoff_address, ST_SetSRID(ST_MakePoint(p_dropoff_lng, p_dropoff_lat), 4326)::geography,
          p_distance_km, p_duration_min, fare, fs.commission_rate)
  returning * into r;
  return r;
end $$;

-- Matching: offer the ride to the nearest eligible rider (20s to respond).
-- Call again after a decline/timeout to retry with the next rider.
-- After 5 offers or no riders nearby the ride becomes 'no_rider_found'.
-- MVP: triggered by the customer app. Later move to an Edge Function/pg_cron.
create or replace function public.dispatch_next_rider(p_ride_id uuid)
returns public.ride_offers
language plpgsql security definer set search_path = public, extensions as $$
declare
  r public.rides;
  cand uuid;
  o public.ride_offers;
  attempts integer;
begin
  select * into r from public.rides where id = p_ride_id for update;
  if not found then raise exception 'Ride not found'; end if;
  if not (r.customer_id = auth.uid() or public.is_admin()) then raise exception 'Not allowed'; end if;
  if r.status <> 'requested' then return null; end if;

  update public.ride_offers set status = 'expired'
   where ride_id = p_ride_id and status = 'pending' and expires_at < now();

  -- an offer is still live: wait for it
  if exists (select 1 from public.ride_offers where ride_id = p_ride_id and status = 'pending') then
    return null;
  end if;

  select count(*) into attempts from public.ride_offers where ride_id = p_ride_id;
  if attempts >= 5 then
    update public.rides set status = 'no_rider_found' where id = p_ride_id;
    return null;
  end if;

  select rl.rider_id into cand
    from public.rider_locations rl
    join public.riders rd   on rd.id = rl.rider_id
    join public.profiles p  on p.id = rd.id
   where rd.status = 'approved' and rd.is_online and not p.is_suspended
     and rl.updated_at > now() - interval '2 minutes'
     and ST_DWithin(rl.location, r.pickup_location, 5000)
     and not exists (select 1 from public.rides x
                      where x.rider_id = rl.rider_id and x.status in ('assigned', 'arriving', 'in_progress'))
     and not exists (select 1 from public.ride_offers ro
                      where ro.ride_id = p_ride_id and ro.rider_id = rl.rider_id)
   order by ST_Distance(rl.location, r.pickup_location)
   limit 1;

  if cand is null then
    update public.rides set status = 'no_rider_found' where id = p_ride_id;
    return null;
  end if;

  insert into public.ride_offers (ride_id, rider_id, expires_at)
  values (p_ride_id, cand, now() + interval '20 seconds')
  returning * into o;
  return o;
end $$;

-- Rider: accept an offer (atomic; only one rider can win a ride)
create or replace function public.accept_ride_offer(p_offer_id uuid)
returns public.rides
language plpgsql security definer set search_path = public, extensions as $$
declare
  o public.ride_offers;
  r public.rides;
begin
  select * into o from public.ride_offers where id = p_offer_id and rider_id = auth.uid() for update;
  if not found then raise exception 'Offer not found'; end if;
  if o.status <> 'pending' or o.expires_at < now() then raise exception 'Offer is no longer available'; end if;
  if not exists (select 1 from public.riders where id = auth.uid() and status = 'approved' and is_online) then
    raise exception 'Rider is not eligible';
  end if;

  update public.rides
     set rider_id = auth.uid(), status = 'assigned', assigned_at = now()
   where id = o.ride_id and status = 'requested' and rider_id is null
   returning * into r;
  if not found then raise exception 'Ride already taken or cancelled'; end if;

  update public.ride_offers set status = 'accepted' where id = o.id;
  update public.ride_offers set status = 'expired' where ride_id = o.ride_id and id <> o.id and status = 'pending';
  return r;
end $$;

create or replace function public.decline_ride_offer(p_offer_id uuid)
returns void
language sql security definer set search_path = public as $$
  update public.ride_offers set status = 'declined'
   where id = p_offer_id and rider_id = auth.uid() and status = 'pending';
$$;

-- Move a ride through its states.
--   rider:    assigned -> arriving -> in_progress -> completed
--   anyone on the ride (or admin): cancel while requested/assigned/arriving
create or replace function public.update_ride_status(
  p_ride_id uuid, p_new_status public.ride_status, p_cancel_reason text default null
) returns public.rides
language plpgsql security definer set search_path = public as $$
declare
  r public.rides;
  uid uuid := auth.uid();
begin
  select * into r from public.rides where id = p_ride_id for update;
  if not found then raise exception 'Ride not found'; end if;
  if not (r.customer_id = uid or r.rider_id = uid or public.is_admin()) then
    raise exception 'Not allowed';
  end if;

  if p_new_status = 'cancelled' then
    if r.status not in ('requested', 'assigned', 'arriving') then
      raise exception 'Ride can no longer be cancelled';
    end if;
    update public.rides
       set status = 'cancelled', cancelled_at = now(), cancel_reason = p_cancel_reason
     where id = p_ride_id returning * into r;

  elsif r.rider_id = uid and (
        (r.status = 'assigned'    and p_new_status = 'arriving')
     or (r.status = 'arriving'    and p_new_status = 'in_progress')
     or (r.status = 'in_progress' and p_new_status = 'completed')) then
    update public.rides set
      status            = p_new_status,
      started_at        = case when p_new_status = 'in_progress' then now() else started_at end,
      completed_at      = case when p_new_status = 'completed'   then now() else completed_at end,
      fare_final        = case when p_new_status = 'completed'   then fare_estimate else fare_final end,
      commission_amount = case when p_new_status = 'completed'   then round(fare_estimate * commission_rate, 2) else commission_amount end,
      rider_amount      = case when p_new_status = 'completed'   then fare_estimate - round(fare_estimate * commission_rate, 2) else rider_amount end
    where id = p_ride_id returning * into r;

  else
    raise exception 'Invalid status change';
  end if;
  return r;
end $$;

-- Admin: review one uploaded document
create or replace function public.review_document(p_doc_id uuid, p_status public.doc_status, p_notes text default null)
returns public.rider_documents
language plpgsql security definer set search_path = public as $$
declare d public.rider_documents;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.rider_documents
     set status = p_status, notes = p_notes, reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_doc_id returning * into d;
  if not found then raise exception 'Document not found'; end if;
  perform public.log_audit('document_reviewed', 'rider_documents', p_doc_id,
                           jsonb_build_object('status', p_status, 'notes', p_notes));
  return d;
end $$;

-- Admin: approve / reject / suspend a rider (approval needs all 4 documents verified)
create or replace function public.set_rider_status(p_rider_id uuid, p_status public.rider_status, p_notes text default null)
returns public.riders
language plpgsql security definer set search_path = public as $$
declare r public.riders;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;

  if p_status = 'approved' and (
       select count(distinct type) from public.rider_documents
        where rider_id = p_rider_id and status = 'verified'
          and type in ('national_id', 'drivers_license', 'vehicle_registration', 'insurance')) < 4 then
    raise exception 'All 4 required documents must be verified first';
  end if;

  update public.riders set
    status      = p_status,
    is_online   = case when p_status = 'approved' then is_online else false end,
    approved_at = case when p_status = 'approved' then now() else approved_at end,
    approved_by = case when p_status = 'approved' then auth.uid() else approved_by end
  where id = p_rider_id returning * into r;
  if not found then raise exception 'Rider not found'; end if;

  perform public.log_audit('rider_status_changed', 'riders', p_rider_id,
                           jsonb_build_object('status', p_status, 'notes', p_notes));
  return r;
end $$;

-- Admin: suspend / reinstate any account
create or replace function public.set_user_suspended(p_user_id uuid, p_suspended boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles set is_suspended = p_suspended where id = p_user_id;
  if p_suspended then
    update public.riders set is_online = false where id = p_user_id;
  end if;
  perform public.log_audit(case when p_suspended then 'user_suspended' else 'user_reinstated' end,
                           'profiles', p_user_id, jsonb_build_object('reason', p_reason));
end $$;

-- Function permissions: signed-in users only; log_audit stays internal
revoke all on function public.request_ride(double precision, double precision, text, double precision, double precision, text, numeric, numeric) from public, anon;
revoke all on function public.dispatch_next_rider(uuid)                      from public, anon;
revoke all on function public.accept_ride_offer(uuid)                        from public, anon;
revoke all on function public.decline_ride_offer(uuid)                       from public, anon;
revoke all on function public.update_ride_status(uuid, public.ride_status, text) from public, anon;
revoke all on function public.review_document(uuid, public.doc_status, text) from public, anon;
revoke all on function public.set_rider_status(uuid, public.rider_status, text) from public, anon;
revoke all on function public.set_user_suspended(uuid, boolean, text)        from public, anon;
revoke all on function public.log_audit(text, text, uuid, jsonb)             from public, anon, authenticated;

grant execute on function public.request_ride(double precision, double precision, text, double precision, double precision, text, numeric, numeric) to authenticated;
grant execute on function public.dispatch_next_rider(uuid)                      to authenticated;
grant execute on function public.accept_ride_offer(uuid)                        to authenticated;
grant execute on function public.decline_ride_offer(uuid)                       to authenticated;
grant execute on function public.update_ride_status(uuid, public.ride_status, text) to authenticated;
grant execute on function public.review_document(uuid, public.doc_status, text) to authenticated;
grant execute on function public.set_rider_status(uuid, public.rider_status, text) to authenticated;
grant execute on function public.set_user_suspended(uuid, boolean, text)        to authenticated;

-- ---------- Admin dashboard stats (admin only) -----------------------
create or replace view public.admin_daily_stats with (security_invoker = true) as
select date_trunc('day', completed_at)::date as day,
       count(*)                                as completed_rides,
       coalesce(sum(fare_final), 0)            as gross_fares,
       coalesce(sum(commission_amount), 0)     as commission
  from public.rides
 where status = 'completed' and public.is_admin()
 group by 1;
grant select on public.admin_daily_stats to authenticated;

-- ---------- Realtime (RLS still applies) -----------------------------
alter publication supabase_realtime add table public.rides, public.ride_offers, public.rider_locations;
