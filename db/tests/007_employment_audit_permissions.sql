BEGIN;
SET LOCAL statement_timeout = '5s';

DO $$
DECLARE statement text;
BEGIN
    IF session_user <> 'sauna_app' OR current_user <> 'sauna_app' THEN
        RAISE EXCEPTION 'Use a restricted app-role connection';
    END IF;
    FOR statement IN SELECT unnest(ARRAY[
        'SELECT * FROM public.workspace_employment_revocation_audit',
        'UPDATE public.workspace_employment_revocation_audit SET revoked_at = now()',
        'DELETE FROM public.workspace_employment_revocation_audit',
        'TRUNCATE public.workspace_employment_revocation_audit',
        'INSERT INTO public.workspace_employment_revocation_audit (claim_token, facility_id, user_id, revoked_at)
            VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), now())'
    ])
    LOOP
        BEGIN
            EXECUTE statement;
            RAISE EXCEPTION 'Unexpected audit privilege';
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;
        END;
    END LOOP;
END;
$$;

INSERT INTO public.workspace_employment_revocation_audit (claim_token, facility_id, user_id)
VALUES ('46000000-0000-0000-0000-000000000001',
        '46000000-0000-0000-0000-000000000002',
        '46000000-0000-0000-0000-000000000003');
ROLLBACK;
