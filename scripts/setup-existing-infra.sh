#!/bin/bash
# ============================================================================
# Post-deploy setup for existing Grafana / Prometheus / Qdrant containers
# Run this AFTER docker compose up -d
# ============================================================================

set -e

echo "=============================================="
echo " Enterprise AI - Existing Infrastructure Setup"
echo "=============================================="
echo ""

# --------------------------------------------------------------------------
# 1. Add Pushgateway scrape job to existing Prometheus
# --------------------------------------------------------------------------
echo "[1/3] Configuring Prometheus to scrape Pushgateway..."

# Get the existing Prometheus config file path
PROM_CONFIG=$(docker inspect prometheus --format '{{range .Mounts}}{{if eq .Destination "/etc/prometheus/prometheus.yml"}}{{.Source}}{{end}}{{end}}')

if [ -z "$PROM_CONFIG" ]; then
  echo "  WARNING: Could not find Prometheus config mount."
  echo "  You need to manually add this to your prometheus.yml scrape_configs:"
  echo ""
  echo '  - job_name: "ai_pushgateway"'
  echo '    honor_labels: true'
  echo '    scrape_interval: 10s'
  echo '    static_configs:'
  echo '      - targets: ["pushgateway:9091"]'
  echo '        labels:'
  echo '          service: "ai-pushgateway"'
  echo ""
  echo "  Then reload: curl -X POST http://localhost:9090/-/reload"
else
  echo "  Found Prometheus config at: $PROM_CONFIG"

  # Check if pushgateway job already exists
  if grep -q "ai_pushgateway" "$PROM_CONFIG" 2>/dev/null; then
    echo "  Pushgateway job already configured. Skipping."
  else
    echo "  Adding pushgateway scrape job..."
    cat >> "$PROM_CONFIG" << 'EOF'

  # Enterprise AI - Pushgateway metrics
  - job_name: "ai_pushgateway"
    honor_labels: true
    scrape_interval: 10s
    static_configs:
      - targets: ["pushgateway:9091"]
        labels:
          service: "ai-pushgateway"
          stack: "enterprise-ai"
EOF
    echo "  Reloading Prometheus config..."
    curl -s -X POST http://localhost:9090/-/reload || echo "  WARNING: Prometheus reload failed. You may need to restart it."
    echo "  Done."
  fi
fi

echo ""

# --------------------------------------------------------------------------
# 2. Add Prometheus datasource to Grafana (if not already present)
# --------------------------------------------------------------------------
echo "[2/3] Checking Grafana datasource..."

# Check if Prometheus datasource exists
GF_USER=${GF_SECURITY_ADMIN_USER:-admin}
GF_PASS=${GF_SECURITY_ADMIN_PASSWORD:-admin}
DS_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  http://${GF_USER}:${GF_PASS}@localhost:3000/api/datasources/name/Prometheus)

if [ "$DS_CHECK" = "200" ]; then
  echo "  Prometheus datasource already exists in Grafana."
else
  echo "  Prometheus datasource not found — it should already exist in your Grafana."
  echo "  If it doesn't, add it manually: URL = http://prometheus:9090"
fi

echo ""

# --------------------------------------------------------------------------
# 3. Import Enterprise AI dashboard to Grafana
# --------------------------------------------------------------------------
echo "[3/3] Importing Enterprise AI dashboard to Grafana..."

DASHBOARD_JSON=$(cat grafana/dashboards.json)

# Wrap in Grafana import format
IMPORT_PAYLOAD=$(cat <<EOF
{
  "dashboard": ${DASHBOARD_JSON},
  "overwrite": true,
  "folderId": 0
}
EOF
)

IMPORT_RESULT=$(curl -s -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -d "$IMPORT_PAYLOAD" \
  http://${GF_USER}:${GF_PASS}@localhost:3000/api/dashboards/db)

HTTP_CODE=$(echo "$IMPORT_RESULT" | tail -1)
RESPONSE=$(echo "$IMPORT_RESULT" | head -1)

if [ "$HTTP_CODE" = "200" ]; then
  echo "  Dashboard imported successfully!"
  echo "  Open: http://localhost:3000/d/enterprise-ai-inspection"
else
  echo "  Dashboard import returned HTTP $HTTP_CODE"
  echo "  Response: $RESPONSE"
  echo "  You can import manually: Grafana → Dashboards → Import → Upload grafana/dashboards.json"
fi

echo ""
echo "=============================================="
echo " Setup complete!"
echo ""
echo " Services:"
echo "   n8n:         http://localhost:5678"
echo "   Grafana:     http://localhost:3000"
echo "   Prometheus:  http://localhost:9090"
echo "   Pushgateway: http://localhost:9091"
echo "   Qdrant:      http://localhost:6333/dashboard"
echo ""
echo " Next steps:"
echo "   1. Open n8n and create credentials (OpenAI + PostgreSQL)"
echo "   2. Update credential IDs in workflow JSON files"
echo "   3. Import the 3 workflows via n8n UI"
echo "   4. Activate all workflows"
echo "=============================================="
