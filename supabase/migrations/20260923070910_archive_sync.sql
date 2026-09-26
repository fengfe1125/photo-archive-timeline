SET local check_function_bodies = off;

CREATE SCHEMA "archive_private";

CREATE TABLE "public"."archive_changes" (
  "user_id"  uuid   NOT NULL,
  "sequence" bigint NOT NULL,
  "record"   jsonb  NOT NULL,
  CONSTRAINT "archive_changes_pkey" PRIMARY KEY (user_id, SEQUENCE)
);

ALTER TABLE "public"."archive_changes"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."archive_conflicts" (
  "user_id"       uuid    NOT NULL,
  "id"            uuid    NOT NULL,
  "local_record"  jsonb   NOT NULL,
  "remote_record" jsonb   NOT NULL,
  "resolved"      boolean NOT NULL DEFAULT false,
  CONSTRAINT "archive_conflicts_pkey" PRIMARY KEY (user_id, id)
);

ALTER TABLE "public"."archive_conflicts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."archive_corrections" (
  "user_id" uuid    NOT NULL,
  "id"      uuid    NOT NULL,
  "payload" jsonb   NOT NULL,
  "version" bigint  NOT NULL,
  "deleted" boolean NOT NULL DEFAULT false,
  CONSTRAINT "archive_corrections_pkey" PRIMARY KEY (user_id, id)
);

ALTER TABLE "public"."archive_corrections"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."archive_heads" (
  "user_id"  uuid   NOT NULL,
  "sequence" bigint NOT NULL DEFAULT 0,
  CONSTRAINT "archive_heads_pkey" PRIMARY KEY (user_id)
);

ALTER TABLE "public"."archive_heads"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."archive_media" (
  "user_id"          uuid   NOT NULL,
  "id"               uuid   NOT NULL,
  "kind"             text   NOT NULL,
  "cloud_identifier" text,
  "version"          bigint NOT NULL DEFAULT 1,
  CONSTRAINT "archive_media_kind_check" CHECK ((kind = ANY (ARRAY['photo'::text, 'video'::text]))),
  CONSTRAINT "archive_media_pkey" PRIMARY KEY (user_id, id),
  CONSTRAINT "archive_media_user_id_cloud_identifier_key" UNIQUE (user_id, cloud_identifier)
);

ALTER TABLE "public"."archive_media"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."archive_receipts" (
  "user_id"      uuid  NOT NULL,
  "operation_id" uuid  NOT NULL,
  "request"      jsonb NOT NULL,
  "response"     jsonb NOT NULL,
  CONSTRAINT "archive_receipts_pkey" PRIMARY KEY (user_id, operation_id)
);

ALTER TABLE "public"."archive_receipts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."archive_stories" (
  "user_id" uuid    NOT NULL,
  "id"      uuid    NOT NULL,
  "payload" jsonb   NOT NULL,
  "version" bigint  NOT NULL,
  "deleted" boolean NOT NULL DEFAULT false,
  CONSTRAINT "archive_stories_pkey" PRIMARY KEY (user_id, id)
);

ALTER TABLE "public"."archive_stories"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."archive_story_items" (
  "user_id"  uuid    NOT NULL,
  "story_id" uuid    NOT NULL,
  "media_id" uuid    NOT NULL,
  "position" integer NOT NULL,
  CONSTRAINT "archive_story_items_pkey" PRIMARY KEY (user_id, story_id, media_id),
  CONSTRAINT "archive_story_items_position_check" CHECK (("position" >= 0)),
  CONSTRAINT "archive_story_items_user_id_story_id_position_key" UNIQUE (user_id, story_id, "position")
);

ALTER TABLE "public"."archive_story_items"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION archive_private.current_record (
  p_user   uuid,
  p_entity text,
  p_id     uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION archive_private.push (
  p_operation jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.archive_pull (
  p_after bigint DEFAULT 0
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.archive_push (
  p_operation jsonb
)
  RETURNS jsonb
  LANGUAGE sql
  SET search_path TO ''
  AS $function$ select archive_private.push(p_operation); $function$;

ALTER TABLE "public"."archive_changes"
  ADD CONSTRAINT "archive_changes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."archive_conflicts"
  ADD CONSTRAINT "archive_conflicts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."archive_heads"
  ADD CONSTRAINT "archive_heads_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."archive_corrections"
  ADD CONSTRAINT "archive_corrections_user_id_id_fkey" FOREIGN KEY (user_id, id) REFERENCES public.archive_media(user_id, id) ON DELETE CASCADE;

ALTER TABLE "public"."archive_media"
  ADD CONSTRAINT "archive_media_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."archive_receipts"
  ADD CONSTRAINT "archive_receipts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."archive_stories"
  ADD CONSTRAINT "archive_stories_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."archive_story_items"
  ADD CONSTRAINT "archive_story_items_user_id_media_id_fkey" FOREIGN KEY (user_id, media_id) REFERENCES public.archive_media(user_id, id);

ALTER TABLE "public"."archive_story_items"
  ADD CONSTRAINT "archive_story_items_user_id_story_id_fkey" FOREIGN KEY (user_id, story_id) REFERENCES public.archive_stories(user_id, id) ON DELETE CASCADE;

CREATE INDEX archive_story_items_media_idx ON public.archive_story_items USING btree (user_id, media_id);

CREATE POLICY "own_changes" ON "public"."archive_changes"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

CREATE POLICY "own_conflicts" ON "public"."archive_conflicts"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

CREATE POLICY "own_corrections" ON "public"."archive_corrections"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

CREATE POLICY "own_heads" ON "public"."archive_heads"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

CREATE POLICY "own_media" ON "public"."archive_media"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

CREATE POLICY "own_receipts" ON "public"."archive_receipts"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

CREATE POLICY "own_stories" ON "public"."archive_stories"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

CREATE POLICY "own_story_items" ON "public"."archive_story_items"
  FOR SELECT
  TO "authenticated"
  USING ((( SELECT auth.uid() AS uid) = user_id));

REVOKE ALL ON FUNCTION "archive_private"."current_record"(uuid, text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "archive_private"."current_record"(uuid, text, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "archive_private"."push"(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "archive_private"."push"(jsonb) TO "authenticated", "postgres";

REVOKE ALL ON FUNCTION "public"."archive_pull"(bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."archive_pull"(bigint) TO "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "public"."archive_push"(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."archive_push"(jsonb) TO "authenticated", "postgres", "service_role";

GRANT USAGE ON SCHEMA "archive_private" TO "authenticated";

GRANT CREATE, USAGE ON SCHEMA "archive_private" TO "postgres";

REVOKE ALL ON TABLE "public"."archive_changes" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_changes" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_changes" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."archive_conflicts" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_conflicts" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_conflicts" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."archive_corrections" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_corrections" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_corrections" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."archive_heads" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_heads" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_heads" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."archive_media" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_media" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_media" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."archive_receipts" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_receipts" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_receipts" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."archive_stories" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_stories" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_stories" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."archive_story_items" FROM "authenticated";

GRANT SELECT ON TABLE "public"."archive_story_items" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."archive_story_items" TO "postgres", "service_role";
