-- ═══════════════════════════════════════════════════════════════════════════
--  R6 PLAYBOOK — Base Supabase (v3 : plusieurs BP par vidéo, noms en français)
--  À coller en entier dans Supabase › SQL Editor › New query › Run.
--
--  • Première installation : crée tout et pré-remplit cartes, BP et agents.
--  • Mise à jour d'une base existante : la convertit sans perdre tes vidéos
--    et passe les noms de cartes, de BP et d'étages en français.
--  • Ré-exécutable sans risque : ne recrée jamais une carte, un BP ou un agent
--    que tu as supprimé ou renommé depuis le site.
-- ═══════════════════════════════════════════════════════════════════════════
--
--   maps ──< sites (BP) ──< strategy_sites >── strategies >── operators
--     └───────────────────────────────────────────┘
--
--  1 stratégie = 1 vidéo (YouTube, Short ou fichier .mp4), pour 1 carte et 1 camp,
--  rangée sur 1 ou plusieurs BP de cette carte (table de liaison strategy_sites).
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
  floor       text not null default 'RDC' check (char_length(floor) between 1 and 6),  -- SS, RDC, 1er, 2e…
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
  map_id         uuid not null references public.maps(id) on delete cascade,
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

-- Base créée avec la v1 (1 vidéo = 1 BP) : la carte devient une colonne de la vidéo
alter table public.strategies add column if not exists map_id uuid references public.maps(id) on delete cascade;

-- (id, carte) : permet à la liaison vidéo ↔ BP d'exiger « même carte » par clé étrangère
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'sites_id_map_key' and conrelid = 'public.sites'::regclass) then
    alter table public.sites add constraint sites_id_map_key unique (id, map_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'strategies_id_map_key' and conrelid = 'public.strategies'::regclass) then
    alter table public.strategies add constraint strategies_id_map_key unique (id, map_id);
  end if;
end $$;

create table if not exists public.strategy_sites (       -- sur quels BP est rangée chaque vidéo
  strategy_id  uuid not null,
  map_id       uuid not null,
  site_id      uuid not null,
  primary key (strategy_id, map_id, site_id),
  -- la vidéo et le BP doivent être sur la même carte (impossible de lier un BP d'une autre carte)
  constraint strategy_sites_strategy_fkey foreign key (strategy_id, map_id)
    references public.strategies(id, map_id) on delete cascade,
  constraint strategy_sites_site_fkey foreign key (site_id, map_id)
    references public.sites(id, map_id) on delete cascade
);
create index if not exists strategy_sites_site_idx on public.strategy_sites(site_id, map_id);

-- Conversion v1 → v2 : chaque vidéo garde son BP, désormais dans strategy_sites
do $$
declare n integer;
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'strategies' and column_name = 'site_id') then
    update public.strategies s set map_id = si.map_id
      from public.sites si
     where si.id = s.site_id and s.map_id is null;
    insert into public.strategy_sites (strategy_id, map_id, site_id)
      select s.id, s.map_id, s.site_id from public.strategies s where s.site_id is not null
      on conflict do nothing;
    get diagnostics n = row_count;
    alter table public.strategies drop column site_id;
    raise notice 'R6 Playbook : % vidéo(s) converties, chacune garde son BP.', n;
  end if;
end $$;
alter table public.strategies alter column map_id set not null;

create index if not exists strategies_map_side_idx  on public.strategies(map_id, side);
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

-- Une vidéo qui n'est plus rangée sur aucun BP est supprimée
-- (ex. : suppression de son seul BP). Vérifié à la fin de la transaction.
create or replace function public.delete_orphan_strategy()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.strategies s
   where s.id = old.strategy_id
     and not exists (select 1 from public.strategy_sites l where l.strategy_id = old.strategy_id);
  return null;
end;
$$;

drop trigger if exists strategy_sites_orphans on public.strategy_sites;
create constraint trigger strategy_sites_orphans
  after delete on public.strategy_sites
  deferrable initially deferred
  for each row execute function public.delete_orphan_strategy();

-- Enregistre une vidéo et ses BP en une seule fois (tout ou rien).
-- strategy : les colonnes de la vidéo (avec "id" pour une modification) ; site_ids : ses BP.
create or replace function public.save_strategy(strategy jsonb, site_ids uuid[])
returns public.strategies
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v public.strategies;
  r public.strategies;
begin
  if not (select public.is_admin()) then
    raise exception 'Action réservée aux admins' using errcode = '42501';
  end if;
  v := jsonb_populate_record(null::public.strategies, strategy);
  site_ids := array(select distinct x from unnest(site_ids) as x where x is not null);
  if cardinality(site_ids) = 0 then
    raise exception 'Choisis au moins un BP' using errcode = '23514';
  end if;
  if exists (select 1 from unnest(site_ids) as x
             left join public.sites s on s.id = x
             where s.id is null or s.map_id is distinct from v.map_id) then
    raise exception 'Tous les BP doivent être sur la carte de la vidéo' using errcode = '23514';
  end if;

  if v.id is null then
    insert into public.strategies (map_id, side, operator_id, title, category, notes, video_url,
                                   provider, video_id, kind, start_seconds, end_seconds, pinned)
    values (v.map_id, v.side, v.operator_id, v.title, coalesce(v.category, 'trick'), v.notes, v.video_url,
            v.provider, v.video_id, coalesce(v.kind, 'video'), v.start_seconds, v.end_seconds, coalesce(v.pinned, false))
    returning * into r;
  else
    -- d'abord les BP retirés (permet aussi de changer la vidéo de carte)
    delete from public.strategy_sites l where l.strategy_id = v.id and not (l.site_id = any (site_ids));
    update public.strategies set
      map_id = v.map_id, side = v.side, operator_id = v.operator_id, title = v.title,
      category = coalesce(v.category, 'trick'), notes = v.notes, video_url = v.video_url,
      provider = v.provider, video_id = v.video_id, kind = coalesce(v.kind, 'video'),
      start_seconds = v.start_seconds, end_seconds = v.end_seconds, pinned = coalesce(v.pinned, false)
    where id = v.id
    returning * into r;
    if not found then
      raise exception 'Vidéo introuvable : actualise les données' using errcode = 'P0002';
    end if;
  end if;

  insert into public.strategy_sites (strategy_id, map_id, site_id)
  select r.id, r.map_id, x from unnest(site_ids) as x
  on conflict do nothing;
  return r;
end;
$$;

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

alter table public.maps           enable row level security;
alter table public.sites          enable row level security;
alter table public.operators      enable row level security;
alter table public.strategies     enable row level security;
alter table public.strategy_sites enable row level security;
alter table public.admins         enable row level security;

grant usage on schema public to anon, authenticated;
grant select on public.maps, public.sites, public.operators, public.strategies, public.strategy_sites to anon, authenticated;
grant insert, update, delete on public.maps, public.sites, public.operators, public.strategies, public.strategy_sites to authenticated;
grant select on public.admins to authenticated;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;
revoke all on function public.save_strategy(jsonb, uuid[]) from public, anon;
grant execute on function public.save_strategy(jsonb, uuid[]) to authenticated;
-- fonctions de déclencheurs : jamais appelables depuis l'API (les déclencheurs fonctionnent quand même)
revoke all on function public.check_strategy_operator_side() from public, anon, authenticated;
revoke all on function public.delete_orphan_strategy() from public, anon, authenticated;
revoke all on function public.bootstrap_first_admin() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['maps', 'sites', 'operators', 'strategies', 'strategy_sites'] loop
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
--  Insérées seulement si la table est vide (premier lancement) : relancer le script
--  ne fait jamais réapparaître une carte, un BP ou un agent supprimé ou renommé.

insert into public.maps (slug, name, sort_order)
select v.slug, v.name, v.ord
from (values
  ('bank', 'Banque', 10),
  ('border', 'Frontière', 20),
  ('calypso-casino', 'Casino Calypso', 30),
  ('chalet', 'Chalet', 40),
  ('clubhouse', 'Clubhouse', 50),
  ('coastline', 'Littoral', 60),
  ('consulate', 'Consulat', 70),
  ('emerald-plains', 'Plaines d''Émeraude', 80),
  ('fortress', 'Forteresse', 90),
  ('kafe', 'Café Dostoyevsky', 100),
  ('kanal', 'Canal', 110),
  ('lair', 'Repaire', 120),
  ('nighthaven-labs', 'Labo de Nighthaven', 130),
  ('oregon', 'Oregon', 140),
  ('outback', 'Outback', 150),
  ('skyscraper', 'Gratte-ciel', 160),
  ('theme-park', 'Parc d''attractions', 170),
  ('villa', 'Villa', 180)
) as v(slug, name, ord)
where not exists (select 1 from public.maps)
on conflict (slug) do nothing;

-- Étages au format de la version française du jeu : SS (sous-sol), RDC, 1er, 2e
insert into public.sites (map_id, name, floor, sort_order)
select m.id, s.name, s.floor, s.ord
from (values
  ('bank', 'Salon exécutif / Bureau du PDG', '1er', 1),
  ('bank', 'Salle du personnel / Open space', 'RDC', 2),
  ('bank', 'Guichets / Archives', 'RDC', 3),
  ('bank', 'Vestiaires / Salle de surveillance', 'SS', 4),
  ('border', 'Casiers de l''armurerie / Archives', '1er', 1),
  ('border', 'Inspections de la douane / Réserve', 'RDC', 2),
  ('border', 'Atelier / Salle de ventilation', 'RDC', 3),
  ('border', 'Salle de bain / Guichets', 'RDC', 4),
  ('calypso-casino', 'Salon des cigares / Pool', '1er', 1),
  ('calypso-casino', 'Bar / Salle des paris', 'RDC', 2),
  ('calypso-casino', 'Blackjack / Poker', 'RDC', 3),
  ('calypso-casino', 'Coffre / Salle de surveillance', 'SS', 4),
  ('chalet', 'Chambre principale / Bureau', '1er', 1),
  ('chalet', 'Bar / Salle de jeux', 'RDC', 2),
  ('chalet', 'Cuisine / Salle à manger', 'RDC', 3),
  ('chalet', 'Cave à vin / Garage à motoneiges', 'SS', 4),
  ('clubhouse', 'Salle de surveillance / Salle des recettes', '1er', 1),
  ('clubhouse', 'Salle de sport / Chambre', '1er', 2),
  ('clubhouse', 'Bar / Scène', 'RDC', 3),
  ('clubhouse', 'Église / Armurerie', 'SS', 4),
  ('coastline', 'Salon chicha / Salle de billard', '1er', 1),
  ('coastline', 'Cinéma / Penthouse', '1er', 2),
  ('coastline', 'Cuisine / Entrée de service', 'RDC', 3),
  ('coastline', 'Bar bleu / Bar Sunrise', 'RDC', 4),
  ('consulate', 'Bureau du consul / Salle de réunion', '1er', 1),
  ('consulate', 'Salle de piano / Salle d''exposition', 'RDC', 2),
  ('consulate', 'Guichets / Serveurs', 'SS/RDC', 3),
  ('consulate', 'Cafétéria / Garage', 'SS', 4),
  ('emerald-plains', 'Bureau du PDG / Administration', '1er', 1),
  ('emerald-plains', 'Galerie / Salle de réunion', '1er', 2),
  ('emerald-plains', 'Bar / Salon', 'RDC', 3),
  ('emerald-plains', 'Cuisine / Salle à manger', 'RDC', 4),
  ('fortress', 'Bureau du commandant / Salle de bain', '1er', 1),
  ('fortress', 'Dortoir / Salle de jeux', '1er', 2),
  ('fortress', 'Salle d''attente / Cafétéria', 'RDC', 3),
  ('fortress', 'Hammam / Salon', 'RDC', 4),
  ('kafe', 'Bar / Bar à cocktails', '2e', 1),
  ('kafe', 'Salle de lecture / Hall avec cheminée', '1er', 2),
  ('kafe', 'Salle de la mine / Musée du train', '1er', 3),
  ('kafe', 'Cuisine (cuisson) / Cuisine (service)', 'RDC', 4),
  ('kanal', 'Salle des serveurs / Salle radar', '1er', 1),
  ('kanal', 'Salle de sécurité / Salle des cartes', 'RDC', 2),
  ('kanal', 'Salle garde-côte / Salon', 'RDC', 3),
  ('kanal', 'Réserve / Kayaks', 'SS', 4),
  ('lair', 'Bureau principal / Salle R6', '1er', 1),
  ('lair', 'Dortoirs / Salle de briefing', 'RDC', 2),
  ('lair', 'Armurerie / Entretien des armes', 'RDC', 3),
  ('lair', 'Labo / Annexe du labo', 'SS', 4),
  ('nighthaven-labs', 'Commandement / Serveurs', '1er', 1),
  ('nighthaven-labs', 'Contrôle / Stockage', 'RDC', 2),
  ('nighthaven-labs', 'Cuisine / Cafétéria', 'RDC', 3),
  ('nighthaven-labs', 'Cuve / Assemblage', 'SS', 4),
  ('oregon', 'Dortoir des enfants / Dortoir principal', '1er', 1),
  ('oregon', 'Cuisine / Cantine', 'RDC', 2),
  ('oregon', 'Salle de réunion / Cuisine', 'RDC', 3),
  ('oregon', 'Buanderie / Réserve', 'SS', 4),
  ('outback', 'Laverie / Salle de jeux', '1er', 1),
  ('outback', 'Salle des fêtes / Bureau', '1er', 2),
  ('outback', 'Salle nature / Salle du garde forestier', 'RDC', 3),
  ('outback', 'Salle des compresseurs / Magasin d''équipement', 'RDC', 4),
  ('skyscraper', 'Salon de thé / Karaoké', '1er', 1),
  ('skyscraper', 'Salle d''exposition / Bureau', '1er', 2),
  ('skyscraper', 'Cuisine / Barbecue', 'RDC', 3),
  ('skyscraper', 'Chambre / Salle de bain', 'RDC', 4),
  ('theme-park', 'Salle d''initiation / Bureau', '1er', 1),
  ('theme-park', 'Dortoir / Garderie', '1er', 2),
  ('theme-park', 'Armurerie / Salle du trône', 'RDC', 3),
  ('theme-park', 'Labo / Stockage', 'RDC', 4),
  ('villa', 'Salle de l''aviateur / Salle de jeux', '1er', 1),
  ('villa', 'Salle des trophées / Salle des statues', '1er', 2),
  ('villa', 'Cuisine / Salle à manger', 'RDC', 3),
  ('villa', 'Réserve d''art / Vieux bureau', 'SS', 4)
) as s(map_slug, name, floor, ord)
join public.maps m on m.slug = s.map_slug
where not exists (select 1 from public.sites)
on conflict (map_id, name) do nothing;

insert into public.operators (slug, name, side)
select v.slug, v.name, v.side
from (values
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
) as v(slug, name, side)
where not exists (select 1 from public.operators)
on conflict (slug) do nothing;


-- ─────────────── 6. NOMS EN FRANÇAIS (bases créées avant la v3) ───────────────
--  Renomme les cartes et les BP qui portent encore leur nom anglais d'origine.
--  Un nom que tu as modifié toi-même n'est jamais touché ; relancer ne change rien.

update public.maps m set name = v.fr
from (values
  ('bank', 'Bank', 'Banque'),
  ('border', 'Border', 'Frontière'),
  ('calypso-casino', 'Calypso Casino', 'Casino Calypso'),
  ('coastline', 'Coastline', 'Littoral'),
  ('consulate', 'Consulate', 'Consulat'),
  ('emerald-plains', 'Emerald Plains', 'Plaines d''Émeraude'),
  ('fortress', 'Fortress', 'Forteresse'),
  ('kafe', 'Kafe Dostoyevsky', 'Café Dostoyevsky'),
  ('kanal', 'Kanal', 'Canal'),
  ('lair', 'Lair', 'Repaire'),
  ('nighthaven-labs', 'Nighthaven Labs', 'Labo de Nighthaven'),
  ('skyscraper', 'Skyscraper', 'Gratte-ciel'),
  ('theme-park', 'Theme Park', 'Parc d''attractions')
) as v(slug, en, fr)
where m.slug = v.slug and m.name = v.en;

update public.sites s set name = v.fr
from (values
  ('bank', 'Executive Lounge / CEO Office', 'Salon exécutif / Bureau du PDG'),
  ('bank', 'Staff Room / Open Area', 'Salle du personnel / Open space'),
  ('bank', 'Teller''s Office / Archives', 'Guichets / Archives'),
  ('bank', 'Lockers / CCTV Room', 'Vestiaires / Salle de surveillance'),
  ('border', 'Armory Lockers / Archives', 'Casiers de l''armurerie / Archives'),
  ('border', 'Customs Inspection / Supply Room', 'Inspections de la douane / Réserve'),
  ('border', 'Workshop / Ventilation Room', 'Atelier / Salle de ventilation'),
  ('border', 'Bathroom / Tellers', 'Salle de bain / Guichets'),
  ('calypso-casino', 'Cigar Room / Pool', 'Salon des cigares / Pool'),
  ('calypso-casino', 'Bar / Betting', 'Bar / Salle des paris'),
  ('calypso-casino', 'Blackjack / Poker', 'Blackjack / Poker'),
  ('calypso-casino', 'Vault / CCTV', 'Coffre / Salle de surveillance'),
  ('chalet', 'Master Bedroom / Office', 'Chambre principale / Bureau'),
  ('chalet', 'Bar / Gaming Room', 'Bar / Salle de jeux'),
  ('chalet', 'Kitchen / Dining Room', 'Cuisine / Salle à manger'),
  ('chalet', 'Wine Cellar / Snowmobile Garage', 'Cave à vin / Garage à motoneiges'),
  ('clubhouse', 'CCTV / Cash Room', 'Salle de surveillance / Salle des recettes'),
  ('clubhouse', 'Gym / Bedroom', 'Salle de sport / Chambre'),
  ('clubhouse', 'Bar / Stage', 'Bar / Scène'),
  ('clubhouse', 'Church / Arsenal Room', 'Église / Armurerie'),
  ('coastline', 'Hookah Lounge / Billiards Room', 'Salon chicha / Salle de billard'),
  ('coastline', 'Theater / Penthouse', 'Cinéma / Penthouse'),
  ('coastline', 'Kitchen / Service Entrance', 'Cuisine / Entrée de service'),
  ('coastline', 'Blue Bar / Sunrise Bar', 'Bar bleu / Bar Sunrise'),
  ('consulate', 'Consul Office / Meeting Room', 'Bureau du consul / Salle de réunion'),
  ('consulate', 'Piano Room / Exposition Room', 'Salle de piano / Salle d''exposition'),
  ('consulate', 'Tellers / Servers', 'Guichets / Serveurs'),
  ('consulate', 'Cafeteria / Garage', 'Cafétéria / Garage'),
  ('emerald-plains', 'CEO Office / Administration', 'Bureau du PDG / Administration'),
  ('emerald-plains', 'Gallery / Meeting', 'Galerie / Salle de réunion'),
  ('emerald-plains', 'Bar / Lounge', 'Bar / Salon'),
  ('emerald-plains', 'Kitchen / Dining', 'Cuisine / Salle à manger'),
  ('fortress', 'Commander''s Office / Bathroom', 'Bureau du commandant / Salle de bain'),
  ('fortress', 'Dormitory / Games Room', 'Dortoir / Salle de jeux'),
  ('fortress', 'Waiting Room / Cafeteria', 'Salle d''attente / Cafétéria'),
  ('fortress', 'Hammam / Sitting Room', 'Hammam / Salon'),
  ('kafe', 'Bar / Cocktail Lounge', 'Bar / Bar à cocktails'),
  ('kafe', 'Reading Room / Fireplace Hall', 'Salle de lecture / Hall avec cheminée'),
  ('kafe', 'Mining Room / Train Museum', 'Salle de la mine / Musée du train'),
  ('kafe', 'Kitchen Cooking / Kitchen Service', 'Cuisine (cuisson) / Cuisine (service)'),
  ('kanal', 'Server Room / Radar Room', 'Salle des serveurs / Salle radar'),
  ('kanal', 'Security Room / Map Room', 'Salle de sécurité / Salle des cartes'),
  ('kanal', 'Coast Guard Meeting Room / Lounge', 'Salle garde-côte / Salon'),
  ('kanal', 'Supply Room / Kayaks', 'Réserve / Kayaks'),
  ('lair', 'Master Office / R6 Room', 'Bureau principal / Salle R6'),
  ('lair', 'Bunks / Briefing', 'Dortoirs / Salle de briefing'),
  ('lair', 'Armory / Weapon Maintenance', 'Armurerie / Entretien des armes'),
  ('lair', 'Lab / Lab Support', 'Labo / Annexe du labo'),
  ('nighthaven-labs', 'Command / Server', 'Commandement / Serveurs'),
  ('nighthaven-labs', 'Control / Storage', 'Contrôle / Stockage'),
  ('nighthaven-labs', 'Kitchen / Cafeteria', 'Cuisine / Cafétéria'),
  ('nighthaven-labs', 'Tank / Assembly', 'Cuve / Assemblage'),
  ('oregon', 'Kids'' Dorms / Dorms Main Hall', 'Dortoir des enfants / Dortoir principal'),
  ('oregon', 'Kitchen / Dining Hall', 'Cuisine / Cantine'),
  ('oregon', 'Meeting Hall / Kitchen', 'Salle de réunion / Cuisine'),
  ('oregon', 'Laundry Room / Supply Room', 'Buanderie / Réserve'),
  ('outback', 'Laundry / Games Room', 'Laverie / Salle de jeux'),
  ('outback', 'Party Room / Office', 'Salle des fêtes / Bureau'),
  ('outback', 'Nature Room / Bushranger Room', 'Salle nature / Salle du garde forestier'),
  ('outback', 'Compressor Room / Gear Store', 'Salle des compresseurs / Magasin d''équipement'),
  ('skyscraper', 'Tea Room / Karaoke', 'Salon de thé / Karaoké'),
  ('skyscraper', 'Exhibition Room / Office', 'Salle d''exposition / Bureau'),
  ('skyscraper', 'Kitchen / BBQ', 'Cuisine / Barbecue'),
  ('skyscraper', 'Bedroom / Bathroom', 'Chambre / Salle de bain'),
  ('theme-park', 'Initiation Room / Office', 'Salle d''initiation / Bureau'),
  ('theme-park', 'Bunk / Day Care', 'Dortoir / Garderie'),
  ('theme-park', 'Armory / Throne Room', 'Armurerie / Salle du trône'),
  ('theme-park', 'Lab / Storage', 'Labo / Stockage'),
  ('villa', 'Aviator Room / Games Room', 'Salle de l''aviateur / Salle de jeux'),
  ('villa', 'Trophy Room / Statuary Room', 'Salle des trophées / Salle des statues'),
  ('villa', 'Kitchen / Dining Room', 'Cuisine / Salle à manger'),
  ('villa', 'Art Storage / Old Office', 'Réserve d''art / Vieux bureau')
) as v(map_slug, en, fr), public.maps m
where m.slug = v.map_slug and s.map_id = m.id and s.name = v.en and v.en <> v.fr
  and not exists (select 1 from public.sites x where x.map_id = s.map_id and x.name = v.fr);

-- Étages : B → SS, 1F → RDC, 2F → 1er, 3F → 2e (comme dans la version française du jeu)
update public.sites s set floor = v.fr
from (values
  ('B', 'SS'),
  ('1F', 'RDC'),
  ('2F', '1er'),
  ('3F', '2e'),
  ('4F', '3e'),
  ('B/1F', 'SS/RDC'),
  ('1F/2F', 'RDC/1er')
) as v(en, fr)
where s.floor = v.en;
alter table public.sites alter column floor set default 'RDC';

-- L'API Supabase relit la structure tout de suite (nouvelles tables et fonctions)
notify pgrst, 'reload schema';

-- Fin. Vérification rapide :
-- select (select count(*) from maps) as cartes, (select count(*) from sites) as bp,
--        (select count(*) from operators) as agents, (select count(*) from strategies) as videos,
--        (select count(*) from strategy_sites) as rangements, (select count(*) from admins) as admins;
