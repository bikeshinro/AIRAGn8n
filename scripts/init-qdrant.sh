#!/bin/sh
# ============================================================================
# Initialize Qdrant collections for Enterprise AI Inspection Knowledge Assistant
# Creates 4 vector indexes: sop, fmea, rca, maintenance
# Vector dimensions: 3072 (OpenAI text-embedding-3-large)
# ============================================================================

set -e

QDRANT_URL="http://qdrant:6333"
VECTOR_SIZE=3072
DISTANCE="Cosine"

echo "=== Qdrant Collection Initialization ==="
echo "Waiting for Qdrant to be fully ready..."
sleep 5

for INDEX in sop fmea rca maintenance; do
  echo ""
  echo "--- Creating collection: ${INDEX} ---"

  # Check if collection already exists
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${QDRANT_URL}/collections/${INDEX}")

  if [ "$STATUS" = "200" ]; then
    echo "Collection '${INDEX}' already exists. Skipping."
    continue
  fi

  # Create collection
  curl -s -X PUT "${QDRANT_URL}/collections/${INDEX}" \
    -H "Content-Type: application/json" \
    -d "{
      \"vectors\": {
        \"size\": ${VECTOR_SIZE},
        \"distance\": \"${DISTANCE}\"
      },
      \"optimizers_config\": {
        \"default_segment_number\": 2,
        \"indexing_threshold\": 20000,
        \"memmap_threshold\": 50000
      },
      \"replication_factor\": 1,
      \"write_consistency_factor\": 1
    }"

  echo ""

  # Create payload indexes for filtering
  echo "Creating payload indexes for '${INDEX}'..."

  curl -s -X PUT "${QDRANT_URL}/collections/${INDEX}/index" \
    -H "Content-Type: application/json" \
    -d '{"field_name": "process_line", "field_schema": "keyword"}'
  echo ""

  curl -s -X PUT "${QDRANT_URL}/collections/${INDEX}/index" \
    -H "Content-Type: application/json" \
    -d '{"field_name": "document_type", "field_schema": "keyword"}'
  echo ""

  curl -s -X PUT "${QDRANT_URL}/collections/${INDEX}/index" \
    -H "Content-Type: application/json" \
    -d '{"field_name": "doc_id", "field_schema": "keyword"}'
  echo ""

  curl -s -X PUT "${QDRANT_URL}/collections/${INDEX}/index" \
    -H "Content-Type: application/json" \
    -d '{"field_name": "revision_number", "field_schema": "integer"}'
  echo ""

  curl -s -X PUT "${QDRANT_URL}/collections/${INDEX}/index" \
    -H "Content-Type: application/json" \
    -d '{"field_name": "access_roles", "field_schema": "keyword"}'
  echo ""

  echo "Collection '${INDEX}' created successfully with payload indexes."
done

echo ""
echo "=== All Qdrant collections initialized ==="

# Verify
echo ""
echo "--- Collection summary ---"
curl -s "${QDRANT_URL}/collections" | head -c 2000
echo ""
echo "=== Done ==="
