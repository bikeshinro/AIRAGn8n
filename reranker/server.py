"""
Cross-Encoder Reranker Service
Provides /rerank endpoint for the Enterprise AI Query Pipeline.
Uses sentence-transformers cross-encoder models.
"""

import os
import time
import logging
from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Lazy-load model to allow health checks before model is ready
_model = None
_model_name = os.environ.get("MODEL_NAME", "cross-encoder/ms-marco-MiniLM-L-6-v2")
_model_ready = False


def get_model():
    global _model, _model_ready
    if _model is None:
        logger.info(f"Loading cross-encoder model: {_model_name}")
        from sentence_transformers import CrossEncoder
        _model = CrossEncoder(_model_name)
        _model_ready = True
        logger.info("Model loaded successfully")
    return _model


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model": _model_name, "model_ready": _model_ready}), 200


@app.route("/rerank", methods=["POST"])
def rerank():
    start = time.time()

    data = request.get_json()
    if not data:
        return jsonify({"error": "Missing JSON body"}), 400

    query = data.get("query", "")
    passages = data.get("passages", [])
    top_k = data.get("top_k", 5)

    if not query or not passages:
        return jsonify({"error": "Both 'query' and 'passages' are required"}), 400

    try:
        model = get_model()

        # Build query-passage pairs
        pairs = [[query, passage] for passage in passages]

        # Score all pairs
        scores = model.predict(pairs)
        scores = [float(s) for s in scores]

        # Build results with original index and score
        results = [{"index": i, "score": scores[i]} for i in range(len(scores))]
        results.sort(key=lambda x: x["score"], reverse=True)

        # Return top_k
        results = results[:top_k]

        latency_ms = (time.time() - start) * 1000
        logger.info(f"Reranked {len(passages)} passages in {latency_ms:.1f}ms, returning top {len(results)}")

        return jsonify({
            "results": results,
            "model": _model_name,
            "latency_ms": round(latency_ms, 2)
        }), 200

    except Exception as e:
        logger.error(f"Reranking failed: {str(e)}")
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    logger.info(f"Starting reranker service on port {port}")
    # Pre-load model at startup
    get_model()
    app.run(host="0.0.0.0", port=port, threaded=True)
