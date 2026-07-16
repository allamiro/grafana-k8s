# Mimir + RustFS — scale-out metrics with S3 object storage

Self-contained deployment of [Grafana Mimir](https://grafana.com/oss/mimir/)
([docs](https://grafana.com/docs/mimir/latest/)) backed by
[RustFS](https://rustfs.com) ([docs](https://docs.rustfs.com)), an
S3-compatible object store, served over **TLS with a self-signed cert** so the
setup mirrors production. Everything runs in the same `grafana-dev` namespace
as the main stack.

## Why Mimir, and why object storage?

The main stack ships Prometheus, which stores metrics on a local PVC — simple,
but bounded by one disk and one process. Mimir is the horizontally-scalable,
long-term alternative: it speaks the same query language (PromQL) and the same
`remote_write` ingest API, but keeps its long-term data as **blocks in object
storage** (S3/GCS/Azure — here, RustFS). That gives you cheap retention,
storage that grows independently of compute, and the ability to later split
Mimir into microservices (ingesters, queriers, ...) that all share the same
bucket.

```
Alloy ──remote_write──►  Mimir (monolithic)  ──blocks──►  RustFS (S3, TLS :9000)
                            ▲     local /data = WAL + cache only
Grafana ────PromQL──────────┘
```

## Configuring the S3 credentials

RustFS (server), Mimir (client), and the bucket Job all read the same
`rustfs-credentials` Secret — one place to configure, three consumers.
Two ways to set it:

**Option A — generated (recommended):** one command creates strong random
keys and applies the Secret:

```bash
./grafana-dev-mimir/generate-rustfs-credentials.sh
```

**Option B — choose your own:** run the kubectl command directly:

```bash
kubectl -n grafana-dev create secret generic rustfs-credentials \
  --from-literal=access-key="my-access-key" \
  --from-literal=secret-key="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

(The checked-in [rustfs-secret.yaml](rustfs-secret.yaml) carries obvious dev
placeholders so `kubectl apply -f grafana-dev-mimir/` works out of the box —
override it with one of the options above for anything beyond a throwaway
dev cluster.)

**Rotating keys later:** re-run either option, then restart both consumers
so they pick up the new values:

```bash
kubectl -n grafana-dev rollout restart deploy/rustfs deploy/mimir
```

## Files

| File | Purpose |
| --- | --- |
| [rustfs-secret.yaml](rustfs-secret.yaml) | S3 access/secret keys shared by RustFS and Mimir (dev placeholders — see "Configuring the S3 credentials"). |
| [generate-rustfs-credentials.sh](generate-rustfs-credentials.sh) | One-command strong random credentials → `rustfs-credentials` Secret. |
| [generate-rustfs-certs.sh](generate-rustfs-certs.sh) | Self-signed CA + TLS cert for RustFS → `rustfs-tls` Secret. |
| [mimir-pvc.yaml](mimir-pvc.yaml) | Both PVCs: RustFS data (30Gi) and Mimir local WAL/cache (20Gi). |
| [rustfs-deployment.yaml](rustfs-deployment.yaml) / [rustfs-svc.yaml](rustfs-svc.yaml) | RustFS server, S3 API on **https://…:9000**, console on 9001. |
| [rustfs-create-buckets-job.yaml](rustfs-create-buckets-job.yaml) | One-shot Job creating the `mimir-blocks` + `mimir-ruler` buckets (idempotent). |
| [mimir-configmap.yaml](mimir-configmap.yaml) | Full Mimir config: monolithic (`target: all`), S3 backend pointed at RustFS, credentials expanded from env. |
| [mimir-deployment.yaml](mimir-deployment.yaml) / [mimir-svc.yaml](mimir-svc.yaml) | Mimir single-binary on 9009 (HTTP) / 9095 (gRPC), trusts the RustFS CA. |

## How the TLS trust works

1. `generate-rustfs-certs.sh` creates a **RustFS Dev CA** and signs a server
   cert whose SANs cover every in-cluster name of the service
   (`rustfs`, `rustfs.grafana-dev.svc.cluster.local`, …).
2. RustFS requires the files to be named exactly **`rustfs_cert.pem`** and
   **`rustfs_key.pem`** inside `RUSTFS_TLS_PATH` — the Secret and Deployment
   already use those names.
3. Mimir and the bucket Job mount only `ca.crt` from the same Secret and use
   it to verify RustFS (`http.tls_ca_path` in the Mimir config,
   `AWS_CA_BUNDLE` in the Job). No `insecure_skip_verify` anywhere.

In production, replace the Secret with your real cert/chain (same key names —
the command is in the header of `generate-rustfs-certs.sh`) and put your CA
chain in `ca.crt`.

## Deploy (in order)

```bash
# 0. Prereq: the grafana-dev namespace exists (main stack Step 2)

# 1. Credentials -- generate strong random keys (recommended):
./grafana-dev-mimir/generate-rustfs-credentials.sh
#    (or, dev-only: kubectl apply -f grafana-dev-mimir/rustfs-secret.yaml)

# 2. TLS cert for RustFS -> Secret rustfs-tls
./grafana-dev-mimir/generate-rustfs-certs.sh

# 3. Storage claims
kubectl apply -f grafana-dev-mimir/mimir-pvc.yaml

# 4. RustFS server
kubectl apply -f grafana-dev-mimir/rustfs-deployment.yaml -f grafana-dev-mimir/rustfs-svc.yaml
kubectl -n grafana-dev rollout status deploy/rustfs

# 5. Create Mimir's buckets
kubectl apply -f grafana-dev-mimir/rustfs-create-buckets-job.yaml
kubectl -n grafana-dev wait --for=condition=complete job/rustfs-create-buckets --timeout=120s

# 6. Mimir itself
kubectl apply -f grafana-dev-mimir/mimir-configmap.yaml \
              -f grafana-dev-mimir/mimir-deployment.yaml \
              -f grafana-dev-mimir/mimir-svc.yaml
kubectl -n grafana-dev rollout status deploy/mimir
```

(Or simply `kubectl apply -f grafana-dev-mimir/` after steps 1–2 — Kubernetes
retries until the ordering resolves itself; the explicit order above just
avoids transient errors.)

## Verify

```bash
kubectl -n grafana-dev get pods -l 'app in (rustfs, mimir)'
kubectl get --raw "/api/v1/namespaces/grafana-dev/services/mimir:9009/proxy/ready"
# RustFS console (browse buckets/objects):
kubectl -n grafana-dev port-forward svc/rustfs 9001:9001   # http://localhost:9001
```

## Wire it into the stack

Both swaps are pre-written as comments:

1. **Ingest** — in [../alloy-configmap.yaml](../alloy-configmap.yaml),
   `prometheus.remote_write` block: switch (or add as a second `endpoint` for
   dual-write) `url = "http://mimir.grafana-dev.svc.cluster.local:9009/api/v1/push"`,
   then `kubectl apply -f alloy-configmap.yaml && kubectl -n grafana-dev rollout restart deploy/alloy`.
2. **Query** — in [../grafana-configmap.yaml](../grafana-configmap.yaml):
   uncomment the Mimir datasource
   (`http://mimir.grafana-dev.svc.cluster.local:9009/prometheus`), then
   `kubectl apply -f grafana-configmap.yaml && kubectl -n grafana-dev rollout restart deploy/grafana`.

Dashboards keep working against Mimir — it's PromQL-compatible; just switch
the dashboard's datasource (or set the Mimir datasource as default).

## Links

| Use | URL |
| --- | --- |
| Mimir project / docs | https://grafana.com/oss/mimir/ · https://grafana.com/docs/mimir/latest/ |
| RustFS project / docs | https://rustfs.com · https://docs.rustfs.com |
| Grafana datasource (query) | `http://mimir.grafana-dev.svc.cluster.local:9009/prometheus` |
| Alloy remote_write (ingest) | `http://mimir.grafana-dev.svc.cluster.local:9009/api/v1/push` |
| RustFS S3 endpoint | `https://rustfs.grafana-dev.svc.cluster.local:9000` |

## Production notes

- **Change the credentials** in `rustfs-secret.yaml` (e.g. `openssl rand -base64 24`).
- **Real certs**: recreate `rustfs-tls` from your CA-signed chain (same Secret keys).
- **Storage classes**: swap `hostpath` for your class in `mimir-pvc.yaml` (Tanzu line is pre-commented).
- **Retention**: `compactor_blocks_retention_period` in the Mimir config (default here: 31 days).
- **Scale**: monolithic (`target: all`) is fine to start; for heavy load run multiple Mimir replicas or split into microservices — all modes share the same RustFS buckets. If you already have enterprise object storage (real S3, vSAN/MinIO, etc.), you can drop RustFS entirely and point the same Mimir config at it.
