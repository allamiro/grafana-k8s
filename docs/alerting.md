# Alerting

This stack has **no alerting at all** today — no Alertmanager, no rules. A
monitoring stack that can't page you is half a stack. This is how to close that.

- [Pick a path](#pick-a-path-grafana-managed-vs-datasource-managed)
- [Option A — Grafana-managed (recommended here)](#option-a--grafana-managed-recommended-here)
- [Option B — Prometheus rules + Alertmanager](#option-b--prometheus-rules--alertmanager)
- [Starter alerts](#starter-alerts)
- [Mixin alerts](#mixin-alerts)
- [Gotchas](#gotchas)

## Pick a path — Grafana-managed vs datasource-managed

| | **(A) Grafana-managed** | **(B) Prometheus/Mimir-managed** |
| --- | --- | --- |
| Rules stored in | Grafana's DB | Prometheus `rule_files` / Mimir ruler |
| Evaluated by | Grafana | Prometheus / Mimir ruler |
| Can query | **any** datasource — incl. **Loki**, Tempo | only that datasource's own TSDB |
| Multi-datasource + expressions | ✅ reduce/math/threshold | ❌ |
| Editable in Grafana UI | ✅ | Mimir/Loki ✅ · **Prometheus: view-only** |
| Needs Alertmanager deployed | ❌ (Grafana has one built in) | ✅ |

**Recommendation for this stack: (A).** You're single-tenant with one
Prometheus and no ruler. (A) is the only path that can alert on **logs** (Loki),
needs no extra component, and avoids the Prometheus view-only limitation —
under (B) you'd hand-edit ConfigMaps while Grafana's UI shows the rules but
refuses to edit them. Grafana's own guidance calls Grafana-managed "the
recommended option… richer feature set" and notes data-source-managed "can
introduce more operational complexity." As of 2026 it's also the default in new
Grafana stacks.

Revisit (B) if you adopt Mimir's ruler for HA/scale.

> **Does Alloy-scrapes-and-remote-writes change where rules live?** No. Samples
> that arrive via `--web.enable-remote-write-receiver` land in Prometheus's
> **local TSDB**, so `rule_files` evaluate against them normally. Both paths
> work. (`--web.enable-remote-write-receiver` is a stable flag, not a feature
> gate — though it's absent from the feature-flags page.)

## Option A — Grafana-managed (recommended here)

### 1. Config

[grafana-configmap.yaml](../grafana-configmap.yaml) already has
`[unified_alerting] enabled = true`. Worth adding:

```ini
[unified_alerting]
enabled = true
execute_alerts = true          # false = rules visible in UI but never evaluated
min_interval = 10s             # floor on per-rule frequency
evaluation_timeout = 30s

# Free alert-state history in the Loki you already run:
[unified_alerting.state_history]
enabled = true
backend = loki
loki_remote_url = http://loki.grafana-dev.svc.cluster.local:3100
```

⚠️ If you ever run **more than one Grafana replica**, set `ha_peers` and keep
`ha_reconnect_timeout` **under 15m** on Kubernetes.

### 2. Provision rules as code

Mount into `/etc/grafana/provisioning/alerting/`. Grafana scans it at startup.

A Grafana-managed rule is a **pipeline**: `A` (query) → `B` (reduce) → `C`
(threshold), with `condition: C`.

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: stack_health
    folder: Stack
    interval: 1m
    rules:
      - uid: target_down
        title: Target down
        condition: C
        for: 5m
        noDataState: NoData
        execErrState: Error
        labels:
          severity: critical
        annotations:
          summary: '{{ $labels.instance }} has been down for 5m'
        data:
          - refId: A
            relativeTimeRange: { from: 600, to: 0 }
            datasourceUid: prometheus          # this repo's Prometheus UID
            model:
              datasource: { type: prometheus, uid: prometheus }
              expr: 'up == 0'
              instant: true
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: reduce
              reducer: last
              expression: A
              refId: B
          - refId: C
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: threshold
              expression: B
              refId: C
              conditions:
                - evaluator: { params: [0], type: gt }
```

> **Get this exact YAML the easy way.** There is no official
> file-provisioning example using a real Prometheus datasource (Grafana's ship
> `testdata`/`__expr__` only), so the block above is adapted, not copied from a
> doc. **Ground truth: build one rule in the UI, then Export → YAML.** Do that
> before hand-writing a pile of them.
>
> Also: `relativeTimeRange` accepts **fixed relative ranges only**. And the
> `export` API's JSON is *not* the same shape the HTTP API accepts for updates —
> don't round-trip blindly.

### 3. Contact points + routing

```yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: Platform Email
    receivers:
      - uid: platform_email
        type: email
        settings:
          addresses: platform@example.com
policies:
  - orgId: 1
    receiver: Platform Email
    group_by: [grafana_folder, alertname]
    routes:
      - receiver: Platform Email
        object_matchers:
          - ['severity', '=', 'critical']
muteTimes:
  - orgId: 1
    name: no_weekends
    time_intervals:
      - weekdays: [saturday, sunday]
```

Types available include `email`, `slack`, `pagerduty`, `opsgenie`, `webhook`,
`teams`, `jira`, `mqtt`, `sns`, `telegram`, and `prometheus-alertmanager` (to
forward into an external Alertmanager).

⚠️ `$VAR` interpolation works in provisioning files, but **not** inside
annotations, time ranges, query models, or template content.

⚠️ Mount these from a **ConfigMap** at `/etc/grafana/provisioning/alerting/`.
Grafana's own `kubernetes/grafana.yaml` example mounts an *empty PVC* over
`/etc/grafana/provisioning` — copying it silently gives you no provisioning.

## Option B — Prometheus rules + Alertmanager

Only if you want rules evaluated outside Grafana.

```yaml
# alertmanager.yml
route:
  receiver: default
  group_by: [cluster, alertname]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
receivers:
  - name: default
```

Image `quay.io/prometheus/alertmanager`, port **9093** (web), **9094**
(cluster — needs **TCP *and* UDP**; empty `--cluster.listen-address` disables
HA).

Point Prometheus at it ([prometheus-configmap.yaml](../prometheus-configmap.yaml)
already carries these as commented blocks):

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager.grafana-dev.svc.cluster.local:9093']
rule_files:
  - /etc/prometheus/rules/*.yaml
```

⚠️ For HA, list **every** Alertmanager in `static_configs` — the docs are
explicit: **do not put them behind a load balancer**.

**Mimir's built-in Alertmanager** is worth it only for **multi-tenancy** (a
separate routing config + UI per tenant) or sharded HA. Overkill for one
namespace.

## Starter alerts

Every metric name below was verified to exist in *this* stack.

```yaml
groups:
  - name: stack_starter
    rules:
      # `up` is emitted by ALLOY's scraper and remote_written in — it works here.
      - alert: TargetDown
        expr: up == 0
        for: 5m
        labels: { severity: critical }

      # The single most important alert here: if this fires, you are blind.
      - alert: AlloyRemoteWriteFailing
        expr: rate(prometheus_remote_storage_samples_failed_total[5m]) > 0
        for: 10m
        labels: { severity: critical }

      - alert: AlloyRemoteWriteBacklog
        expr: prometheus_remote_storage_samples_pending > 0
        for: 15m
        labels: { severity: warning }

      - alert: LokiDiscardingSamples
        expr: sum by (tenant, reason) (rate(loki_discarded_samples_total[5m])) > 0
        for: 10m
        labels: { severity: warning }

      - alert: TempoCompactionsFailing
        expr: |
          sum by (cluster, namespace) (increase(tempodb_compaction_errors_total[1h])) > 2
        for: 1h
        labels: { severity: critical }

      - alert: MimirIngesterUnhealthy
        expr: min by (cluster, namespace) (cortex_ring_members{state="Unhealthy", name="ingester"}) > 0
        for: 15m
        labels: { severity: critical }
```

> ⚠️ **All of these except `TargetDown` need
> [meta-monitoring](meta-monitoring.md) turned on first** — `loki_*`, `tempo*`,
> and `cortex_*` are not collected today, so they'd evaluate to empty forever
> (silently: an alert that never fires looks identical to a healthy one).

**Prometheus tolerates a ~2h remote-write outage** without data loss, so
`for: 10m` on remote-write failure leaves plenty of margin.

K8s-level alerts (`KubePodCrashLooping`, `KubePersistentVolumeFillingUp`) need
**kube-state-metrics** and **kubelet** scraped with `job="kube-state-metrics"`
and `job="kubelet"` — neither is deployed here (see the commented
kube-state-metrics block in [alloy-configmap.yaml](../alloy-configmap.yaml)).

## Mixin alerts

Loki, Tempo, and Mimir each ship `alerts.yaml` next to their dashboards:

| Mixin | alerts | recording rules required? |
| --- | --- | --- |
| Loki | `production/loki-mixin-compiled/alerts.yaml` | **yes** — e.g. `LokiRequestLatency` reads `cluster_namespace_job_route:loki_request_duration_seconds:99quantile`, defined in `rules.yaml` |
| Mimir | `operations/mimir-mixin-compiled/alerts.yaml` | **yes** — same colon-notation pattern |
| Tempo | `operations/tempo-mixin-compiled/alerts.yaml` | no — queries raw metrics; ships `runbook_url` on every alert |
| Alloy | `operations/alloy-mixin/rendered/alerts/` | no |

Install `rules.yaml` **and** `alerts.yaml` together — installing alerts alone
means they never fire.

Every mixin alert aggregates `by (cluster, namespace)`. See the
[label contract](meta-monitoring.md#step-2--the-label-contract-mixins-are-strict).

**Alloy can sync rules from CRDs**: `mimir.rules.kubernetes` and
`loki.rules.kubernetes` discover `PrometheusRule` resources and load them into
Mimir/Loki — worth knowing if you already use the Prometheus Operator CRDs.

## Gotchas

| Symptom | Cause |
| --- | --- |
| Alert never fires, no error | The metric isn't collected — see [meta-monitoring](meta-monitoring.md). Empty vector ≠ healthy. |
| Mixin alerts all silent | Missing `cluster`/`namespace` labels, or recording rules not installed. |
| Rules visible in UI but not editable | Prometheus-managed rules are **view-only** in Grafana. Use Grafana-managed. |
| Provisioned rules don't appear | Mounted over `/etc/grafana/provisioning` with an empty volume, or wrong subdir — must be `provisioning/alerting/`. |
| Alerts fire but nothing is delivered | No contact point / notification policy. Check `prometheus_notifications_errors_total` (Option B). |
| Flapping on NoData | Set a pending period (`for:`); 2026 Grafana applies pending to NoData/Error too. |

## Sources

- [Grafana-managed rules](https://grafana.com/docs/grafana/latest/alerting/alerting-rules/create-grafana-managed-rule/) · [datasource-managed](https://grafana.com/docs/grafana/latest/alerting/alerting-rules/create-data-source-managed-rule/)
- [Provision alerting resources](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/) · [configure Alertmanager](https://grafana.com/docs/grafana/latest/alerting/set-up/configure-alertmanager/)
- [`[unified_alerting]` reference](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
- [Alertmanager config](https://prometheus.io/docs/alerting/latest/configuration/) · [HA](https://prometheus.io/docs/alerting/latest/high_availability/)
- [Prometheus remote_write practices](https://prometheus.io/docs/practices/remote_write/) · [mimirtool](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/)
