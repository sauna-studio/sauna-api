CREATE TABLE public.workspace_employment_rechecks (
    facility_id uuid NOT NULL,
    user_id uuid NOT NULL,
    directory_user_id text NOT NULL,
    customer_id text NOT NULL,
    group_id text NOT NULL,
    next_check_at timestamptz NOT NULL DEFAULT now(),
    claim_token uuid,
    claimed_until timestamptz,
    PRIMARY KEY (facility_id, user_id),
    CONSTRAINT workspace_rechecks_membership_fk FOREIGN KEY (facility_id, user_id)
        REFERENCES public.facility_memberships (facility_id, user_id) ON DELETE CASCADE,
    CONSTRAINT workspace_rechecks_directory_id_valid CHECK (directory_user_id ~ '^[A-Za-z0-9_-]{1,128}$'),
    CONSTRAINT workspace_rechecks_customer_id_valid CHECK (customer_id ~ '^[A-Za-z0-9_-]{1,128}$'),
    CONSTRAINT workspace_rechecks_group_id_valid CHECK (group_id ~ '^[A-Za-z0-9_-]{1,128}$'),
    CONSTRAINT workspace_rechecks_claim_pair CHECK ((claim_token IS NULL) = (claimed_until IS NULL))
);
CREATE INDEX workspace_rechecks_due_idx ON public.workspace_employment_rechecks (next_check_at, facility_id, user_id);

CREATE TABLE public.workspace_employment_revocation_audit (
    claim_token uuid PRIMARY KEY,
    facility_id uuid NOT NULL,
    user_id uuid NOT NULL,
    revoked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
