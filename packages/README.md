# Prometheus-ecosystem packages (offline / air-gap installs)

Exporters and servers for hosts **outside** Kubernetes — the RHEL VMs, bare
metal, network gear, and Windows boxes that feed the stack via
[prometheus-file-sd/](../prometheus-file-sd/) or
[examples/alloy-external.alloy](../examples/alloy-external.alloy).

> **Not in git.** The binaries (~284 MB) are git-ignored. Only this README,
> [manifest.txt](manifest.txt), and [fetch-packages.sh](fetch-packages.sh) are
> tracked. Refetch with `./packages/fetch-packages.sh`.

## Where RPMs come from — read this first

**Upstream Prometheus publishes no RPMs**; it ships `tar.gz` on GitHub. But two
RPM repos cover EL9 between them, and **which repo is newest differs per
component**:

| Component | EPEL 9 | [prometheus-rpm](https://packagecloud.io/prometheus-rpm/release) | Upstream tarball |
| --- | --- | --- | --- |
| prometheus | ✅ **3.13.1-1** | ❌ not in repo | ✅ 3.13.1 |
| node_exporter | ✅ **1.11.1-1** (`node-exporter`) | ✅ 1.9.0-1 (`node_exporter`) | ✅ 1.12.1 |
| alertmanager | ✅ **0.33.0-1** | ✅ 0.28.1-1 | ✅ 0.33.1 |
| **snmp_exporter** | ❌ not packaged | ✅ **0.28.0-1** | ✅ 0.30.1 |
| **blackbox_exporter** | ❌ not packaged | ✅ **0.26.0-1** | ✅ 0.28.0 |
| pushgateway | ❌ not packaged | ✅ **1.11.0-1** | ✅ 1.11.3 |
| windows_exporter | — | — | ✅ 0.31.7 (MSI/EXE) |

Rules of thumb:

- **snmp_exporter / blackbox_exporter / pushgateway** → **prometheus-rpm** is
  the only RPM source on EL9.
- **prometheus / node_exporter / alertmanager** → **EPEL** is newer; prefer it.
- **Newest of all** → upstream tarball (but you build the systemd unit yourself).

> ⚠️ **Don't mix sources for the same component.** EPEL's `node-exporter` and
> prometheus-rpm's `node_exporter` are *different package names shipping the
> same binary* — installing both will collide.

prometheus-rpm also carries ~57 EL9 exporters EPEL doesn't (mysqld, postgres,
ipmi, bind, haproxy, elasticsearch, …):

```bash
dnf --repofrompath='promrpm,https://packagecloud.io/prometheus-rpm/release/el/9/x86_64' \
    --repo=promrpm --nogpgcheck list available
```

**RPM or tarball?** RPMs give you a systemd unit, a `prometheus` service user,
and `/etc/prometheus/` config paths for free. Tarballs give you the newest
version and an identical layout on every distro. Both are here — pick per host.

Exact versions and verification status: [manifest.txt](manifest.txt).

## Adding the prometheus-rpm repo (online hosts)

```bash
curl -s https://packagecloud.io/install/repositories/prometheus-rpm/release/script.rpm.sh | sudo bash
sudo dnf install -y snmp_exporter blackbox_exporter
```

The bundled RPMs here were downloaded with `--nogpgcheck` (download only). For
installs, import the repo key rather than disabling GPG:
<https://packagecloud.io/prometheus-rpm/release/gpgkey>

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

### snmp_exporter

**RPM (prometheus-rpm)** — installs the binary, a systemd unit, and the
generated module file:

```bash
sudo dnf install -y ./packages/rpm/snmp_exporter-0.28.0-1.el9.x86_64.rpm
# -> /usr/bin/snmp_exporter
#    /etc/prometheus/snmp.yml                     (modules: if_mib, cisco_wlc, ...)
#    /usr/lib/systemd/system/snmp_exporter.service
sudo systemctl enable --now snmp_exporter
```

**Tarball** (newer, 0.30.1) — same files, unit is yours to write:

```bash
tar xzf packages/tarball/snmp_exporter-0.30.1.linux-amd64.tar.gz
sudo install -m 0755 snmp_exporter-0.30.1.linux-amd64/snmp_exporter /usr/local/bin/
sudo install -D -m 0644 snmp_exporter-0.30.1.linux-amd64/snmp.yml /etc/snmp_exporter/snmp.yml
```

Listens on **:9116**. Probe a device by hand:

```bash
curl 'localhost:9116/snmp?module=if_mib&target=192.168.1.1'
```

> Modules are selected **per device** via a `__param_module` label in the
> file_sd target file — see
> [prometheus-file-sd/targets/snmp/switches.yaml](../prometheus-file-sd/targets/snmp/switches.yaml).
> Custom OIDs need the *generator* (in the source repo); it's in neither the RPM
> nor the tarball.

### blackbox_exporter

```bash
sudo dnf install -y ./packages/rpm/blackbox_exporter-0.26.0-1.el9.x86_64.rpm
# -> /usr/bin/blackbox_exporter
#    /etc/prometheus/blackbox.yml
#    /usr/lib/systemd/system/blackbox_exporter.service   (User=prometheus)
sudo systemctl enable --now blackbox_exporter
```

Listens on **:9115**.

> ### ⚠️ ICMP probes fail out of the box
> The RPM's unit runs `User=prometheus` and grants **no `CAP_NET_RAW`**
> (verified: no `AmbientCapabilities` in the shipped unit, no `setcap`
> scriptlet). So `http_2xx` works while `icmp` silently fails. Fix with a
> systemd drop-in:
>
> ```bash
> sudo systemctl edit blackbox_exporter
> ```
> ```ini
> [Service]
> AmbientCapabilities=CAP_NET_RAW
> ```
> ```bash
> sudo systemctl restart blackbox_exporter
> ```
>
> For a **tarball** install instead: `sudo setcap cap_net_raw+ep /usr/local/bin/blackbox_exporter`

```bash
curl 'localhost:9115/probe?module=http_2xx&target=https://example.com'
curl 'localhost:9115/probe?module=icmp&target=10.0.0.1'      # needs CAP_NET_RAW
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
