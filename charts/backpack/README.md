# Backpack Helm chart

Deploys [Backpack](https://github.com/linus-berg/backpack) on Kubernetes: the
API, GUI, gateway, collector router, and any set of collectors and processors
you list in the values.

The chart does **not** deploy the infrastructure Backpack depends on. These
must already be reachable from the cluster:

- RabbitMQ (with the management API enabled)
- MongoDB
- Redis
- S3-compatible object storage (e.g. MinIO)
- An OIDC provider (e.g. Keycloak)

## Installing

```bash
helm repo add backpack https://linus-berg.github.io/helm-charts/
helm repo update
```

The chart has no default `values.yaml`, so `helm show values` prints nothing.
Start from [`values.example.yaml`](values.example.yaml) instead:

```bash
helm pull backpack/backpack --untar
cp backpack/values.example.yaml my-values.yaml
# edit my-values.yaml
helm install backpack backpack/backpack -n backpack --create-namespace -f my-values.yaml
```

Resource names are fixed (`backpack-api`, `collector-git`, ...) rather than
prefixed with the release name, so install one release per namespace.

> **Credentials are stored in Secrets.** The RabbitMQ and Redis passwords,
> the MongoDB connection string, the S3 keys and `http_proxy` go into
> `common-env-secret`, `api-env-secret`, `gateway-env-secret` and
> `collector-env-secret`. The other settings stay in the matching
> `*-env-config` ConfigMaps. Two things are not covered:
>
> - Helm stores the full values, credentials included, in its release Secret
>   (`sh.helm.release.v1.<release>.v<revision>`), so anyone who can read
>   Secrets in the namespace can read them there too.
> - `env` entries of collectors and processors that use `value` are written
>   into the Deployment in plain text. Give credentials, such as the Helm
>   processor's ArtifactHub keys, through `valueFrom.secretKeyRef` instead.

## What gets deployed

| Resource | Kind | Image |
| :--- | :--- | :--- |
| `backpack-api` | Deployment + LoadBalancer Service | `ghcr.io/linus-berg/backpack/integration/api:<backpack.version>` |
| `backpack-gui` | Deployment + LoadBalancer Service | `ghcr.io/linus-berg/backpack/gui:<gui.version>` |
| `backpack-gateway` | Deployment | `ghcr.io/linus-berg/backpack/core/gateway:<backpack.version>` |
| `collector-router` | Deployment | `ghcr.io/linus-berg/backpack/collector/router:<backpack.version>` |
| `collector-<id>` | Deployment, or StatefulSet + headless Service (see [Collector storage](#collector-storage)) | per entry in `collectors` |
| `processor-<id>` | Deployment | per entry in `processors` |
| `collector-<id>-<volume>`, `processor-<id>-<volume>` | PersistentVolumeClaim | one per `extraVolumes` entry of a Deployment |
| `common-env-config`, `api-env-config`, `gateway-env-config`, `collector-env-config` | ConfigMap | |
| `ca-certificates` | ConfigMap, only when `ca_certificates` is set | |
| `common-env-secret`, `api-env-secret`, `gateway-env-secret`, `collector-env-secret` | Secret | |
| same name as the workload, e.g. `backpack-api` | PodDisruptionBudget, only for workloads that set `podDisruptionBudget` (see [Pod settings](#pod-settings)) | |

Pods are restarted automatically when the ConfigMaps and Secrets they read
change.

## Configuration

Values marked *required* make `helm install` fail when missing. The others
are not validated and render empty when unset, so set every value the
services you deploy need.

### Global

| Key | Description | Default |
| :--- | :--- | :--- |
| `backpack.version` | Image tag for the API, gateway and router (*required*). Usually also anchored as the `tag` of collectors and processors. | |
| `backpack.log.level` | Default .NET log level (`LOGGING__LOGLEVEL__DEFAULT`) (*required*). | |
| `http_proxy` | Sets `HTTP_PROXY`/`HTTPS_PROXY` (both cases) for the API, gateway, router, collectors and processors. The Git collector also uses it as `git config http.proxy`. Stored in a Secret, since proxy URLs can carry credentials. | unset |
| `no_proxy` | List of hosts, joined into `NO_PROXY`/`no_proxy`. | unset |
| `hosts` | `hostAliases` entries (`ip`, `hostnames`) for every pod except the GUI. | unset |
| `ca_certificates` | PEM bundle stored in the `ca-certificates` ConfigMap and mounted over `/etc/ssl/certs/ca-certificates.crt` in the API, collectors and processors. It **replaces** the image's bundle, so include the public roots too if those services need to reach the internet. | unset |
| `oidc.authority` | OIDC realm URL (`BP_OIDC_AUTHORITY`). | |
| `oidc.audience` | Expected `aud` claim / client ID (`BP_OIDC_AUDIENCE`). | |
| `otel.host` | OpenTelemetry collector endpoint (`BP_OTEL_HOST`). | unset |
| `defaults` | Pod settings for every workload that doesn't set its own, see [Pod settings](#pod-settings). | unset |

### API, GUI, gateway and router

| Key | Description |
| :--- | :--- |
| `api.host` | Public URL of the API (`BP_API_HOST`). |
| `api.port` | Service port, forwarded to container port 8080. |
| `api.loadBalancerIP` | Requested load balancer IP of the API Service. |
| `api.replicas` | API replicas. |
| `gui.version` | GUI image tag (*required*). Versioned separately from `backpack.version`. |
| `gui.port` | Service port, forwarded to container port 80. |
| `gui.loadBalancerIP` | Requested load balancer IP of the GUI Service. |
| `gui.replicas` | GUI replicas (*required*). |
| `ingestion.replicas` | Gateway replicas (*required*). |
| `router.replicas` | Collector router replicas. |

`api`, `gui`, `ingestion` and `router` also take the [pod settings](#pod-settings).

### Infrastructure

| Key | Description | Used by |
| :--- | :--- | :--- |
| `rabbitmq.host`, `rabbitmq.user`, `rabbitmq.pass` | RabbitMQ connection (*required*). | everything except the GUI |
| `rabbitmq.api` | RabbitMQ management API URL. | API |
| `mongo.host`, `mongo.port`, `mongo.user`, `mongo.pass` | Combined into `BP_MONGO_STR`. `user` and `pass` are percent-encoded by the chart, so give them unencoded. | API, gateway |
| `redis.host`, `redis.user`, `redis.pass` | Redis connection. | API, gateway |
| `s3.endpoint`, `s3.accessKey`, `s3.secretKey`, `s3.region`, `s3.bucket` | Object storage the collectors upload to. | collectors |

### Collectors

Each entry of `collectors` deploys one collector. Which queue a collector
consumes is decided by its image, not by `id`:

| Image | Queues (`collector-...`) | Notes |
| :--- | :--- | :--- |
| `collector/git` | `git` | Needs persistent storage, run it as a StatefulSet. |
| `collector/http` | `http`, `https` | |
| `collector/container` | `docker`, `oci` | Copies images into the registry in `BP_COLLECTOR_CONTAINER_REGISTRY`. The chart does not set this variable, add it through `env` or every collect fails. |
| `collector/docker-archive` | `docker-archive` | |
| `collector/wget` | `wget` | |
| `collector/huggingface` | `hf` | |

| Key | Description | Default |
| :--- | :--- | :--- |
| `id` | Resource name suffix: `collector-<id>`. | |
| `image`, `tag` | Container image. | |
| `replicas` | Number of pods. | |
| `kind` | `Deployment` or `StatefulSet`. | `Deployment` |
| `env` | Extra environment variables. Each entry has a `name` and either a `value` or a `valueFrom` (e.g. `secretKeyRef`). | |
| `extraVolumes[].name` | Volume name. | |
| `extraVolumes[].mountPath` | Mount path in the container. Collectors work in `/data` (`BP_COLLECTOR_DIRECTORY`). | |
| `extraVolumes[].size` | Requested storage. | `1Gi` |
| `extraVolumes[].storageClass` | Storage class. | cluster default |
| `extraVolumes[].accessMode` | Access mode. | `ReadWriteOnce` |
| `persistentVolumeClaimRetentionPolicy` | StatefulSet only. `whenDeleted` / `whenScaled`, each `Retain` or `Delete`. Needs Kubernetes 1.27+. | Kubernetes default, `Retain` for both |

Every entry also takes the [pod settings](#pod-settings).

### Processors

Each entry of `processors` deploys a `processor-<id>` Deployment. The keys
are the same as for collectors, minus `kind` and
`persistentVolumeClaimRetentionPolicy`, plus:

| Key | Description |
| :--- | :--- |
| `imagePullSecrets` | List of secret names used to pull the image. |

Some processors need credentials through `env`, for example the Helm
processor reads `ARTIFACTHUB_API_KEY_ID` and `ARTIFACTHUB_API_KEY_SECRET`.
Read them from a Secret so they stay out of the values and the pod spec:

```bash
kubectl create secret generic artifacthub --from-literal=id=... --from-literal=secret=...
```

```yaml
processors:
  - id: helm
    image: ghcr.io/linus-berg/backpack/processor/helm
    tag: *backpack_version
    replicas: 1
    env:
      - name: ARTIFACTHUB_API_KEY_ID
        valueFrom:
          secretKeyRef: {name: artifacthub, key: id}
      - name: ARTIFACTHUB_API_KEY_SECRET
        valueFrom:
          secretKeyRef: {name: artifacthub, key: secret}
```

### Pod settings

`api`, `gui`, `ingestion` (the gateway), `router` and every entry of
`collectors` and `processors` take these keys. None of them are set unless
you set them.

| Key | Sets | Falls back to `defaults.<key>` |
| :--- | :--- | :--- |
| `podSecurityContext` | Pod `securityContext`. | yes |
| `securityContext` | Container `securityContext`. | yes |
| `resources` | Container `resources`. | yes |
| `nodeSelector`, `tolerations`, `affinity` | Pod scheduling. | yes |
| `livenessProbe`, `readinessProbe`, `startupProbe` | Container probes. | no |
| `podDisruptionBudget` | Creates a PodDisruptionBudget with this spec, named after the workload: `minAvailable` or `maxUnavailable` (not both), optionally `unhealthyPodEvictionPolicy`. The selector is filled in by the chart. | no |

A workload's own value replaces the default as a whole, it is not merged
with it. Set it to `{}` or `[]` to opt a workload out of a default:

```yaml
defaults:
  tolerations:
    - {key: dedicated, operator: Equal, value: backpack, effect: NoSchedule}
  resources:
    requests: {cpu: 50m, memory: 128Mi}

api:
  resources:
    requests: {cpu: 250m, memory: 256Mi}
    limits: {memory: 1Gi}
  readinessProbe:
    tcpSocket: {port: 8080}
  podDisruptionBudget:
    maxUnavailable: 1

gui:
  tolerations: []   # schedule the GUI anywhere
```

- **Probes.** The chart sets none. The API listens on port 8080 and the GUI
  on port 80. The chart declares no ports for the gateway, router,
  collectors or processors, so probe those with `exec` unless you know the
  port they listen on.
- **Disruption budgets.** Prefer `maxUnavailable: 1`. A `minAvailable` equal
  to the replica count (e.g. `minAvailable: 1` with one replica) blocks every
  eviction, so node drains hang until it is removed.
- **Security contexts.** Check what the image expects before setting
  `runAsNonRoot` or `readOnlyRootFilesystem`. The npm processor, for
  example, caches in `/root/.npm` and the API writes logs to `/logs/`.

## Collector storage

### How each collector uses disk

| Collector | Disk usage | Needs persistence |
| :--- | :--- | :--- |
| Git | Keeps a `git clone --mirror` of every repository it has collected under `/data/git/<host>/<path>/<repo>`. Later collects only run `git remote update --prune`. The uploaded bundle is staged under `/data/git/tmp/bundles` and deleted afterwards. | **Yes** |
| Docker archive | Stages `skopeo` tarballs under `/data/docker-archive`, deleted after upload. | No, scratch only. Size it for the largest image. |
| HTTP, Hugging Face | Streams to S3. Response bodies are spooled to `/tmp` (container ephemeral storage), not `/data`. | No |
| Container | Copies registry to registry with `skopeo`. | No |
| Wget | Streams to S3. | No |

Losing the Git cache does not lose data, because every bundle is a full
`git bundle create --all`. It does mean the next collect of every repository
is a full clone again, which for large repositories takes a long time
(each repository is allowed up to 120 minutes) and a lot of bandwidth.

### Why Git runs as a StatefulSet

With `kind: Deployment` the Git collector's `extraVolumes` become one
Helm-managed PVC shared by every replica. That breaks in several ways:

- **Rollouts.** A rolling update starts the new pod before stopping the old
  one. If the new pod lands on another node it cannot attach the
  `ReadWriteOnce` volume and the rollout hangs. If it lands on the same node,
  both pods use the same mirrors at the same time.
- **Sharing mirrors is unsafe.** The collector's per-repository locks only
  exist inside one process, and before each collect it deletes any `*.lock`
  and `tmp_*` files it finds in the repository. In a second pod those can
  belong to a git process that is still running. This also rules out sharing
  one `ReadWriteMany` volume between replicas.
- **Lifecycle.** The PVC belongs to the Helm release, so `helm uninstall` or
  renaming the volume in the values deletes it, and the cache with it.

With `kind: StatefulSet`:

- A pod is stopped before its replacement starts, so the volume is never
  contested during a rollout.
- Each replica gets its own claim per `extraVolumes` entry, named
  `<volume>-collector-<id>-<ordinal>`, e.g. `data-collector-git-0`.
- Those claims are created by Kubernetes, not Helm. Unless
  `persistentVolumeClaimRetentionPolicy` says otherwise they survive
  `helm upgrade`, `helm uninstall`, scaling down and deleting the
  StatefulSet. A replica that comes back picks up its old claim.

```yaml
collectors:
  - id: git
    image: ghcr.io/linus-berg/backpack/collector/git
    tag: *backpack_version
    kind: StatefulSet
    replicas: 1
    extraVolumes:
      - name: data
        mountPath: /data
        storageClass: standard
        size: 100Gi
```

`kind: StatefulSet` works for any collector, but only Git benefits from it.

### Scaling the Git collector

RabbitMQ spreads the messages of the `collector-git` queue across all
replicas, not by repository. Every replica therefore builds its own
mirror of every repository it is handed. With N replicas you end up with up
to N copies of each mirror and N initial clones. One pod already works on up
to 10 repositories at a time.

Prefer a single replica with a large volume. If you do scale out, size every
replica's volume for the whole set of repositories.

### Operations

List the claims of the Git collector:

```bash
kubectl get pvc -l app=collector-git
```

**Resizing.** Kubernetes does not allow changing `volumeClaimTemplates` on an
existing StatefulSet, so changing `size`, `storageClass`, `accessMode` or the
volume list makes `helm upgrade` fail with
`Forbidden: updates to statefulset spec for fields other than ...`. To grow
the volumes (the storage class needs `allowVolumeExpansion: true`):

```bash
# 1. Grow every replica's claim
kubectl patch pvc data-collector-git-0 -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
# 2. Delete the StatefulSet but leave its pods running
kubectl delete statefulset collector-git --cascade=orphan
# 3. Set the new size in the values and upgrade. Helm recreates the
#    StatefulSet, which adopts the running pods and existing claims.
helm upgrade backpack backpack/backpack -f my-values.yaml
```

**Moving an existing Git collector from Deployment to StatefulSet.** The
upgrade deletes the Deployment and its PVC `collector-git-data`, and the
StatefulSet starts with an empty `data-collector-git-0`. That is safe, it
just re-clones every repository. To keep the existing mirrors instead, move
the volume to the new claim name before upgrading:

```bash
kubectl scale deployment collector-git --replicas=0
PV=$(kubectl get pvc collector-git-data -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl delete pvc collector-git-data
kubectl patch pv "$PV" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-collector-git-0
  labels:
    app: collector-git
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard   # must match the PV
  volumeName: $PV
  resources:
    requests:
      storage: 10Gi            # must not exceed the PV's capacity
EOF
# Now set kind: StatefulSet in the values and upgrade
helm upgrade backpack backpack/backpack -f my-values.yaml
```

The claim spec has to match the volume (storage class, access mode, at most
its capacity) and the `extraVolumes` entry, or it never binds.

**Uninstalling.** `helm uninstall` leaves StatefulSet claims behind. Delete
them once you no longer need the cache:

```bash
kubectl delete pvc data-collector-git-0
```
