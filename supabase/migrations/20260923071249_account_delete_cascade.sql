SET local check_function_bodies = off;

REVOKE ALL ON FUNCTION "public"."archive_pull"(bigint) FROM "anon";

REVOKE ALL ON FUNCTION "public"."archive_push"(jsonb) FROM "anon";

REVOKE ALL ON TABLE "public"."archive_changes" FROM "anon";

REVOKE ALL ON TABLE "public"."archive_conflicts" FROM "anon";

REVOKE ALL ON TABLE "public"."archive_corrections" FROM "anon";

REVOKE ALL ON TABLE "public"."archive_heads" FROM "anon";

REVOKE ALL ON TABLE "public"."archive_media" FROM "anon";

REVOKE ALL ON TABLE "public"."archive_receipts" FROM "anon";

REVOKE ALL ON TABLE "public"."archive_stories" FROM "anon";

REVOKE ALL ON TABLE "public"."archive_story_items" FROM "anon";

ALTER TABLE "public"."archive_story_items"
  DROP CONSTRAINT "archive_story_items_user_id_media_id_fkey";

ALTER TABLE "public"."archive_story_items"
  ADD CONSTRAINT "archive_story_items_user_id_media_id_fkey" FOREIGN KEY (user_id, media_id) REFERENCES public.archive_media(user_id, id) ON DELETE CASCADE;
