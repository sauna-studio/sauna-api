-- Synthetic shape/TTL constraints only; cryptographic values are not credentials.
BEGIN;
DO $$
BEGIN
 IF session_user <> 'sauna_app' THEN RAISE EXCEPTION 'Requires real app-role connection'; END IF;
END $$;
CREATE FUNCTION pg_temp.expect_challenge_check(sql text, expected_constraint text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE constraint_name text;
BEGIN
 BEGIN
  EXECUTE sql;
 EXCEPTION WHEN check_violation THEN
  GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
  IF constraint_name IS DISTINCT FROM expected_constraint THEN RAISE EXCEPTION 'Unexpected constraint'; END IF;
  RETURN;
 END;
 RAISE EXCEPTION 'Expected check rejection';
END $$;
INSERT INTO public.webauthn_challenges(id,challenge,binding_hash,rp_id,origin,purpose,created_at,expires_at)
VALUES ('30000000-0000-0000-0000-000000000001',decode(repeat('ab',32),'hex'),decode(repeat('cd',32),'hex'),'localhost','http://localhost:5173','authentication',clock_timestamp(),clock_timestamp()+interval '1 minute');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET challenge=decode(''ab'',''hex'')','webauthn_challenge_length');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET binding_hash=decode(''ab'',''hex'')','webauthn_binding_length');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET purpose=''other''','webauthn_purpose_valid');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET expires_at=created_at','webauthn_expiry_valid');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET expires_at=created_at+interval ''6 minutes''','webauthn_expiry_valid');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET expires_at=''infinity''','webauthn_expiry_valid');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET consumed_at=expires_at','webauthn_consumed_valid');
SELECT pg_temp.expect_challenge_check('UPDATE public.webauthn_challenges SET consumed_at=created_at-interval ''1 second''','webauthn_consumed_valid');
ROLLBACK;
SELECT 'Challenge shape/TTL constraints passed; synthetic fixtures rolled back';
