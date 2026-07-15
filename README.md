# grafana-k8s

Kubernetes manifests for deploying [Grafana](https://grafana.com/) to a cluster.
This repo keeps the deployment as a small set of plain, readable YAML files you can
`kubectl apply` directly — no Helm chart or operator required.

## Contents

| File | Kind | Description |
| --- | --- | --- |
| [grafana-k8-ns.yaml](grafana-k8-ns.yaml) | `Namespace` | Creates the `grafana-dev` namespace that everything else lives in. |
| [grafana-k8-pvc.yaml](grafana-k8-pvc.yaml) | `PersistentVolumeClaim` ×2 | Persistent storage — one claim for Grafana data, one for plugins. |
| [grafana-k8-configmap.yaml](grafana-k8-configmap.yaml) | `ConfigMap` | `grafana.ini` settings and a provisioned default datasource. |
| [grafana-k8-deployment.yaml](grafana-k8-deployment.yaml) | `Deployment` | Runs the Grafana container and mounts the PVCs + config. |
| [grafana-k8-svc.yaml](grafana-k8-svc.yaml) | `Service` | Exposes Grafana on port `3000` inside the cluster. |

> **Storage note:** The PVCs use the `tanzu-storage-computer` StorageClass. Change
> `storageClassName` in [grafana-k8-pvc.yaml](grafana-k8-pvc.yaml) to match your cluster.

## Prerequisites

- A running Kubernetes cluster (minikube, kind, k3s, or a managed cluster).
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/) configured to talk to it.
- A `StorageClass` capable of provisioning a `ReadWriteOnce` volume (most clusters
  ship a default one).

## Quick start

Apply the manifests in order:

```bash
# 1. Create the namespace
kubectl apply -f grafana-k8-ns.yaml

# 2. Create the persistent volume claims
kubectl apply -f grafana-k8-pvc.yaml

# 3. Create the TLS Secret Grafana serves from (see "TLS" below)
kubectl -n grafana-dev create secret tls grafana-tls \
  --cert=path/to/tls.crt --key=path/to/tls.key

# 4. Create the config, then the workload and service
kubectl apply -f grafana-k8-configmap.yaml
kubectl apply -f grafana-k8-deployment.yaml
kubectl apply -f grafana-k8-svc.yaml
```

Or apply everything at once:

```bash
kubectl apply -f grafana-k8-ns.yaml
kubectl apply -f .
```

Verify:

```bash
kubectl get all,pvc -n grafana-dev
```

Expose Grafana with a port-forward for local access:

```bash
kubectl port-forward -n grafana-dev svc/grafana 3000:3000
# then open http://localhost:3000  (default login: admin / admin)
```

> **Security:** The admin password defaults to `admin` via the
> `GF_SECURITY_ADMIN_PASSWORD` env var in the Deployment. Replace it with a
> `Secret` reference before using this anywhere real.

## TLS

Grafana terminates TLS itself (`protocol = https` in the ConfigMap) and serves on
container port `3000`; the Service exposes it externally on `443`. Grafana reads
its cert and key from `/etc/grafana/certs`, which is mounted from a `grafana-tls`
Secret — **not** stored in this repo. Create it before deploying:

```bash
kubectl -n grafana-dev create secret tls grafana-tls \
  --cert=path/to/tls.crt --key=path/to/tls.key
```

The cert paths in [grafana-k8-configmap.yaml](grafana-k8-configmap.yaml)
(`cert_file` / `cert_key`) must match that mount path. Use a cert whose SAN
covers `grafana-dev.example.com` (the configured `domain`/`root_url`).

## Teardown

```bash
kubectl delete namespace grafana-dev
```

Deleting the namespace removes every resource created above, including the PVC.

## Roadmap

- [x] Namespace
- [x] PersistentVolumeClaims (data + plugins)
- [x] ConfigMap for `grafana.ini` / datasource provisioning
- [x] Deployment (Grafana container)
- [x] Service
- [ ] Secret for the admin password
- [ ] Ingress example

## License

Licensed under the [Apache License 2.0](LICENSE).
