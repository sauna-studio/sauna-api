BEGIN;
DO $$ BEGIN
 IF session_user <> 'sauna_app' OR current_user <> 'sauna_app' THEN
  RAISE EXCEPTION 'Use a real restricted app-role connection';
 END IF;
END $$;
SET LOCAL statement_timeout = '5s';
CREATE FUNCTION pg_temp.expect_catalog_failure(statement text, expected_state text, expected_constraint text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual_constraint text;
BEGIN
 BEGIN EXECUTE statement;
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS actual_constraint = CONSTRAINT_NAME;
  IF SQLSTATE <> expected_state OR (expected_constraint IS NOT NULL AND actual_constraint <> expected_constraint) THEN
   RAISE EXCEPTION 'Unexpected catalog constraint rejection';
  END IF;
  RETURN;
 END;
 RAISE EXCEPTION 'Invalid catalog input unexpectedly succeeded';
END $$;
INSERT INTO public.facilities(id,name,time_zone) VALUES
 ('50000000-0000-0000-0000-000000000001','Synthetic catalog A','Asia/Tokyo'),
 ('50000000-0000-0000-0000-000000000002','Synthetic catalog B','Asia/Tokyo');
INSERT INTO public.products(facility_id,id,kind,name,published,currency,unit_price_minor)
SELECT '50000000-0000-0000-0000-000000000001', id, kind, 'Synthetic catalog',true,'JPY',0 FROM (VALUES
 ('50000000-0000-0000-0000-000000000011'::uuid,'private_sauna'),
 ('50000000-0000-0000-0000-000000000012'::uuid,'shared_sauna'),
 ('50000000-0000-0000-0000-000000000013'::uuid,'day_tent'),
 ('50000000-0000-0000-0000-000000000014'::uuid,'overnight_tent')) AS p(id,kind);
INSERT INTO public.products(facility_id,id,kind,name,currency,unit_price_minor) VALUES
 ('50000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000011','shared_sauna','Synthetic B','JPY',0);
INSERT INTO public.product_offerings(facility_id,product_id,kind,capacity,minimum_duration_minutes,maximum_duration_minutes,minimum_nights,maximum_nights)
SELECT facility_id,id,kind,6,60,180,CASE WHEN kind='overnight_tent' THEN 1 ELSE 0 END,CASE WHEN kind='overnight_tent' THEN 3 ELSE 0 END
FROM public.products WHERE facility_id='50000000-0000-0000-0000-000000000001';
SELECT pg_temp.expect_catalog_failure($q$UPDATE public.product_offerings SET capacity=0$q$,'23514','product_offerings_capacity_valid');
SELECT pg_temp.expect_catalog_failure($q$UPDATE public.product_offerings SET minimum_duration_minutes=0$q$,'23514','product_offerings_duration_valid');
SELECT pg_temp.expect_catalog_failure($q$UPDATE public.product_offerings SET maximum_duration_minutes=59$q$,'23514','product_offerings_duration_valid');
SELECT pg_temp.expect_catalog_failure($q$UPDATE public.product_offerings SET minimum_nights=0 WHERE kind='overnight_tent'$q$,'23514','product_offerings_nights_valid');
SELECT pg_temp.expect_catalog_failure($q$UPDATE public.product_offerings SET maximum_nights=4 WHERE kind='day_tent'$q$,'23514','product_offerings_nights_valid');
SELECT pg_temp.expect_catalog_failure($q$UPDATE public.product_offerings SET minimum_nights=4 WHERE kind='overnight_tent'$q$,'23514','product_offerings_nights_valid');
SELECT pg_temp.expect_catalog_failure($q$INSERT INTO public.product_offerings VALUES ('50000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000011','private_sauna',2,60,120,0,0)$q$,'23503','product_offerings_product_kind_fk');
SELECT pg_temp.expect_catalog_failure($q$UPDATE public.products SET kind='shared_sauna' WHERE facility_id='50000000-0000-0000-0000-000000000001' AND kind='private_sauna'$q$,'23503','product_offerings_product_kind_fk');
SELECT pg_temp.expect_catalog_failure('TRUNCATE public.product_offerings','42501');
DO $$ BEGIN
 IF (SELECT count(*) FROM public.product_offerings) <> 4 THEN RAISE EXCEPTION 'Invalid writes changed configured offers'; END IF;
END $$;
ROLLBACK;
