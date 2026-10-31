-- Run on an explicitly isolated local test database with the migrated schema.
-- Fixtures and temporary helpers are rolled back even after successful tests.
BEGIN;
DO $$ BEGIN
 IF session_user <> 'sauna_app' OR current_user <> 'sauna_app' THEN
  RAISE EXCEPTION 'Use a real restricted app-role connection, not admin SET ROLE';
 END IF;
END $$;
SET LOCAL statement_timeout = '5s';

CREATE FUNCTION pg_temp.expect_failure(statement text, expected_state text, expected_constraint text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual_constraint text;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_constraint = CONSTRAINT_NAME;
        IF SQLSTATE <> expected_state OR
           (expected_constraint IS NOT NULL AND actual_constraint <> expected_constraint) THEN
            RAISE EXCEPTION 'Expected state % constraint %, got % constraint %',
                expected_state, expected_constraint, SQLSTATE, actual_constraint;
        END IF;
        RETURN;
    END;
    RAISE EXCEPTION 'Expected SQLSTATE %, statement unexpectedly succeeded', expected_state;
END $$;

INSERT INTO public.facilities (id, name, time_zone) VALUES
 ('10000000-0000-0000-0000-000000000001', 'Synthetic River A', 'Asia/Tokyo'),
 ('20000000-0000-0000-0000-000000000001', 'Synthetic River B', 'Asia/Tokyo');
INSERT INTO public.users (id) VALUES
 ('00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-000000000002');
INSERT INTO public.facility_memberships (facility_id, user_id, role) VALUES
 ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'manager'),
 ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'staff');
INSERT INTO public.products (facility_id, id, kind, name, currency, unit_price_minor) VALUES
 ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', 'private_sauna', 'Synthetic Private', 'JPY', 1000),
 ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000013', 'shared_sauna', 'Synthetic Shared', 'JPY', 500),
 ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', 'day_tent', 'Synthetic Day Tent', 'JPY', 1500),
 ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000012', 'overnight_tent', 'Synthetic Overnight', 'JPY', 2000);
-- Customer user2 has no membership at facility A and may still own a booking.
INSERT INTO public.reservations (facility_id, id, user_id, currency, total_minor) VALUES
 ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000002', 'JPY', 1000),
 ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000001', 'JPY', 2000);
INSERT INTO public.reservation_items (facility_id, id, reservation_id, product_id, product_name_snapshot, quantity, unit_price_minor, starts_at, ends_at)
VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000011', 'Synthetic quote', 1, 1000, '2027-01-01T01:00:00Z', '2027-01-01T02:00:00Z');

-- Check exact constraint names to avoid passing for the wrong reason.
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservation_items SET product_id='00000000-0000-0000-0000-000000000012'
 WHERE facility_id='10000000-0000-0000-0000-000000000001'
$sql$, '23503', 'reservation_items_product_fk');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservation_items SET reservation_id='00000000-0000-0000-0000-000000000032'
 WHERE facility_id='10000000-0000-0000-0000-000000000001'
$sql$, '23503', 'reservation_items_reservation_fk');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservation_items SET facility_id='20000000-0000-0000-0000-000000000001'
 WHERE facility_id='10000000-0000-0000-0000-000000000001'
$sql$, '23503', 'reservation_items_reservation_fk');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.facility_memberships SET role='superuser'
$sql$, '23514', 'facility_memberships_role_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.facility_memberships SET status='unexpected'
$sql$, '23514', 'facility_memberships_status_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.products SET unit_price_minor=-1
$sql$, '23514', 'products_price_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.products SET currency='jpy'
$sql$, '23514', 'products_currency_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.products SET kind='unsupported'
$sql$, '23514', 'products_kind_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservations SET total_minor=-1
$sql$, '23514', 'reservations_total_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservations SET status='unexpected'
$sql$, '23514', 'reservations_status_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservation_items SET quantity=0
$sql$, '23514', 'reservation_items_quantity_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservation_items SET unit_price_minor=-1
$sql$, '23514', 'reservation_items_price_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservation_items SET ends_at=starts_at
$sql$, '23514', 'reservation_items_time_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservation_items SET ends_at='infinity'
$sql$, '23514', 'reservation_items_time_valid');
SELECT pg_temp.expect_failure($sql$
 UPDATE public.reservations SET user_id='00000000-0000-0000-0000-000000000099'
$sql$, '23503', 'reservations_user_fk');
SELECT pg_temp.expect_failure($sql$
 DELETE FROM public.facilities WHERE id='10000000-0000-0000-0000-000000000001'
$sql$, '23503');
SELECT pg_temp.expect_failure('CREATE TABLE public.unexpected_app_table (id integer)', '42501');
SELECT pg_temp.expect_failure('ALTER TABLE public.products ADD COLUMN unexpected integer', '42501');
SELECT pg_temp.expect_failure('DROP TABLE public.reservation_items', '42501');
SELECT pg_temp.expect_failure('TRUNCATE public.reservation_items', '42501');
SELECT pg_temp.expect_failure('SET ROLE sauna_admin', '42501');

DO $$
DECLARE affected integer;
BEGIN
 IF current_user <> 'sauna_app' THEN
  RAISE EXCEPTION 'Constraint tests must execute as the restricted app role';
 END IF;
 IF (SELECT count(*) FROM public.products WHERE facility_id='10000000-0000-0000-0000-000000000001') <> 2 THEN
  RAISE EXCEPTION 'Facility-filtered list failed';
 END IF;
 IF (SELECT name FROM public.products WHERE facility_id='20000000-0000-0000-0000-000000000001' AND id='00000000-0000-0000-0000-000000000011') IS DISTINCT FROM 'Synthetic Day Tent' THEN
  RAISE EXCEPTION 'Composite-key detail failed';
 END IF;
 UPDATE public.products SET name='Changed Synthetic' WHERE facility_id='10000000-0000-0000-0000-000000000001' AND id='00000000-0000-0000-0000-000000000012';
 GET DIAGNOSTICS affected = ROW_COUNT;
 IF affected <> 0 THEN RAISE EXCEPTION 'Wrong facility filter changed a row'; END IF;
 UPDATE public.products SET name='Changed Synthetic' WHERE facility_id='10000000-0000-0000-0000-000000000001' AND id='00000000-0000-0000-0000-000000000011';
 IF (SELECT name FROM public.products WHERE facility_id='20000000-0000-0000-0000-000000000001' AND id='00000000-0000-0000-0000-000000000011') IS DISTINCT FROM 'Synthetic Day Tent' THEN
  RAISE EXCEPTION 'Scoped update changed another facility';
 END IF;
 IF (SELECT product_name_snapshot FROM public.reservation_items WHERE facility_id='10000000-0000-0000-0000-000000000001') IS DISTINCT FROM 'Synthetic quote' THEN
  RAISE EXCEPTION 'Catalog update changed historic snapshot';
 END IF;
END $$;
ROLLBACK;
SELECT 'Schema constraints and restricted role checks passed; fixtures rolled back' AS result;
