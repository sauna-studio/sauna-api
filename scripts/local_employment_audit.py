#!/usr/bin/env python3
"""Generate guarded retention SQL for the isolated audit fixture."""
DATABASE = 'sauna_audit_sandbox'
MARKER = 'sauna-local-audit-sandbox-v1'


def retention_sql(days, limit, apply):
    if type(days) is not int or not 1 <= days <= 3_650:
        raise ValueError('Retention days must be between 1 and 3650')
    if type(limit) is not int or not 1 <= limit <= 1_000:
        raise ValueError('Batch size must be between 1 and 1000')
    if type(apply) is not bool:
        raise ValueError('Apply must be explicit')
    # Select a stable order and lock the rows only when deleting; concurrent
    # maintenance can skip another worker's batch without exceeding its limit.
    locking = 'FOR UPDATE SKIP LOCKED' if apply else ''
    candidates = f'''SELECT claim_token
FROM public.workspace_employment_revocation_audit
WHERE revoked_at < statement_timestamp() - make_interval(days => {days})
ORDER BY revoked_at, claim_token
LIMIT {limit}
{locking}'''
    if apply:
        operation = f'''WITH candidates AS MATERIALIZED ({candidates}), removed AS (
    DELETE FROM public.workspace_employment_revocation_audit audit
    USING candidates
    WHERE audit.claim_token = candidates.claim_token
    RETURNING 1
)
SELECT count(*) FROM removed;'''
    else:
        operation = f'SELECT count(*) FROM ({candidates}) candidates;'
    return f'''BEGIN;
SET LOCAL statement_timeout = '5s';
DO $guard$
BEGIN
    IF current_database() <> '{DATABASE}'
        OR current_user <> 'sauna_admin'
        OR NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_database
            WHERE datname = current_database()
              AND pg_catalog.pg_get_userbyid(datdba) = 'sauna_admin'
              AND pg_catalog.shobj_description(oid, 'pg_database') = '{MARKER}'
        ) THEN
        RAISE EXCEPTION 'Refusing unowned audit sandbox database';
    END IF;
END;
$guard$;
{operation}
COMMIT;'''
