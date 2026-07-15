#!/usr/bin/env bash
# Generate a self-signed CA + server certificate to simulate TLS locally,
# then load them into the cluster as the `grafana-tls` Secret.
#
# Usage:
#   ./certs/generate-certs.sh
#
# Override defaults via env vars:
#   DOMAIN=grafana.example.com NAMESPACE=grafana-dev ./certs/generate-certs.sh
#
# In production, skip this script and create the Secret from your real
# cert/key instead:
#   kubectl -n grafana-dev create secret tls grafana-tls \
#     --cert=real.crt --key=real.key
set -euo pipefail

DOMAIN="${DOMAIN:-grafana.example.com}"
NAMESPACE="${NAMESPACE:-grafana-dev}"
DAYS="${DAYS:-825}"
OUT="$(cd "$(dirname "$0")" && pwd)/out"

mkdir -p "$OUT"
cd "$OUT"

echo ">> 1/4 Generating self-signed CA (Grafana Dev CA)"
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/O=Grafana Dev/CN=Grafana Dev CA" -out ca.crt

echo ">> 2/4 Generating server key + CSR for ${DOMAIN}"
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -subj "/CN=${DOMAIN}" -out tls.csr

echo ">> 3/4 Signing server cert (SANs: ${DOMAIN}, localhost, 127.0.0.1)"
cat > san.cnf <<EOF
subjectAltName = DNS:${DOMAIN}, DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days "${DAYS}" -sha256 -extfile san.cnf -out tls.crt

echo ">> 4/4 Creating/updating Secret ${NAMESPACE}/grafana-tls (full chain + CA)"
# Grafana serves the FULL CHAIN: server cert followed by the CA cert.
cat tls.crt ca.crt > fullchain.crt

# One Secret carrying the chain, the key, and the CA -- matches the
# cert_file / cert_key / ca_cert paths in grafana.ini.
kubectl -n "${NAMESPACE}" create secret generic grafana-tls \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=fullchain.crt \
  --from-file=tls.key=tls.key \
  --from-file=ca.crt=ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Done. Files in certs/out/ (git-ignored). Secret 'grafana-tls' is ready."
echo "Your browser will warn about the self-signed cert -- expected in dev."
