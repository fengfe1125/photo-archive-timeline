import { PGlite } from "npm:@electric-sql/pglite@0.3.14";
function assert(ok: unknown, message: string) {
  if (!ok) throw new Error(message);
}
Deno.test("Postgres ledger RLS, request uniqueness, expiry and account deletion", async () => {
  const db = new PGlite();
  try {
    await db.exec(
      `create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema auth to authenticated; grant execute on function auth.uid() to authenticated;`,
    );
    await db.exec(
      await Deno.readTextFile(
        new URL("../../schemas/search.sql", import.meta.url),
      ),
    );
    const a = "00000000-0000-4000-8000-000000000001",
      b = "00000000-0000-4000-8000-000000000002",
      id = "10000000-0000-4000-8000-000000000001";
    await db.query("insert into auth.users values ($1),($2)", [a, b]);
    await db.query(
      `insert into search_usage(user_id,id,search_id,endpoint,payload_hash,provider,model,currency) values ($1,$2,$2,'analyze-photo','hash','MiniMax','MiniMax-M3','CNY')`,
      [a, id],
    );
    let rejected = false;
    try {
      await db.query(
        `insert into search_usage(user_id,id,search_id,endpoint,payload_hash,provider,model,currency) values ($1,$2,$2,'analyze-photo','hash','MiniMax','MiniMax-M3','CNY')`,
        [a, id],
      );
    } catch {
      rejected = true;
    }
    assert(rejected, "duplicate request must not reserve another call");
    await db.exec(`set role authenticated; set request.jwt.claim.sub='${b}';`);
    assert(
      (await db.query("select * from search_usage")).rows.length === 0,
      "other user must not see ledger",
    );
    await db.exec(`set request.jwt.claim.sub='${a}';`);
    assert(
      (await db.query("select * from search_usage")).rows.length === 1,
      "owner sees own ledger",
    );
    rejected = false;
    try {
      await db.exec(`update search_usage set cost=0`);
    } catch {
      rejected = true;
    }
    assert(rejected, "client cannot alter billing");
    rejected = false;
    try {
      await db.exec(`select * from search_receipts`);
    } catch {
      rejected = true;
    }
    assert(rejected, "client cannot read receipts directly");
    await db.exec("reset role");
    await db.query(
      `insert into search_receipts(user_id,id,result,expires_at) values ($1,$2,'{}',now()-interval '1 hour')`,
      [a, id],
    );
    await db.exec("delete from search_receipts where expires_at <= now()");
    assert(
      (await db.query("select * from search_receipts")).rows.length === 0,
      "expired payload is deleted",
    );
    await db.query("delete from auth.users where id=$1", [a]);
    assert(
      (await db.query("select * from search_usage")).rows.length === 0,
      "delete account removes ledger",
    );
  } finally {
    await db.close();
  }
});
