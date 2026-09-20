#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Deploy Plumber (omnirai) platform to namespace "plumber"
# Host: trade.omnirai.ai (via Cloudflare tunnel)
# NOTE: reuses the existing postgres StatefulSet in ns plumber (bundled postgres disabled).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${1:-plumber}"
CHART="${SCRIPT_DIR}/helm-charts"

echo "==> Deploying Plumber platform to namespace '${NAMESPACE}'..."
helm upgrade --install plumber "${CHART}" \
  -f "${SCRIPT_DIR}/manifests/values.yaml" \
  --set namespace="${NAMESPACE}" \
  --namespace "${NAMESPACE}" --create-namespace \
  --wait --timeout 3m

echo ""
echo "==> ✅ Deployment complete!"
echo ""
echo "    Namespace: ${NAMESPACE}"
echo "    Site:      https://trade.omnirai.ai"
echo "    Gateway:   plumber-https-gw (istio-ingress)"
echo ""
echo "    DNS: add CNAME trade.omnirai.ai -> <tunnel>.cfargotunnel.com (proxied)"
