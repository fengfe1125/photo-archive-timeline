-- Run once as the project database owner after applying search.sql.
-- Named scheduling replaces the existing job rather than creating duplicates.
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule(
  'photo-search-receipt-expiry',
  '* * * * *',
  $$delete from public.search_receipts where expires_at <= now();$$
);
-- Mark abandoned requests without assuming they were free. Never redispatch them.
select cron.schedule(
  'photo-search-pending-reconciliation',
  '*/5 * * * *',
  $$update public.search_usage set status = 'unknown'
    where status = 'pending' and created_at < now() - interval '10 minutes';$$
);
