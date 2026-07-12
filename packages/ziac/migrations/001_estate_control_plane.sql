BEGIN;

CREATE TABLE IF NOT EXISTS ziac_accounts (
    google_subject STRING PRIMARY KEY,
    email_hash BYTES NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    disabled_at TIMESTAMPTZ NULL
);

CREATE TABLE IF NOT EXISTS ziac_identity_sessions (
    session_digest BYTES PRIMARY KEY CHECK (length(session_digest) = 32),
    google_subject STRING NOT NULL REFERENCES ziac_accounts (google_subject),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ziac_identity_sessions_subject_idx
    ON ziac_identity_sessions (google_subject, expires_at DESC);

CREATE TABLE IF NOT EXISTS ziac_entitlements (
    google_subject STRING PRIMARY KEY REFERENCES ziac_accounts (google_subject),
    tier STRING NOT NULL CHECK (tier IN ('free', 'pro')),
    active BOOL NOT NULL,
    source STRING NOT NULL,
    source_customer_hash BYTES NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ziac_gcp_connections (
    connection_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    google_subject STRING NOT NULL REFERENCES ziac_accounts (google_subject),
    project_id STRING NOT NULL,
    status STRING NOT NULL CHECK (status IN ('connected', 'disconnected')),
    credential_ciphertext BYTES NOT NULL,
    credential_kms_key_version STRING NOT NULL,
    credential_sha256 BYTES NOT NULL CHECK (length(credential_sha256) = 32),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ NULL,
    UNIQUE (google_subject, project_id)
);

CREATE TABLE IF NOT EXISTS ziac_oauth_challenges (
    state_digest BYTES PRIMARY KEY CHECK (length(state_digest) = 32),
    nonce_digest BYTES NOT NULL CHECK (length(nonce_digest) = 32),
    verifier_digest BYTES NOT NULL CHECK (length(verifier_digest) = 32),
    redirect_uri STRING NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ziac_estate_audit (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    google_subject STRING NOT NULL,
    action STRING NOT NULL,
    resource_id STRING NOT NULL,
    outcome STRING NOT NULL CHECK (outcome IN ('allowed', 'denied')),
    request_digest BYTES NULL,
    detail JSONB NOT NULL DEFAULT '{}'::JSONB
);

CREATE INDEX IF NOT EXISTS ziac_estate_audit_subject_time_idx
    ON ziac_estate_audit (google_subject, occurred_at DESC);

COMMIT;
