export type Query = {
  start?: string | null;
  end?: string | null;
  city: string;
  include: string[];
  exclude: string[];
  night: boolean;
  needsYear: boolean;
  unresolved: string;
};
export function validateQuery(value: unknown): Query {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid query");
  }
  const q = value as Record<string, unknown>;
  for (const key of ["start", "end"]) {
    const d = q[key];
    if (
      d != null &&
      (typeof d !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(d) ||
        !Number.isFinite(Date.parse(d)) ||
        new Date(d).toISOString().slice(0, 10) !== d)
    ) throw new Error("Invalid date");
  }
  if (q.start && q.end && String(q.start) > String(q.end)) {
    throw new Error("Invalid range");
  }
  if (
    typeof q.city !== "string" || q.city.length > 100 ||
    typeof q.unresolved !== "string" || q.unresolved.length > 2000 ||
    typeof q.night !== "boolean" || typeof q.needsYear !== "boolean"
  ) throw new Error("Invalid query");
  for (const key of ["include", "exclude"]) {
    if (
      !Array.isArray(q[key]) || (q[key] as unknown[]).length > 20 ||
      !(q[key] as unknown[]).every((x) =>
        typeof x === "string" && x.length > 0 && x.length <= 100
      )
    ) throw new Error("Invalid terms");
  }
  return {
    start: q.start as string | null,
    end: q.end as string | null,
    city: q.city,
    include: q.include as string[],
    exclude: q.exclude as string[],
    night: q.night,
    needsYear: q.needsYear,
    unresolved: q.unresolved,
  };
}
export function probability(response: Record<string, any>): number {
  const p = response.answers?.match?.noul;
  if (typeof p !== "number" || !Number.isFinite(p) || p < 0 || p > 1) {
    throw new Error("Invalid probability");
  }
  return p;
}
export function usageRecord(
  raw: Record<string, any>,
  provider: string,
  pricing: { input: number; output: number; cache: number; currency: string },
) {
  const usage = raw.usage ?? {};
  const number = (v: unknown): number | null =>
    typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null;
  const input = number(usage.prompt_tokens ?? usage.input_tokens),
    output = number(usage.completion_tokens ?? usage.output_tokens);
  const cached =
    number(usage.prompt_tokens_details?.cached_tokens ?? usage.cached_tokens) ??
      0;
  const reasoning = number(usage.completion_tokens_details?.reasoning_tokens);
  const actual = number(usage.cost);
  const estimate = input != null && output != null && cached <= input
    ? ((input - cached) * pricing.input + cached * pricing.cache +
      output * pricing.output) / 1e6
    : null;
  return {
    input_tokens: input,
    output_tokens: output,
    cached_tokens: cached,
    reasoning_tokens: reasoning,
    cost: actual ?? (provider === "MiniMax" ? estimate : null),
    currency: actual != null && provider === "OpenRouter"
      ? "USD"
      : pricing.currency,
    estimated: actual == null && provider === "MiniMax" && estimate != null,
  };
}
export function parseObject(text: unknown): Record<string, any> {
  if (typeof text !== "string") throw new Error("Missing response");
  const value = JSON.parse(
    text.replace(/^```(?:json)?\s*/, "").replace(/\s*```$/, ""),
  );
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid response");
  }
  return value;
}
