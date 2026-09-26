import { createClient } from "npm:@supabase/supabase-js@2.99.3";

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return new Response("Unauthorized", { status: 401 });
  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const jwt = authorization.slice(7);
  // Online Auth validation, not just JWT decoding: deleted users must not act.
  const { data: { user }, error } = await admin.auth.getUser(jwt);
  if (error || !user) return new Response("Unauthorized", { status: 401 });
  // Storage objects do not follow Auth foreign-key cascades. Remove every object
  // under this authenticated account before deleting the user.
  async function objects(bucket: string, folder: string): Promise<string[]> {
    const paths: string[] = [];
    for (let offset = 0; ; offset += 1000) {
      const page = await admin.storage.from(bucket).list(folder, { limit: 1000, offset });
      if (page.error) throw page.error;
      const entries = page.data ?? [];
      for (const entry of entries) {
        const path = `${folder}/${entry.name}`;
        if (entry.id) paths.push(path);
        else paths.push(...await objects(bucket, path));
      }
      if (entries.length < 1000) break;
    }
    return paths;
  }
  try {
    for (const bucket of ["archive-originals", "archive-previews"]) {
      const paths = await objects(bucket, user.id);
      for (let index = 0; index < paths.length; index += 1000) {
        const removed = await admin.storage.from(bucket).remove(paths.slice(index, index + 1000));
        if (removed.error) throw removed.error;
      }
    }
  } catch {
    return Response.json({ error: "Media cleanup failed; account retained for retry" }, { status: 503 });
  }
  const revoked = await admin.auth.admin.signOut(jwt, "global");
  if (revoked.error) return Response.json({ error: "Session revocation failed" }, { status: 503 });
  const deleted = await admin.auth.admin.deleteUser(user.id);
  if (deleted.error) return Response.json({ error: "Account deletion failed; retry after signing in" }, { status: 503 });
  return Response.json({ deleted: true });
});
