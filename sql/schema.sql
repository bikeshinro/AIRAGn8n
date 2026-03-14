-- ============================================================================
-- Enterprise AI Inspection Knowledge Assistant - Database Schema
-- Compatible with PostgreSQL 14+
-- ============================================================================

-- Document metadata and revision tracking
CREATE TABLE IF NOT EXISTS document_metadata (
    doc_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_name           VARCHAR(500) NOT NULL,
    file_hash           VARCHAR(128),
    document_type       VARCHAR(50) NOT NULL CHECK (document_type IN ('sop', 'fmea', 'rca', 'maintenance')),
    process_line        VARCHAR(100) NOT NULL,
    access_roles        TEXT[] NOT NULL DEFAULT '{}',
    revision_status     VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (revision_status IN ('active', 'superseded', 'draft')),
    revision_number     INTEGER NOT NULL DEFAULT 1,
    previous_revision_id UUID REFERENCES document_metadata(doc_id),
    chunk_count         INTEGER NOT NULL DEFAULT 0,
    vector_index        VARCHAR(50) NOT NULL,
    ingested_by         VARCHAR(200),
    ingested_at         TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Document chunks reference (maps chunk_id to vector DB)
CREATE TABLE IF NOT EXISTS document_chunks (
    chunk_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_id              UUID NOT NULL REFERENCES document_metadata(doc_id) ON DELETE CASCADE,
    chunk_index         INTEGER NOT NULL,
    chunk_text          TEXT NOT NULL,
    token_count         INTEGER,
    vector_id           VARCHAR(200),
    vector_index        VARCHAR(50) NOT NULL,
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- RBAC policies
CREATE TABLE IF NOT EXISTS rbac_policies (
    policy_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_name           VARCHAR(100) NOT NULL UNIQUE,
    allowed_indexes     TEXT[] NOT NULL DEFAULT '{}',
    allowed_process_lines TEXT[] NOT NULL DEFAULT '{}',
    can_ingest          BOOLEAN DEFAULT FALSE,
    can_query           BOOLEAN DEFAULT TRUE,
    max_queries_per_hour INTEGER DEFAULT 100,
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Retrieval / query logs
CREATE TABLE IF NOT EXISTS retrieval_logs (
    log_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    query_text          TEXT NOT NULL,
    user_id             VARCHAR(200) NOT NULL,
    user_role           VARCHAR(100) NOT NULL,
    process_line        VARCHAR(100),
    shift               VARCHAR(20),
    matched_doc_ids     UUID[],
    matched_indexes     TEXT[],
    top_k_scores        DOUBLE PRECISION[],
    rerank_scores       DOUBLE PRECISION[],
    answer_text         TEXT,
    confidence_score    DOUBLE PRECISION,
    hallucination_flag  BOOLEAN DEFAULT FALSE,
    cache_hit           BOOLEAN DEFAULT FALSE,
    total_latency_ms    DOUBLE PRECISION,
    embedding_latency_ms DOUBLE PRECISION,
    vector_query_latency_ms DOUBLE PRECISION,
    rerank_latency_ms   DOUBLE PRECISION,
    llm_latency_ms      DOUBLE PRECISION,
    tokens_used         INTEGER,
    cost_estimate       DOUBLE PRECISION,
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Security audit log
CREATE TABLE IF NOT EXISTS security_audit_log (
    audit_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type          VARCHAR(50) NOT NULL CHECK (event_type IN (
        'rbac_rejection', 'prompt_injection', 'cross_process_access',
        'jwt_invalid', 'rate_limit_exceeded', 'superseded_access_attempt',
        'ingestion_failure'
    )),
    user_id             VARCHAR(200),
    user_role           VARCHAR(100),
    process_line        VARCHAR(100),
    target_resource     VARCHAR(200),
    details             JSONB DEFAULT '{}',
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Plant / process insights (aggregated periodically)
CREATE TABLE IF NOT EXISTS query_insights (
    insight_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_line        VARCHAR(100) NOT NULL,
    shift               VARCHAR(20),
    query_count         INTEGER DEFAULT 0,
    avg_confidence      DOUBLE PRECISION,
    low_confidence_queries JSONB DEFAULT '[]',
    cost_per_index      JSONB DEFAULT '{}',
    period_start        TIMESTAMP WITH TIME ZONE NOT NULL,
    period_end          TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_doc_meta_process_line ON document_metadata(process_line);
CREATE INDEX IF NOT EXISTS idx_doc_meta_revision_status ON document_metadata(revision_status);
CREATE INDEX IF NOT EXISTS idx_doc_meta_document_type ON document_metadata(document_type);
CREATE INDEX IF NOT EXISTS idx_doc_meta_file_hash ON document_metadata(file_hash);
CREATE INDEX IF NOT EXISTS idx_doc_chunks_doc_id ON document_chunks(doc_id);
CREATE INDEX IF NOT EXISTS idx_doc_chunks_vector_index ON document_chunks(vector_index);
CREATE INDEX IF NOT EXISTS idx_retrieval_logs_user_id ON retrieval_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_retrieval_logs_created_at ON retrieval_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_retrieval_logs_confidence ON retrieval_logs(confidence_score);
CREATE INDEX IF NOT EXISTS idx_retrieval_logs_process_line ON retrieval_logs(process_line);
CREATE INDEX IF NOT EXISTS idx_security_audit_event_type ON security_audit_log(event_type);
CREATE INDEX IF NOT EXISTS idx_security_audit_created_at ON security_audit_log(created_at);
CREATE INDEX IF NOT EXISTS idx_query_insights_process_line ON query_insights(process_line);
CREATE INDEX IF NOT EXISTS idx_query_insights_period ON query_insights(period_start, period_end);

-- Seed default RBAC policies
INSERT INTO rbac_policies (role_name, allowed_indexes, allowed_process_lines, can_ingest, can_query) VALUES
    ('admin',       ARRAY['sop','fmea','rca','maintenance'], ARRAY['*'], TRUE,  TRUE),
    ('engineer',    ARRAY['sop','fmea','rca','maintenance'], ARRAY['*'], TRUE,  TRUE),
    ('operator',    ARRAY['sop','maintenance'],              ARRAY['*'], FALSE, TRUE),
    ('inspector',   ARRAY['sop','fmea','rca'],               ARRAY['*'], FALSE, TRUE),
    ('viewer',      ARRAY['sop'],                             ARRAY['*'], FALSE, TRUE)
ON CONFLICT (role_name) DO NOTHING;
