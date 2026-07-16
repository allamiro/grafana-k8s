# Prometheus-ecosystem packages (offline / air-gap installs)

Exporters and servers for hosts **outside** Kubernetes — the RHEL VMs, bare
metal, network gear, and Windows boxes that feed the stack via
[prometheus-file-sd/](../prometheus-file-sd/) or
[examples/alloy-external.alloy](../examples/alloy-external.alloy).

> **Not in git.** The binaries (~284 MB) are git-ignored. Only this README,
> [manifest.txt](manifest.txt), and [fetch-packages.sh](fetch-packages.sh) are
> tracked. Refetch with `./packages/fetch-packages.sh`.

## RPM vs tarball — read this first

**Upstream Prometheus does not publish RPMs.** It ships `tar.gz` binaries on
GitHub. RPMs come from EPEL, which packages only *some* components — and at
different (usually older) versions:

| Component | EPEL RPM | Upstream tarball |
| --- | --- | --- |
| prometheus | ✅ 3.13.1-1.el9 | ✅ 3.13.1 |
| node_exporter | ✅ 1.11.1-1.el9 (as `node-exporter`) | ✅ 1.12.1 |
| alertmanager | ✅ 0.33.0-1.el9 | ✅ 0.33.1 |
| **snmp_exporter** | ❌ **not packaged** | ✅ 0.30.1 |
| **blackbox_exporter** | ❌ **not packaged** | ✅ 0.28.0 |
| pushgateway | ❌ not packaged | ✅ 1.11.3 |
| windows_exporter | — (MSI) | ✅ 0.31.7 |

So for **SNMP and blackbox there is no RPM option** — tarball or container only.

**Which to use?** RPMs give you systemd units, a service user, and `/etc/`
config paths for free — nice for a handful of RHEL hosts. Tarballs give you the
current upstream version and identical layout on every distro — better when you
want one version everywhere, or need snmp/blackbox anyway (you do). Mixing is
fine; just don't install both for the same component.

Exact versions and verification status: [manifest.txt](manifest.txt).

## Contents

```
packages/
├── tarball/    upstream linux-amd64 .tar.gz  (all sha256-verified)
├── rpm/        EPEL 9 RPMs                   (rpm -K digests OK)
└── windows/    windows_exporter .msi + .exe
```

## Installing — RPM (RHEL/Rocky/Alma 9)

```bash
sudo dnf install -y ./packages/rpm/node-exporter-1.11.1-1.el9.x86_64.rpm
sudo systemctl enable --now node_exporter
curl -s localhost:9100/metrics | head        # verify
```

The RPM creates the service user and unit for you. Same pattern for
`prometheus` and `alertmanager`.

## Installing — tarball (any distro; required for snmp/blackbox)

Example with node_exporter; identical shape for the others:

```bash
tar xzf packages/tarball/node_exporter-1.12.1.linux-amd64.tar.gz
sudo install -o root -g root -m 0755 \
  node_exporter-1.12.1.linux-amd64/node_exporter /usr/local/bin/node_exporter
sudo useradd --system --no-create-home --shell /sbin/nologin node_exporter
```

```ini
# /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now node_exporter
```

### snmp_exporter (tarball only)

Ships a large generated `snmp.yml` of modules (`if_mib`, `cisco_wlc`, …):

```bash
tar xzf packages/tarball/snmp_exporter-0.30.1.linux-amd64.tar.gz
sudo install -m 0755 snmp_exporter-0.30.1.linux-amd64/snmp_exporter /usr/local/bin/
sudo install -D -m 0644 snmp_exporter-0.30.1.linux-amd64/snmp.yml /etc/snmp_exporter/snmp.yml
# ExecStart=/usr/local/bin/snmp_exporter --config.file=/etc/snmp_exporter/snmp.yml
```

Listens on **:9116**. Probe a device by hand:

```bash
curl 'localhost:9116/snmp?module=if_mib&target=192.168.1.1'
```

> Modules are selected **per device** via a `__param_module` label in the
> file_sd target file — see
> [prometheus-file-sd/targets/snmp/switches.yaml](../prometheus-file-sd/targets/snmp/switches.yaml).
> Custom OIDs need the *generator* (in the source repo), not this tarball.

### blackbox_exporter (tarball only)

```bash
tar xzf packages/tarball/blackbox_exporter-0.28.0.linux-amd64.tar.gz
sudo install -m 0755 blackbox_exporter-0.28.0.linux-amd64/blackbox_exporter /usr/local/bin/
sudo install -D -m 0644 blackbox_exporter-0.28.0.linux-amd64/blackbox.yml /etc/blackbox_exporter/blackbox.yml
```

Listens on **:9115**. ICMP probes need extra privilege:

```bash
sudo setcap cap_net_raw+ep /usr/local/bin/blackbox_exporter
```

(Miss this and `icmp` probes fail while `http_2xx` works — a classic.)

```bash
curl 'localhost:9115/probe?module=http_2xx&target=https://example.com'
```

## Installing — Windows

```powershell
msiexec /i windows_exporter-0.31.7-amd64.msi ENABLED_COLLECTORS="cpu,cs,logical_disk,net,os,service,system,memory"
```

Listens on **:9182**. Open the firewall and confirm from the Prometheus host:

```powershell
New-NetFirewallRule -DisplayName "windows_exporter" -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
```

## Wiring them into Prometheus

Don't hand-edit `prometheus.yml` per host — add the target to a file_sd file:

| Exporter | Port | Target file |
| --- | --- | --- |
| node_exporter | 9100 | [targets/linux/prod.yaml](../prometheus-file-sd/targets/linux/prod.yaml) |
| windows_exporter | 9182 | [targets/windows/prod.yaml](../prometheus-file-sd/targets/windows/prod.yaml) |
| snmp_exporter | 9116 | [targets/snmp/switches.yaml](../prometheus-file-sd/targets/snmp/switches.yaml) |
| blackbox_exporter | 9115 | [targets/blackbox/probes.yaml](../prometheus-file-sd/targets/blackbox/probes.yaml) |

For SNMP/blackbox the *targets* are the devices/URLs — the exporter address goes
in the job's `relabel_configs`. See
[prometheus-file-sd/README.md](../prometheus-file-sd/README.md).

## Refetching / verifying

```bash
./packages/fetch-packages.sh        # re-downloads everything, verifies sha256
```

It resolves **latest** from the GitHub API each run, so versions move — pin by
editing the script or keeping [manifest.txt](manifest.txt) with the bundle.

Verify by hand any time:

```bash
rpm -K packages/rpm/*.rpm                 # RPM digests
gzip -t packages/tarball/*.tar.gz         # archive integrity
```

Upstream publishes `sha256sums.txt` per release; the script checks each tarball
against it and records the result in the manifest.
