# grafana-k8s

Plain-YAML Kubernetes manifests for a complete Grafana observability stack in a
single namespace, **`grafana-dev`**:

| App | Signal | Store/Role |
| --- | --- | --- |
| **Grafana** | UI | Dashboards + Explore, served over HTTPS (self-signed chain in dev). |
| **Loki** | Logs | Log store. |
| **Prometheus** | Metrics | Metrics store (remote-write receiver enabled). |
| **Tempo** | Traces | Trace store + service-graph metrics generator. |
| **Pyroscope** | Profiles | Continuous-profiling store. |
| **Alloy** | Collector | One agent that collects logs, metrics, traces, and profiles and fans them out to the stores above. |
| **Mimir** (optional) | Metrics | Scale-out Prometheus alternative, self-contained in [grafana-dev-mimir/](grafana-dev-mimir/). |

Sized for **Docker Desktop's built-in Kubernetes**; the same files carry to
production (Tanzu, etc.) by changing the clearly marked placeholders. No Helm,
no operators — just `kubectl apply`.

```
                     ┌──────────── you (https) ─────────────┐
                     ▼                                       │
 apps ──logs──►  ┌───────┐ ──►  Loki        ◄──queries── ┌─────────┐
 apps ──metrics► │ Alloy │ ──►  Prometheus  ◄──queries── │ Grafana │
 apps ──OTLP───► │       │ ──►  Tempo       ◄──queries── │  :443   │
 apps ──pprof──► └───────┘ ──►  Pyroscope   ◄──queries── └─────────┘
```

## Layout

All stack manifests live flat in the repo root (one application stack, one
directory). Each app has its own `<app>-configmap.yaml` / `<app>-deployment.yaml` /
`<app>-svc.yaml`; **all PVCs are in the single [pvcs.yaml](pvcs.yaml)**.
Extras: [certs/generate-certs.sh](certs/generate-certs.sh) (self-signed TLS),
[examples/alloy-external.alloy](examples/alloy-external.alloy) (collecting from
hosts outside Kubernetes), and [grafana-dev-mimir/](grafana-dev-mimir/)
(optional standalone Mimir, self-contained including its own PVC).

## Placeholders to replace for production

| Placeholder | Where | Replace with |
| --- | --- | --- |
| `grafana.example.com` | [grafana-configmap.yaml](grafana-configmap.yaml), cert script, external example | Real URL, or `https://<ip>:<port>` in `root_url`. |
| `loadBalancerIP: 10.0.0.100` | [grafana-svc-loadbalancer.yaml](grafana-svc-loadbalancer.yaml) | Your LB IP (Tanzu/NSX/MetalLB), or delete to auto-assign. |
| `storageClassName: hostpath` | [pvcs.yaml](pvcs.yaml), [grafana-dev-mimir/mimir-pvc.yaml](grafana-dev-mimir/mimir-pvc.yaml) | Docker Desktop's class; for Tanzu switch to the commented `tanzu-storage-computer` lines. |
| self-signed certs | [certs/generate-certs.sh](certs/generate-certs.sh) | Real chain: see the `kubectl create secret generic grafana-tls` command in [grafana-deployment.yaml](grafana-deployment.yaml). |
| `admin / admin` | [grafana-deployment.yaml](grafana-deployment.yaml) | Secret-backed `GF_SECURITY_ADMIN_PASSWORD`. |
| `cluster = "docker-desktop"` | [alloy-configmap.yaml](alloy-configmap.yaml), Tempo/Prometheus configs | Your cluster name. |

## Deploy: all steps, start to finish

### Step 1 — Prerequisites

Docker Desktop with Kubernetes enabled (Settings → Kubernetes → Enable) and
`openssl` installed.

```bash
kubectl config use-context docker-desktop
kubectl get nodes          # one Ready node
```

### Step 2 — Namespace

```bash
kubectl apply -f namespace.yaml          # creates grafana-dev
```

### Step 3 — All PVCs (one file)

```bash
kubectl apply -f pvcs.yaml
kubectl -n grafana-dev get pvc
```

On Tanzu, first swap `hostpath` for the commented `tanzu-storage-computer`.

### Step 4 — Self-signed certs (TLS simulation)

```bash
./certs/generate-certs.sh
```

Creates a dev CA, signs a cert for `grafana.example.com` (SANs include
`localhost` / `127.0.0.1`), builds the **full chain** (`fullchain.crt` =
server cert + CA), and creates the `grafana-tls` Secret carrying `tls.crt`
(chain), `tls.key`, and `ca.crt` — matching `cert_file` / `cert_key` /
`ca_cert` in `grafana.ini`. Outputs land in `certs/out/` (git-ignored).

### Step 5 — Storage backends

```bash
kubectl apply -f loki-configmap.yaml -f loki-deployment.yaml -f loki-svc.yaml
kubectl apply -f prometheus-configmap.yaml -f prometheus-deployment.yaml -f prometheus-svc.yaml
kubectl apply -f tempo-configmap.yaml -f tempo-deployment.yaml -f tempo-svc.yaml
kubectl apply -f pyroscope-configmap.yaml -f pyroscope-deployment.yaml -f pyroscope-svc.yaml
```

### Step 6 — Alloy (the collector)

```bash
kubectl apply -f alloy-rbac.yaml -f alloy-configmap.yaml -f alloy-deployment.yaml -f alloy-svc.yaml
```

Alloy immediately starts tailing **every pod's logs in every namespace**,
scraping **cadvisor container metrics**, and listening for OTLP traces.

### Step 7 — Grafana

```bash
kubectl apply -f grafana-configmap.yaml -f grafana-deployment.yaml
```

All five datasources (Prometheus, Loki, Tempo, Pyroscope — plus commented
Mimir) are auto-provisioned.

### Step 8 — Expose Grafana: pick ONE Service variant

```bash
# Option A -- LoadBalancer (Docker Desktop maps it to localhost;
# on Tanzu/MetalLB set loadBalancerIP in the file first):
kubectl apply -f grafana-svc-loadbalancer.yaml

# Option B -- ClusterIP + port-forward (no LB available):
kubectl apply -f grafana-svc-clusterip.yaml
```

Same Service name in both files — apply one. To switch later:
`kubectl -n grafana-dev delete svc grafana` then apply the other.

### Step 9 — Verify

```bash
kubectl -n grafana-dev get pods,svc,pvc
```

All pods `Running 1/1` within a couple of minutes (first run pulls images).

### Step 10 — Access

```bash
# Option A (LoadBalancer) on Docker Desktop:
open https://localhost/
#   simulate the DNS name too:
#   echo "127.0.0.1 grafana.example.com" | sudo tee -a /etc/hosts
#   open https://grafana.example.com/
# Option A on a real LB: https://10.0.0.100/ or https://grafana.example.com/

# Option B (port-forward):
kubectl -n grafana-dev port-forward svc/grafana 3000:3000
open https://localhost:3000/
```

Accept the self-signed-cert warning (or import `certs/out/ca.crt` into your
trust store). Login: `admin` / `admin` — change it on first login.

Side UIs:

```bash
kubectl -n grafana-dev port-forward svc/alloy 12345:12345        # Alloy UI
kubectl -n grafana-dev port-forward svc/prometheus 9090:9090     # Prometheus UI
kubectl -n grafana-dev port-forward svc/loki 3100:3100           # Loki API
kubectl -n grafana-dev port-forward svc/tempo 3200:3200          # Tempo API
kubectl -n grafana-dev port-forward svc/pyroscope 4040:4040      # Pyroscope UI
```

## Collecting from your applications

### Logs — Kubernetes (any namespace)

Nothing to do: Alloy discovers **all pods in all namespaces** through the
Kubernetes API and ships their stdout/stderr to Loki with `namespace`, `pod`,
`container`, `app`, and `node` labels. Query in Grafana → Explore → Loki:

```logql
{namespace="my-app-namespace"}                 # everything in a namespace
{namespace="payments", app="checkout"}         # one app
{namespace="payments"} |= "error"              # filter by content
```

### Metrics — Kubernetes (any namespace)

Two paths, both flowing into Prometheus via Alloy:

1. **Container metrics (automatic):** cadvisor CPU/memory/network for every
   pod, e.g. `container_memory_working_set_bytes{namespace="payments"}`.
2. **Application metrics (opt-in per pod):** expose `/metrics` and annotate
   the pod template — Alloy scrapes it automatically, whatever the namespace:

```yaml
template:
  metadata:
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "8080"       # your metrics port
      prometheus.io/path: "/metrics"   # optional (default /metrics)
```

### Traces — Kubernetes

Point your app's OTLP exporter at Alloy (works from any namespace):

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy.grafana-dev.svc.cluster.local:4318
```

Tempo's metrics generator also derives RED metrics + the Grafana service map
automatically.

### Profiles — Kubernetes

Copy the `pyroscope.scrape` block in [alloy-configmap.yaml](alloy-configmap.yaml)
and point it at any service exposing Go `/debug/pprof` (or push directly with
a Pyroscope SDK to `http://pyroscope.grafana-dev.svc.cluster.local:4040`).

### Applications OUTSIDE Kubernetes (VMs, bare metal)

Install Alloy on the external host and run it with
[examples/alloy-external.alloy](examples/alloy-external.alloy). It collects:

- **logs** from local files (`/var/log/...`) → Loki
- **host metrics** (node-exporter equivalent) + local app `/metrics` → Prometheus
- **OTLP traces** from local apps → Tempo
- **pprof profiles** → Pyroscope

Edit the `CHANGE:` markers: the host label and the four backend endpoints.
For a local simulation, port-forward the four stores and use `localhost`
endpoints (commands are in the example file); in production, expose the ingest
endpoints (LoadBalancer/Ingress) and use those URLs instead.

## Production on Tanzu: how log collection changes

Alloy can get pod logs two ways, and this repo ships both:

| | Dev (this repo's default) | Production Tanzu ([examples/alloy-logs-daemonset-tanzu.yaml](examples/alloy-logs-daemonset-tanzu.yaml)) |
| --- | --- | --- |
| Component | `loki.source.kubernetes` in [alloy-configmap.yaml](alloy-configmap.yaml) | `loki.source.file` reading `/var/log/pods` |
| How | Streams logs through the Kubernetes API server (like `kubectl logs`) | One Alloy pod per node tails that node's log files directly |
| Runs as | Single-replica Deployment, unprivileged | DaemonSet, root + hostPath (needs privileged namespace) |
| Good for | Single node (Docker Desktop), restricted clusters | Multi-node production — scales with nodes, no API-server load |

To switch on Tanzu:

1. TKG v1.26+ enforces the `restricted` Pod Security profile on namespaces by
   default, which blocks hostPath volumes. Allow it (label is also prepared,
   commented, in [namespace.yaml](namespace.yaml)):
   ```bash
   kubectl label --overwrite ns grafana-dev pod-security.kubernetes.io/enforce=privileged
   ```
2. Remove the LOGS section from [alloy-configmap.yaml](alloy-configmap.yaml)
   (so logs aren't collected twice) — the main Alloy Deployment keeps doing
   metrics, OTLP traces, and profiles.
3. `kubectl apply -f examples/alloy-logs-daemonset-tanzu.yaml`

Everything downstream (Loki, dashboards, queries) is identical in both modes.

## Optional: Mimir instead of Prometheus

[grafana-dev-mimir/](grafana-dev-mimir/) is a self-contained, scale-out
metrics store (same `grafana-dev` namespace, own PVC included):

```bash
kubectl apply -f grafana-dev-mimir/
```

Then point ingestion and queries at it — both swaps are pre-written as
comments: the `remote_write` URL in [alloy-configmap.yaml](alloy-configmap.yaml)
and the Mimir datasource in [grafana-configmap.yaml](grafana-configmap.yaml).

## Teardown

```bash
kubectl delete namespace grafana-dev
kubectl delete clusterrole alloy clusterrolebinding alloy
```

## License

Licensed under the [Apache License 2.0](LICENSE).
