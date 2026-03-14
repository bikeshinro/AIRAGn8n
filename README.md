# Enterprise AI Inspection Knowledge Assistant

Production-ready n8n workflow system for multi-index RAG with RBAC enforcement, revision control, hallucination detection, Prometheus metrics, Redis caching, and plant-specific monitoring.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         n8n Workflow Engine                             │
│                                                                         │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │  01 - Document    │  │  02 - Query      │  │  03 - Monitoring     │  │
│  │  Ingestion        │  │  Pipeline        │  │  & Metrics           │  │
│  │  Pipeline         │  │                  │  │                      │  │
│  └────────┬─────────┘  └────────┬─────────┘  └──────────┬───────────┘  │
│           │                     │                        │              │
└───────────┼─────────────────────┼────────────────────────┼──────────────┘
            │                     │                        │
     ┌──────┼─────────────────────┼────────────────────────┼──────┐
     │      ▼                     ▼                        ▼      │
     │  ┌────────┐  ┌──────────┐  ┌───────┐  ┌────────────────┐  │
     │  │Qdrant  │  │PostgreSQL│  │ Redis │  │ Prometheus     │  │
     │  │VectorDB│  │          │  │ Cache │  │ Pushgateway    │  │
     │  └────────┘  └──────────┘  └───────┘  └───────┬────────┘  │
     │   (4 indexes)                                  │           │
     │   sop|fmea|rca|maintenance                     ▼           │
     │                                          ┌──────────┐      │
     │                                          │ Grafana  │      │
     │                                          │ (5 views)│      │
     │                                          └──────────┘      │
     └────────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
AIRAGn8n/
├── docker-compose.yml                          # Full-stack Docker Compose
├── .env.example                                # Environment variable template (copy to .env)
├── .dockerignore
├── workflows/
│   ├── 01_document_ingestion_pipeline.json     # Document ingestion workflow
│   ├── 02_query_pipeline.json                  # Query + RAG pipeline workflow
│   └── 03_monitoring_metrics.json              # Monitoring & metrics workflow
├── sql/
│   └── schema.sql                              # PostgreSQL schema + seed data
├── grafana/
│   ├── dashboards.json                         # Pre-built Grafana dashboard
│   └── provisioning/
│       ├── datasources/datasource.yml          # Prometheus datasource
│       └── dashboards/dashboard.yml            # Dashboard provisioner
├── prometheus/
│   └── prometheus.yml                          # Prometheus scrape config
├── reranker/
│   └── server.py                               # Cross-encoder reranker API
├── scripts/
│   └── init-qdrant.sh                          # Qdrant collection bootstrap
└── README.md
```

---

## Workflows

### 1. Document Ingestion Pipeline (`01_document_ingestion_pipeline.json`)

**Trigger:** `POST /webhook/ingest-document`

**Flow:**
1. Receive document (PDF/DOCX/TXT) via webhook
2. Validate input fields and file type
3. Extract text content
4. Split into overlapping chunks (1500 chars, 200 overlap)
5. Generate embeddings via OpenAI `text-embedding-3-large` (3072 dims)
6. Store vectors in Qdrant multi-index DB (sop/fmea/rca/maintenance)
7. Store chunk metadata in PostgreSQL
8. Aggregate and store document metadata
9. Handle revision control (supersede previous revision if applicable)
10. Compute and push Prometheus metrics
11. Return success response

**Request body:**
```json
{
  "file_name": "SOP-Welding-Line3-v2.pdf",
  "file_content": "... extracted text ...",
  "document_type": "sop",
  "process_line": "welding-line-3",
  "access_roles": ["engineer", "operator"],
  "revision_number": 2,
  "previous_revision_id": "uuid-of-v1",
  "ingested_by": "admin@plant.com"
}
```

**Metrics emitted:**
| Metric | Type | Description |
|--------|------|-------------|
| `ai_ingestion_total` | counter | Total document ingestions |
| `ai_ingestion_latency_seconds` | histogram | Ingestion latency |
| `ai_ingestion_chunks_total` | counter | Total chunks created |
| `ai_ingestion_retry_total` | counter | Embedding/DB retries |
| `ai_ingestion_failed_total` | counter | Failed ingestions |
| `ai_revision_superseded_total` | counter | Documents marked superseded |

---

### 2. Query Pipeline (`02_query_pipeline.json`)

**Trigger:** `POST /webhook/query`

**Flow:**
1. Parse incoming query request
2. Validate JWT / OAuth2 token (decode + expiry check)
3. Enforce RBAC (role → allowed indexes + process lines)
4. Detect prompt injection (16+ pattern checks)
5. Check Redis cache for previous answer
6. **Cache hit** → return cached answer with metrics
7. **Cache miss** → generate query embedding (text-embedding-3-large)
8. Multi-index semantic search across Qdrant (per-index parallel)
9. Merge results, filter superseded revisions
10. Cross-encoder reranking (top-5)
11. Build LLM context with source citations
12. Generate answer via GPT-4o-mini (temperature=0.1)
13. Hallucination detection + confidence scoring
14. Cache result in Redis (1hr TTL)
15. Store retrieval log in PostgreSQL
16. Compute and push all query metrics
17. Return answer with sources and metadata

**Request body:**
```json
{
  "query": "What is the torque spec for flange bolt Stage 3?",
  "process_line": "assembly-line-1",
  "shift": "day",
  "target_indexes": ["sop", "maintenance"],
  "top_k": 10
}
```

**Headers required:**
```
Authorization: Bearer <JWT_TOKEN>
```

**JWT payload expected:**
```json
{
  "sub": "user123",
  "role": "engineer",
  "process_lines": ["assembly-line-1", "welding-line-3"],
  "exp": 1700000000
}
```

**Response:**
```json
{
  "success": true,
  "query_id": "qry-...",
  "answer": "According to SOP-Welding-Line3-v2 [Source 1], the torque spec...",
  "confidence_score": 0.87,
  "hallucination_flag": false,
  "sources": [
    { "index": "sop", "document": "SOP-Welding-Line3-v2.pdf", "process_line": "welding-line-3", "score": 0.92 }
  ],
  "latency_seconds": 2.34,
  "cache_hit": false
}
```

**Metrics emitted:**
| Metric | Type | Description |
|--------|------|-------------|
| `ai_query_total` | counter | Total queries |
| `ai_query_latency_seconds` | histogram | End-to-end query latency |
| `ai_embedding_latency_seconds` | histogram | Embedding generation latency |
| `ai_vector_query_latency_seconds` | histogram | Vector DB search latency |
| `ai_rerank_latency_seconds` | histogram | Cross-encoder rerank latency |
| `ai_answer_generation_latency_seconds` | histogram | LLM answer latency |
| `ai_hallucination_flag_total` | counter | Hallucination flags |
| `ai_confidence_score` | gauge | Per-query confidence score |
| `ai_unsupported_answers_total` | counter | Unsupported/insufficient answers |
| `ai_retrieval_from_superseded_total` | counter | Superseded docs filtered |
| `ai_rbac_rejections_total` | counter | RBAC access denials |
| `ai_prompt_injection_attempts_total` | counter | Prompt injection attempts |
| `ai_cross_process_access_attempts_total` | counter | Cross-line access attempts |
| `ai_auth_failures_total` | counter | JWT auth failures |

---

### 3. Monitoring & Metrics (`03_monitoring_metrics.json`)

**Triggers:**
- Every 5 minutes: aggregate and push monitoring metrics
- Every 1 hour: cleanup old records (>90 days logs, >365 days insights)

**Periodic metrics (5-min window):**
| Metric | Type | Description |
|--------|------|-------------|
| `ai_active_documents_total` | gauge | Active docs by type/status |
| `ai_revision_superseded_total` | gauge | Superseded doc count |
| `ai_queries_by_process_line` | gauge | Queries per line/shift |
| `ai_avg_confidence_by_process_line` | gauge | Avg confidence per line |
| `ai_hallucinations_by_process_line` | gauge | Hallucinations per line |
| `ai_low_confidence_by_process_line` | gauge | Low-confidence count per line |
| `ai_cost_by_process_line` | gauge | Cost per line |
| `ai_avg_latency_by_process_line` | gauge | Avg latency per line |
| `ai_low_confidence_queries_total` | gauge | Low-confidence queries (1hr) |
| `ai_security_events_total` | gauge | Security events by type |
| `ai_cost_per_index` | gauge | Cost by vector index |

---

## RBAC Roles

| Role | Allowed Indexes | Can Ingest | Can Query |
|------|----------------|------------|-----------|
| `admin` | sop, fmea, rca, maintenance | ✅ | ✅ |
| `engineer` | sop, fmea, rca, maintenance | ✅ | ✅ |
| `operator` | sop, maintenance | ❌ | ✅ |
| `inspector` | sop, fmea, rca | ❌ | ✅ |
| `viewer` | sop | ❌ | ✅ |

---

## Grafana Dashboard Sections

The included dashboard (`grafana/dashboards.json`) provides 5 views:

1. **Executive Overview** — Total queries, ingestions, confidence, hallucination rate, active docs, security events
2. **Engineering / Performance** — Query latency percentiles (p50/p95/p99), latency breakdown by stage, ingestion latency, retry rates
3. **AI Quality** — Confidence distribution, hallucination trends, low-confidence training opportunities
4. **Security / Compliance** — RBAC rejections, prompt injection attempts, cross-process access, auth failures
5. **Plant / Process Insights** — Queries by process line & shift, confidence by line, cost by index, latency by line

---

## Prerequisites

- **Docker Engine** ≥ 24.0, **Docker Compose** ≥ 2.20
- **OpenAI API Key** with access to `text-embedding-3-large` and `gpt-4o-mini`
- ~2 GB additional RAM (reranker model needs ~1.5 GB)

### Existing containers (reused — already running)

| Container | Network | Port | Role |
|-----------|---------|------|------|
| `grafana` | `observability_default` | 3000 | Dashboard visualization |
| `prometheus` | `observability_default` | 9090 | Metrics storage |
| `qdrant` | `observability_default` | 6333, 6334 | Multi-index vector DB |

### New containers (added by this Compose)

| Service | Image | Port | Purpose |
|---------|-------|------|----------|
| **n8n** | `n8nio/n8n:latest` | 5678 | Workflow engine |
| **ai-postgres** | `postgres:16-alpine` | 5432 | Metadata, logs, RBAC, insights |
| **Redis** | `redis:7-alpine` | 6379 | Query result caching (LRU, 256 MB) |
| **Pushgateway** | `prom/pushgateway:v1.9.0` | 9091 | Metrics ingestion endpoint |
| **Reranker** | `python:3.11-slim` | 8080 | Cross-encoder reranking |
| **Qdrant Init** | `curlimages/curl` | — | One-shot collection bootstrap |

All new services join the **`observability_default`** network so they can reach your existing Grafana, Prometheus, and Qdrant by hostname.

---

## Quick Start (Docker Compose)

### 1. Configure environment

```bash
# Copy the template and fill in your values
cp .env.example .env

# Edit .env — at minimum set:
#   OPENAI_API_KEY        (required)
#   N8N_ENCRYPTION_KEY    (required — any random 32+ char string)
#   POSTGRES_PASSWORD     (required)
#   REDIS_PASSWORD        (required)
#   GF_SECURITY_ADMIN_PASSWORD  (recommended)
```

### 2. Launch the stack

```bash
docker compose up -d
```

This will:
- Start PostgreSQL (`ai-postgres`) and auto-run `sql/schema.sql`
- Run `qdrant-init` to create 4 vector collections on your **existing** Qdrant
- Start Redis with LRU eviction and AOF persistence
- Start Pushgateway for n8n metrics ingestion
- Start the cross-encoder reranker (first start downloads model ~80 MB)
- Start n8n connected to PostgreSQL for workflow state

> **Note:** Grafana, Prometheus, and Qdrant are **not** started — your existing containers are reused.

### 3. Wire Prometheus → Pushgateway

Your existing Prometheus needs a new scrape target. Add this job to your Prometheus config:

```yaml
  - job_name: "ai_pushgateway"
    honor_labels: true
    scrape_interval: 10s
    static_configs:
      - targets: ["pushgateway:9091"]
        labels:
          service: "ai-pushgateway"
```

Then hot-reload Prometheus:
```bash
curl -X POST http://localhost:9090/-/reload
```

### 4. Import Grafana dashboard

In your existing Grafana at **http://localhost:3000**:
1. Go to **Dashboards → Import**
2. Upload `grafana/dashboards.json`
3. Select `Prometheus` as the data source

Or run the helper script (Linux/Mac/WSL):
```bash
bash scripts/setup-existing-infra.sh
```

### 5. Import workflows into n8n

Open n8n at **http://localhost:5678** and:

1. Go to **Settings → Credentials** and create:
   - **HTTP Header Auth** named "OpenAI API Key"
     - Header Name: `Authorization`
     - Header Value: `Bearer sk-your-key-here`
   - **PostgreSQL** named "PostgreSQL"
     - Host: `ai-postgres`, Port: `5432`, Database: `enterprise_ai`
     - User: `n8n_user`, Password: (your `POSTGRES_PASSWORD`)

2. Note the **credential IDs** from the URL after saving each credential.

3. Update credential IDs in the workflow JSON files:
   - Replace `OPENAI_HEADER_AUTH_CREDENTIAL_ID` with your OpenAI credential ID
   - Replace `POSTGRES_CREDENTIAL_ID` with your PostgreSQL credential ID

4. Import all 3 workflows via **Settings → Import from File**:
   - `workflows/01_document_ingestion_pipeline.json`
   - `workflows/02_query_pipeline.json`
   - `workflows/03_monitoring_metrics.json`

5. **Activate** all 3 workflows. The monitoring workflow starts its 5-min cycle automatically.

### 6. Verify everything

```bash
# All new containers healthy
docker compose ps

# Qdrant collections created
curl http://localhost:6333/collections

# Pushgateway ready
curl http://localhost:9091/-/healthy

# Reranker loaded
curl http://localhost:8080/health

# Prometheus scraping pushgateway
curl -s http://localhost:9090/api/v1/targets | findstr pushgateway
```

### Access points

- **n8n**: http://localhost:5678
- **Grafana**: http://localhost:3000 (your existing instance)
- **Prometheus**: http://localhost:9090 (your existing instance)
- **Pushgateway**: http://localhost:9091
- **Qdrant**: http://localhost:6333/dashboard (your existing instance)

---

## Docker Compose Commands

```bash
# Start all services
docker compose up -d

# View logs (all services)
docker compose logs -f

# View logs (specific service)
docker compose logs -f n8n
docker compose logs -f reranker

# Stop all services (data preserved in volumes)
docker compose down

# Stop and remove all data (fresh start)
docker compose down -v

# Rebuild reranker after code changes
docker compose up -d --force-recreate reranker

# Scale n8n workers (if using queue mode)
docker compose up -d --scale n8n=3
```

---

## Environment Variables

Copy `.env.example` to `.env` and fill in your values. Key settings:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OPENAI_API_KEY` | **Yes** | — | OpenAI API key |
| `N8N_ENCRYPTION_KEY` | **Yes** | — | n8n credential encryption key |
| `POSTGRES_PASSWORD` | **Yes** | — | PostgreSQL password |
| `REDIS_PASSWORD` | **Yes** | — | Redis password |
| `GF_SECURITY_ADMIN_PASSWORD` | Recommended | `grafana-change-me` | Grafana admin password |
| `N8N_BASIC_AUTH_USER` | Optional | `admin` | n8n UI username |
| `N8N_BASIC_AUTH_PASSWORD` | Optional | `changeme` | n8n UI password |
| `RERANKER_MODEL` | Optional | `cross-encoder/ms-marco-MiniLM-L-6-v2` | Cross-encoder model |
| `WEBHOOK_URL` | Optional | `http://localhost:5678` | External webhook base URL |

---

## Retry & Error Handling

| Component | Max Retries | Backoff | Metric |
|-----------|-------------|---------|--------|
| OpenAI Embeddings | 3 | 2s exponential | `ai_ingestion_retry_total` |
| Vector DB writes | 3 | 3s exponential | `ai_ingestion_retry_total` |
| Vector DB search | 2 | 1s fixed | `ai_query_errors_total` |
| Cross-encoder rerank | 2 | 1s fixed | `ai_query_errors_total` |
| LLM generation | 2 | 3s exponential | `ai_query_errors_total` |
| Prometheus push | 2 | 1s fixed | `ai_monitoring_retry_total` |

Each workflow has a dedicated **Error Trigger** node that catches unhandled errors, classifies them by stage, emits failure metrics, and logs to `security_audit_log`.

---

## Hallucination Detection

The system uses a multi-signal approach:

1. **Unsupported answer detection** — checks for phrases like "I don't have sufficient information"
2. **Claim-context alignment** — extracts sentence-level claims and measures word overlap with retrieved context
3. **Confidence scoring** — weighted formula: `60% claim_support + 40% retrieval_quality`
4. **Flag threshold** — hallucination flag raised when claim support < 40%

---

## Security Features

- **JWT validation** with expiry check (JWKS verification ready)
- **RBAC enforcement** against role-based index and process-line policies
- **Prompt injection detection** with 16+ regex patterns + query length limits
- **Cross-process access prevention** with audit logging
- **All security events** logged to `security_audit_log` table and Prometheus

---

## Customization

### Adding a new vector index
1. Add to `scripts/init-qdrant.sh` loop (or create manually via Qdrant API)
2. Add to `document_type` CHECK constraint in `sql/schema.sql`
3. Update RBAC policies in `rbac_policies` table
4. Update `validTypes` array in `Validate_Input` code node
5. Update `rbacPolicies` map in `Enforce_RBAC` code node

### Adjusting chunk size
Edit `Split_Into_Chunks` code node constants:
- `CHUNK_SIZE` (default: 1500 chars)
- `CHUNK_OVERLAP` (default: 200 chars)
- `MIN_CHUNK_SIZE` (default: 100 chars)

### Changing LLM model
Edit `Generate_Answer_LLM` node JSON body — change `model` parameter.

### Redis cache TTL
Edit `Cache_Result_Redis` node — change `3600` (seconds) in SETEX args.

### Swapping the reranker model
Set `RERANKER_MODEL` in `.env` to any Hugging Face cross-encoder model name, then:
```bash
docker compose up -d --force-recreate reranker
```

### Production hardening
- Set `N8N_PROTOCOL=https` and configure a reverse proxy (Traefik, Caddy, nginx)
- Rotate `N8N_ENCRYPTION_KEY`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD` via secrets manager
- Enable Qdrant API key auth: set `QDRANT__SERVICE__API_KEY` in docker-compose
- Add resource limits to all services via `deploy.resources.limits`
- Enable PostgreSQL SSL: mount certs and set `PGSSLMODE=verify-full`

---

## Network Topology

All services communicate on the `enterprise-ai-network` Docker bridge network. Internal DNS names match the service names in `docker-compose.yml`:

| Internal Hostname | Port | Used By |
|-------------------|------|----------|
| `postgres` | 5432 | n8n, monitoring workflow |
| `qdrant` | 6333 | ingestion + query workflows |
| `redis` | 6379 | query workflow (cache) |
| `pushgateway` | 9091 | all workflows (metrics push) |
| `prometheus` | 9090 | Grafana |
| `reranker` | 8080 | query workflow |

Only n8n (5678), Grafana (3000), and Prometheus (9090) need to be exposed externally.
