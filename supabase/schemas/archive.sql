-- The public API only grants reads and two transactional RPCs. Privileged writes
-- live in an unexposed schema and explicitly validate the authenticated user.
create schema if not exists archive_private;
revoke all on schema archive_private from public, anon;
grant usage on schema archive_private to authenticated;

create table public.archive_media (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  kind text not null check (kind in ('photo','video')),
  cloud_identifier text,
  version bigint not null default 1,
  primary key (user_id,id),
  unique(user_id,cloud_identifier)
);
create table public.archive_stories (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  payload jsonb not null,
  version bigint not null,
  deleted boolean not null default false,
  primary key(user_id,id)
);
create table public.archive_story_items (
  user_id uuid not null,
  story_id uuid not null,
  media_id uuid not null,
  position integer not null check(position >= 0),
  primary key(user_id,story_id,media_id),
  unique(user_id,story_id,position),
  foreign key(user_id,story_id) references public.archive_stories(user_id,id) on delete cascade,
  foreign key(user_id,media_id) references public.archive_media(user_id,id) on delete cascade
);
create index archive_story_items_media_idx on public.archive_story_items(user_id,media_id);
create table public.archive_corrections (
  user_id uuid not null,
  id uuid not null,
  payload jsonb not null,
  version bigint not null,
  deleted boolean not null default false,
  primary key(user_id,id),
  foreign key(user_id,id) references public.archive_media(user_id,id) on delete cascade
);
create table public.archive_heads (
  user_id uuid primary key references auth.users(id) on delete cascade,
  sequence bigint not null default 0
);
create table public.archive_changes (
  user_id uuid not null references auth.users(id) on delete cascade,
  sequence bigint not null,
  record jsonb not null,
  primary key(user_id,sequence)
);
create table public.archive_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null,
  request jsonb not null,
  response jsonb not null,
  primary key(user_id,operation_id)
);
create table public.archive_conflicts (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  local_record jsonb not null,
  remote_record jsonb not null,
  resolved boolean not null default false,
  primary key(user_id,id)
);

alter table public.archive_media enable row level security;
alter table public.archive_stories enable row level security;
alter table public.archive_story_items enable row level security;
alter table public.archive_corrections enable row level security;
alter table public.archive_heads enable row level security;
alter table public.archive_changes enable row level security;
alter table public.archive_receipts enable row level security;
alter table public.archive_conflicts enable row level security;
create policy own_media on public.archive_media for select to authenticated using((select auth.uid()) = user_id);
create policy own_stories on public.archive_stories for select to authenticated using((select auth.uid()) = user_id);
create policy own_story_items on public.archive_story_items for select to authenticated using((select auth.uid()) = user_id);
create policy own_corrections on public.archive_corrections for select to authenticated using((select auth.uid()) = user_id);
create policy own_heads on public.archive_heads for select to authenticated using((select auth.uid()) = user_id);
create policy own_changes on public.archive_changes for select to authenticated using((select auth.uid()) = user_id);
create policy own_receipts on public.archive_receipts for select to authenticated using((select auth.uid()) = user_id);
create policy own_conflicts on public.archive_conflicts for select to authenticated using((select auth.uid()) = user_id);
revoke all on public.archive_media,public.archive_stories,public.archive_story_items,public.archive_corrections,public.archive_heads,public.archive_changes,public.archive_receipts,public.archive_conflicts from anon,authenticated;
grant select on public.archive_media,public.archive_stories,public.archive_story_items,public.archive_corrections,public.archive_heads,public.archive_changes,public.archive_receipts,public.archive_conflicts to authenticated;

create function archive_private.current_record(p_user uuid,p_entity text,p_id uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare result jsonb;
begin
  if p_entity = 'media' then
    select jsonb_build_object('entity','media','id',id,'version',version,'deleted',false,
      'payload',jsonb_strip_nulls(jsonb_build_object('kind',kind,'cloudIdentifier',cloud_identifier))) into result
      from public.archive_media where user_id=p_user and id=p_id;
  elsif p_entity = 'story' then
    select jsonb_build_object('entity','story','id',id,'version',version,'deleted',deleted,'payload',payload) into result
      from public.archive_stories where user_id=p_user and id=p_id;
  elsif p_entity = 'correction' then
    select jsonb_build_object('entity','correction','id',id,'version',version,'deleted',deleted,'payload',payload) into result
      from public.archive_corrections where user_id=p_user and id=p_id;
  end if;
  return coalesce(result,jsonb_build_object('entity',p_entity,'id',p_id,'version',0,'deleted',true,'payload','{}'::jsonb));
end $$;
revoke all on function archive_private.current_record(uuid,text,uuid) from public,anon,authenticated;

create function archive_private.push(p_operation jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  op uuid := (p_operation->>'id')::uuid;
  entity text := p_operation->>'entity';
  entity_id uuid := (p_operation->>'entityID')::uuid;
  base bigint := (p_operation->>'baseVersion')::bigint;
  gone boolean := (p_operation->>'deleted')::boolean;
  body jsonb := p_operation->'payload';
  resolving uuid := (p_operation->>'resolving')::uuid;
  current_value jsonb; local_value jsonb; response jsonb; saved_request jsonb;
  next_version bigint; next_sequence bigint; canonical uuid;
  allowed text[]; field text; day_text text;
begin
  if actor is null or not exists(select 1 from auth.users where id=actor) then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if op is null or entity_id is null or base is null or base < 0 or gone is null or
    entity is null or entity not in ('media','story','correction') or jsonb_typeof(body) is distinct from 'object' or octet_length(p_operation::text)>524288 then
    raise exception 'Invalid operation' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_object_keys(p_operation) k where k not in ('id','entity','entityID','baseVersion','deleted','payload','resolving')) then
    raise exception 'Unknown operation field' using errcode='22023';
  end if;
  -- Row lock spans record changes, conflict updates, receipt and sequence assignment.
  -- A later writer cannot obtain its sequence before this transaction commits.
  insert into public.archive_heads(user_id) values(actor) on conflict do nothing;
  perform 1 from public.archive_heads where user_id=actor for update;
  select r.request,r.response into saved_request,response from public.archive_receipts r where r.user_id=actor and r.operation_id=op;
  if found then
    if saved_request <> p_operation then raise exception 'Operation ID reused with different content' using errcode='22023'; end if;
    return response;
  end if;
  if resolving is not null and not exists(
    select 1 from public.archive_conflicts where user_id=actor and id=resolving
      and local_record->>'entity'=entity and (local_record->>'id')::uuid=entity_id) then
    raise exception 'Unknown conflict' using errcode='22023';
  end if;
  if gone then
    if entity='media' or body <> '{}'::jsonb then raise exception 'Invalid deletion' using errcode='22023'; end if;
  else
    allowed := case entity when 'media' then array['kind','cloudIdentifier']
      when 'story' then array['title','description','mediaIDs','coverID']
      else array['description','dayMode','day','placeMode','place'] end;
    if exists(select 1 from jsonb_object_keys(body) k where not(k=any(allowed))) then
      raise exception 'Payload contains fields outside the privacy allowlist' using errcode='22023';
    end if;
    if entity='media' then
      if coalesce(body->>'kind','') not in ('photo','video') or length(coalesce(body->>'cloudIdentifier',''))>4096 then raise exception 'Invalid media reference' using errcode='22023'; end if;
      if body ? 'cloudIdentifier' and jsonb_typeof(body->'cloudIdentifier') <> 'string' then raise exception 'Invalid cloud identifier' using errcode='22023'; end if;
      select id into canonical from public.archive_media where user_id=actor and cloud_identifier=body->>'cloudIdentifier';
    elsif entity='story' then
      if jsonb_typeof(body->'title') is distinct from 'string' or length(btrim(body->>'title')) not between 1 and 500
        or jsonb_typeof(body->'description') is distinct from 'string' or length(body->>'description')>20000
        or jsonb_typeof(body->'mediaIDs') is distinct from 'array' then raise exception 'Invalid story' using errcode='22023'; end if;
      if jsonb_array_length(body->'mediaIDs')>5000 or
        (select count(*) from jsonb_array_elements_text(body->'mediaIDs')) <>
        (select count(distinct value) from jsonb_array_elements_text(body->'mediaIDs')) then raise exception 'Invalid story members' using errcode='22023'; end if;
      if exists(select 1 from jsonb_array_elements_text(body->'mediaIDs') x where not exists(
        select 1 from public.archive_media m where m.user_id=actor and m.id=x.value::uuid)) then raise exception 'Photo reference unavailable' using errcode='42501'; end if;
      if (jsonb_array_length(body->'mediaIDs')=0 and body->>'coverID' is not null) or
         (jsonb_array_length(body->'mediaIDs')>0 and (body->>'coverID' is null or not (body->'mediaIDs' ? (body->>'coverID')))) then raise exception 'Invalid cover' using errcode='22023'; end if;
    else
      if not exists(select 1 from public.archive_media where user_id=actor and id=entity_id) then raise exception 'Photo reference unavailable' using errcode='42501'; end if;
      if jsonb_typeof(body->'description') is distinct from 'string' or length(body->>'description')>20000 or
        coalesce(body->>'dayMode','') not in ('original','clear','value') or coalesce(body->>'placeMode','') not in ('original','clear','value') then raise exception 'Invalid correction' using errcode='22023'; end if;
      if body->>'dayMode'='value' then
        if jsonb_typeof(body->'day') is distinct from 'object' or exists(select 1 from jsonb_object_keys(body->'day') k where k not in ('year','month','day')) then raise exception 'Invalid day' using errcode='22023'; end if;
        -- make_date rejects nonexistent calendar dates, including invalid leap days.
        day_text := make_date((body->'day'->>'year')::int,(body->'day'->>'month')::int,(body->'day'->>'day')::int)::text;
        if day_text is null or (body->'day'->>'year')::int not between 1 and 9999 then raise exception 'Invalid day' using errcode='22023'; end if;
      elsif body ? 'day' then raise exception 'Original date must stay local' using errcode='22023'; end if;
      if body->>'placeMode'='value' then
        if jsonb_typeof(body->'place') is distinct from 'object' or jsonb_typeof(body->'place'->'name') is distinct from 'string' or length(body->'place'->>'name')>1000
          or exists(select 1 from jsonb_object_keys(body->'place') k where k not in ('name','latitude','longitude')) then raise exception 'Invalid place' using errcode='22023'; end if;
        if (body->'place' ? 'latitude') <> (body->'place' ? 'longitude') then raise exception 'Coordinates must be paired' using errcode='22023'; end if;
        if body->'place' ? 'latitude' and (jsonb_typeof(body->'place'->'latitude')<>'number' or jsonb_typeof(body->'place'->'longitude')<>'number' or
          (body->'place'->>'latitude')::numeric not between -90 and 90 or (body->'place'->>'longitude')::numeric not between -180 and 180) then raise exception 'Invalid coordinates' using errcode='22023'; end if;
      elsif body ? 'place' then raise exception 'Original location must stay local' using errcode='22023'; end if;
    end if;
  end if;
  current_value := archive_private.current_record(actor,entity,entity_id);
  if canonical is not null and canonical<>entity_id and base=0 and (current_value->>'version')::bigint=0 then
    current_value := archive_private.current_record(actor,'media',canonical);
    response := jsonb_build_object('status','canonical','record',current_value);
  elsif (current_value->>'version')::bigint <> base then
    local_value := jsonb_build_object('entity',entity,'id',entity_id,'version',base,'deleted',gone,'payload',body);
    insert into public.archive_conflicts(user_id,id,local_record,remote_record) values(actor,op,local_value,current_value);
    if resolving is not null then update public.archive_conflicts set resolved=true where user_id=actor and id=resolving; end if;
    response := jsonb_build_object('status','conflict','record',current_value,'conflict',jsonb_build_object('id',op,'local',local_value,'remote',current_value));
  else
    next_version := base+1;
    if entity='media' then
      insert into public.archive_media(user_id,id,kind,cloud_identifier,version) values(actor,entity_id,body->>'kind',body->>'cloudIdentifier',next_version)
        on conflict(user_id,id) do update set kind=excluded.kind,cloud_identifier=excluded.cloud_identifier,version=excluded.version;
    elsif entity='story' then
      insert into public.archive_stories(user_id,id,payload,version,deleted) values(actor,entity_id,body,next_version,gone)
        on conflict(user_id,id) do update set payload=excluded.payload,version=excluded.version,deleted=excluded.deleted;
      delete from public.archive_story_items where user_id=actor and story_id=entity_id;
      if not gone then
        insert into public.archive_story_items(user_id,story_id,media_id,position)
          select actor,entity_id,value::uuid,ordinality::int-1 from jsonb_array_elements_text(body->'mediaIDs') with ordinality;
      end if;
    else
      insert into public.archive_corrections(user_id,id,payload,version,deleted) values(actor,entity_id,body,next_version,gone)
        on conflict(user_id,id) do update set payload=excluded.payload,version=excluded.version,deleted=excluded.deleted;
    end if;
    update public.archive_heads set sequence=sequence+1 where user_id=actor returning sequence into next_sequence;
    current_value := archive_private.current_record(actor,entity,entity_id);
    insert into public.archive_changes(user_id,sequence,record) values(actor,next_sequence,current_value);
    if resolving is not null then update public.archive_conflicts set resolved=true where user_id=actor and id=resolving; end if;
    response := jsonb_build_object('status','accepted','record',current_value);
  end if;
  insert into public.archive_receipts(user_id,operation_id,request,response) values(actor,op,p_operation,response);
  return response;
end $$;
revoke all on function archive_private.push(jsonb) from public,anon;
grant execute on function archive_private.push(jsonb) to authenticated;

create function public.archive_push(p_operation jsonb) returns jsonb
language sql security invoker set search_path = '' as $$ select archive_private.push(p_operation); $$;
revoke all on function public.archive_push(jsonb) from public,anon;
grant execute on function public.archive_push(jsonb) to authenticated;

create function public.archive_pull(p_after bigint default 0) returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare items jsonb; conflicts jsonb; cursor_value bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_after<0 then raise exception 'Invalid cursor' using errcode='22023'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('sequence',sequence,'record',record) order by sequence),'[]'::jsonb),coalesce(max(sequence),p_after)
    into items,cursor_value from (select sequence,record from public.archive_changes where user_id=(select auth.uid()) and sequence>p_after order by sequence limit 200) page;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'local',local_record,'remote',remote_record)),'[]'::jsonb)
    into conflicts from public.archive_conflicts where user_id=(select auth.uid()) and not resolved;
  return jsonb_build_object('changes',items,'conflicts',conflicts,'cursor',cursor_value,'hasMore',
    exists(select 1 from public.archive_changes where user_id=(select auth.uid()) and sequence>cursor_value));
end $$;
revoke all on function public.archive_pull(bigint) from public,anon;
grant execute on function public.archive_pull(bigint) to authenticated;
