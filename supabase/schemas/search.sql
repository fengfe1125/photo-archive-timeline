-- AI billing is independent of archive synchronization. No raw photos or queries in the ledger.
create table public.search_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  search_id uuid not null,
  endpoint text not null,
  payload_hash text not null,
  provider text not null,
  model text not null,
  status text not null default 'pending' check (status in ('pending','complete','failed','unknown')),
  created_at timestamptz not null default now(),
  input_tokens bigint,
  output_tokens bigint,
  cached_tokens bigint,
  reasoning_tokens bigint,
  cost numeric check (cost >= 0),
  currency text not null,
  billing_mode text not null default 'payg' check (billing_mode in ('payg','subscription')),
  estimated boolean not null default false,
  elapsed_ms bigint,
  provider_request_id text,
  price_version text,
  fx_rate numeric,
  fx_date text,
  primary key (user_id,id)
);
create index search_usage_history_idx on public.search_usage(user_id,created_at desc,id);
alter table public.search_usage enable row level security;
create policy search_usage_owner on public.search_usage for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.search_usage from anon,authenticated;
grant select on public.search_usage to authenticated;
grant all on public.search_usage to service_role;

create table public.search_receipts (
  user_id uuid not null,
  id uuid not null,
  result jsonb not null,
  expires_at timestamptz not null default (now() + interval '24 hours'),
  primary key(user_id,id),
  foreign key(user_id,id) references public.search_usage(user_id,id) on delete cascade
);
create index search_receipts_expiry_idx on public.search_receipts(expires_at);
alter table public.search_receipts enable row level security;
revoke all on public.search_receipts from anon,authenticated;
grant all on public.search_receipts to service_role;
-- Receipts are accessed only by the authenticated proxy. Deployment installs hourly expiry cleanup.
