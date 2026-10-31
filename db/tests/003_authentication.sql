BEGIN;
CREATE FUNCTION pg_temp.expect_auth_failure(sql text, expected_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed text;
BEGIN
 BEGIN EXECUTE sql;
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS observed = RETURNED_SQLSTATE;
  IF observed <> expected_state THEN RAISE EXCEPTION 'Unexpected authentication constraint state'; END IF;
  RETURN;
 END;
 RAISE EXCEPTION 'Expected authentication constraint rejection';
END $$;
INSERT INTO public.users(id) VALUES ('40000000-0000-0000-0000-000000000001'),('40000000-0000-0000-0000-000000000002');
INSERT INTO public.passkey_accounts(user_id,user_handle) VALUES
 ('40000000-0000-0000-0000-000000000001',decode(repeat('11',32),'hex')),
 ('40000000-0000-0000-0000-000000000002',decode(repeat('22',32),'hex'));
INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up)
VALUES (decode('01','hex'),'40000000-0000-0000-0000-000000000001',decode(repeat('11',32),'hex'),decode('a0','hex'),0,false,false);
SELECT pg_temp.expect_auth_failure('UPDATE public.passkey_accounts SET user_handle=decode(''01'',''hex'')','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.passkey_credentials SET user_id=''40000000-0000-0000-0000-000000000002''','23503');
SELECT pg_temp.expect_auth_failure('UPDATE public.passkey_credentials SET sign_count=-1','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.passkey_credentials SET sign_count=4294967296','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.passkey_credentials SET is_backed_up=true','23514');
INSERT INTO public.auth_sessions(token_hash,user_id,credential_id,origin,created_at,expires_at)
VALUES (decode(repeat('aa',32),'hex'),'40000000-0000-0000-0000-000000000001',decode('01','hex'),'http://localhost:5173',clock_timestamp(),clock_timestamp()+interval '1 hour');
SELECT pg_temp.expect_auth_failure('UPDATE public.auth_sessions SET user_id=''40000000-0000-0000-0000-000000000002''','23503');
SELECT pg_temp.expect_auth_failure('UPDATE public.auth_sessions SET token_hash=decode(''aa'',''hex'')','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.auth_sessions SET origin=''https://attacker.invalid''','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.auth_sessions SET expires_at=created_at','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.auth_sessions SET expires_at=created_at+interval ''2 days''','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.auth_sessions SET expires_at=''infinity''','23514');
SELECT pg_temp.expect_auth_failure('UPDATE public.auth_sessions SET revoked_at=created_at-interval ''1 second''','23514');
ROLLBACK;
SELECT 'Authentication owner, token, counter and deadline constraints passed; fixtures rolled back';
