# Correlation — the reason to run LGTM instead of four tools

Four signals are only worth co-locating if you can **pivot between them**: from
a spiking metric to the trace that caused it, from that trace to the logs of the
exact request, and from there to a CPU profile.

## Where this stack actually is

| Link | Mechanism | Status |
| --- | --- | --- |
| Trace → Logs | Tempo `tracesToLogsV2` | ✅ configured |
| Trace → Metrics | Tempo `tracesToMetrics` | ⚠️ `serviceMap` only |
| **Log → Trace** | Loki `derivedFields` | ❌ **missing** — the most-used jump |
| **Metric → Trace** | exemplars | ❌ **broken in 3 places** (below) |
| **Trace → Profile** | Tempo `tracesToProfiles` | ❌ missing |

Verified from [grafana-configmap.yaml](../grafana-configmap.yaml): Loki,
Prometheus, Mimir, and Pyroscope datasources carry **no** correlation config at
all.

## 1. Log → Trace (Loki `derivedFields`)

Turns a trace ID in a log line into a clickable link to Tempo.

```yaml
# in datasources.yaml, the Loki datasource
    jsonData:
      derivedFields:
        - name: TraceID
          matcherType: regex               # default when omitted
          matcherRegex: 'trace_?[Ii][Dd]=(\w+)'   # capture group 1 = the value
          datasourceUid: tempo
          url: '$${__value.raw}'
          urlDisplayLabel: 'View Trace'
```

Two matcher types, and the difference matters:

- **`regex`** (default) — `matcherRegex` runs against the **log line**; capture
  group 1 is the trace ID.
- **`label`** — `matcherRegex` matches **label keys** (indexed, parsed, or
  structured metadata), and that key's *value* is used. For OTLP logs where the
  ID is a label, one pattern covers both spellings:

```yaml
        - name: TraceID
          matcherType: label
          matcherRegex: 'trace[_]?id'      # matches traceid AND trace_id
          datasourceUid: tempo
          url: '$${__value.raw}'
```

> **`$${__value.raw}` — the double `$` is mandatory** in provisioning files;
> Grafana interpolates a single `$` as an env var. When `datasourceUid` is set,
> `url` is treated as a **query** against that datasource, not a URL.
>
> **Use one or the other**, not both — Grafana groups derived fields by
> `name` and takes the first, so two fields named `TraceID` will collide.

## 2. Metric → Trace (exemplars)

An exemplar is a trace ID attached to a histogram sample: click the diamond on a
latency spike, land in the trace that *was* that spike.

### This repo breaks it in three places

Each failure is **silent** — no error, no rejection metric, just no diamonds.

**(a) Tempo never sends them.** In
[tempo-configmap.yaml](../tempo-configmap.yaml) `send_exemplars` is commented
out, and the upstream default is **`false`**:

```yaml
metrics_generator:
  storage:
    remote_write:
      - url: http://prometheus.grafana-dev.svc.cluster.local:9090/api/v1/write
        send_exemplars: true      # <- REQUIRED. Default false. Currently commented out.
```

**(b) Prometheus would drop them anyway.**
[prometheus-deployment.yaml](../prometheus-deployment.yaml) has
`--web.enable-remote-write-receiver` and `--web.enable-lifecycle`, but **not**:

```yaml
args:
  - --enable-feature=exemplar-storage    # <- REQUIRED, still gated in Prometheus 3.x
```

This flag did **not** graduate in 3.0. Without it, `AppendExemplar` returns
early — a no-op that drops exemplars from **every** path (scrape, remote-write,
OTLP) with no error. Optionally tune the global circular buffer (it's read only
when the flag is on):

```yaml
storage:
  exemplars:
    max_exemplars: 100000     # default 100000; <=0 disables
```

**(c) Grafana has no link destination:**

```yaml
# Prometheus datasource
    jsonData:
      exemplarTraceIdDestinations:
        - name: traceID              # the exemplar's LABEL KEY -- see below
          datasourceUid: tempo
          urlDisplayLabel: 'View Trace'
```

> ### ⚠️ `traceID`, not `trace_id`
> Tempo's generator labels exemplars with `traceID` (`trace_id_label_name`
> default) — Tempo's own docs note this "is different to the OTEL convention."
> If exemplars come from your app's OpenMetrics endpoint instead, OTel SDKs
> typically emit `trace_id`. **A mismatch here is the single most common reason
> exemplar links silently fail.**

**If you use Mimir**, it drops exemplars by default too:

```yaml
limits:
  max_global_exemplars_per_user: 100000    # default 0 = ingestion DISABLED (experimental)
```

**Alloy needs nothing** — `send_exemplars` defaults to **`true`** in its
`endpoint` block (a real divergence from upstream Prometheus remote_write, which
defaults to `false`). `prometheus.scrape` has no exemplar option; collection is
implicit via OpenMetrics protocol negotiation.

### End-to-end checklist

Every hop is a silent failure point:

| # | Component | Action | Default |
| --- | --- | --- | --- |
| 1 | App **or** Tempo generator | produce exemplars | — |
| 2 | Alloy scrape | nothing | OpenMetrics negotiated |
| 3 | Alloy remote_write | nothing | `send_exemplars = true` ✅ |
| 4 | **Tempo generator** | `send_exemplars: true` | **false** ❌ |
| 5 | **Prometheus** | `--enable-feature=exemplar-storage` | **off** ❌ |
| 6 | Mimir (if used) | `max_global_exemplars_per_user: 100000` | **0** ❌ |
| 7 | **Grafana** | `exemplarTraceIdDestinations[].name` matching #4 | — ❌ |

> **`traces_spanmetrics_calls_total` will NEVER carry exemplars** — Tempo's
> counter implementation has a literal `// TODO: support exemplars`. Only
> histograms do. Hang exemplar links off
> **`traces_spanmetrics_latency_bucket`**, never `calls_total`.

## 3. Trace → Profile (`tracesToProfiles`)

```yaml
# Tempo datasource
    jsonData:
      tracesToProfiles:
        datasourceUid: 'pyroscope'
        tags: [{ key: 'service.name', value: 'service_name' }]
        profileTypeId: 'process_cpu:cpu:nanoseconds:cpu:nanoseconds'
        customQuery: false
```

`tags` `value` is a **rename target, not a match value**:
`{key: 'service.name', value: 'service_name'}` means "read span attribute
`service.name`, emit as Pyroscope label `service_name`". Bare `{key: 'job'}`
keeps the name. `customQuery: true` switches to a raw `query` selector instead.

**Config alone isn't enough — the app must be instrumented.** Two distinct
things are required:

| Thing | Kind | Role |
| --- | --- | --- |
| `pyroscope.profile.id` | span **attribute** | Grafana renders the link only if present |
| **`span_id`** | pprof **label** on the profile | the actual server-side join key |

You need **three** pieces: the Pyroscope SDK, the OTel SDK, **and** the language
bridge — "without this package, traces and profiles are independent signals with
no connection between them."

| Language | Bridge |
| --- | --- |
| Go | `github.com/grafana/otel-profiling-go` → `otel.SetTracerProvider(otelpyroscope.NewTracerProvider(tp))` |
| Java | `grafana/otel-profiling-java` agent extension + `OTEL_PYROSCOPE_START_PROFILING=true` |
| Python | `pyroscope-otel` → `provider.add_span_processor(PyroscopeSpanProcessor())` |

Gotchas:
- Labels are set on the **local root span only** (first span created in that
  process) by default. Go can widen via `WithSpanIDLabelScope(ScopeAllSpans)` —
  at significant cardinality cost.
- **Spans shorter than ~20ms often have no samples** — CPU time below the
  sample interval means nothing was collected. The attribute's presence doesn't
  guarantee a profile exists.
- The Pyroscope datasource type must be exactly `grafana-pyroscope-datasource`
  or the link is silently suppressed.
- Go supports **CPU profiling only** for this correlation.
- In pull mode, Pyroscope's `service_name` must match OTel's `service.name`.

## 4. Trace → Metrics (`tracesToMetrics`)

```yaml
# Tempo datasource
    jsonData:
      tracesToMetrics:
        datasourceUid: 'prometheus'
        spanStartTimeShift: '-2m'
        spanEndTimeShift: '2m'
        tags: [{ key: 'service.name', value: 'service' }, { key: 'job' }]
        queries:
          - name: 'Request rate'
            query: 'sum(rate(traces_spanmetrics_calls_total{$$__tags}[5m]))'
          - name: 'p99 latency'
            query: 'histogram_quantile(0.99, sum(rate(traces_spanmetrics_latency_bucket{$$__tags}[5m])) by (le))'
      serviceMap:
        datasourceUid: 'prometheus'
      nodeGraph:
        enabled: true
```

`$$__tags` is the provisioning-escaped form of `$__tags`. The time shifts have
no stored default (the UI shows `-2m`/`2m` as placeholders only). This needs no
metrics-generator — any Prometheus-compatible source works.

### The metric names (this trips everyone)

| Metric | Type | Note |
| --- | --- | --- |
| `traces_spanmetrics_latency` | histogram | ✅ use `_bucket` for exemplars |
| `traces_spanmetrics_calls_total` | counter | ✅ no exemplars, ever |
| `traces_spanmetrics_size_total` | counter | |
| `traces_target_info` | — | opt-in (`enable_target_info`) |
| ~~`traces_spanmetrics_duration_seconds`~~ | — | ❌ **dead since Tempo 1.5 (2022)** |

The rename went `duration_seconds` → **`latency`**. Tempo's source still has a
constant *named* `metricDurationSeconds` whose *value* is
`"traces_spanmetrics_latency"` — that fossil is why the old name persists in so
many blog posts.

Service graphs: `traces_service_graph_request_total`,
`traces_service_graph_request_failed_total`,
`traces_service_graph_request_{server,client}_seconds` (all labelled `client`,
`server`, `connection_type`). Note `service-graphs-connection-info` and
messaging-system metrics are **opt-in** — bare `service-graphs` doesn't include
them.

> `metrics_ingestion_time_range_slack` defaults to **30s** — spans older than
> that are **silently dropped** by the generator. A very common "why are there
> no span metrics" cause.
>
> `lokiSearch` was **removed** from the Tempo datasource — don't add it.

## Applying this to the repo

Roughly, in [grafana-configmap.yaml](../grafana-configmap.yaml) add
`derivedFields` to Loki and `exemplarTraceIdDestinations` to Prometheus/Mimir;
extend the Tempo datasource with `tracesToMetrics` + `tracesToProfiles`. Then
uncomment `send_exemplars: true` in [tempo-configmap.yaml](../tempo-configmap.yaml)
and add `--enable-feature=exemplar-storage` to
[prometheus-deployment.yaml](../prometheus-deployment.yaml).

Restart order matters only in that Grafana re-reads provisioning on restart:

```bash
kubectl -n grafana-dev rollout restart deploy/tempo deploy/prometheus deploy/grafana
```

### Verifying each link

```bash
# exemplars actually stored? (empty = broken somewhere in the 7-step chain)
curl -s '.../api/v1/query_exemplars?query=traces_spanmetrics_latency_bucket&start=...&end=...'

# span metrics being produced at all?
curl -s '.../api/v1/query?query=traces_spanmetrics_calls_total'
```

In the UI: a metric→trace link is working when latency panels show **diamond
markers**. Log→trace works when a Loki log row expands to show a **TraceID**
field with a "View Trace" button.

## Sources

- [Loki datasource / derivedFields](https://grafana.com/docs/grafana/latest/datasources/loki/)
- [Prometheus datasource / exemplars](https://grafana.com/docs/grafana/latest/datasources/prometheus/configure/) · [feature flags](https://prometheus.io/docs/prometheus/latest/feature_flags/) · [`<exemplars>` config](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#exemplars)
- [Tempo: trace to profiles](https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/configure-trace-to-profiles/) · [span metrics](https://grafana.com/docs/tempo/latest/metrics-from-traces/span-metrics/span-metrics-metrics-generator/) · [service graphs](https://grafana.com/docs/tempo/latest/metrics-from-traces/service_graphs/)
- [Alloy prometheus.remote_write](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.remote_write/) · [Mimir exemplars](https://grafana.com/docs/mimir/latest/manage/use-exemplars/store-exemplars/)
- [otel-profiling-go](https://github.com/grafana/otel-profiling-go)

> **Version note:** Tempo's `/latest/` docs now describe a Kafka-based
> generator (`consume_from_kafka`, `ring_mode: partition`). If you're pinned to
> an older Tempo (this repo uses **2.8.1**), verify against that version's docs,
> not `/latest/`.
