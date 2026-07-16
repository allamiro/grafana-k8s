# Saved container images (air-gap bundle)

Every image this project references, exported as a gzipped **docker-archive**.
Useful for air-gapped clusters (Tanzu, hardened minikube) where nodes cannot
pull from Docker Hub / ghcr.io.

> **Not in git.** The `*.tar.gz` archives are git-ignored — they total ~1.1 GB
> and GitHub rejects any file over 100 MB. Only this README and
> [manifest.txt](manifest.txt) (image → resolved digest) are tracked.
> Regenerate the archives with the script below.

## Contents

| Image | Archive | Size |
| --- | --- | --- |
| `grafana/grafana:latest` | `grafana_grafana_latest.tar.gz` | 401M |
| `grafana/alloy:latest` | `grafana_alloy_latest.tar.gz` | 167M |
| `amazon/aws-cli:latest` | `amazon_aws-cli_latest.tar.gz` | 148M |
| `prom/prometheus:latest` | `prom_prometheus_latest.tar.gz` | 108M |
| `rustfs/rustfs:latest` | `rustfs_rustfs_latest.tar.gz` | 87M |
| `grafana/pyroscope:latest` | `grafana_pyroscope_latest.tar.gz` | 61M |
| `grafana/loki:latest` | `grafana_loki_latest.tar.gz` | 51M |
| `grafana/mimir:latest` | `grafana_mimir_latest.tar.gz` | 39M |
| `grafana/tempo:2.8.1` | `grafana_tempo_2.8.1.tar.gz` | 37M |
| `ghcr.io/…/telemetrygen:latest` | `ghcr.io_open-telemetry_…_latest.tar.gz` | 13M |
| `busybox:1.36` | `busybox_1.36.tar.gz` | 2.3M |

The exact digest each `:latest` resolved to is recorded in
[manifest.txt](manifest.txt) — use those to pin the deployments reproducibly.

## Loading them

**minikube** (loads into the node's runtime):

```bash
for f in images/*.tar.gz; do minikube image load "$f"; done
# multi-node: repeat per node with `minikube image load --node <name>`
```

**Docker / podman:**

```bash
for f in images/*.tar.gz; do docker load -i "$f"; done   # or: podman load -i "$f"
```

**containerd / CRI-O node (air-gapped):** copy the archive to the node, then:

```bash
ctr -n k8s.io images import <file>.tar.gz        # containerd
podman load -i <file>.tar.gz                     # CRI-O via podman
```

**Private registry (Harbor, the usual Tanzu path):** load, retag, push, then
point the manifests at your registry:

```bash
podman load -i images/grafana_grafana_latest.tar.gz
podman tag docker.io/grafana/grafana:latest harbor.example.com/obs/grafana:latest
podman push harbor.example.com/obs/grafana:latest
```

## Regenerating the bundle

```bash
./images/save-images.sh
```

It reads every `image:` reference out of the manifests, so it stays in sync as
the stack changes. Note it pulls **fully-qualified** names (`docker.io/...`):
podman's short-name resolution needs an interactive TTY and fails in scripts.
