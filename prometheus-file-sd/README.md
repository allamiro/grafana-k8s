# Dynamic Prometheus targets with `file_sd` — migration guide

How to move big, hand-maintained `static_configs` (Windows, Linux, SNMP,
blackbox, …) onto **file-based service discovery**, so adding a host becomes
"write a file" instead of "edit `prometheus.yml` and restart Prometheus" —
**without redoing your dashboards**.

- [The problem](#the-problem)
- [How file_sd works](#how-file_sd-works)
- [The golden rule: don't break dashboards](#the-golden-rule-dont-break-dashboards)
- [Step-by-step migration](#step-by-step-migration)
- [Per-exporter recipes](#per-exporter-recipes) — [node/windows](#a-node--windows-exporter-the-easy-case) · [SNMP](#b-snmp-exporter) · [blackbox](#c-blackbox-exporter) · [collapsing duplicate jobs](#d-collapsing-duplicate-jobs)
- [Grouping targets](#grouping-targets)
- [Running it in Kubernetes](#running-it-in-kubernetes)
- [Generating the files automatically](#generating-the-files-automatically)
- [Verify and roll back](#verify-and-roll-back)
- [Gotchas](#gotchas)
- [The Alloy equivalent](#the-alloy-equivalent)

## The problem

A `prometheus.yml` that grew organically usually looks like this:

```yaml
scrape_configs:
  - job_name: 'windows'
    static_configs:
      - targets: ['win1:9182', 'win2:9182', 'win3:9182']   # ...and 200 more
  - job_name: 'blackbox_http'
    static_configs:
      - targets: ['https://a.example.com', 'https://b.example.com']
  - job_name: 'blackbox_icmp'      # same job, different module...
  - job_name: 'blackbox_tcp'       # ...and again
```

Every new host is a config edit + reload, the file is thousands of lines, and
the module-per-job duplication multiplies everything.

## How file_sd works

You declare the *job* once; the *targets* live in separate files that Prometheus
watches:

```yaml
scrape_configs:
  - job_name: 'windows'
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/windows/*.yaml
        refresh_interval: 30s
```

```yaml
# /etc/prometheus/targets/windows/prod.yaml
- targets: ['win1:9182', 'win2:9182']
  labels:
    env: prod
```

Each `- targets: [...] / labels: {...}` block is a **target group**. A file may
contain many. Prometheus picks up file changes via inotify (with
`refresh_interval` as a safety net).

**The key property:** changing a *target file* needs **no reload and no
restart**. Only changes to `prometheus.yml` itself do. That's the whole win.

Files may be `.yaml`, `.yml`, or `.json` — the glob decides.

## The golden rule: don't break dashboards

Dashboards query **label values**, overwhelmingly `job` and `instance`:

```promql
up{job="windows", instance="win1:9182"}
sum by (job) (rate(windows_cpu_time_total[5m]))
```

`file_sd` changes *where the target list comes from*, **not** the labels the
targets end up with. So:

> **Keep `job_name` and whatever `instance` resolves to identical, and every
> existing dashboard keeps working. Migrate mechanically first; improve labels
> second.**

Doing both at once is what breaks things.

| Change | Dashboards |
| --- | --- |
| `static_configs` → `file_sd_configs`, same job | ✅ safe |
| **Adding** new labels (`site`, `env`, `role`) | ✅ safe (additive) |
| Reorganising target files/directories | ✅ safe |
| Renaming `job_name` | ❌ breaks `job="..."` filters |
| Changing what `instance` resolves to | ❌ breaks — the classic SNMP/blackbox footgun |
| Removing/renaming a label a panel filters on | ❌ breaks |

## Step-by-step migration

### Step 1 — Capture a baseline (do not skip)

This is what lets you *prove* nothing changed:

```bash
curl -s localhost:9090/api/v1/targets \
  | jq -S '[.data.activeTargets[] | {job: .labels.job, instance: .labels.instance}] | sort' \
  > /tmp/targets-before.json

wc -l /tmp/targets-before.json
```

### Step 2 — Lay out the target directory

Group by system type; the directory becomes a label later (Step 6).

```
/etc/prometheus/targets/
├── windows/prod.yaml
├── linux/prod.yaml        # filename = env (see grouping, below)
├── snmp/switches.yaml
└── blackbox/probes.yaml
```

See [targets/](targets/) for ready-to-copy samples and
[prometheus-jobs.yaml](prometheus-jobs.yaml) for the matching `scrape_configs`.

> Keep one directory per *system type* (one `files:` glob each). Don't nest
> deeper expecting a wildcard to find it — file_sd only globs the **last** path
> segment (see [grouping](#grouping-targets)).

### Step 3 — Convert one job

Change **only** the discovery block. Leave `job_name`, `metrics_path`,
`params`, and `relabel_configs` byte-identical.

```yaml
# BEFORE
- job_name: 'windows'
  static_configs:
    - targets: ['win1:9182', 'win2:9182']

# AFTER
- job_name: 'windows'                 # unchanged
  file_sd_configs:                    # <- the only edit
    - files: ['/etc/prometheus/targets/windows/*.yaml']
      refresh_interval: 30s
```

Move the hosts into the file:

```yaml
# targets/windows/prod.yaml
- targets: ['win1:9182', 'win2:9182']
```

### Step 4 — Validate before reloading

```bash
promtool check config /etc/prometheus/prometheus.yml
```

### Step 5 — Reload

`prometheus.yml` changed, so this one time you *do* reload:

```bash
curl -X POST localhost:9090/-/reload      # needs --web.enable-lifecycle
# or:  kill -HUP $(pidof prometheus)
```

From now on, target files change with no reload at all.

### Step 6 — Diff the baseline

```bash
curl -s localhost:9090/api/v1/targets \
  | jq -S '[.data.activeTargets[] | {job: .labels.job, instance: .labels.instance}] | sort' \
  > /tmp/targets-after.json

diff /tmp/targets-before.json /tmp/targets-after.json \
  && echo "IDENTICAL — no dashboard can break"
```

An empty diff means every `job`/`instance` pair survived. Repeat per job; do
one job at a time.

## Per-exporter recipes

### A. node / windows exporter (the easy case)

The target *is* the thing being scraped, so `instance` defaults to
`__address__` — nothing to preserve manually.

```yaml
- job_name: 'windows'
  file_sd_configs:
    - files: ['/etc/prometheus/targets/windows/*.yaml']
- job_name: 'linux'
  file_sd_configs:
    - files: ['/etc/prometheus/targets/linux/*.yaml']
```

```yaml
# targets/windows/prod.yaml
- targets: ['win1:9182', 'win2:9182']
  labels:
    env: prod
    os: windows
```

### B. SNMP exporter

Here the target is the **device**, and `__address__` is rewritten to the
*exporter*. `instance` is set by relabeling — **keep those rules exactly** and
`instance` stays the device address, exactly as before.

```yaml
- job_name: 'snmp'                    # unchanged
  metrics_path: /snmp                 # unchanged
  file_sd_configs:                    # <- only this changed
    - files: ['/etc/prometheus/targets/snmp/*.yaml']
  relabel_configs:                    # unchanged -> instance preserved
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: snmp-exporter:9116   # the exporter, not the device
```

**The payoff:** set the SNMP module *per device* in the file with
`__param_module`, instead of one job per module:

```yaml
# targets/snmp/switches.yaml
- targets: ['192.168.1.1', '192.168.1.2']
  labels:
    __param_module: if_mib
    site: dc1

- targets: ['192.168.9.9']
  labels:
    __param_module: cisco_wlc
    site: dc2
```

Labels starting with `__` are consumed during relabeling and **dropped
afterwards** — they steer the scrape without adding any series.

> If your current config sets `params: module: [if_mib]` on the job, that's the
> job-wide default. A `__param_module` label on a target overrides it per device.

### C. Blackbox exporter

Identical shape to SNMP:

```yaml
- job_name: 'blackbox'
  metrics_path: /probe
  file_sd_configs:
    - files: ['/etc/prometheus/targets/blackbox/*.yaml']
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: blackbox-exporter:9115
```

```yaml
# targets/blackbox/http.yaml
- targets: ['https://a.example.com', 'https://b.example.com']
  labels:
    __param_module: http_2xx
    team: web

- targets: ['10.0.0.1', '10.0.0.2']
  labels:
    __param_module: icmp
    team: network
```

### D. Collapsing duplicate jobs

If you have `blackbox_http`, `blackbox_icmp`, `blackbox_tcp` that differ **only
by module**, `__param_module` collapses them into one job — usually the single
biggest cleanup.

> ⚠️ **This changes `job`.** Dashboards filtering `job="blackbox_icmp"` will
> break. Two safe ways:
>
> 1. **Keep the job names** — one job per module, each with its own `files:`
>    glob. Zero dashboard churn, still gets you dynamic targets. Do this first.
> 2. **Collapse, and re-add the distinction as a real label** so panels can be
>    repointed:
>    ```yaml
>    - targets: ['10.0.0.1']
>      labels:
>        __param_module: icmp
>        probe_type: icmp      # a real label; query probe_type="icmp"
>    ```
>    Then update panels from `job="blackbox_icmp"` → `probe_type="icmp"`.
>
> Option 1 during migration, option 2 later as a deliberate change.

## Grouping targets

Three levels — pick by whether groups need *filtering* or different *scrape
behavior*.

**1. Labels per target group** (most common):

```yaml
- targets: ['win1:9182']
  labels: { env: prod, role: dc, site: dc1 }
```
```promql
sum by (site, role) (rate(windows_cpu_time_total[5m]))
```
Grafana variable: `label_values(up, site)`.

**2. Filename → label**, via the built-in `__meta_filepath` meta-label. Adding
an environment becomes "add a file":

```yaml
- job_name: 'linux'
  file_sd_configs:
    - files: ['/etc/prometheus/targets/linux/*.yaml']   # prod.yaml, dev.yaml
  relabel_configs:
    - source_labels: [__meta_filepath]
      regex: '.*/linux/([^/]+)\.yaml'
      target_label: env                                 # prod.yaml -> env="prod"
```

> ### ⚠️ file_sd globs: last path segment only
> A glob is allowed **only in the final path segment**. A nested pattern is
> rejected at load time:
> ```
> FAILED: parsing YAML file prometheus.yml:
> path name "/etc/prometheus/targets/linux/*/*.yaml" is not valid for file discovery
> ```
> (Verified with `promtool check config`.) So either put the group in the
> **filename** as above, or list directories **explicitly**:
> ```yaml
> - files:
>     - /etc/prometheus/targets/linux/prod/*.yaml
>     - /etc/prometheus/targets/linux/dev/*.yaml
> ```
> The explicit form still gives you `__meta_filepath`, so the directory regex
> (`'.*/linux/([^/]+)/.*'`) works — you just can't discover the directories
> with a wildcard.

**3. Separate jobs** — only when the group needs a different
`scrape_interval`, `metrics_path`, port, or auth. Labels can't express those.

⚠️ Cardinality: `env`, `site`, `role`, `team` are fine. Anything unbounded
per-host (UUIDs, or a hostname you already have in `instance`) multiplies series
and will hurt.

## Running it in Kubernetes

Keep targets in their **own** ConfigMap, separate from `prometheus.yml`:

```bash
kubectl create configmap prometheus-targets -n grafana-dev \
  --from-file=targets/windows/ --from-file=targets/snmp/ \
  --dry-run=client -o yaml | kubectl apply -f -
```

> ### ⚠️ The `subPath` trap
> Mount the **directory**, never `subPath`. ConfigMap volumes mounted with
> `subPath` **never receive updates** — you'd be back to restarting Prometheus,
> defeating the entire point.

```yaml
volumeMounts:
  - name: targets
    mountPath: /etc/prometheus/targets   # directory — updates propagate
volumes:
  - name: targets
    configMap:
      name: prometheus-targets
```

Flow: update the ConfigMap → kubelet syncs the volume (up to ~60s) → Prometheus
reloads targets itself. No pod restart.

Nested directories (for the `__meta_filepath` trick) don't come from
`--from-file` flatly — use a ConfigMap per directory, each mounted at its own
path, or project them with `items:`.

## Generating the files automatically

The point of file_sd is that *something else* writes the files:

- **Ansible/Puppet** — template the target file from your inventory; you already
  have the host list there.
- **CMDB/inventory export** — a cron job that dumps YAML/JSON.
- **`http_sd_configs`** — skip files entirely; Prometheus polls your inventory
  API for JSON targets. Best option if you have an API:

  ```yaml
  - job_name: 'windows'
    http_sd_configs:
      - url: https://cmdb.example.com/prometheus/windows
        refresh_interval: 60s
  ```
  The endpoint returns the same target-group shape:
  ```json
  [ { "targets": ["win1:9182"], "labels": { "env": "prod" } } ]
  ```

Write files **atomically** (`write temp → rename`). Prometheus may otherwise read
a half-written file and briefly drop targets.

## Verify and roll back

```bash
promtool check config /etc/prometheus/prometheus.yml    # syntax
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
```

Useful queries while migrating:

```promql
count by (job) (up)          # target counts per job — compare before/after
up == 0                      # anything newly down?
```

Prometheus UI → **Status → Service Discovery** shows discovered targets, their
meta-labels (including `__meta_filepath`), and the relabeling result — the
fastest way to debug why a target vanished.

**Rollback** is trivial: the old `static_configs` job is a git revert away, and
target files are additive. Migrate one job at a time and you're never more than
one revert from working.

## Gotchas

| Symptom | Cause |
| --- | --- |
| Targets vanish after migrating | The glob doesn't match. Check **Status → Service Discovery**; paths are relative to the *Prometheus container*, not your workstation. |
| SNMP/blackbox `instance` became the exporter's address | You dropped the `__param_target` → `instance` relabel rule. This is *the* dashboard-breaker. |
| ConfigMap updated, Prometheus didn't notice | Mounted with `subPath`. Mount the directory. |
| Targets flap during file writes | Non-atomic writes. Write temp + `rename`. |
| `__param_module` label shows on the metric | It won't — `__`-prefixed labels are dropped after relabeling. If you see it, you named it without the `__` prefix. |
| Changed a target file, nothing happened | That's expected to be *fast*, not instant — inotify plus `refresh_interval`. In K8s, add kubelet's ConfigMap sync (~60s). |

## The Alloy equivalent

This repo uses [Alloy](../alloy-configmap.yaml) as its collector, which has the
same primitives — worth using instead of a second standalone Prometheus for
non-Kubernetes hosts (see [examples/alloy-external.alloy](../examples/alloy-external.alloy)):

```alloy
discovery.file "windows" {
  files = ["/etc/alloy/targets/windows/*.yaml"]
}

discovery.relabel "windows" {
  targets = discovery.file.windows.targets
  rule {
    source_labels = ["__meta_filepath"]
    regex         = ".*/windows/([^/]+)/.*"
    target_label  = "env"
  }
}

prometheus.scrape "windows" {
  targets    = discovery.relabel.windows.output
  forward_to = [prometheus.remote_write.default.receiver]
}
```

`discovery.http`, `discovery.dns`, and `discovery.consul` mirror
`http_sd_configs` / `dns_sd_configs` / `consul_sd_configs`.

## References

- [Prometheus configuration — `file_sd_config`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config)
- [Prometheus configuration — `http_sd_config`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#http_sd_config)
- [Relabeling](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config)
- [SNMP exporter](https://github.com/prometheus/snmp_exporter) · [Blackbox exporter](https://github.com/prometheus/blackbox_exporter) · [Windows exporter](https://github.com/prometheus-community/windows_exporter)
