BEGIN;
DO $$ BEGIN
 IF session_user <> 'sauna_app' OR current_user <> 'sauna_app' THEN RAISE EXCEPTION 'Restricted inventory connection required'; END IF;
 IF has_database_privilege(current_user,current_database(),'CREATE') OR has_schema_privilege(current_user,'extensions','CREATE') THEN
  RAISE EXCEPTION 'Runtime role has prerequisite creation privileges';
 END IF;
END $$;
SET LOCAL statement_timeout='5s';
CREATE FUNCTION pg_temp.expect_inventory_failure(statement text, expected_state text, expected_constraint text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual_constraint text;
BEGIN
 BEGIN EXECUTE statement;
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS actual_constraint=CONSTRAINT_NAME;
  IF SQLSTATE <> expected_state OR (expected_constraint IS NOT NULL AND actual_constraint <> expected_constraint) THEN
   RAISE EXCEPTION 'Unexpected inventory constraint rejection: state %, constraint %', SQLSTATE,actual_constraint;
  END IF;
  RETURN;
 END;
 RAISE EXCEPTION 'Invalid inventory statement unexpectedly succeeded';
END $$;
SELECT pg_temp.expect_inventory_failure('CREATE SCHEMA sauna_unauthorized','42501');
SELECT pg_temp.expect_inventory_failure('CREATE TABLE extensions.sauna_unauthorized(id int)','42501');
SELECT pg_temp.expect_inventory_failure('CREATE EXTENSION hstore','42501');
SELECT pg_temp.expect_inventory_failure('ALTER EXTENSION btree_gist SET SCHEMA public','42501');
SELECT pg_temp.expect_inventory_failure('DROP EXTENSION btree_gist','42501');
SELECT pg_temp.expect_inventory_failure('ALTER SCHEMA extensions OWNER TO sauna_app','42501');

INSERT INTO public.facilities(id,name,time_zone) VALUES
 ('70000000-0000-0000-0000-000000000001','Synthetic inventory A','Asia/Tokyo'),
 ('70000000-0000-0000-0000-000000000002','Synthetic inventory B','Asia/Tokyo');
INSERT INTO public.products(facility_id,id,kind,name,currency,unit_price_minor)
SELECT f.id,p.id,p.kind,'Synthetic inventory product','JPY',0
FROM public.facilities AS f CROSS JOIN (VALUES
 ('71000000-0000-0000-0000-000000000001'::uuid,'private_sauna'),
 ('71000000-0000-0000-0000-000000000002'::uuid,'shared_sauna'),
 ('71000000-0000-0000-0000-000000000003'::uuid,'day_tent'),
 ('71000000-0000-0000-0000-000000000004'::uuid,'overnight_tent')) AS p(id,kind);
INSERT INTO public.product_offerings
SELECT facility_id,id,kind,6,60,180,CASE WHEN kind='overnight_tent' THEN 1 ELSE 0 END,CASE WHEN kind='overnight_tent' THEN 3 ELSE 0 END FROM public.products;
INSERT INTO public.inventory_resources(facility_id,id,kind,name,capacity,enabled)
SELECT f.id,r.id,r.kind,'Synthetic physical resource',r.capacity,true
FROM public.facilities AS f CROSS JOIN (VALUES
 ('72000000-0000-0000-0000-000000000001'::uuid,'sauna',2),
 ('72000000-0000-0000-0000-000000000002'::uuid,'tent',1)) AS r(id,kind,capacity);
INSERT INTO public.inventory_resources(facility_id,id,kind,name,capacity,enabled) VALUES
 ('70000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000003','sauna','Synthetic B-only',2,true);
INSERT INTO public.inventory_product_resources
SELECT p.facility_id,p.product_id,p.kind,r.id,r.kind
FROM public.product_offerings AS p JOIN public.inventory_resources AS r ON r.facility_id=p.facility_id
WHERE (p.kind IN ('private_sauna','shared_sauna') AND r.kind='sauna') OR (p.kind IN ('day_tent','overnight_tent') AND r.kind='tent');

CREATE FUNCTION pg_temp.inventory_claim(fid uuid,pid uuid,rid uuid,cap int,seats int4range,start_at timestamptz DEFAULT '2030-01-01 00:00Z',end_at timestamptz DEFAULT '2030-01-01 01:00Z')
RETURNS void LANGUAGE SQL AS $$
 INSERT INTO public.inventory_claims(facility_id,product_id,product_kind,resource_id,resource_capacity,starts_at,ends_at,seat_slots)
 SELECT fid,p.product_id,p.product_kind,rid,cap,start_at,end_at,seats FROM public.inventory_product_resources AS p
 WHERE p.facility_id=fid AND p.product_id=pid AND p.resource_id=rid;
$$;
SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000001',2,'[0,1)');
SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000001',2,'[1,2)');
SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000002','71000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000001',2,'(,)');
SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000001',2,'(,)','2030-01-01 01:00Z','2030-01-01 02:00Z');
SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000003','72000000-0000-0000-0000-000000000002',1,'(,)');
SELECT pg_temp.expect_inventory_failure($q$SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000001',2,'(,)')$q$,'23P01','inventory_claim_no_overlap');
SELECT pg_temp.expect_inventory_failure($q$SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000002','72000000-0000-0000-0000-000000000001',2,'[0,1)')$q$,'23P01','inventory_claim_no_overlap');
SELECT pg_temp.expect_inventory_failure($q$SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000004','72000000-0000-0000-0000-000000000002',1,'(,)')$q$,'23P01','inventory_claim_no_overlap');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_resources SET capacity=3 WHERE capacity=2$q$,'23503','inventory_claim_capacity_fk');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET seat_slots='[0,2)' WHERE product_kind='shared_sauna'$q$,'23514','inventory_claim_seats_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET seat_slots='[-1,0)' WHERE product_kind='shared_sauna'$q$,'23514','inventory_claim_seats_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET seat_slots='[2,3)' WHERE product_kind='shared_sauna'$q$,'23514','inventory_claim_seats_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET seat_slots='(,)' WHERE product_kind='shared_sauna'$q$,'23514','inventory_claim_seats_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET seat_slots='[0,1)' WHERE product_kind='private_sauna'$q$,'23514','inventory_claim_seats_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET seat_slots='empty'$q$,'23514','inventory_claim_seats_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET starts_at=ends_at$q$,'23514','inventory_claim_period_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET ends_at='infinity'$q$,'23514','inventory_claim_period_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET resource_capacity=3$q$,'23503','inventory_claim_capacity_fk');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET released_at='2000-01-01 00:00:00+00'$q$,'23514','inventory_claim_release_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET product_kind='shared_sauna',seat_slots='[0,1)' WHERE product_kind='private_sauna'$q$,'23503','inventory_claim_mapping_fk');
SELECT pg_temp.expect_inventory_failure($q$INSERT INTO public.inventory_product_resources VALUES ('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000002','shared_sauna','72000000-0000-0000-0000-000000000003','sauna')$q$,'23503','inventory_product_resource_fk');
UPDATE public.inventory_claims SET released_at=clock_timestamp() WHERE facility_id='70000000-0000-0000-0000-000000000001' AND starts_at='2030-01-01 00:00Z' AND product_kind='shared_sauna';
SELECT pg_temp.inventory_claim('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000001','72000000-0000-0000-0000-000000000001',2,'(,)');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_claims SET released_at=NULL WHERE product_kind='shared_sauna'$q$,'23P01','inventory_claim_no_overlap');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_resources SET capacity=3 WHERE capacity=2$q$,'23503','inventory_claim_capacity_fk');
SELECT pg_temp.expect_inventory_failure($q$INSERT INTO public.inventory_product_resources VALUES ('70000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000002','shared_sauna','72000000-0000-0000-0000-000000000002','tent')$q$,'23514','inventory_product_resource_kind_valid');
SELECT pg_temp.expect_inventory_failure($q$UPDATE public.inventory_resources SET kind='tent' WHERE kind='sauna'$q$,'23503','inventory_product_resource_fk');
ROLLBACK;
