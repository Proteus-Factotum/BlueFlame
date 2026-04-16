create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  display_name text,
  notification_email text not null,
  timezone text not null default 'Europe/Copenhagen',
  created_at timestamptz not null default now()
);

create table public.availability_rules (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_time time not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.blocked_dates (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  blocked_on date not null,
  created_at timestamptz not null default now(),
  unique (profile_id, blocked_on)
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  starts_at timestamptz not null,
  guest_name text not null,
  guest_contact text not null,
  created_at timestamptz not null default now(),
  unique (profile_id, starts_at)
);

create index availability_rules_profile_id_idx on public.availability_rules (profile_id);
create index blocked_dates_profile_id_idx on public.blocked_dates (profile_id);
create index bookings_profile_id_idx on public.bookings (profile_id);
create index bookings_starts_at_idx on public.bookings (starts_at);

alter table public.profiles enable row level security;
alter table public.availability_rules enable row level security;
alter table public.blocked_dates enable row level security;
alter table public.bookings enable row level security;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  email_base text;
  candidate_slug text;
  suffix integer := 0;
begin
  email_base := lower(split_part(coalesce(new.email, new.id::text), '@', 1));
  email_base := regexp_replace(email_base, '[^a-z0-9]+', '-', 'g');
  email_base := trim(both '-' from email_base);
  candidate_slug := coalesce(nullif(email_base, ''), 'profile');

  while exists (select 1 from public.profiles where slug = candidate_slug) loop
    suffix := suffix + 1;
    candidate_slug := email_base || '-' || suffix::text;
  end loop;

  insert into public.profiles (id, slug, display_name, notification_email)
  values (new.id, candidate_slug, coalesce(new.raw_user_meta_data ->> 'display_name', ''), new.email);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create policy "profiles_select_own"
on public.profiles
for select
to authenticated
using (auth.uid() = id);

create policy "profiles_insert_own"
on public.profiles
for insert
to authenticated
with check (auth.uid() = id);

create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

create policy "availability_rules_manage_own"
on public.availability_rules
for all
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

create policy "blocked_dates_manage_own"
on public.blocked_dates
for all
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

create policy "bookings_select_own"
on public.bookings
for select
to authenticated
using (profile_id = auth.uid());

create or replace function public.get_public_booking_options(target_slug text)
returns table (
  starts_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_record public.profiles%rowtype;
  local_today date;
  min_day date;
  max_day date;
begin
  select *
  into profile_record
  from public.profiles
  where slug = target_slug;

  if not found then
    return;
  end if;

  local_today := (now() at time zone profile_record.timezone)::date;
  min_day := local_today + 2;
  max_day := local_today + 14;

  return query
  with candidate_days as (
    select generate_series(min_day, max_day, interval '1 day')::date as slot_day
  ),
  generated_slots as (
    select
      (((candidate_days.slot_day + availability_rules.start_time) at time zone profile_record.timezone)) as starts_at
    from candidate_days
    join public.availability_rules
      on availability_rules.profile_id = profile_record.id
     and availability_rules.is_active = true
     and availability_rules.weekday = extract(dow from candidate_days.slot_day)::smallint
    left join public.blocked_dates
      on blocked_dates.profile_id = profile_record.id
     and blocked_dates.blocked_on = candidate_days.slot_day
    where blocked_dates.id is null
  )
  select generated_slots.starts_at
  from generated_slots
  left join public.bookings
    on bookings.profile_id = profile_record.id
   and bookings.starts_at = generated_slots.starts_at
  where bookings.id is null
  order by generated_slots.starts_at asc;
end;
$$;

grant execute on function public.get_public_booking_options(text) to anon, authenticated;

create or replace function public.create_booking(
  target_slug text,
  requested_starts_at timestamptz,
  guest_name text,
  guest_contact text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_record public.profiles%rowtype;
  local_today date;
  requested_local_date date;
begin
  if coalesce(trim(guest_name), '') = '' then
    raise exception 'Navn mangler.';
  end if;

  if coalesce(trim(guest_contact), '') = '' then
    raise exception 'Kontakt mangler.';
  end if;

  select *
  into profile_record
  from public.profiles
  where slug = target_slug;

  if not found then
    raise exception 'Booking-siden findes ikke.';
  end if;

  local_today := (now() at time zone profile_record.timezone)::date;
  requested_local_date := (requested_starts_at at time zone profile_record.timezone)::date;

  if requested_local_date < local_today + 2 then
    raise exception 'Tidspunktet er for taet paa.';
  end if;

  if requested_local_date > local_today + 14 then
    raise exception 'Tidspunktet ligger for langt ude i fremtiden.';
  end if;

  if not exists (
    select 1
    from public.get_public_booking_options(target_slug) available
    where available.starts_at = requested_starts_at
  ) then
    raise exception 'Tidspunktet er ikke laengere ledigt.';
  end if;

  insert into public.bookings (profile_id, starts_at, guest_name, guest_contact)
  values (profile_record.id, requested_starts_at, trim(guest_name), trim(guest_contact));

  return jsonb_build_object(
    'ok', true,
    'starts_at', requested_starts_at
  );
exception
  when unique_violation then
    raise exception 'Tidspunktet er lige blevet taget.';
end;
$$;

grant execute on function public.create_booking(text, timestamptz, text, text) to anon, authenticated;

comment on function public.get_public_booking_options(text)
is 'Returns the public booking options generated from recurring availability rules for the next 2-14 days.';

comment on function public.create_booking(text, timestamptz, text, text)
is 'Creates a booking for a public booking page when the requested slot is still valid and available.';

-- Example recurring rules for a newly created profile:
-- insert into public.availability_rules (profile_id, weekday, start_time)
-- select id, 2, '16:00'::time from public.profiles where slug = 'robin-hansen';
-- insert into public.availability_rules (profile_id, weekday, start_time)
-- select id, 4, '18:30'::time from public.profiles where slug = 'robin-hansen';
