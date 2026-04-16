create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  display_name text,
  notification_email text not null,
  created_at timestamptz not null default now()
);

create table public.availability_days (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  available_on date not null,
  start_time time not null,
  created_at timestamptz not null default now(),
  unique (profile_id, available_on)
);

create table public.availability_automations (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  start_time time not null,
  weekdays smallint[] not null default '{}',
  created_at timestamptz not null default now(),
  check (
    array_position(weekdays, null) is null
    and weekdays <@ array[0, 1, 2, 3, 4, 5, 6]::smallint[]
  )
);

create table public.availability_overrides (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  available_on date not null,
  action text not null check (action in ('set', 'clear')),
  start_time time,
  created_at timestamptz not null default now(),
  primary key (profile_id, available_on),
  check (
    (action = 'set' and start_time is not null)
    or (action = 'clear' and start_time is null)
  )
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  booked_on date not null,
  start_time time not null,
  guest_name text not null,
  guest_contact text not null,
  created_at timestamptz not null default now(),
  unique (profile_id, booked_on)
);

create index availability_days_profile_id_idx on public.availability_days (profile_id);
create index availability_days_available_on_idx on public.availability_days (available_on);
create index availability_automations_profile_id_idx on public.availability_automations (profile_id);
create index availability_overrides_profile_id_idx on public.availability_overrides (profile_id);
create index availability_overrides_available_on_idx on public.availability_overrides (available_on);
create index bookings_profile_id_idx on public.bookings (profile_id);
create index bookings_booked_on_idx on public.bookings (booked_on);

alter table public.profiles enable row level security;
alter table public.availability_days enable row level security;
alter table public.availability_automations enable row level security;
alter table public.availability_overrides enable row level security;
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

create policy "availability_days_manage_own"
on public.availability_days
for all
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

create policy "availability_automations_manage_own"
on public.availability_automations
for all
to authenticated
using (profile_id = auth.uid())
with check (profile_id = auth.uid());

create policy "availability_overrides_manage_own"
on public.availability_overrides
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
  available_on date,
  start_time time
)
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_record public.profiles%rowtype;
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

  min_day := current_date + 2;
  max_day := current_date + 14;

  return query
  select availability_days.available_on, availability_days.start_time
  from public.availability_days
  left join public.bookings
    on bookings.profile_id = availability_days.profile_id
   and bookings.booked_on = availability_days.available_on
  where availability_days.profile_id = profile_record.id
    and availability_days.available_on between min_day and max_day
    and bookings.id is null
  order by availability_days.available_on asc;
end;
$$;

grant execute on function public.get_public_booking_options(text) to anon, authenticated;

create or replace function public.create_booking(
  target_slug text,
  requested_date date,
  requested_time time,
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
begin
  if coalesce(trim(guest_name), '') = '' then
    raise exception 'Name is required.';
  end if;

  if coalesce(trim(guest_contact), '') = '' then
    raise exception 'Contact information is required.';
  end if;

  select *
  into profile_record
  from public.profiles
  where slug = target_slug;

  if not found then
    raise exception 'Booking page was not found.';
  end if;

  if requested_date < current_date + 2 then
    raise exception 'This date is too soon to book.';
  end if;

  if requested_date > current_date + 14 then
    raise exception 'This date is outside the booking window.';
  end if;

  if not exists (
    select 1
    from public.availability_days
    where profile_id = profile_record.id
      and available_on = requested_date
      and start_time = requested_time
  ) then
    raise exception 'This time is no longer available.';
  end if;

  if exists (
    select 1
    from public.bookings
    where profile_id = profile_record.id
      and booked_on = requested_date
  ) then
    raise exception 'This date has already been taken.';
  end if;

  insert into public.bookings (profile_id, booked_on, start_time, guest_name, guest_contact)
  values (
    profile_record.id,
    requested_date,
    requested_time,
    trim(guest_name),
    trim(guest_contact)
  );

  return jsonb_build_object(
    'ok', true,
    'booked_on', requested_date,
    'start_time', requested_time
  );
exception
  when unique_violation then
    raise exception 'This date has just been taken.';
end;
$$;

grant execute on function public.create_booking(text, date, time, text, text) to anon, authenticated;

comment on function public.get_public_booking_options(text)
is 'Returns bookable options for the next rolling 14-day window with a 2-day notice requirement.';

comment on function public.create_booking(text, date, time, text, text)
is 'Creates a booking for a public booking page when the requested day is still available.';
