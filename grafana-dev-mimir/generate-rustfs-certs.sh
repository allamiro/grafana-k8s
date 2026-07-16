#!/usr/bin/env bash
# Generate a self-signed CA + TLS certificate for RustFS (Mimir's S3-compatible
# object store) and load them as the `rustfs-tls` Secret.
#
# RustFS requires the files to be named EXACTLY rustfs_cert.pem and
# rustfs_key.pem inside the RUSTFS_TLS_PATH directory.
#
# Usage:
#   ./grafana-dev-mimir/generate-rustfs-certs.sh
#
# In production, create the Secret from your real cert instead (keep the
# same key names):
#   kubectl -n grafana-dev create secret generic rustfs-tls \
#     --from-file=rustfs_cert.pem=real-fullchain.pem \
#     --from-file=rustfs_key.pem=real.key \
#     --from-file=ca.crt=real-ca.crt
set -euo pipefail

NAMESPACE="${NAMESPACE:-grafana-dev}"
DAYS="${DAYS:-825}"
OUT="$(cd "$(dirname "$0")" && pwd)/certs-out"

mkdir -p "$OUT"
cd "$OUT"

echo ">> 1/4 Generating self-signed CA (RustFS Dev CA)"
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/O=RustFS Dev/CN=RustFS Dev CA" -out ca.crt

echo ">> 2/4 Generating server key + CSR"
openssl genrsa -out rustfs_key.pem 2048
openssl req -new -key rustfs_key.pem \
  -subj "/CN=rustfs.${NAMESPACE}.svc.cluster.local" -out rustfs.csr

echo ">> 3/4 Signing server cert (SANs cover the in-cluster service names)"
cat > san.cnf <<EOF
subjectAltName = DNS:rustfs, DNS:rustfs.${NAMESPACE}, DNS:rustfs.${NAMESPACE}.svc, DNS:rustfs.${NAMESPACE}.svc.cluster.local, DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in rustfs.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days "${DAYS}" -sha256 -extfile san.cnf -out rustfs_cert.pem

echo ">> Verifying the chain (fail fast on trust/verification problems)"
# The exact check Mimir/the bucket Job do at runtime: does rustfs_cert.pem
# chain to the CA in ca.crt? If this fails, so will every client.
openssl verify -CAfile ca.crt rustfs_cert.pem
# Confirm the SANs are present -- clients validate the name against these,
# NOT the CN. A missing SAN is the #1 cause of "certificate is valid for X,
# not Y" errors.
openssl x509 -in rustfs_cert.pem -noout -ext subjectAltName

echo ">> 4/4 Creating/updating Secret ${NAMESPACE}/rustfs-tls"
kubectl -n "${NAMESPACE}" create secret generic rustfs-tls \
  --from-file=rustfs_cert.pem=rustfs_cert.pem \
  --from-file=rustfs_key.pem=rustfs_key.pem \
  --from-file=ca.crt=ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Done. Files in grafana-dev-mimir/certs-out/ (git-ignored)."
