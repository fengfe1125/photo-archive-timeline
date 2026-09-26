import { searchHandler } from "./search-handler.ts";
function assert(value: unknown, message: string) {
  if (!value) throw new Error(message);
}
Deno.test("proxy authenticates, reserves once, replays receipt and does not retry uncertain charges", async () => {
  const prior = globalThis.fetch;
  const envKeys = [
    "SUPABASE_URL",
    "SUPABASE_SERVICE_ROLE_KEY",
    "MINIMAX_API_KEY",
    "OPENROUTER_API_KEY",
    "MINIMAX_BASE_URL",
    "OPENROUTER_BASE_URL",
  ];
  const previous = new Map(envKeys.map((k) => [k, Deno.env.get(k)]));
  Deno.env.set("SUPABASE_URL", "https://search-test.invalid");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-key");
  Deno.env.set("MINIMAX_API_KEY", "sk-cp-test");
  Deno.env.set("OPENROUTER_API_KEY", "test");
  Deno.env.set("MINIMAX_BASE_URL", "https://minimax-test.invalid/v1");
  Deno.env.set("OPENROUTER_BASE_URL", "https://jev-test.invalid/api");
  const rows = new Map<string, Record<string, any>>(),
    receipts = new Map<string, Record<string, any>>();
  const user = "00000000-0000-4000-8000-000000000001";
  let providerCalls = 0;
  let timeout = false;
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init), url = new URL(req.url);
    if (url.pathname === "/auth/v1/user") {
      return req.headers.get("authorization") === "Bearer valid"
        ? json({ id: user, email: "test@example.test" })
        : json({ message: "Invalid token" }, 401);
    }
    if (url.hostname === "minimax-test.invalid") {
      providerCalls++;
      if (timeout) throw new TypeError("Simulated disconnect");
      return json({
        id: "provider-test",
        model: "MiniMax-M3",
        choices: [{
          message: {
            content: JSON.stringify({
              description: "山脉与树林",
              labels: ["山林"],
            }),
          },
        }],
        usage: { prompt_tokens: 400, completion_tokens: 30 },
      });
    }
    if (url.pathname.startsWith("/rest/v1/")) {
      const table = url.pathname.split("/").pop(),
        map = table === "search_receipts" ? receipts : rows;
      if (req.method === "POST") {
        const data = await req.json();
        const key = data.user_id + ":" + data.id;
        if (map.has(key)) {
          return json({ code: "23505", message: "duplicate" }, 409);
        }
        map.set(key, data);
        return new Response(null, { status: 201 });
      }
      const id = url.searchParams.get("id")?.replace("eq.", ""),
        uid = url.searchParams.get("user_id")?.replace("eq.", "");
      const row = map.get(uid + ":" + id);
      if (req.method === "PATCH") {
        if (row) Object.assign(row, await req.json());
        return new Response(null, { status: 204 });
      }
      if (req.method === "GET") return row ? json(row) : json(null);
    }
    throw new Error("Unexpected test network target " + url.hostname);
  };
  const endpoint = searchHandler("analyze-photo");
  const request = (id: string, authorization = "valid", image = "/9j/AA==") =>
    new Request("https://app.invalid/analyze-photo", {
      method: "POST",
      headers: {
        authorization: "Bearer " + authorization,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        requestId: id,
        searchId: "20000000-0000-4000-8000-000000000001",
        image,
      }),
    });
  try {
    const id = "10000000-0000-4000-8000-000000000001";
    assert(
      (await endpoint(request(id, "invalid"))).status === 401,
      "invalid user rejected",
    );
    assert(providerCalls === 0, "no unauthorized model call");
    const first = await endpoint(request(id));
    assert(first.status === 200, "valid request completes");
    assert(
      (await first.json()).description === "山脉与树林",
      "description returned",
    );
    assert(
      rows.get(user + ":" + id)?.billing_mode === "subscription",
      "subscription ledger distinguished",
    );
    assert(
      rows.get(user + ":" + id)?.cost === null,
      "subscription not fabricated as PAYG",
    );
    assert(
      (await endpoint(request(id))).status === 200,
      "duplicate replays receipt",
    );
    assert(providerCalls === 1, "duplicate never charged again");
    assert(
      (await endpoint(request(id, "valid", "/9j/BB=="))).status === 409,
      "changed payload rejected",
    );
    timeout = true;
    const uncertain = "10000000-0000-4000-8000-000000000002";
    assert(
      (await endpoint(request(uncertain))).status === 502,
      "disconnected request reports failure",
    );
    assert(
      rows.get(user + ":" + uncertain)?.status === "unknown",
      "unknown fee is retained",
    );
    assert(
      (await endpoint(request(uncertain))).status === 409,
      "uncertain request never auto repeated",
    );
    assert(providerCalls === 2, "no extra provider call");
  } finally {
    globalThis.fetch = prior;
    for (const key of envKeys) {
      const v = previous.get(key);
      if (v === undefined) Deno.env.delete(key);
      else Deno.env.set(key, v);
    }
  }
});
