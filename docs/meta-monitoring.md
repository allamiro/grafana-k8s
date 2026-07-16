# Meta-monitoring — who watches the watchers

Dashboards and alerts for the stack's **own** components (Loki, Tempo, Mimir,
Alloy, Grafana), using the official Grafana **mixins**.

> ### ⚠️ Start here: this stack currently collects none of these metrics
>
> Verified on a live deploy — Prometheus contains exactly **two** jobs:
> ```
> $ curl .../api/v1/label/job/values
> ["prometheus", "prometheus.scrape.cadvisor"]
> ```
> Alloy discovers app metrics **only** from pods annotated
> `prometheus.io/scrape: "true"` ([alloy-configmap.yaml](../alloy-configmap.yaml)),
> and **no component in this stack carries that annotation** — so
> `loki_request_duration_seconds`, `tempo_ring_members`, and `cortex_*` return
> no series.
>
> The data is there, just unharvested. Measured from the running pods:
>
> | Component | `/metrics` exposed | Scraped? |
> | --- | --- | --- |
> | Loki | ~1,475 lines (119 × `loki_request_duration_seconds`) | ❌ |
> | Pyroscope | ~1,497 lines | ❌ |
> | Mimir | ~1,423 lines (1,916 × `cortex_*`) | ❌ |
> | Alloy | ~643 lines | ❌ |
> | Tempo | ~457 lines | ❌ |
>
> **Every mixin dashboard and alert below renders empty until you fix this.**
> Not a label problem — the metrics were never collected. See
> [Step 1](#step-1-scrape-the-stack-itself).

## Step 1 — Scrape the stack itself

Add to each component's **pod template** (`spec.template.metadata.annotations`):

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port:   "3100"      # per component, see table
  prometheus.io/path:   "/metrics"  # optional; /metrics is the default
```

| Component | Port | Notes |
| --- | --- | --- |
| Loki | 3100 | |
| Tempo | 3200 | |
| Pyroscope | 4040 | |
| Mimir | 9009 | |
| Alloy | 12345 | its own `/metrics` |
| Grafana | 3000 | **serves HTTPS here** — needs a `scheme: https` scrape, not the plain annotation path |
| Prometheus | 9090 | already self-scrapes via its own `scrape_configs` |

RustFS is an S3 store, not a Prometheus target — skip it.

**Cost:** this adds roughly 5,000+ series. Fine for a dev box; size your
retention accordingly in production.

## Step 2 — The label contract (mixins are strict)

Mixins don't query raw metrics; they aggregate `by (cluster, namespace, job)`.
Get these wrong and dashboards render **empty with no error** — the classic
silent failure.

From each mixin's `config.libsonnet` (the authoritative source):

| Mixin | cluster | namespace | job | instance |
| --- | --- | --- | --- | --- |
| Loki | `cluster` | `namespace` | `job` | `pod` (+ `container`) |
| Mimir | `cluster` | `namespace` | `job` | `pod` |
| Tempo | `cluster` | `namespace` | `job` | — |
| Alloy | `cluster` | `namespace` | `job` | `instance` |

Three requirements, and this stack meets only the first:

1. **`cluster`** — ✅ already set. Alloy's `external_labels` adds
   `cluster="docker-desktop"` (verified present on shipped series). Change it
   per environment in [alloy-configmap.yaml](../alloy-configmap.yaml).
2. **`namespace`** — ✅ the `metrics_pods` relabel already sets it from
   `__meta_kubernetes_namespace`.
3. **`job` must be `<namespace>/<component>`** — ❌ **not** what Alloy produces.
   Mimir's docs are explicit: monolithic → `<namespace>/mimir`; microservices →
   `<namespace>/<component>` (e.g. `grafana-dev/distributor`). Loki and Tempo
   follow the same convention.

So add a relabel rule rewriting `job` for the stack's own pods:

```alloy
// in discovery.relabel "metrics_pods"
rule {
  source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_label_app"]
  separator     = "/"
  target_label  = "job"          // -> "grafana-dev/loki", "grafana-dev/mimir", ...
}
```

> Alloy does **not** attach `cluster` by default — this stack's
> `external_labels` is what supplies it. Keep that if you rebuild the config.

## Step 3 — Get the dashboards

### There are (mostly) no grafana.com IDs

An enumeration of the Grafana Labs org (`grafana.com/api/dashboards?orgSlug=grafana`,
59 dashboards) contains **zero** official Loki, Tempo, Alloy, or Pyroscope
meta-monitoring dashboards. Don't hunt for a "Loki official" ID — it doesn't
exist. They ship **only** as repo mixins.

| Source | Available as |
| --- | --- |
| **Mimir** | ✅ 25 grafana.com IDs **and** repo mixin |
| **Grafana** | ✅ ID **24838** "Grafana Internal Metrics" |
| **Loki / Tempo / Alloy** | ❌ repo mixin only |
| **Pyroscope** | ❌ no mixin or dashboards found |

**Mimir by ID** (all Prometheus datasource): `17607` Overview · `16026` Writes ·
`16016` Reads · `16013` Queries · `16009` Compactor · `16018` Ruler · `16011`
Object Store · `16019` Scaling · `16021` Tenants · `16020` Slow queries
(*needs Loki + Prometheus*) · plus resources/networking variants
(16006–16026, 17605–17609).
URL form: <https://grafana.com/grafana/dashboards/17607-mimir-overview/>

### Mixin repo paths (verified)

```bash
# Loki — 13 dashboards
git clone --depth 1 https://github.com/grafana/loki
ls loki/production/loki-mixin-compiled/dashboards/

# Tempo — 9 dashboards
ls tempo/operations/tempo-mixin-compiled/dashboards/

# Mimir — 27 dashboards
ls mimir/operations/mimir-mixin-compiled/dashboards/

# Alloy — 9 dashboards. NOTE: 'rendered/', NOT the '-compiled' convention
ls alloy/operations/alloy-mixin/rendered/dashboards/
```

Alloy also publishes a release artifact: `alloy-mixin-dashboards-<TAG>.zip`.

### Searching the catalog

The browse page is a client-side SPA; **use the API for anything scripted**
(and note the param is `dataSourceSlugIn`, *not* `dataSource`):

```bash
curl -s 'https://grafana.com/api/dashboards?filter=mimir'          # by text (param is filter=)
curl -s 'https://grafana.com/api/dashboards?dataSourceSlugIn=loki' # by datasource
curl -s 'https://grafana.com/api/dashboards?orgSlug=grafana'       # official only
```

Valid datasource slugs: `prometheus`, `loki`, `tempo`,
`grafana-pyroscope-datasource`. (`pyroscope` alone 404s; `mimir`/`alloy` aren't
datasources.) A `200` from that site proves nothing — bogus params still return
the SPA shell.

## Step 4 — Recording rules (or 10 dashboards stay blank)

Loki and Mimir dashboards query **recording rules**, not raw metrics. Install
`rules.yaml` into Prometheus or **these render empty**:

| Mixin | rules | Dashboards that break without them |
| --- | --- | --- |
| **Loki** | 18 records, group `loki_rules` | `loki-operational`, `loki-reads`, `loki-writes`, `loki-bloom-gateway` |
| **Mimir** | **122 records, 16 groups** | `mimir-alertmanager`, `mimir-queries`, `mimir-writes`, `mimir-overview`, `mimir-reads`, `mimir-scaling` |
| **Tempo** | rules exist, but **no dashboard uses them** | none — dashboards work as-is (rules back `alerts.yaml`) |
| **Alloy** | none ship | none |

Install into Prometheus:

```bash
kubectl -n grafana-dev create configmap loki-mixin-rules \
  --from-file=loki/production/loki-mixin-compiled/rules.yaml \
  --from-file=loki/production/loki-mixin-compiled/alerts.yaml
# mount at /etc/prometheus/rules/ and add to prometheus.yml:
#   rule_files:
#     - /etc/prometheus/rules/*.yaml
```

Into Mimir's ruler instead: `mimirtool rules load rules.yaml alerts.yaml`
(mixin files lack the `namespace:` key mimirtool wants — add it).

> **Two Loki dashboards stay broken no matter what.** `loki-deletion` needs
> `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate`
> (from **kubernetes-mixin**, not Loki's rules), and `loki-bloom-build` needs
> `loki_cell:bytes:rate1m` (a Grafana-internal rule that ships nowhere). Not
> your fault — don't debug them.

## Step 5 — Provision them

This repo already provisions [dashboards/](../dashboards/) via
[grafana-dashboards-configmap.yaml](../grafana-dashboards-configmap.yaml). Add
mixin dashboards the same way:

```yaml
apiVersion: 1
providers:
  - name: mixins
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10        # see below
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true   # subdirs -> Grafana folders (Loki/, Tempo/, ...)
```

**`updateIntervalSeconds` semantics matter:**
- **≤ 10** → Grafana **watches the filesystem** and updates on change.
- **> 10** → Grafana **polls** at that interval.

Watch mode is what makes ConfigMap-mounted dashboards pick up edits — kubelet's
own ConfigMap propagation is ~60s on top.

⚠️ With `disableDeletion: false`, removing a provisioning source **deletes** the
dashboard from Grafana's DB.

## Customising labels instead of relabeling

If you can't reshape `job`/`cluster` at scrape time, regenerate the mixin with
different matchers:

```bash
jb init && jb install github.com/grafana/mimir/operations/mimir-mixin@main
# override _config.per_cluster_label / per_job_label ...
make build-mixin
```

## Alloy self-monitoring

`operations/alloy-mixin/` — 9 dashboards (cluster-node, cluster-overview,
controller, logs, loki, opentelemetry, otel-engine-overview,
**prometheus-remote-write**, resources) plus `rendered/alerts/`. No recording
rules needed; only a Prometheus datasource.

`alloy-prometheus-remote-write` is the one to reach for when metrics stop
arriving — it graphs the `prometheus_remote_storage_*` queues (see
[alerting.md](alerting.md)).

Config knobs (`config.libsonnet`): `enableK8sCluster` (default true — injects
the `$cluster`/`$namespace` vars), `filterSelector` (e.g.
`job=~"integrations/alloy"`), and `logsFilterSelector` — **set the last one**
(e.g. `service_name="alloy"`) or the `alloy-logs` dashboard shows unrelated
platform logs.

## Verify it worked

```bash
# 1. the stack's own components are now targets
curl -s .../api/v1/label/job/values          # expect grafana-dev/loki, grafana-dev/mimir, ...

# 2. a mixin-critical series exists AND carries the required labels
curl -s '.../api/v1/query?query=loki_request_duration_seconds_count'   # cluster? namespace? job?

# 3. a recording rule is materialising
curl -s '.../api/v1/query?query=cluster_job_route:loki_request_duration_seconds:sum_rate'
```

If (2) returns series but a dashboard is still blank, it's the **label
contract** ([Step 2](#step-2--the-label-contract-mixins-are-strict)). If (3) is
empty, it's **recording rules** ([Step 4](#step-4--recording-rules-or-10-dashboards-stay-blank)).

## Sources

- [Loki mixin](https://github.com/grafana/loki/tree/main/production/loki-mixin-compiled) · [docs](https://grafana.com/docs/loki/latest/operations/meta-monitoring/mixins/)
- [Tempo mixin](https://github.com/grafana/tempo/tree/main/operations/tempo-mixin-compiled) · [docs](https://grafana.com/docs/tempo/latest/operations/monitor/set-up-monitoring/)
- [Mimir mixin](https://github.com/grafana/mimir/tree/main/operations/mimir-mixin-compiled) · [requirements](https://grafana.com/docs/mimir/latest/manage/monitor-grafana-mimir/requirements/) · [installing](https://grafana.com/docs/mimir/latest/manage/monitor-grafana-mimir/installing-dashboards-and-alerts/)
- [Alloy mixin](https://github.com/grafana/alloy/tree/main/operations/alloy-mixin) · [import guide](https://grafana.com/docs/alloy/latest/troubleshoot/import-mixin-dashboards/)
- [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
