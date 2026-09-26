alter table public.archive_media_assets drop constraint archive_media_assets_check2;
alter table public.archive_media_assets add constraint archive_media_assets_preview_path_check
  check (preview_path is null or preview_path in (
    user_id::text || '/' || media_id::text || '/preview.webp',
    user_id::text || '/' || media_id::text || '/preview.jpg'
  ));

create or replace function public.archive_complete_asset(p_media_id uuid, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); asset public.archive_media_assets%rowtype;
  object_size bigint; preview_name text;
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
  if p_preview then
    select name into preview_name from storage.objects where bucket_id = 'archive-previews'
      and name in (actor::text || '/' || p_media_id::text || '/preview.webp',
                   actor::text || '/' || p_media_id::text || '/preview.jpg')
      order by name desc limit 1;
    if preview_name is not null then
      update public.archive_media_assets set preview_path = preview_name
        where user_id = actor and media_id = p_media_id;
    end if;
  end if;
  update public.archive_media_assets set status = 'ready' where user_id = actor and media_id = p_media_id;
  return jsonb_build_object('mediaID', p_media_id, 'status', 'ready');
end $$;
