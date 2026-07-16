# Alert rules

Prometheus alerting rules covering every environment this stack watches — the
Kubernetes cluster, the LGTM components themselves, and the non-Kubernetes
fleet (Linux, Windows, network gear, endpoint probes).

Standard `groups:` format — drop them into `rule_files` in any Prometheus, or
load them into Mimir's ruler. Nothing here is specific to this repo except the
LGTM group.

## Contents

| File | Group(s) | Rules | Needs |
| --- | --- | --- | --- |
| [node-linux.yaml](node-linux.yaml) | `node-linux` | 15 | node_exporter (:9100) |
| [windows.yaml](windows.yaml) | `windows` | 9 | windows_exporter (:9182) |
| [snmp-network.yaml](snmp-network.yaml) | `snmp-network` | 8 | snmp_exporter (:9116) |
| [blackbox-probes.yaml](blackbox-probes.yaml) | `blackbox-probes` | 10 | blackbox_exporter (:9115) |
| [kubernetes.yaml](kubernetes.yaml) | `kubernetes-containers` | 2 | **cadvisor — works today** |
| | `kubernetes-state` | 7 | ⚠️ **kube-state-metrics (NOT deployed)** |
| | `kubernetes-storage` | 3 | ⚠️ **kubelet `/metrics` (not scraped)** |
| [lgtm-stack.yaml](lgtm-stack.yaml) | `lgtm-stack` | 13 | ⚠️ [meta-monitoring](../docs/meta-monitoring.md) enabled |
| [prometheus-self.yaml](prometheus-self.yaml) | `prometheus-self`, `alertmanager-self` | 14 | Prometheus (Alertmanager rules: Option B only) |

**81 rules total.**

## Verified, not guessed

Every metric name was checked against the real thing, because most alert
snippets on the internet are silently wrong:

| Source | How it was verified |
| --- | --- |
| node_exporter | **Ran 1.12.1**, read `/metrics` |
| blackbox_exporter | **Ran 0.28.0**, probed a real HTTPS endpoint |
| snmp_exporter | Grepped the `if_mib` module in the shipped 1.9 MB `snmp.yml` (0.30.1) |
| windows_exporter | Official 0.31.7 collector docs (can't run on Linux) |
| LGTM + Prometheus | Queried a **live cluster** |

Then all 81 were **loaded into a real Prometheus 3.13.1**:

```
promtool check rules            -> SUCCESS, 81 rules
live load                       -> 81 loaded, 0 unhealthy, 0 evaluation failures
prometheus_rule_evaluation_failures_total == 0
```

### Corrections this caught

- **`windows_cs_physical_memory_bytes`** → **`windows_memory_physical_total_bytes`**
- **`windows_os_physical_memory_free_bytes`** → **`windows_memory_available_bytes`**
- **`windows_system_system_up_time`** → **`windows_system_boot_time_timestamp`**

The three left-hand names are all over blogs and Stack Overflow. They're from
old windows_exporter versions and **do not exist in 0.31.x** — an alert using
them never fires and never errors.

## Install

**Into Prometheus** — mount as a ConfigMap and point `rule_files` at it:

```bash
kubectl -n grafana-dev create configmap prometheus-alert-rules \
  --from-file=alerts/ --dry-run=client -o yaml | kubectl apply -f -
```

```yaml
# prometheus.yml
rule_files:
  - /etc/prometheus/rules/*.yaml
```

```yaml
# prometheus-deployment.yaml
        volumeMounts:
          - name: alert-rules
            mountPath: /etc/prometheus/rules     # directory, NOT subPath
      volumes:
        - name: alert-rules
          configMap:
            name: prometheus-alert-rules
```

Then `kubectl -n grafana-dev rollout restart deploy/prometheus`, or
`curl -X POST .../-/reload` (this deployment has `--web.enable-lifecycle`).

> Mount the **directory**, not `subPath` — `subPath` mounts never receive
> ConfigMap updates.

**Into Mimir's ruler:**

```bash
mimirtool rules load alerts/*.yaml --address=http://mimir:9009 --id=anonymous
```
(mimirtool wants a `namespace:` key the plain files don't carry — add one.)

**Grafana-managed alerting** uses a different schema entirely — see
[docs/alerting.md](../docs/alerting.md).

## Verify they loaded

```bash
curl -s .../api/v1/rules | jq '[.data.groups[].rules[]] | length'
curl -s '.../api/v1/query?query=sum(prometheus_rule_evaluation_failures_total)'   # want 0
```

Prometheus UI → **Alerts** lists every rule and its state.

## Before you trust these

> ### ⚠️ An empty alert is not a healthy alert
> A rule whose metric doesn't exist evaluates to an empty vector forever — it
> never fires and never errors. That is **indistinguishable from healthy**.
> Confirm the underlying metric exists before believing silence:
>
> ```bash
> curl -s '.../api/v1/query?query=count(node_filesystem_avail_bytes)'
> ```

Known cases in this repo:

- **`kubernetes-state`** rules need **kube-state-metrics**, which this stack
  does **not** deploy. All 7 are dead until you install it.
- **`kubernetes-storage`** rules need the **kubelet's `/metrics`** — Alloy
  currently scrapes only `/metrics/cadvisor`. A commented `kubelet` scrape
  block is in [alloy-configmap.yaml](../alloy-configmap.yaml).
- **`lgtm-stack`** rules need [meta-monitoring](../docs/meta-monitoring.md)
  (scrape annotations + the `job="<namespace>/<app>"` relabel).
- **`NodeSystemdUnitFailed`** needs `node_exporter --collector.systemd`, which
  is **off by default** (verified: the metric is absent from a stock 1.12.1).
- **`alertmanager-self`** only applies if you run a standalone Alertmanager
  (Option B). Grafana-managed alerting doesn't use those metrics.

## Tuning

Thresholds are starting points, not gospel. Most likely to need per-site
changes:

| Rule | Why |
| --- | --- |
| `WindowsServiceNotRunning` | The `name=~"MSSQLSERVER\|W3SVC\|Spooler"` regex is a placeholder — **edit it**. |
| `NodeHighCPU` / `WindowsHighCPU` | 85% is wrong for batch nodes that are meant to run hot. |
| `SNMPInterfaceHigh*Utilisation` | 80% of `ifHighSpeed`; wrong on links with a policer/shaper. |
| `SSLCertExpiringIn30Days` | Match your renewal window (ACME needs far less than 30d). |
| `*DiskWillFillIn24h` | `predict_linear` over 6h is noisy for spiky workloads. |

`instance`/`job` matchers assume the layout in
[prometheus-file-sd/](../prometheus-file-sd/) (`job=~".*linux.*"`,
`.*windows.*`, `.*snmp.*`). Adjust if your job names differ.

## Sources

- [awesome-prometheus-alerts](https://samber.github.io/awesome-prometheus-alerts/)
- [kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) · [node-exporter mixin](https://github.com/prometheus/node_exporter/tree/master/docs/node-mixin)
- [windows_exporter collectors](https://github.com/prometheus-community/windows_exporter/tree/master/docs)
- [blackbox_exporter](https://github.com/prometheus/blackbox_exporter) · [snmp_exporter](https://github.com/prometheus/snmp_exporter)
- Loki / Tempo / Mimir mixin `alerts.yaml` — see [docs/meta-monitoring.md](../docs/meta-monitoring.md)
