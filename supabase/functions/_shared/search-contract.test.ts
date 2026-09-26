import {
  parseObject,
  probability,
  usageRecord,
  validateQuery,
} from "./search-contract.ts";
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${JSON.stringify(a)} != ${JSON.stringify(b)}`);
  }
}
function rejects(fn: () => unknown) {
  let failed = false;
  try {
    fn();
  } catch {
    failed = true;
  }
  if (!failed) throw new Error("Expected rejection");
}
const q = {
  start: null,
  end: null,
  city: "武汉",
  include: ["聚餐"],
  exclude: [],
  night: false,
  needsYear: false,
  unresolved: "",
};
Deno.test("query validation rejects invalid dates and unbounded fields", () => {
  equal(validateQuery(q).city, "武汉");
  rejects(() => validateQuery({ ...q, start: "2025-02-29" }));
  rejects(() =>
    validateQuery({ ...q, start: "2025-03-01", end: "2025-02-01" })
  );
  rejects(() => validateQuery({ ...q, include: ["x".repeat(101)] }));
  rejects(() => validateQuery({ ...q, night: "true" }));
});
Deno.test("Jev typed probability is validated, not generated prose", () => {
  equal(probability({ answers: { match: { type: "noul", noul: 0.8 } } }), 0.8);
  rejects(() => probability({ answers: { match: { noul: "0.8" } } }));
  rejects(() => probability({ answers: { match: { noul: 1.1 } } }));
});
Deno.test("provider costs take precedence and missing usage is unknown", () => {
  const rates = { input: 2.1, output: 8.4, cache: 0.42, currency: "CNY" };
  const actual = usageRecord(
    { usage: { input_tokens: 100, output_tokens: 2, cost: 0.002 } },
    "OpenRouter",
    rates,
  );
  equal(actual.cost, 0.002);
  equal(actual.currency, "USD");
  equal(actual.estimated, false);
  const estimated = usageRecord(
    { usage: { prompt_tokens: 1000000, completion_tokens: 1000000 } },
    "MiniMax",
    rates,
  );
  equal(estimated.cost, 10.5);
  equal(estimated.estimated, true);
  equal(usageRecord({}, "MiniMax", rates).cost, null);
  equal(
    usageRecord(
      { usage: { input_tokens: 5, output_tokens: 2 } },
      "OpenRouter",
      rates,
    ).cost,
    null,
  );
});
Deno.test("cached inputs are charged at cache price; malformed output is rejected", () => {
  const result = usageRecord(
    {
      usage: {
        prompt_tokens: 1000000,
        completion_tokens: 0,
        prompt_tokens_details: { cached_tokens: 1000000 },
      },
    },
    "MiniMax",
    { input: 2.1, output: 8.4, cache: 0.42, currency: "CNY" },
  );
  equal(result.cost, 0.42);
  rejects(() => parseObject("not json"));
  rejects(() => parseObject("[]"));
});
