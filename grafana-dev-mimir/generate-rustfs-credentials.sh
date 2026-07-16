#!/usr/bin/env bash
# Generate strong random S3 credentials for RustFS and store them as the
# `rustfs-credentials` Secret (used by RustFS, Mimir, and the bucket Job).
#
# Usage:
#   ./grafana-dev-mimir/generate-rustfs-credentials.sh
#
# Prints the generated keys once so you can save them in your password
# manager. Re-running rotates the credentials.
#
# IMPORTANT: if RustFS/Mimir are already running, restart them afterwards so
# every component picks up the new keys:
#   kubectl -n grafana-dev rollout restart deploy/rustfs deploy/mimir
set -euo pipefail

NAMESPACE="${NAMESPACE:-grafana-dev}"

ACCESS_KEY="rustfs-$(openssl rand -hex 6)"
SECRET_KEY="$(openssl rand -base64 24)"

kubectl -n "${NAMESPACE}" create secret generic rustfs-credentials \
  --from-literal=access-key="${ACCESS_KEY}" \
  --from-literal=secret-key="${SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Secret ${NAMESPACE}/rustfs-credentials updated."
echo "  access-key: ${ACCESS_KEY}"
echo "  secret-key: ${SECRET_KEY}"
echo
echo "Save these somewhere safe -- they are not shown again."
echo "If RustFS/Mimir are already running, restart them now:"
echo "  kubectl -n ${NAMESPACE} rollout restart deploy/rustfs deploy/mimir"
