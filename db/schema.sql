-- Business schema source of truth; generate forward-only Atlas migrations.
-- Composite keys prevent cross-facility references. They are not authorization:
-- trusted tenant context and access policies are implemented in later work.
-- No credential, payment instrument, customer name or email is stored here.
CREATE TABLE public.facilities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    time_zone text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT facilities_name_valid CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    CONSTRAINT facilities_time_zone_valid CHECK (length(btrim(time_zone)) BETWEEN 1 AND 64)
);

-- Global identity is independent of employee membership. Customers need not be
-- members of a facility to reserve. Passkey credentials are a later migration.
CREATE TABLE public.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.facility_memberships (
    facility_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (facility_id, user_id),
    CONSTRAINT facility_memberships_facility_fk FOREIGN KEY (facility_id) REFERENCES public.facilities (id),
    CONSTRAINT facility_memberships_user_fk FOREIGN KEY (user_id) REFERENCES public.users (id),
    CONSTRAINT facility_memberships_role_valid CHECK (role IN ('owner', 'manager', 'staff')),
    CONSTRAINT facility_memberships_status_valid CHECK (status IN ('active', 'revoked'))
);
CREATE INDEX facility_memberships_user_idx ON public.facility_memberships (user_id);

CREATE TABLE public.products (
    facility_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    kind text NOT NULL,
    name text NOT NULL,
    published boolean NOT NULL DEFAULT false,
    currency text NOT NULL,
    unit_price_minor bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (facility_id, id),
    CONSTRAINT products_facility_fk FOREIGN KEY (facility_id) REFERENCES public.facilities (id),
    CONSTRAINT products_kind_valid CHECK (kind IN ('private_sauna', 'shared_sauna', 'day_tent', 'overnight_tent')),
    CONSTRAINT products_name_valid CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    CONSTRAINT products_currency_valid CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT products_price_valid CHECK (unit_price_minor >= 0)
);

-- State transitions, price calculation, item totals, inventory holds and payment
-- confirmation require transaction/application rules in subsequent Issues.
CREATE TABLE public.reservations (
    facility_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    currency text NOT NULL,
    total_minor bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (facility_id, id),
    CONSTRAINT reservations_facility_fk FOREIGN KEY (facility_id) REFERENCES public.facilities (id),
    CONSTRAINT reservations_user_fk FOREIGN KEY (user_id) REFERENCES public.users (id),
    CONSTRAINT reservations_status_valid CHECK (status IN ('draft', 'pending_payment', 'confirmed', 'cancelled', 'expired')),
    CONSTRAINT reservations_currency_valid CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT reservations_total_valid CHECK (total_minor >= 0)
);
CREATE INDEX reservations_user_idx ON public.reservations (user_id, facility_id);

-- Currency is inherited from the parent reservation. The product reference is
-- for identity only: historic quoted prices must not follow current catalog edits.
CREATE TABLE public.reservation_items (
    facility_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    reservation_id uuid NOT NULL,
    product_id uuid NOT NULL,
    product_name_snapshot text NOT NULL,
    quantity integer NOT NULL,
    unit_price_minor bigint NOT NULL,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (facility_id, id),
    CONSTRAINT reservation_items_reservation_fk FOREIGN KEY (facility_id, reservation_id) REFERENCES public.reservations (facility_id, id),
    CONSTRAINT reservation_items_product_fk FOREIGN KEY (facility_id, product_id) REFERENCES public.products (facility_id, id),
    CONSTRAINT reservation_items_name_valid CHECK (length(btrim(product_name_snapshot)) BETWEEN 1 AND 200),
    CONSTRAINT reservation_items_quantity_valid CHECK (quantity > 0),
    CONSTRAINT reservation_items_price_valid CHECK (unit_price_minor >= 0),
    CONSTRAINT reservation_items_time_valid CHECK (isfinite(starts_at) AND isfinite(ends_at) AND starts_at < ends_at)
);
CREATE INDEX reservation_items_reservation_idx ON public.reservation_items (facility_id, reservation_id);
CREATE INDEX reservation_items_product_idx ON public.reservation_items (facility_id, product_id);
