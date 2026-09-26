-- Cloud media extends the v1 archive protocol without changing its payloads.
insert into storage.buckets (id, name, public, file_size_limit)
values ('archive-originals', 'archive-originals', false, 52428800),
       ('archive-previews', 'archive-previews', false, 5242880)
on conflict (id) do nothing;

create table public.archive_media_assets (
  user_id uuid not null,
  media_id uuid not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  bytes bigint not null check (bytes > 0 and bytes <= 52428800),
  mime_type text not null check (length(mime_type) between 3 and 100),
  display_name text not null check (length(display_name) between 1 and 500),
  object_path text not null,
  preview_path text,
  captured_at timestamptz,
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  time_sources jsonb not null default '[]'::jsonb check (jsonb_typeof(time_sources) = 'array'),
  geo_sources jsonb not null default '[]'::jsonb check (jsonb_typeof(geo_sources) = 'array'),
  status text not null default 'pending' check (status in ('pending', 'ready')),
  created_at timestamptz not null default now(),
  primary key (user_id, media_id),
  unique (user_id, sha256),
  unique (object_path),
  foreign key (user_id, media_id) references public.archive_media (user_id, id) on delete cascade,
  check ((latitude is null) = (longitude is null)),
  check (object_path = user_id::text || '/' || media_id::text || '/' || sha256),
  check (preview_path is null or preview_path = user_id::text || '/' || media_id::text || '/preview.webp')
);
create index archive_media_assets_timeline_idx on public.archive_media_assets (user_id, captured_at desc, media_id);
alter table public.archive_media_assets enable row level security;
create policy own_media_assets on public.archive_media_assets for select to authenticated
  using ((select auth.uid()) = user_id);
revoke all on public.archive_media_assets from anon, authenticated;
grant select on public.archive_media_assets to authenticated;

create table public.archive_story_extras (
  user_id uuid not null,
  story_id uuid not null,
  start_day date,
  end_day date,
  place text check (place is null or length(place) <= 1000),
  version bigint not null default 1 check (version > 0),
  primary key (user_id, story_id),
  foreign key (user_id, story_id) references public.archive_stories (user_id, id) on delete cascade,
  check (end_day is null or start_day is null or end_day >= start_day)
);
alter table public.archive_story_extras enable row level security;
create policy own_story_extras on public.archive_story_extras for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
revoke all on public.archive_story_extras from anon, authenticated;
grant select, insert, update, delete on public.archive_story_extras to authenticated;

create table public.archive_story_captions (
  user_id uuid not null,
  story_id uuid not null,
  media_id uuid not null,
  caption text not null check (length(caption) <= 20000),
  version bigint not null default 1 check (version > 0),
  primary key (user_id, story_id, media_id),
  foreign key (user_id, story_id) references public.archive_stories (user_id, id) on delete cascade,
  foreign key (user_id, media_id) references public.archive_media (user_id, id) on delete cascade
);
create index archive_story_captions_media_idx on public.archive_story_captions (user_id, media_id);
alter table public.archive_story_captions enable row level security;
create policy own_story_captions on public.archive_story_captions for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
revoke all on public.archive_story_captions from anon, authenticated;
grant select, insert, update, delete on public.archive_story_captions to authenticated;

create policy archive_originals_read on storage.objects for select to authenticated
  using (bucket_id = 'archive-originals' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy archive_originals_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'archive-originals' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy archive_previews_read on storage.objects for select to authenticated
  using (bucket_id = 'archive-previews' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy archive_previews_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'archive-previews' and (storage.foldername(name))[1] = (select auth.uid()::text));

create function public.archive_prepare_asset(
  p_media_id uuid, p_sha256 text, p_bytes bigint, p_mime_type text, p_display_name text,
  p_captured_at timestamptz default null, p_latitude double precision default null,
  p_longitude double precision default null, p_time_sources jsonb default '[]'::jsonb,
  p_geo_sources jsonb default '[]'::jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); existing public.archive_media_assets%rowtype;
begin
  if actor is null or not exists (select 1 from auth.users where id = actor) then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_sha256 !~ '^[0-9a-f]{64}$' or p_bytes not between 1 and 52428800 or
     length(p_mime_type) not between 3 and 100 or length(p_display_name) not between 1 and 500 or
     (p_latitude is null) <> (p_longitude is null) or p_latitude not between -90 and 90 or
     p_longitude not between -180 and 180 or jsonb_typeof(p_time_sources) <> 'array' or
     jsonb_typeof(p_geo_sources) <> 'array' or
     octet_length(p_time_sources::text) > 65536 or octet_length(p_geo_sources::text) > 65536 then
    raise exception 'Invalid asset' using errcode = '22023';
  end if;
  if not exists (select 1 from public.archive_media where user_id = actor and id = p_media_id) then
    raise exception 'Media reference unavailable' using errcode = '42501';
  end if;
  insert into public.archive_heads(user_id) values (actor) on conflict do nothing;
  perform 1 from public.archive_heads where user_id = actor for update;
  select * into existing from public.archive_media_assets where user_id = actor and sha256 = p_sha256;
  if found then
    return jsonb_build_object('mediaID', existing.media_id, 'objectPath', existing.object_path,
      'previewPath', existing.preview_path, 'status', existing.status,
      'duplicate', existing.media_id <> p_media_id);
  end if;
  insert into public.archive_media_assets
    (user_id, media_id, sha256, bytes, mime_type, display_name, object_path,
     captured_at, latitude, longitude, time_sources, geo_sources)
  values (actor, p_media_id, p_sha256, p_bytes, p_mime_type, p_display_name,
    actor::text || '/' || p_media_id::text || '/' || p_sha256,
    p_captured_at, p_latitude, p_longitude, p_time_sources, p_geo_sources)
  on conflict (user_id, media_id) do nothing;
  select * into existing from public.archive_media_assets where user_id = actor and media_id = p_media_id;
  if existing.sha256 <> p_sha256 then
    raise exception 'Media already has a different original' using errcode = '22023';
  end if;
  return jsonb_build_object('mediaID', existing.media_id, 'objectPath', existing.object_path,
    'previewPath', existing.preview_path, 'status', existing.status, 'duplicate', false);
end $$;

create function public.archive_complete_asset(p_media_id uuid, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); asset public.archive_media_assets%rowtype; object_size bigint;
begin
  if actor is null or not exists (select 1 from auth.users where id = actor) then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select * into asset from public.archive_media_assets
    where user_id = actor and media_id = p_media_id for update;
  if not found then raise exception 'Asset not found' using errcode = '22023'; end if;
  select (metadata->>'size')::bigint into object_size from storage.objects
    where bucket_id = 'archive-originals' and name = asset.object_path;
  if object_size is distinct from asset.bytes then
    raise exception 'Uploaded original missing or wrong size' using errcode = '22023';
  end if;
  if p_preview and exists (select 1 from storage.objects where bucket_id = 'archive-previews'
    and name = actor::text || '/' || p_media_id::text || '/preview.webp') then
    update public.archive_media_assets set preview_path = actor::text || '/' || p_media_id::text || '/preview.webp'
      where user_id = actor and media_id = p_media_id;
  end if;
  update public.archive_media_assets set status = 'ready' where user_id = actor and media_id = p_media_id;
  return jsonb_build_object('mediaID', p_media_id, 'status', 'ready');
end $$;

revoke all on function public.archive_prepare_asset(uuid,text,bigint,text,text,timestamptz,double precision,double precision,jsonb,jsonb) from public;
revoke all on function public.archive_complete_asset(uuid,boolean) from public;
grant execute on function public.archive_prepare_asset(uuid,text,bigint,text,text,timestamptz,double precision,double precision,jsonb,jsonb) to authenticated;
grant execute on function public.archive_complete_asset(uuid,boolean) to authenticated;
