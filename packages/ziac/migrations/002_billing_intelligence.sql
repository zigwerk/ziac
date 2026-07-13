BEGIN;

CREATE TABLE IF NOT EXISTS ziac_billing_sources (
    source_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id UUID NULL REFERENCES ziac_gcp_connections (connection_id),
    source_kind STRING NOT NULL CHECK (source_kind IN ('self_host', 'customer_connection')),
    owner_project_id STRING NOT NULL,
    billing_project_id STRING NOT NULL,
    export_table STRING NOT NULL,
    location STRING NULL,
    currency STRING NOT NULL CHECK (length(currency) = 3),
    enabled BOOL NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (owner_project_id, export_table)
);

CREATE TABLE IF NOT EXISTS ziac_billing_ingestion_runs (
    run_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id UUID NOT NULL REFERENCES ziac_billing_sources (source_id),
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    status STRING NOT NULL CHECK (status IN ('running', 'complete', 'failed')),
    query_job_id STRING NULL,
    billed_total_micros INT8 NULL,
    attributed_total_micros INT8 NULL,
    unattributed_total_micros INT8 NULL,
    coverage_basis_points INT4 NULL CHECK (coverage_basis_points BETWEEN 0 AND 10000),
    error_code STRING NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ NULL,
    UNIQUE (source_id, window_start, window_end)
);

CREATE TABLE IF NOT EXISTS ziac_billing_resource_costs (
    run_id UUID NOT NULL REFERENCES ziac_billing_ingestion_runs (run_id) ON DELETE CASCADE,
    resource_id STRING NOT NULL,
    google_global_name STRING NOT NULL,
    amount_micros INT8 NOT NULL,
    currency STRING NOT NULL CHECK (length(currency) = 3),
    attribution STRING NOT NULL CHECK (attribution IN ('global_name', 'ziac_label')),
    observed_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (run_id, resource_id, google_global_name)
);

CREATE INDEX IF NOT EXISTS ziac_billing_runs_source_window_idx
    ON ziac_billing_ingestion_runs (source_id, window_end DESC);

COMMIT;
