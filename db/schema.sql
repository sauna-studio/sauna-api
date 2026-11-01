-- Business schema source of truth; generate forward-only Atlas migrations.
-- Composite keys prevent cross-facility references. They are not authorization:
-- trusted tenant context and access policies are implemented in later work.
-- No private key, raw session secret, payment instrument, customer name or email is stored here.
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

-- The redundant kind key binds offer conditions to the product's current kind;
-- an unconstrained copied kind would allow inconsistent overnight conditions.
ALTER TABLE public.products ADD CONSTRAINT products_catalog_kind_unique UNIQUE (facility_id, id, kind);
CREATE TABLE public.product_offerings (
    facility_id uuid NOT NULL,
    product_id uuid NOT NULL,
    kind text NOT NULL,
    capacity integer NOT NULL,
    minimum_duration_minutes integer NOT NULL,
    maximum_duration_minutes integer NOT NULL,
    minimum_nights integer NOT NULL,
    maximum_nights integer NOT NULL,
    PRIMARY KEY (facility_id, product_id),
    CONSTRAINT product_offerings_product_kind_fk FOREIGN KEY (facility_id, product_id, kind) REFERENCES public.products (facility_id, id, kind),
    CONSTRAINT product_offerings_capacity_valid CHECK (capacity > 0),
    CONSTRAINT product_offerings_duration_valid CHECK (minimum_duration_minutes > 0 AND maximum_duration_minutes >= minimum_duration_minutes),
    CONSTRAINT product_offerings_nights_valid CHECK (
        (kind IN ('private_sauna','shared_sauna','day_tent') AND minimum_nights = 0 AND maximum_nights = 0) OR
        (kind = 'overnight_tent' AND minimum_nights > 0 AND maximum_nights >= minimum_nights)
    )
);

-- Product conditions and physical inventory capacity are distinct authorities.
ALTER TABLE public.product_offerings ADD CONSTRAINT product_offerings_kind_unique UNIQUE (facility_id, product_id, kind);
CREATE TABLE public.inventory_resources (
    facility_id uuid NOT NULL REFERENCES public.facilities(id),
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    kind text NOT NULL,
    name text NOT NULL,
    capacity integer NOT NULL,
    enabled boolean NOT NULL DEFAULT false,
    PRIMARY KEY (facility_id, id),
    UNIQUE (facility_id, id, kind),
    UNIQUE (facility_id, id, capacity),
    CONSTRAINT inventory_resources_kind_valid CHECK (kind IN ('sauna','tent')),
    -- BETWEEN leaves a false-positive Atlas CE diff; retain canonical form until sauna-api#66 is resolved.
    CONSTRAINT inventory_resources_name_valid CHECK (((length(name) >= 1) AND (length(name) <= 200)) AND (length(btrim(name)) > 0)),
    CONSTRAINT inventory_resources_capacity_valid CHECK (capacity > 0)
);
CREATE TABLE public.inventory_product_resources (
    facility_id uuid NOT NULL,
    product_id uuid NOT NULL,
    product_kind text NOT NULL,
    resource_id uuid NOT NULL,
    resource_kind text NOT NULL,
    PRIMARY KEY (facility_id, product_id, resource_id),
    UNIQUE (facility_id, product_id, resource_id, product_kind),
    CONSTRAINT inventory_product_offering_fk FOREIGN KEY (facility_id,product_id,product_kind) REFERENCES public.product_offerings(facility_id,product_id,kind),
    CONSTRAINT inventory_product_resource_fk FOREIGN KEY (facility_id,resource_id,resource_kind) REFERENCES public.inventory_resources(facility_id,id,kind),
    CONSTRAINT inventory_product_resource_kind_valid CHECK (
        (product_kind IN ('private_sauna','shared_sauna') AND resource_kind='sauna') OR
        (product_kind IN ('day_tent','overnight_tent') AND resource_kind='tent')
    )
);
CREATE TABLE public.inventory_claims (
    facility_id uuid NOT NULL,
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    product_id uuid NOT NULL,
    product_kind text NOT NULL,
    resource_id uuid NOT NULL,
    resource_capacity integer NOT NULL,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    seat_slots int4range NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    released_at timestamptz,
    PRIMARY KEY (facility_id, id),
    CONSTRAINT inventory_claim_mapping_fk FOREIGN KEY (facility_id,product_id,resource_id,product_kind) REFERENCES public.inventory_product_resources(facility_id,product_id,resource_id,product_kind),
    CONSTRAINT inventory_claim_capacity_fk FOREIGN KEY (facility_id,resource_id,resource_capacity) REFERENCES public.inventory_resources(facility_id,id,capacity),
    CONSTRAINT inventory_claim_period_valid CHECK (isfinite(starts_at) AND isfinite(ends_at) AND starts_at < ends_at),
    CONSTRAINT inventory_claim_seats_valid CHECK (
        NOT isempty(seat_slots) AND (
            (product_kind='shared_sauna' AND NOT lower_inf(seat_slots) AND NOT upper_inf(seat_slots)
             AND lower(seat_slots)>=0 AND upper(seat_slots)<=resource_capacity
             AND upper(seat_slots)::bigint-lower(seat_slots)::bigint=1) OR
            (product_kind IN ('private_sauna','day_tent','overnight_tent') AND lower_inf(seat_slots) AND upper_inf(seat_slots))
        )
    ),
    CONSTRAINT inventory_claim_release_valid CHECK (isfinite(created_at) AND (released_at IS NULL OR (isfinite(released_at) AND released_at >= created_at))),
    CONSTRAINT inventory_claim_no_overlap EXCLUDE USING gist (
        facility_id extensions.gist_uuid_ops WITH =,
        resource_id extensions.gist_uuid_ops WITH =,
        tstzrange(starts_at,ends_at,'[)') WITH &&,
        seat_slots WITH &&
    ) WHERE (released_at IS NULL)
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

-- Public WebAuthn challenge state, not a credential or authenticated session.
-- The browser's independent flow secret is stored only as a SHA-256 digest.
CREATE TABLE public.webauthn_challenges (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge bytea NOT NULL,
    binding_hash bytea NOT NULL,
    rp_id text NOT NULL,
    origin text NOT NULL,
    purpose text NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    CONSTRAINT webauthn_challenge_length CHECK (octet_length(challenge) = 32),
    CONSTRAINT webauthn_binding_length CHECK (octet_length(binding_hash) = 32),
    CONSTRAINT webauthn_rp_length CHECK (length(rp_id) BETWEEN 1 AND 253),
    CONSTRAINT webauthn_origin_length CHECK (length(origin) BETWEEN 1 AND 2048),
    CONSTRAINT webauthn_purpose_valid CHECK (purpose IN ('registration', 'authentication')),
    CONSTRAINT webauthn_expiry_valid CHECK (isfinite(created_at) AND isfinite(expires_at) AND expires_at > created_at AND expires_at <= created_at + interval '5 minutes'),
    CONSTRAINT webauthn_consumed_valid CHECK (consumed_at IS NULL OR (isfinite(consumed_at) AND consumed_at >= created_at AND consumed_at < expires_at))
);
CREATE INDEX webauthn_challenges_expiry_idx ON public.webauthn_challenges (expires_at);

-- Global account handles are opaque server-generated bytes, never email/Google IDs.
CREATE TABLE public.passkey_accounts (
    user_id uuid PRIMARY KEY REFERENCES public.users(id),
    user_handle bytea NOT NULL UNIQUE,
    CONSTRAINT passkey_account_handle_length CHECK (octet_length(user_handle) = 32),
    UNIQUE (user_id, user_handle)
);
CREATE TABLE public.passkey_registration_intents (
    challenge_id uuid PRIMARY KEY REFERENCES public.webauthn_challenges(id),
    user_id uuid NOT NULL UNIQUE,
    user_handle bytea NOT NULL UNIQUE,
    CONSTRAINT passkey_intent_handle_length CHECK (octet_length(user_handle) = 32)
);
CREATE TABLE public.passkey_credentials (
    id bytea PRIMARY KEY,
    user_id uuid NOT NULL,
    user_handle bytea NOT NULL,
    public_key_cose bytea NOT NULL,
    sign_count bigint NOT NULL,
    backup_eligible boolean NOT NULL,
    is_backed_up boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_used_at timestamptz,
    revoked_at timestamptz,
    UNIQUE (user_id, id),
    CONSTRAINT passkey_credential_owner_fk FOREIGN KEY (user_id,user_handle) REFERENCES public.passkey_accounts(user_id,user_handle),
    CONSTRAINT passkey_credential_id_length CHECK (octet_length(id) BETWEEN 1 AND 1023),
    CONSTRAINT passkey_key_length CHECK (octet_length(public_key_cose) BETWEEN 1 AND 512),
    CONSTRAINT passkey_counter_range CHECK (sign_count BETWEEN 0 AND 4294967295),
    CONSTRAINT passkey_backup_flags CHECK (NOT is_backed_up OR backup_eligible),
    CONSTRAINT passkey_credential_times CHECK (isfinite(created_at) AND (last_used_at IS NULL OR isfinite(last_used_at)) AND (revoked_at IS NULL OR isfinite(revoked_at)))
);
CREATE TABLE public.auth_sessions (
    token_hash bytea PRIMARY KEY,
    user_id uuid NOT NULL,
    credential_id bytea NOT NULL,
    origin text NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    CONSTRAINT auth_session_credential_owner_fk FOREIGN KEY (user_id,credential_id) REFERENCES public.passkey_credentials(user_id,id),
    CONSTRAINT auth_session_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT auth_session_origin CHECK (origin IN ('http://localhost:5173','http://localhost:5174')),
    CONSTRAINT auth_session_expiry CHECK (isfinite(created_at) AND isfinite(expires_at) AND expires_at > created_at AND expires_at <= created_at + interval '1 day'),
    CONSTRAINT auth_session_revocation CHECK (revoked_at IS NULL OR (isfinite(revoked_at) AND revoked_at >= created_at))
);
CREATE INDEX auth_sessions_user_idx ON public.auth_sessions(user_id);
CREATE INDEX auth_sessions_expiry_idx ON public.auth_sessions(expires_at);

ALTER TABLE public.auth_sessions ADD CONSTRAINT auth_session_user_hash_unique UNIQUE (user_id, token_hash);
CREATE TABLE public.passkey_management_intents (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES public.passkey_accounts(user_id),
    session_hash bytea NOT NULL,
    rp_id text NOT NULL,
    origin text NOT NULL,
    action text NOT NULL,
    target_credential_id bytea,
    challenge bytea NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    authorization_credential_id bytea,
    authorized_at timestamptz,
    registration_challenge bytea,
    registration_consumed_at timestamptz,
    CONSTRAINT passkey_management_session_owner_fk FOREIGN KEY (user_id,session_hash) REFERENCES public.auth_sessions(user_id,token_hash),
    CONSTRAINT passkey_management_target_owner_fk FOREIGN KEY (user_id,target_credential_id) REFERENCES public.passkey_credentials(user_id,id),
    CONSTRAINT passkey_management_authorizer_owner_fk FOREIGN KEY (user_id,authorization_credential_id) REFERENCES public.passkey_credentials(user_id,id),
    CONSTRAINT passkey_management_action CHECK (action IN ('add','revoke')),
    CONSTRAINT passkey_management_target CHECK ((action='add' AND target_credential_id IS NULL) OR (action='revoke' AND target_credential_id IS NOT NULL)),
    CONSTRAINT passkey_management_hash CHECK (octet_length(session_hash)=32),
    CONSTRAINT passkey_management_nonce CHECK (octet_length(challenge)=32 AND (registration_challenge IS NULL OR octet_length(registration_challenge)=32)),
    CONSTRAINT passkey_management_rp CHECK (rp_id='localhost' AND origin IN ('http://localhost:5173','http://localhost:5174')),
    CONSTRAINT passkey_management_expiry CHECK (isfinite(created_at) AND isfinite(expires_at) AND expires_at>created_at AND expires_at<=created_at+interval '5 minutes'),
    CONSTRAINT passkey_management_consumed CHECK (consumed_at IS NULL OR (isfinite(consumed_at) AND consumed_at>=created_at AND consumed_at<expires_at)),
    CONSTRAINT passkey_management_authorization CHECK (
        (authorized_at IS NULL AND authorization_credential_id IS NULL AND registration_challenge IS NULL) OR
        (authorized_at IS NOT NULL AND isfinite(authorized_at) AND authorization_credential_id IS NOT NULL AND consumed_at IS NOT NULL AND authorized_at>=consumed_at AND authorized_at<expires_at AND ((action='add' AND registration_challenge IS NOT NULL) OR (action='revoke' AND registration_challenge IS NULL AND authorization_credential_id<>target_credential_id)))
    ),
    CONSTRAINT passkey_management_registration_consumed CHECK (registration_consumed_at IS NULL OR (action='add' AND authorized_at IS NOT NULL AND isfinite(registration_consumed_at) AND registration_consumed_at>=authorized_at AND registration_consumed_at<expires_at))
);
CREATE INDEX passkey_management_expiry_idx ON public.passkey_management_intents(expires_at);
