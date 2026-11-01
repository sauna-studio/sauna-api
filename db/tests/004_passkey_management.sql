BEGIN;
CREATE FUNCTION pg_temp.expect_management_failure(sql text, expected_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed text;
BEGIN
 BEGIN EXECUTE sql;
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS observed = RETURNED_SQLSTATE;
  IF observed <> expected_state THEN RAISE EXCEPTION 'Unexpected management constraint state'; END IF;
  RETURN;
 END;
 RAISE EXCEPTION 'Expected management constraint rejection';
END $$;
INSERT INTO public.users(id) VALUES ('50000000-0000-0000-0000-000000000001'),('50000000-0000-0000-0000-000000000002');
INSERT INTO public.passkey_accounts(user_id,user_handle) VALUES
 ('50000000-0000-0000-0000-000000000001',decode(repeat('51',32),'hex')),
 ('50000000-0000-0000-0000-000000000002',decode(repeat('52',32),'hex'));
INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up) VALUES
 (decode('51','hex'),'50000000-0000-0000-0000-000000000001',decode(repeat('51',32),'hex'),decode('a0','hex'),0,false,false),
 (decode('52','hex'),'50000000-0000-0000-0000-000000000002',decode(repeat('52',32),'hex'),decode('a0','hex'),0,false,false);
INSERT INTO public.auth_sessions(token_hash,user_id,credential_id,origin,created_at,expires_at)
VALUES (decode(repeat('51',32),'hex'),'50000000-0000-0000-0000-000000000001',decode('51','hex'),'http://localhost:5173',clock_timestamp(),clock_timestamp()+interval '1 hour');
INSERT INTO public.passkey_management_intents(id,user_id,session_hash,rp_id,origin,action,challenge,created_at,expires_at)
VALUES ('50000000-0000-0000-0000-000000000003','50000000-0000-0000-0000-000000000001',decode(repeat('51',32),'hex'),'localhost','http://localhost:5173','add',decode(repeat('53',32),'hex'),clock_timestamp()-interval '1 second',clock_timestamp()+interval '1 minute');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET user_id=''50000000-0000-0000-0000-000000000002'' WHERE id=''50000000-0000-0000-0000-000000000003''','23503');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET session_hash=decode(repeat(''54'',32),''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23503');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET action=''unknown'' WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET action=''revoke'' WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET target_credential_id=decode(''51'',''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET action=''revoke'',target_credential_id=decode(''52'',''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23503');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET challenge=decode(''53'',''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET rp_id=''foreign.invalid'' WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET origin=''https://foreign.invalid'' WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET expires_at=created_at WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET expires_at=created_at+interval ''6 minutes'' WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET consumed_at=expires_at WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET registration_consumed_at=clock_timestamp() WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET authorized_at=created_at+interval ''1 millisecond'',authorization_credential_id=decode(''51'',''hex''),registration_challenge=decode(repeat(''55'',32),''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET consumed_at=created_at+interval ''1 millisecond'',authorized_at=created_at+interval ''1 millisecond'',authorization_credential_id=decode(''52'',''hex''),registration_challenge=decode(repeat(''55'',32),''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23503');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET consumed_at=created_at+interval ''1 millisecond'',authorized_at=created_at+interval ''1 millisecond'',authorization_credential_id=decode(''51'',''hex''),registration_challenge=decode(''55'',''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
SELECT pg_temp.expect_management_failure('UPDATE public.passkey_management_intents SET action=''revoke'',target_credential_id=decode(''51'',''hex''),consumed_at=created_at+interval ''1 millisecond'',authorized_at=created_at+interval ''1 millisecond'',authorization_credential_id=decode(''51'',''hex'') WHERE id=''50000000-0000-0000-0000-000000000003''','23514');
ROLLBACK;
SELECT 'Management ownership, phase, purpose, nonce and expiry constraints passed; fixtures rolled back';
