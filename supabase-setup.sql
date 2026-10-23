-- ═══════════════════════════════════════════════════════════════════════════
--  R6 PLAYBOOK — Base Supabase
--  À coller en entier dans Supabase › SQL Editor › New query › Run.
--  Ré-exécutable sans risque : ne supprime jamais tes vidéos.
-- ═══════════════════════════════════════════════════════════════════════════
--
--  maps ──< sites (BP) ──< strategies >── operators
--                              │
--                          1 ligne = 1 vidéo (YouTube, Short ou fichier .mp4)
--
--  • Lecture publique (le site s'affiche sans connexion).
--  • Écriture réservée aux comptes listés dans « admins ».
--  • Le premier compte créé dans Authentication devient admin automatiquement.
-- ═══════════════════════════════════════════════════════════════════════════


-- ───────────────────────────── 1. TABLES ─────────────────────────────

create table if not exists public.maps (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null check (char_length(name) between 1 and 60),
  image_url   text check (image_url is null or char_length(image_url) <= 1000),
  is_active   boolean not null default true,            -- masquer une carte sans la supprimer
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.sites (                -- les BP (bomb sites)
  id          uuid primary key default gen_random_uuid(),
  map_id      uuid not null references public.maps(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 80),
  floor       text not null default '1F' check (char_length(floor) between 1 and 6),
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  unique (map_id, name)
);
create index if not exists sites_map_id_idx on public.sites(map_id);

create table if not exists public.operators (            -- les agents
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null check (char_length(name) between 1 and 40),
  side        text not null check (side in ('attack', 'defense')),
  icon_url    text check (icon_url is null or char_length(icon_url) <= 1000),
  created_at  timestamptz not null default now()
);

create table if not exists public.strategies (           -- 1 ligne = 1 vidéo, sans limite
  id             uuid primary key default gen_random_uuid(),
  site_id        uuid not null references public.sites(id) on delete cascade,
  side           text not null check (side in ('attack', 'defense')),
  operator_id    uuid references public.operators(id) on delete set null,  -- null = générique
  title          text not null check (char_length(title) between 1 and 140),
  category       text not null default 'trick'
                   check (category in ('trick', 'placement', 'ligne', 'setup', 'utilitaire', 'autre')),
  notes          text check (notes is null or char_length(notes) <= 2000),
  video_url      text not null check (char_length(video_url) between 4 and 1000),
  provider       text not null check (provider in ('youtube', 'file')),
  video_id       text,                                   -- identifiant YouTube (11 caractères)
  kind           text not null default 'video' check (kind in ('video', 'short')),
  start_seconds  integer check (start_seconds is null or start_seconds >= 0),
  end_seconds    integer check (end_seconds is null or end_seconds > 0),
  pinned         boolean not null default false,
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid() references auth.users(id) on delete set null,
  constraint strategies_youtube_id check (provider <> 'youtube' or video_id ~ '^[A-Za-z0-9_-]{11}$'),
  constraint strategies_segment check (start_seconds is null or end_seconds is null or end_seconds > start_seconds)
);
create index if not exists strategies_site_side_idx on public.strategies(site_id, side);
create index if not exists strategies_operator_idx  on public.strategies(operator_id);
create index if not exists strategies_order_idx     on public.strategies(pinned desc, created_at desc);

create table if not exists public.admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);


-- ─────────────────────────── 2. FONCTIONS ───────────────────────────

-- Vrai si l'utilisateur connecté est admin (utilisé par toutes les règles d'écriture)
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.admins a where a.user_id = (select auth.uid()));
$$;

-- L'agent d'une stratégie doit jouer dans le bon camp
create or replace function public.check_strategy_operator_side()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.operator_id is not null and exists (
    select 1 from public.operators o where o.id = new.operator_id and o.side <> new.side
  ) then
    raise exception 'Cet agent ne joue pas en %', case new.side when 'attack' then 'attaque' else 'défense' end
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists strategies_operator_side on public.strategies;
create trigger strategies_operator_side
  before insert or update of operator_id, side on public.strategies
  for each row execute function public.check_strategy_operator_side();

-- Le tout premier compte créé devient admin
create or replace function public.bootstrap_first_admin()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.admins) then
    insert into public.admins (user_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_bootstrap_admin on auth.users;
create trigger on_auth_user_created_bootstrap_admin
  after insert on auth.users
  for each row execute function public.bootstrap_first_admin();

-- Si ton compte existe déjà avant ce script : il devient admin maintenant
insert into public.admins (user_id)
select u.id from auth.users u
where not exists (select 1 from public.admins)
order by u.created_at
limit 1
on conflict do nothing;


-- ──────────────────────── 3. SÉCURITÉ (RLS) ────────────────────────

alter table public.maps       enable row level security;
alter table public.sites      enable row level security;
alter table public.operators  enable row level security;
alter table public.strategies enable row level security;
alter table public.admins     enable row level security;

grant usage on schema public to anon, authenticated;
grant select on public.maps, public.sites, public.operators, public.strategies to anon, authenticated;
grant insert, update, delete on public.maps, public.sites, public.operators, public.strategies to authenticated;
grant select on public.admins to authenticated;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['maps', 'sites', 'operators', 'strategies'] loop
    execute format('drop policy if exists "Lecture publique" on public.%I', t);
    execute format('create policy "Lecture publique" on public.%I for select to anon, authenticated using (true)', t);
    execute format('drop policy if exists "Ajout admin" on public.%I', t);
    execute format('create policy "Ajout admin" on public.%I for insert to authenticated with check ((select public.is_admin()))', t);
    execute format('drop policy if exists "Modification admin" on public.%I', t);
    execute format('create policy "Modification admin" on public.%I for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()))', t);
    execute format('drop policy if exists "Suppression admin" on public.%I', t);
    execute format('create policy "Suppression admin" on public.%I for delete to authenticated using ((select public.is_admin()))', t);
  end loop;
end $$;

drop policy if exists "Voir son statut admin" on public.admins;
create policy "Voir son statut admin" on public.admins
  for select to authenticated using (user_id = (select auth.uid()));


-- ─────────────── 4. STOCKAGE (logos d'agents, images de cartes) ───────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 5242880,
        array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml', 'image/gif'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "media : ajout admin" on storage.objects;
create policy "media : ajout admin" on storage.objects
  for insert to authenticated with check (bucket_id = 'media' and (select public.is_admin()));

drop policy if exists "media : modification admin" on storage.objects;
create policy "media : modification admin" on storage.objects
  for update to authenticated using (bucket_id = 'media' and (select public.is_admin()));

drop policy if exists "media : suppression admin" on storage.objects;
create policy "media : suppression admin" on storage.objects
  for delete to authenticated using (bucket_id = 'media' and (select public.is_admin()));


-- ──────────────────────── 5. DONNÉES DE DÉPART ────────────────────────
--  Cartes classées de l'Année 11 (BP vérifiés oct. 2026, Villa après Split Fire).
--  Tout reste modifiable depuis le site (mode gestion).

insert into public.maps (slug, name, sort_order) values
  ('bank', 'Bank', 10),
  ('border', 'Border', 20),
  ('calypso-casino', 'Calypso Casino', 30),
  ('chalet', 'Chalet', 40),
  ('clubhouse', 'Clubhouse', 50),
  ('coastline', 'Coastline', 60),
  ('consulate', 'Consulate', 70),
  ('emerald-plains', 'Emerald Plains', 80),
  ('fortress', 'Fortress', 90),
  ('kafe', 'Kafe Dostoyevsky', 100),
  ('kanal', 'Kanal', 110),
  ('lair', 'Lair', 120),
  ('nighthaven-labs', 'Nighthaven Labs', 130),
  ('oregon', 'Oregon', 140),
  ('outback', 'Outback', 150),
  ('skyscraper', 'Skyscraper', 160),
  ('theme-park', 'Theme Park', 170),
  ('villa', 'Villa', 180)
on conflict (slug) do nothing;

insert into public.sites (map_id, name, floor, sort_order)
select m.id, s.name, s.floor, s.ord
from (values
  ('bank', 'Executive Lounge / CEO Office', '2F', 1),
  ('bank', 'Staff Room / Open Area', '1F', 2),
  ('bank', 'Teller''s Office / Archives', '1F', 3),
  ('bank', 'Lockers / CCTV Room', 'B', 4),
  ('border', 'Armory Lockers / Archives', '2F', 1),
  ('border', 'Customs Inspection / Supply Room', '1F', 2),
  ('border', 'Workshop / Ventilation Room', '1F', 3),
  ('border', 'Bathroom / Tellers', '1F', 4),
  ('calypso-casino', 'Cigar Room / Pool', '2F', 1),
  ('calypso-casino', 'Bar / Betting', '1F', 2),
  ('calypso-casino', 'Blackjack / Poker', '1F', 3),
  ('calypso-casino', 'Vault / CCTV', 'B', 4),
  ('chalet', 'Master Bedroom / Office', '2F', 1),
  ('chalet', 'Bar / Gaming Room', '1F', 2),
  ('chalet', 'Kitchen / Dining Room', '1F', 3),
  ('chalet', 'Wine Cellar / Snowmobile Garage', 'B', 4),
  ('clubhouse', 'CCTV / Cash Room', '2F', 1),
  ('clubhouse', 'Gym / Bedroom', '2F', 2),
  ('clubhouse', 'Bar / Stage', '1F', 3),
  ('clubhouse', 'Church / Arsenal Room', 'B', 4),
  ('coastline', 'Hookah Lounge / Billiards Room', '2F', 1),
  ('coastline', 'Theater / Penthouse', '2F', 2),
  ('coastline', 'Kitchen / Service Entrance', '1F', 3),
  ('coastline', 'Blue Bar / Sunrise Bar', '1F', 4),
  ('consulate', 'Consul Office / Meeting Room', '2F', 1),
  ('consulate', 'Piano Room / Exposition Room', '1F', 2),
  ('consulate', 'Tellers / Servers', 'B/1F', 3),
  ('consulate', 'Cafeteria / Garage', 'B', 4),
  ('emerald-plains', 'CEO Office / Administration', '2F', 1),
  ('emerald-plains', 'Gallery / Meeting', '2F', 2),
  ('emerald-plains', 'Bar / Lounge', '1F', 3),
  ('emerald-plains', 'Kitchen / Dining', '1F', 4),
  ('fortress', 'Commander''s Office / Bathroom', '2F', 1),
  ('fortress', 'Dormitory / Games Room', '2F', 2),
  ('fortress', 'Waiting Room / Cafeteria', '1F', 3),
  ('fortress', 'Hammam / Sitting Room', '1F', 4),
  ('kafe', 'Bar / Cocktail Lounge', '3F', 1),
  ('kafe', 'Reading Room / Fireplace Hall', '2F', 2),
  ('kafe', 'Mining Room / Train Museum', '2F', 3),
  ('kafe', 'Kitchen Cooking / Kitchen Service', '1F', 4),
  ('kanal', 'Server Room / Radar Room', '2F', 1),
  ('kanal', 'Security Room / Map Room', '1F', 2),
  ('kanal', 'Coast Guard Meeting Room / Lounge', '1F', 3),
  ('kanal', 'Supply Room / Kayaks', 'B', 4),
  ('lair', 'Master Office / R6 Room', '2F', 1),
  ('lair', 'Bunks / Briefing', '1F', 2),
  ('lair', 'Armory / Weapon Maintenance', '1F', 3),
  ('lair', 'Lab / Lab Support', 'B', 4),
  ('nighthaven-labs', 'Command / Server', '2F', 1),
  ('nighthaven-labs', 'Control / Storage', '1F', 2),
  ('nighthaven-labs', 'Kitchen / Cafeteria', '1F', 3),
  ('nighthaven-labs', 'Tank / Assembly', 'B', 4),
  ('oregon', 'Kids'' Dorms / Dorms Main Hall', '2F', 1),
  ('oregon', 'Kitchen / Dining Hall', '1F', 2),
  ('oregon', 'Meeting Hall / Kitchen', '1F', 3),
  ('oregon', 'Laundry Room / Supply Room', 'B', 4),
  ('outback', 'Laundry / Games Room', '2F', 1),
  ('outback', 'Party Room / Office', '2F', 2),
  ('outback', 'Nature Room / Bushranger Room', '1F', 3),
  ('outback', 'Compressor Room / Gear Store', '1F', 4),
  ('skyscraper', 'Tea Room / Karaoke', '2F', 1),
  ('skyscraper', 'Exhibition Room / Office', '2F', 2),
  ('skyscraper', 'Kitchen / BBQ', '1F', 3),
  ('skyscraper', 'Bedroom / Bathroom', '1F', 4),
  ('theme-park', 'Initiation Room / Office', '2F', 1),
  ('theme-park', 'Bunk / Day Care', '2F', 2),
  ('theme-park', 'Armory / Throne Room', '1F', 3),
  ('theme-park', 'Lab / Storage', '1F', 4),
  ('villa', 'Aviator Room / Games Room', '2F', 1),
  ('villa', 'Trophy Room / Statuary Room', '2F', 2),
  ('villa', 'Kitchen / Dining Room', '1F', 3),
  ('villa', 'Art Storage / Old Office', 'B', 4)
) as s(map_slug, name, floor, ord)
join public.maps m on m.slug = s.map_slug
on conflict (map_id, name) do nothing;

insert into public.operators (slug, name, side) values
  -- Attaque
  ('ace', 'Ace', 'attack'), ('amaru', 'Amaru', 'attack'), ('ash', 'Ash', 'attack'),
  ('blackbeard', 'Blackbeard', 'attack'), ('blitz', 'Blitz', 'attack'), ('brava', 'Brava', 'attack'),
  ('buck', 'Buck', 'attack'), ('capitao', 'Capitão', 'attack'), ('deimos', 'Deimos', 'attack'),
  ('dokkaebi', 'Dokkaebi', 'attack'), ('finka', 'Finka', 'attack'), ('flores', 'Flores', 'attack'),
  ('fuze', 'Fuze', 'attack'), ('glaz', 'Glaz', 'attack'), ('gridlock', 'Gridlock', 'attack'),
  ('grim', 'Grim', 'attack'), ('hibana', 'Hibana', 'attack'), ('iana', 'Iana', 'attack'),
  ('iq', 'IQ', 'attack'), ('jackal', 'Jackal', 'attack'), ('kali', 'Kali', 'attack'),
  ('lion', 'Lion', 'attack'), ('maverick', 'Maverick', 'attack'), ('montagne', 'Montagne', 'attack'),
  ('nokk', 'Nøkk', 'attack'), ('nomad', 'Nomad', 'attack'), ('osa', 'Osa', 'attack'),
  ('ram', 'Ram', 'attack'), ('rauora', 'Rauora', 'attack'), ('sens', 'Sens', 'attack'),
  ('sledge', 'Sledge', 'attack'), ('solid-snake', 'Solid Snake', 'attack'), ('striker', 'Striker', 'attack'),
  ('thatcher', 'Thatcher', 'attack'), ('thermite', 'Thermite', 'attack'), ('twitch', 'Twitch', 'attack'),
  ('ying', 'Ying', 'attack'), ('zero', 'Zero', 'attack'), ('zofia', 'Zofia', 'attack'),
  -- Défense
  ('alibi', 'Alibi', 'defense'), ('aruni', 'Aruni', 'defense'), ('azami', 'Azami', 'defense'),
  ('bandit', 'Bandit', 'defense'), ('castle', 'Castle', 'defense'), ('caveira', 'Caveira', 'defense'),
  ('clash', 'Clash', 'defense'), ('denari', 'Denari', 'defense'), ('doc', 'Doc', 'defense'),
  ('echo', 'Echo', 'defense'), ('ela', 'Ela', 'defense'), ('fenrir', 'Fenrir', 'defense'),
  ('frost', 'Frost', 'defense'), ('goyo', 'Goyo', 'defense'), ('jager', 'Jäger', 'defense'),
  ('kaid', 'Kaid', 'defense'), ('kapkan', 'Kapkan', 'defense'), ('lesion', 'Lesion', 'defense'),
  ('maestro', 'Maestro', 'defense'), ('melusi', 'Melusi', 'defense'), ('mira', 'Mira', 'defense'),
  ('mozzie', 'Mozzie', 'defense'), ('mute', 'Mute', 'defense'), ('noor', 'Noor', 'defense'),
  ('oryx', 'Oryx', 'defense'), ('pulse', 'Pulse', 'defense'), ('rook', 'Rook', 'defense'),
  ('sentry', 'Sentry', 'defense'), ('skopos', 'Skopós', 'defense'), ('smoke', 'Smoke', 'defense'),
  ('solis', 'Solis', 'defense'), ('tachanka', 'Tachanka', 'defense'), ('thorn', 'Thorn', 'defense'),
  ('thunderbird', 'Thunderbird', 'defense'), ('tubarao', 'Tubarão', 'defense'), ('valkyrie', 'Valkyrie', 'defense'),
  ('vigil', 'Vigil', 'defense'), ('wamai', 'Wamai', 'defense'), ('warden', 'Warden', 'defense')
on conflict (slug) do nothing;

-- Fin. Vérification rapide :
-- select (select count(*) from maps) as cartes, (select count(*) from sites) as bp,
--        (select count(*) from operators) as agents, (select count(*) from admins) as admins;
