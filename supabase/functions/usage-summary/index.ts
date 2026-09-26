import { searchHandler } from "../_shared/search-handler.ts";
Deno.serve(searchHandler("usage-summary"));
