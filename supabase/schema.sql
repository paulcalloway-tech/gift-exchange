-- =====================================================================
--  Gift Exchange — database setup for Supabase
--  Paste this whole file into Supabase > SQL Editor and click Run.
--  Safe to run again: it only adds what is missing and replaces the
--  functions.
--
--  How it stays secret: every table has row-level security turned on
--  with NO policies, so nobody can read tables directly. The app only
--  talks to the functions below, and each one checks who is calling.
--  Nobody (not even the organizer) can read someone else's match
--  until the organizer chooses to reveal the whole chain at the end.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- Tables ----------------------------------------------------

create table if not exists public.groups (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(trim(name)) between 1 and 80),
  exchange_date date,
  budget        text check (budget is null or length(budget) <= 40),
  invite_code   text not null unique
                default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  status        text not null default 'open' check (status in ('open', 'drawn')),
  drawn_at      timestamptz,
  created_at    timestamptz not null default now()
);
alter table public.groups add column if not exists join_by date;
alter table public.groups add column if not exists chain_revealed_at timestamptz;

create table if not exists public.members (
  id           uuid primary key default gen_random_uuid(),
  group_id     uuid not null references public.groups(id) on delete cascade,
  user_id      uuid unique references auth.users(id) on delete set null,
  display_name text not null check (length(trim(display_name)) between 1 and 40),
  pin_hash     text not null,
  pin_fails    int  not null default 0,
  amazon_url   text,
  is_admin     boolean not null default false,
  joined_at    timestamptz not null default now()
);
create unique index if not exists members_group_name
  on public.members (group_id, lower(display_name));
-- A simple written list, for people who'd rather not use an Amazon list.
alter table public.members add column if not exists wish_list text
  check (wish_list is null or length(wish_list) <= 2000);
-- Small square profile photo stored as a JPEG data URL (about 10 KB).
alter table public.members add column if not exists photo text
  check (photo is null or (length(photo) <= 60000 and photo like 'data:image/jpeg;base64,%'));
-- Mailing address, shown only to the person buying for them.
alter table public.members add column if not exists ship_to text
  check (ship_to is null or length(ship_to) <= 300);
alter table public.members add column if not exists wish_updated_at timestamptz;
alter table public.members add column if not exists pin_reset_at timestamptz;

-- "Don't pair" rules. Stored once per pair (smaller id first), checked both ways.
create table if not exists public.conflicts (
  group_id uuid not null references public.groups(id) on delete cascade,
  member_a uuid not null references public.members(id) on delete cascade,
  member_b uuid not null references public.members(id) on delete cascade,
  primary key (member_a, member_b),
  check (member_a < member_b)
);

-- Who buys for whom. Written only by the draw functions.
create table if not exists public.assignments (
  giver        uuid primary key references public.members(id) on delete cascade,
  receiver     uuid not null unique references public.members(id) on delete cascade,
  group_id     uuid not null references public.groups(id) on delete cascade,
  viewed_at    timestamptz,
  purchased_at timestamptz
);

-- Anonymous questions from a buyer to their person.
create table if not exists public.questions (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups(id) on delete cascade,
  asker       uuid not null references public.members(id) on delete cascade,
  recipient   uuid not null references public.members(id) on delete cascade,
  question    text not null check (length(question) between 1 and 300),
  answer      text check (answer is null or length(answer) <= 500),
  asked_at    timestamptz not null default now(),
  answered_at timestamptz
);

-- One row, touched by the keep-alive job so the free project never idles.
create table if not exists public.keepalive (
  id        int primary key default 1 check (id = 1),
  pinged_at timestamptz not null default now(),
  pings     int not null default 0
);

alter table public.groups      enable row level security;
alter table public.members     enable row level security;
alter table public.conflicts   enable row level security;
alter table public.assignments enable row level security;
alter table public.questions   enable row level security;
alter table public.keepalive   enable row level security;
revoke all on public.groups, public.members, public.conflicts, public.assignments,
              public.questions, public.keepalive from anon, authenticated;

-- Older versions of these functions had fewer settings; remove them if present.
drop function if exists public.create_group(text, date, text, text, text, text);
drop function if exists public.create_group(text, date, text, text, text, text, text);
drop function if exists public.join_group(text, text, text, text);
drop function if exists public.update_me(text, text);
drop function if exists public.update_me(text, text, text);

-- ---------- Private helpers ------------------------------------------

create or replace function public._me() returns public.members
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
declare m public.members;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into m from public.members where user_id = auth.uid();
  if not found then raise exception 'You are not in a group on this phone yet'; end if;
  return m;
end $$;

create or replace function public._admin() returns public.members
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
declare m public.members;
begin
  m := public._me();
  if not m.is_admin then raise exception 'Only the organizer can do that'; end if;
  return m;
end $$;

create or replace function public._check_pin(p text) returns void
language plpgsql immutable as $$
begin
  if p is null or p !~ '^[0-9]{4}$' then raise exception 'PIN must be 4 digits'; end if;
end $$;

create or replace function public._clean_amazon(p text) returns text
language plpgsql immutable as $$
declare u text := nullif(trim(coalesce(p, '')), '');
begin
  if u is null then return null; end if;
  if u !~* '^https?://' then u := 'https://' || u; end if;
  u := regexp_replace(u, '^http://', 'https://', 'i');
  if u !~* '^https://([a-z0-9-]+\.)*(amazon\.[a-z.]+|a\.co|amzn\.to|amzn\.com)(/|\?|$)' then
    raise exception 'That doesn''t look like an Amazon link';
  end if;
  if length(u) > 500 then raise exception 'That link is too long'; end if;
  return u;
end $$;

create or replace function public._clean_list(p text) returns text
language plpgsql immutable as $$
declare t text;
begin
  -- trim each line, drop blank lines, cap at 40 lines
  select string_agg(l, E'\n') into t from (
    select trim(l) as l from regexp_split_to_table(coalesce(p, ''), E'\r?\n') with ordinality as x(l, n)
     where trim(l) <> '' order by n limit 40) s;
  if t is null then return null; end if;
  if length(t) > 2000 then raise exception 'Your list is a bit long. Keep it under 2,000 characters.'; end if;
  return t;
end $$;

create or replace function public._clean_text(p text, max_len int, what text) returns text
language plpgsql immutable as $$
declare t text := nullif(trim(regexp_replace(coalesce(p, ''), E'\r\n', E'\n', 'g')), '');
begin
  if t is not null and length(t) > max_len then
    raise exception '% is too long (keep it under % characters)', what, max_len;
  end if;
  return t;
end $$;

create or replace function public._clean_name(p text) returns text
language plpgsql immutable as $$
declare n text := regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g');
begin
  if length(n) < 1 then raise exception 'Please enter your name'; end if;
  if length(n) > 40 then raise exception 'Name is too long'; end if;
  return n;
end $$;

create or replace function public._is_conflict(g uuid, a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.conflicts
                 where group_id = g and member_a = least(a, b) and member_b = greatest(a, b));
$$;

-- The whole gift loop in order, starting with the organizer.
create or replace function public._chain(g uuid) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  with recursive start as (
    select a.giver from public.assignments a join public.members m on m.id = a.giver
     where a.group_id = g order by m.is_admin desc, m.joined_at limit 1
  ), loop as (
    select a.giver, a.receiver, 1 as n from public.assignments a where a.giver = (select giver from start)
    union all
    select a.giver, a.receiver, l.n + 1 from loop l join public.assignments a on a.giver = l.receiver
     where l.receiver <> (select giver from start) and l.n < 200
  )
  select coalesce(json_agg(json_build_object('name', m.display_name, 'photo', m.photo) order by l.n), '[]'::json)
    from loop l join public.members m on m.id = l.giver;
$$;

-- ---------- Everyone: joining and signing back in --------------------

-- Organizer creates the exchange (and becomes its admin).
create or replace function public.create_group(
  p_group_name text, p_exchange_date date, p_budget text,
  p_display_name text, p_pin text, p_amazon_url text default null, p_wish_list text default null,
  p_join_by date default null)
returns json language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare g public.groups;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then
    raise exception 'This phone is already in a gift exchange';
  end if;
  perform public._check_pin(p_pin);
  if length(trim(coalesce(p_group_name, ''))) = 0 then raise exception 'Please name the exchange'; end if;
  insert into public.groups (name, exchange_date, budget, join_by)
    values (trim(p_group_name), p_exchange_date, nullif(trim(coalesce(p_budget, '')), ''), p_join_by)
    returning * into g;
  insert into public.members (group_id, user_id, display_name, pin_hash, amazon_url, wish_list, is_admin)
    values (g.id, auth.uid(), public._clean_name(p_display_name),
            crypt(p_pin, gen_salt('bf')), public._clean_amazon(p_amazon_url), public._clean_list(p_wish_list), true);
  return json_build_object('ok', true, 'invite_code', g.invite_code);
end $$;

-- What the Join screen shows for an invite code (no secrets, no photos).
create or replace function public.group_preview(p_code text)
returns json language sql stable security definer set search_path = public, pg_temp as $$
  select json_build_object(
    'name', g.name, 'exchange_date', g.exchange_date, 'budget', g.budget, 'status', g.status,
    'join_by', g.join_by,
    'members', coalesce((select json_agg(json_build_object('id', m.id, 'name', m.display_name)
                                         order by lower(m.display_name))
                         from public.members m where m.group_id = g.id), '[]'::json))
  from public.groups g where g.invite_code = upper(trim(p_code));
$$;

create or replace function public.join_group(
  p_code text, p_display_name text, p_pin text, p_amazon_url text default null, p_wish_list text default null)
returns json language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare g public.groups; existing public.members; nm text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into g from public.groups where invite_code = upper(trim(p_code));
  if not found then raise exception 'That invite link wasn''t recognized'; end if;
  select * into existing from public.members where user_id = auth.uid();
  if found then
    if existing.group_id = g.id then return json_build_object('ok', true); end if;
    raise exception 'This phone is already in a different gift exchange';
  end if;
  perform public._check_pin(p_pin);
  nm := public._clean_name(p_display_name);
  if exists (select 1 from public.members where group_id = g.id and lower(display_name) = lower(nm)) then
    raise exception 'Someone already joined as %. If that''s you, tap "I already joined".', nm;
  end if;
  insert into public.members (group_id, user_id, display_name, pin_hash, amazon_url, wish_list)
    values (g.id, auth.uid(), nm, crypt(p_pin, gen_salt('bf')),
            public._clean_amazon(p_amazon_url), public._clean_list(p_wish_list));
  return json_build_object('ok', true);
end $$;

-- Sign back in on a new phone, a cleared browser, or the Home Screen app.
create or replace function public.reclaim(p_code text, p_member_id uuid, p_pin text)
returns json language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare m public.members;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select m2.* into m from public.members m2 join public.groups g on g.id = m2.group_id
   where m2.id = p_member_id and g.invite_code = upper(trim(p_code));
  if not found then raise exception 'Person not found'; end if;
  if m.pin_fails >= 5 then
    return json_build_object('ok', false, 'error',
      'Too many wrong tries. Ask the organizer to reset your PIN.');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' or crypt(p_pin, m.pin_hash) <> m.pin_hash then
    update public.members set pin_fails = pin_fails + 1 where id = m.id;
    return json_build_object('ok', false, 'error',
      format('Wrong PIN. %s tries left.', 4 - m.pin_fails));
  end if;
  update public.members set user_id = null where user_id = auth.uid() and id <> m.id;
  update public.members set user_id = auth.uid(), pin_fails = 0 where id = m.id;
  return json_build_object('ok', true);
end $$;

-- ---------- Everyone: home screen ------------------------------------

create or replace function public.my_state()
returns json language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.members; g public.groups; a public.assignments;
begin
  if auth.uid() is null then return json_build_object('member', null); end if;
  select * into m from public.members where user_id = auth.uid();
  if not found then return json_build_object('member', null); end if;
  select * into g from public.groups where id = m.group_id;
  select * into a from public.assignments where giver = m.id;
  return json_build_object(
    'member', json_build_object('id', m.id, 'name', m.display_name, 'photo', m.photo,
                                'amazon_url', m.amazon_url, 'wish_list', m.wish_list, 'ship_to', m.ship_to,
                                'is_admin', m.is_admin, 'pin_reset_at', m.pin_reset_at),
    'group', json_build_object('name', g.name, 'exchange_date', g.exchange_date, 'budget', g.budget,
                               'join_by', g.join_by, 'status', g.status, 'invite_code', g.invite_code,
                               'chain_revealed', g.chain_revealed_at is not null),
    'members', coalesce((select json_agg(json_build_object(
                  'name', x.display_name, 'photo', x.photo, 'is_admin', x.is_admin,
                  'has_list', x.amazon_url is not null or x.wish_list is not null)
                  order by x.joined_at)
                from public.members x where x.group_id = g.id), '[]'::json),
    'in_draw',  a.giver is not null,
    'viewed',   a.viewed_at is not null,
    'purchased', a.purchased_at is not null,
    'progress', json_build_object(
       'purchased', (select count(*) from public.assignments where group_id = g.id and purchased_at is not null),
       'total',     (select count(*) from public.assignments where group_id = g.id)),
    -- questions my (current) buyer asked me; the asker is never included
    'questions_for_me', coalesce((select json_agg(json_build_object(
          'id', q.id, 'question', q.question, 'answer', q.answer) order by q.asked_at)
        from public.questions q join public.assignments b on b.giver = q.asker and b.receiver = m.id
       where q.recipient = m.id), '[]'::json),
    -- questions I asked my (current) person
    'my_questions', coalesce((select json_agg(json_build_object(
          'id', q.id, 'question', q.question, 'answer', q.answer) order by q.asked_at)
        from public.questions q
       where q.asker = m.id and q.recipient = a.receiver), '[]'::json),
    'chain', case when g.chain_revealed_at is not null then public._chain(g.id) else null end);
end $$;

-- Your person. Marks the assignment as viewed (this locks the draw).
create or replace function public.reveal()
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.members; a public.assignments; r public.members; g public.groups;
begin
  m := public._me();
  select * into a from public.assignments where giver = m.id;
  if not found then raise exception 'You haven''t been assigned anyone yet'; end if;
  if a.viewed_at is null then update public.assignments set viewed_at = now() where giver = m.id; end if;
  select * into r from public.members where id = a.receiver;
  select * into g from public.groups where id = m.group_id;
  return json_build_object('name', r.display_name, 'photo', r.photo,
    'amazon_url', r.amazon_url, 'wish_list', r.wish_list, 'ship_to', r.ship_to,
    'list_updated_at', case when r.wish_updated_at > g.drawn_at then r.wish_updated_at end);
end $$;

create or replace function public.set_purchased(p_done boolean)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.members;
begin
  m := public._me();
  update public.assignments
     set purchased_at = case when p_done then coalesce(purchased_at, now()) else null end
   where giver = m.id;
  if not found then raise exception 'You haven''t been assigned anyone yet'; end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.update_me(
  p_display_name text, p_amazon_url text, p_wish_list text, p_ship_to text default null)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.members; nm text; amz text; lst text;
begin
  m := public._me();
  nm  := public._clean_name(p_display_name);
  amz := public._clean_amazon(p_amazon_url);
  lst := public._clean_list(p_wish_list);
  if exists (select 1 from public.members where group_id = m.group_id
             and lower(display_name) = lower(nm) and id <> m.id) then
    raise exception 'Someone else is already using that name';
  end if;
  update public.members
     set display_name = nm, amazon_url = amz, wish_list = lst,
         ship_to = public._clean_text(p_ship_to, 300, 'Mailing address'),
         wish_updated_at = case when amz is distinct from m.amazon_url or lst is distinct from m.wish_list
                                then now() else wish_updated_at end
   where id = m.id;
  return json_build_object('ok', true);
end $$;

create or replace function public.set_photo(p_photo text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.members;
begin
  m := public._me();
  if p_photo is not null and (p_photo not like 'data:image/jpeg;base64,%' or length(p_photo) > 60000) then
    raise exception 'That photo couldn''t be used. Try a different one.';
  end if;
  update public.members set photo = p_photo where id = m.id;
  return json_build_object('ok', true);
end $$;

-- Ask your person something. They never see who asked.
create or replace function public.ask_question(p_question text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.members; a public.assignments; q text;
begin
  m := public._me();
  select * into a from public.assignments where giver = m.id;
  if not found then raise exception 'You haven''t been assigned anyone yet'; end if;
  q := public._clean_text(p_question, 300, 'Question');
  if q is null then raise exception 'Type a question first'; end if;
  if (select count(*) from public.questions where asker = m.id and recipient = a.receiver) >= 10 then
    raise exception 'That''s plenty of questions for one person';
  end if;
  insert into public.questions (group_id, asker, recipient, question) values (m.group_id, m.id, a.receiver, q);
  return json_build_object('ok', true);
end $$;

create or replace function public.answer_question(p_id uuid, p_answer text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.members; t text;
begin
  m := public._me();
  t := public._clean_text(p_answer, 500, 'Answer');
  if t is null then raise exception 'Type an answer first'; end if;
  update public.questions set answer = t, answered_at = now() where id = p_id and recipient = m.id;
  if not found then raise exception 'Question not found'; end if;
  return json_build_object('ok', true);
end $$;

-- ---------- Organizer only -------------------------------------------

create or replace function public.admin_overview()
returns json language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me public.members; g public.groups; n int; warns text[] := '{}'; r record;
begin
  me := public._admin();
  select * into g from public.groups where id = me.group_id;
  select count(*) into n from public.members where group_id = me.group_id;
  if n < 3 then warns := array_append(warns, 'You need at least 3 people to draw.'); end if;
  for r in
    select m.display_name, n - 1 - (select count(*) from public.conflicts c
                                    where c.member_a = m.id or c.member_b = m.id) as allowed
      from public.members m where m.group_id = me.group_id
  loop
    if n >= 3 and r.allowed < 2 then
      warns := array_append(warns, format('%s can only be paired with %s %s. Remove a rule.',
                               r.display_name, r.allowed, case when r.allowed = 1 then 'person' else 'people' end));
    end if;
  end loop;
  return json_build_object(
    'status', g.status,
    'details', json_build_object('name', g.name, 'exchange_date', g.exchange_date,
                                 'budget', g.budget, 'join_by', g.join_by),
    'chain_revealed', g.chain_revealed_at is not null,
    'members', coalesce((select json_agg(json_build_object(
        'id', m.id, 'name', m.display_name, 'photo', m.photo, 'is_admin', m.is_admin,
        'has_list', m.amazon_url is not null or m.wish_list is not null, 'locked', m.pin_fails >= 5,
        'in_draw', a.giver is not null, 'viewed', a.viewed_at is not null,
        'purchased', a.purchased_at is not null) order by m.joined_at)
      from public.members m left join public.assignments a on a.giver = m.id
      where m.group_id = me.group_id), '[]'::json),
    'conflicts', coalesce((select json_agg(json_build_object(
        'a', c.member_a, 'b', c.member_b, 'a_name', ma.display_name, 'b_name', mb.display_name)
        order by lower(ma.display_name))
      from public.conflicts c
      join public.members ma on ma.id = c.member_a
      join public.members mb on mb.id = c.member_b
      where c.group_id = me.group_id), '[]'::json),
    'any_viewed', exists (select 1 from public.assignments where group_id = me.group_id and viewed_at is not null),
    'warnings', to_json(warns));
end $$;

create or replace function public.update_group(
  p_name text, p_exchange_date date, p_budget text, p_join_by date)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members;
begin
  me := public._admin();
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Please name the exchange'; end if;
  update public.groups
     set name = trim(p_name), exchange_date = p_exchange_date, join_by = p_join_by,
         budget = public._clean_text(p_budget, 40, 'Spending limit')
   where id = me.group_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.add_conflict(p_a uuid, p_b uuid)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members;
begin
  me := public._admin();
  if p_a = p_b then raise exception 'Pick two different people'; end if;
  if (select count(*) from public.members where id in (p_a, p_b) and group_id = me.group_id) <> 2 then
    raise exception 'Person not found';
  end if;
  insert into public.conflicts (group_id, member_a, member_b)
    values (me.group_id, least(p_a, p_b), greatest(p_a, p_b)) on conflict do nothing;
  return json_build_object('ok', true);
end $$;

create or replace function public.remove_conflict(p_a uuid, p_b uuid)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members;
begin
  me := public._admin();
  delete from public.conflicts
   where group_id = me.group_id and member_a = least(p_a, p_b) and member_b = greatest(p_a, p_b);
  return json_build_object('ok', true);
end $$;

-- The draw: one random loop (A buys for B, B for C ... last for A),
-- reshuffled until no "don't pair" rule is broken.
create or replace function public.run_draw(p_confirm text default null)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members; g public.groups; ids uuid[]; ck text[]; n int; i int; ok boolean;
        giver uuid; recv uuid;
begin
  me := public._admin();
  select * into g from public.groups where id = me.group_id for update;
  if exists (select 1 from public.assignments where group_id = g.id and viewed_at is not null)
     and coalesce(upper(trim(p_confirm)), '') <> 'REDRAW' then
    raise exception 'Someone has already seen their person. Type REDRAW to draw again anyway.';
  end if;
  select array_agg(id) into ids from public.members where group_id = g.id;
  n := coalesce(array_length(ids, 1), 0);
  if n < 3 then raise exception 'You need at least 3 people to draw'; end if;
  select coalesce(array_agg(member_a::text || member_b::text), '{}') into ck
    from public.conflicts where group_id = g.id;

  for attempt in 1..20000 loop
    -- gen_random_uuid() uses the server's cryptographic random source
    select array_agg(x order by gen_random_uuid()) into ids from unnest(ids) as x;
    ok := true;
    for i in 1..n loop
      giver := ids[i];
      recv  := ids[(i % n) + 1];
      if (least(giver, recv)::text || greatest(giver, recv)::text) = any(ck) then
        ok := false; exit;
      end if;
    end loop;
    if ok then
      delete from public.assignments where group_id = g.id;
      for i in 1..n loop
        insert into public.assignments (giver, receiver, group_id) values (ids[i], ids[(i % n) + 1], g.id);
      end loop;
      update public.groups set status = 'drawn', drawn_at = now(), chain_revealed_at = null where id = g.id;
      return json_build_object('ok', true, 'people', n);
    end if;
  end loop;
  raise exception 'Couldn''t find a draw that follows every rule. Remove a "don''t pair" rule and try again.';
end $$;

-- Someone joined after the draw: slot them into the loop.
-- Only one person's assignment changes (they're told on their home screen).
create or replace function public.add_to_draw(p_member_id uuid)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members; a public.assignments;
begin
  me := public._admin();
  if not exists (select 1 from public.members where id = p_member_id and group_id = me.group_id) then
    raise exception 'Person not found';
  end if;
  if exists (select 1 from public.assignments where giver = p_member_id) then
    return json_build_object('ok', true);
  end if;
  select * into a from public.assignments x
   where x.group_id = me.group_id and x.purchased_at is null
     and not public._is_conflict(me.group_id, x.giver, p_member_id)
     and not public._is_conflict(me.group_id, p_member_id, x.receiver)
   order by gen_random_uuid() limit 1;
  if not found then
    raise exception 'No spot fits the rules without changing someone who already bought. Use Redraw instead.';
  end if;
  update public.assignments set receiver = p_member_id, viewed_at = null where giver = a.giver;
  insert into public.assignments (giver, receiver, group_id) values (p_member_id, a.receiver, me.group_id);
  return json_build_object('ok', true);
end $$;

create or replace function public.remove_member(p_member_id uuid)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members; giver_row public.assignments; mine public.assignments; redraw boolean := false;
begin
  me := public._admin();
  if p_member_id = me.id then raise exception 'You can''t remove yourself'; end if;
  if not exists (select 1 from public.members where id = p_member_id and group_id = me.group_id) then
    raise exception 'Person not found';
  end if;
  select * into mine from public.assignments where giver = p_member_id;
  select * into giver_row from public.assignments where receiver = p_member_id;
  if mine.giver is not null and giver_row.giver is not null then
    if giver_row.giver = mine.receiver
       or public._is_conflict(me.group_id, giver_row.giver, mine.receiver) then
      -- Reconnecting would break a rule: clear the draw so the organizer redraws.
      delete from public.assignments where group_id = me.group_id;
      update public.groups set status = 'open', drawn_at = null, chain_revealed_at = null where id = me.group_id;
      redraw := true;
    else
      delete from public.assignments where giver = p_member_id;
      update public.assignments set receiver = mine.receiver, viewed_at = null where giver = giver_row.giver;
    end if;
  end if;
  delete from public.members where id = p_member_id;
  return json_build_object('ok', true, 'redraw_needed', redraw);
end $$;

-- The reset is recorded and shown to that person, so it can't happen quietly.
create or replace function public.reset_pin(p_member_id uuid, p_new_pin text)
returns json language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare me public.members;
begin
  me := public._admin();
  perform public._check_pin(p_new_pin);
  update public.members set pin_hash = crypt(p_new_pin, gen_salt('bf')), pin_fails = 0, pin_reset_at = now()
   where id = p_member_id and group_id = me.group_id;
  if not found then raise exception 'Person not found'; end if;
  return json_build_object('ok', true);
end $$;

-- After the exchange: show everyone the whole loop (or hide it again).
create or replace function public.set_chain_revealed(p_show boolean)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members;
begin
  me := public._admin();
  if p_show and not exists (select 1 from public.groups where id = me.group_id and status = 'drawn') then
    raise exception 'Draw names first';
  end if;
  update public.groups set chain_revealed_at = case when p_show then now() end where id = me.group_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.delete_group(p_confirm text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare me public.members;
begin
  me := public._admin();
  if coalesce(upper(trim(p_confirm)), '') <> 'DELETE' then raise exception 'Type DELETE to confirm'; end if;
  delete from public.groups where id = me.group_id;
  return json_build_object('ok', true);
end $$;

-- ---------- Keep-alive (called by the scheduled GitHub job) ----------

create or replace function public.keepalive()
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare k public.keepalive;
begin
  insert into public.keepalive (id, pinged_at, pings) values (1, now(), 1)
    on conflict (id) do update set pinged_at = now(), pings = public.keepalive.pings + 1
    returning * into k;
  return json_build_object('ok', true, 'at', k.pinged_at, 'pings', k.pings,
                           'people', (select count(*) from public.members));
end $$;

-- ---------- Who may call what ----------------------------------------

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.create_group(text, date, text, text, text, text, text, date),
  public.join_group(text, text, text, text, text),
  public.reclaim(text, uuid, text),
  public.my_state(),
  public.reveal(),
  public.set_purchased(boolean),
  public.update_me(text, text, text, text),
  public.set_photo(text),
  public.ask_question(text),
  public.answer_question(uuid, text),
  public.admin_overview(),
  public.update_group(text, date, text, date),
  public.add_conflict(uuid, uuid),
  public.remove_conflict(uuid, uuid),
  public.run_draw(text),
  public.add_to_draw(uuid),
  public.remove_member(uuid),
  public.reset_pin(uuid, text),
  public.set_chain_revealed(boolean),
  public.delete_group(text)
to authenticated;

grant execute on function public.group_preview(text), public.keepalive() to anon, authenticated;
