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
helm show values backpack/backpack   # every key with its default
```

[`values.yaml`](values.yaml) holds the defaults and
[`values.example.yaml`](values.example.yaml) a complete example. Start from
the example:

```bash
helm pull backpack/backpack --untar
cp backpack/values.example.yaml my-values.yaml
# edit my-values.yaml
helm install backpack backpack/backpack -n backpack --create-namespace -f my-values.yaml
```

Resource names are fixed (`backpack-api`, `collector-git`, ...) rather than
prefixed with the release name, so install one release per namespace.

The values are checked against [`values.schema.json`](values.schema.json),
so a wrong type, an unknown `kind` or an `id` that is not a valid resource
name fails the install with a message pointing at the key.

### Images

Backpack images are published to `ghcr.io/linus-berg/backpack/...` as
`master-<commit>` by every commit to Backpack's `master` branch. The chart's
`appVersion` names the latest build at the time of the chart release. That
build is used for the
API, gateway, router and every collector and processor, unless you set
`backpack.version` or a workload's own `tag`. The GUI is built from its own
repository and tagged `<commit>` (`gui.version`).

To pull from a mirror, set `image` of `api`, `gui`, `ingestion` and `router`,
and of every collector and processor, plus `defaults.imagePullSecrets` if
the mirror needs credentials.

### Upgrading to 0.1.0

- The chart now has a `values.yaml`, so keys you never set get its defaults,
  and the values are validated against the schema.
- Collector and processor Deployments with a `ReadWriteOnce` volume now roll
  out with the `Recreate` strategy (see [Collector storage](#collector-storage)).
  Every pod restarts once during the upgrade, because labels were added.
- `backpack.version` and the `tag` of collectors and processors are now
  optional and default to the chart's `appVersion`.
- The images of the old `values.example.yaml` did not exist. If you copied
  it, check `image` of the JetBrains and GitHub releases processors
  (`processor/jetbrains-plugins`, `processor/jetbrains-ide`,
  `processor/github-releases`) and drop the PHP processor, which is no
  longer built.

## What gets deployed

| Resource | Kind | Image |
| :--- | :--- | :--- |
| `backpack-api` | Deployment + Service, optionally an Ingress | `api.image`, tag `backpack.version` |
| `backpack-gui` | Deployment + Service, optionally an Ingress | `gui.image`, tag `gui.version` |
| `backpack-gateway` | Deployment | `ingestion.image`, tag `backpack.version` |
| `collector-router` | Deployment | `router.image`, tag `backpack.version` |
| `collector-<id>`, `processor-<id>` | Deployment, or StatefulSet + headless Service (see [Collector storage](#collector-storage)) | per entry in `collectors` and `processors` |
| `collector-<id>-<volume>`, `processor-<id>-<volume>` | PersistentVolumeClaim | one per claim in `extraVolumes` of a Deployment |
| `<volume>-collector-<id>-<n>`, `<volume>-processor-<id>-<n>` | PersistentVolumeClaim, created by Kubernetes | one per claim in `extraVolumes` and replica of a StatefulSet |
| `common-env-config`, `api-env-config`, `gateway-env-config`, `collector-env-config` | ConfigMap | |
| `ca-certificates` | ConfigMap, only when `ca_certificates` is set | |
| `common-env-secret`, `api-env-secret`, `gateway-env-secret`, `collector-env-secret` | Secret, unless replaced through `existingSecrets` | |
| same name as the workload, e.g. `backpack-api` | PodDisruptionBudget, only for workloads that set `podDisruptionBudget` | |

Every resource has the `app.kubernetes.io/name`, `app.kubernetes.io/instance`,
`app.kubernetes.io/managed-by` and `helm.sh/chart` labels. The workloads,
their pods and their Services also have `app: <name>`, which every selector
matches on, and `app.kubernetes.io/component`.

Pods are restarted automatically when the ConfigMaps and Secrets the chart
creates for them change. Secrets from `existingSecrets` are not watched,
restart the pods yourself after changing them.

## Configuration

`values.yaml` has the default of every key. Values marked *required* make
`helm install` fail when empty.

### Global

| Key | Description | Default |
| :--- | :--- | :--- |
| `backpack.version` | Image tag of the API, gateway and router, and of every collector and processor without its own `tag`. | the chart's `appVersion` |
| `backpack.log.level` | Default .NET log level (`LOGGING__LOGLEVEL__DEFAULT`) (*required*). | `Information` |
| `http_proxy` | Sets `HTTP_PROXY`/`HTTPS_PROXY` (both cases) for the API, gateway, router, collectors and processors. The Git collector also uses it as `git config http.proxy`. Stored in a Secret, since proxy URLs can carry credentials. | unset |
| `no_proxy` | List of hosts, joined into `NO_PROXY`/`no_proxy`. | unset |
| `hosts` | `hostAliases` entries (`ip`, `hostnames`) for every pod except the GUI. | unset |
| `ca_certificates` | PEM bundle stored in the `ca-certificates` ConfigMap and mounted over `/etc/ssl/certs/ca-certificates.crt` in the API, collectors and processors. It **replaces** the image's bundle, so include the public roots too if those services need to reach the internet. | unset |
| `oidc.authority` | OIDC realm URL (`BP_OIDC_AUTHORITY`). | |
| `oidc.audience` | Expected `aud` claim / client ID (`BP_OIDC_AUDIENCE`). | |
| `otel.host` | OpenTelemetry collector endpoint (`BP_OTEL_HOST`). | unset |
| `existingSecrets.*` | Secrets you manage, see [Credentials](#credentials). | unset |
| `defaults.*` | Pod settings for every workload that doesn't set its own, see [Pod settings](#pod-settings). | unset |

### Credentials

The chart stores the credentials from the values in four Secrets, and the
other settings in the matching `*-env-config` ConfigMaps:

| Secret | Keys | Read by |
| :--- | :--- | :--- |
| `common-env-secret` | `BP_RABBIT_MQ_PASS`, and `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, `https_proxy` when `http_proxy` is set | everything except the GUI |
| `api-env-secret` | `BP_REDIS_PASS`, `BP_MONGO_STR` | API |
| `gateway-env-secret` | `BP_REDIS_PASS`, `BP_MONGO_STR` | gateway |
| `collector-env-secret` | `BP_S3_ACCESS_KEY`, `BP_S3_SECRET_KEY` | collectors |

Two things are not covered by that:

- Helm stores the full values, credentials included, in its release Secret
  (`sh.helm.release.v1.<release>.v<revision>`), so anyone who can read
  Secrets in the namespace can read them there too.
- `env` entries of collectors and processors that use `value` are written
  into the Deployment in plain text. Give credentials, such as the Helm
  processor's ArtifactHub keys, through `valueFrom.secretKeyRef` instead.

To keep the credentials out of the values altogether, create the Secrets
yourself with the keys from the table and name them in `existingSecrets`.
The chart then doesn't create that Secret and ignores the matching values:

```bash
kubectl create secret generic backpack-common --from-literal=BP_RABBIT_MQ_PASS=...
kubectl create secret generic backpack-api \
  --from-literal=BP_REDIS_PASS=... \
  --from-literal=BP_MONGO_STR='mongodb://backpack:p%40ss@mongo:27017/'
kubectl create secret generic backpack-s3 \
  --from-literal=BP_S3_ACCESS_KEY=... --from-literal=BP_S3_SECRET_KEY=...
```

```yaml
existingSecrets:
  common: backpack-common
  api: backpack-api
  gateway: backpack-api   # the gateway needs the same keys as the API
  collector: backpack-s3
```

`BP_MONGO_STR` is used as it is, so percent-encode special characters in
the username and password yourself (`@` is `%40`, `:` is `%3A`, `/` is
`%2F`). With `existingSecrets.common`, put the proxy variables into that
Secret too if you use a proxy. The usernames and hosts still come from the
values.

### API, GUI, gateway and router

| Key | Description | Default |
| :--- | :--- | :--- |
| `api.image`, `api.tag` | API image, the tag defaults to `backpack.version`. | `ghcr.io/linus-berg/backpack/integration/api` |
| `api.host` | Public URL of the API (`BP_API_HOST`). | |
| `api.replicas` | API replicas. | `1` |
| `api.port` | Service port, forwarded to container port 8080. | `8080` |
| `gui.image` | GUI image. | `ghcr.io/linus-berg/backpack/gui` |
| `gui.version` | GUI image tag (*required*), versioned separately from `backpack.version`. | the latest build at the time of the chart release |
| `gui.replicas` | GUI replicas (*required*). | `1` |
| `gui.port` | Service port, forwarded to container port 80. | `80` |
| `ingestion.image`, `ingestion.tag` | Gateway image. | `ghcr.io/linus-berg/backpack/core/gateway` |
| `ingestion.replicas` | Gateway replicas (*required*). | `1` |
| `router.image`, `router.tag` | Collector router image. | `ghcr.io/linus-berg/backpack/collector/router` |
| `router.replicas` | Collector router replicas. | `1` |

The API and the GUI are exposed through a Service each, and optionally an
Ingress. These keys exist for both `api` and `gui`:

| Key | Description | Default |
| :--- | :--- | :--- |
| `service.type` | `ClusterIP`, `NodePort` or `LoadBalancer`. | `LoadBalancer` |
| `service.annotations` | Annotations of the Service, e.g. for your load balancer. | |
| `service.nodePort` | Node port of a `NodePort` or `LoadBalancer` Service. | picked by Kubernetes |
| `loadBalancerIP` | Requested IP of a `LoadBalancer` Service. Deprecated by Kubernetes, many providers want an annotation in `service.annotations` instead. | |
| `ingress.enabled` | Create an Ingress for the Service. | `false` |
| `ingress.className` | `ingressClassName`. | cluster default |
| `ingress.annotations` | Annotations of the Ingress. | |
| `ingress.hosts` | Rules, each a `host` with `paths` (`path`, `pathType`). `paths` defaults to `/` with `Prefix`. At least one entry is needed. | |
| `ingress.tls` | TLS section of the Ingress, passed through. | |

```yaml
api:
  host: https://api.backpack.example.com
  service:
    type: ClusterIP
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: api.backpack.example.com
    tls:
      - secretName: backpack-api-tls
        hosts: [api.backpack.example.com]
```

All four also take the [pod settings](#pod-settings).

### Infrastructure

| Key | Description | Used by |
| :--- | :--- | :--- |
| `rabbitmq.host`, `rabbitmq.user`, `rabbitmq.pass` | RabbitMQ connection (*required*, `pass` unless `existingSecrets.common` is set). | everything except the GUI |
| `rabbitmq.api` | RabbitMQ management API URL. | API |
| `mongo.host`, `mongo.port`, `mongo.user`, `mongo.pass` | Combined into `BP_MONGO_STR`. `user` and `pass` are percent-encoded by the chart, so give them unencoded. `port` defaults to `27017`. | API, gateway |
| `redis.host`, `redis.user`, `redis.pass` | Redis connection. | API, gateway |
| `s3.endpoint`, `s3.accessKey`, `s3.secretKey`, `s3.region`, `s3.bucket` | Object storage the collectors upload to. | collectors |

### Collectors and processors

Every entry of `collectors` deploys a `collector-<id>`, every entry of
`processors` a `processor-<id>`. Which queue a worker consumes is decided by
its image, not by `id`.

| Collector image | Queues (`collector-...`) | Notes |
| :--- | :--- | :--- |
| `collector/git` | `git` | Needs persistent storage, run it as a StatefulSet. |
| `collector/http` | `http`, `https` | |
| `collector/container` | `docker`, `oci` | Copies images into the registry in `BP_COLLECTOR_CONTAINER_REGISTRY`. The chart does not set this variable, add it through `env` or every collect fails. |
| `collector/docker-archive` | `docker-archive` | Needs scratch space, see [Collector storage](#collector-storage). |
| `collector/wget` | `wget` | |
| `collector/huggingface` | `hf` | |

Processor images: `processor/npm`, `processor/nuget`, `processor/pypi`,
`processor/container`, `processor/rancher`, `processor/helm`,
`processor/jetbrains-plugins`, `processor/jetbrains-ide`,
`processor/github-releases`, `processor/terraform` and
`processor/huggingface`.

| Key | Description | Default |
| :--- | :--- | :--- |
| `id` | Resource name suffix, a lowercase DNS label of at most 42 characters. Must be unique among the collectors, and among the processors. | |
| `image`, `tag` | Container image. | tag: `backpack.version` |
| `replicas` | Number of pods. | `1` |
| `kind` | `Deployment` or `StatefulSet`. | `Deployment` |
| `strategy` | Deployment only. The Deployment strategy, see [Collector storage](#collector-storage) for the default. | |
| `env` | Extra environment variables. Each entry has a `name` and either a `value` or a `valueFrom` (e.g. `secretKeyRef`). | |
| `extraVolumes[].name` | Volume name. | |
| `extraVolumes[].mountPath` | Mount path in the container. Collectors work in `/data` (`BP_COLLECTOR_DIRECTORY`). | |
| `extraVolumes[].type` | `persistentVolumeClaim`, or `emptyDir` for scratch space that lives as long as the pod. | `persistentVolumeClaim` |
| `extraVolumes[].size` | Requested storage of a claim, size limit of an `emptyDir`. | claim: `1Gi`, `emptyDir`: no limit |
| `extraVolumes[].storageClass` | Storage class of a claim. | cluster default |
| `extraVolumes[].accessMode` | Access mode of a claim. | `ReadWriteOnce` |
| `persistentVolumeClaimRetentionPolicy` | StatefulSet only. `whenDeleted` / `whenScaled`, each `Retain` or `Delete`. Needs Kubernetes 1.27+. | Kubernetes default, `Retain` for both |

Every entry also takes the [pod settings](#pod-settings).

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
| `imagePullSecrets` | Names of Secrets to pull the image with. | yes |
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
  imagePullSecrets: [my-registry]
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
  on port 80, both named `http`. The chart declares no ports for the
  gateway, router, collectors or processors, so probe those with `exec`
  unless you know the port they listen on.
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
| Docker archive | Stages `skopeo` tarballs under `/data/docker-archive`, deleted after upload. | No, scratch only. Use an `emptyDir` sized for the largest image. |
| HTTP, Hugging Face | Streams to S3. Response bodies are spooled to `/tmp` (container ephemeral storage), not `/data`. | No |
| Container | Copies registry to registry with `skopeo`. | No |
| Wget | Streams to S3. | No |

```yaml
collectors:
  - id: docker-archive
    image: ghcr.io/linus-berg/backpack/collector/docker-archive
    replicas: 1
    extraVolumes:
      - name: data
        mountPath: /data
        type: emptyDir
        size: 50Gi
```

Losing the Git cache does not lose data, because every bundle is a full
`git bundle create --all`. It does mean the next collect of every repository
is a full clone again, which for large repositories takes a long time
(each repository is allowed up to 120 minutes) and a lot of bandwidth.

### Deployments with volumes

With `kind: Deployment` every claim in `extraVolumes` becomes one
Helm-managed PVC, `<collector|processor>-<id>-<volume>`, shared by every
replica. A rolling update would start the new pod while the old one still
holds the claim, and a `ReadWriteOnce` claim can only be attached to one
node. So when a Deployment has a `ReadWriteOnce` (or `ReadWriteOncePod`)
claim, the chart rolls it out with the `Recreate` strategy instead: the old
pod stops before the new one starts, at the cost of a short gap in which no
pod consumes the queue. Set `strategy` to override that, e.g. for a
`ReadWriteMany` claim:

```yaml
processors:
  - id: npm
    image: ghcr.io/linus-berg/backpack/processor/npm
    replicas: 2
    strategy:
      type: RollingUpdate
    extraVolumes:
      - name: cache
        mountPath: /root/.npm
        accessMode: ReadWriteMany
        storageClass: nfs
```

More than one replica on a `ReadWriteOnce` claim only works while they all
land on the same node, the others stay `Pending`. The install notes warn
about it.

### Why Git runs as a StatefulSet

As a Deployment, the Git collector's replicas would share one claim, which
breaks:

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
    kind: StatefulSet
    replicas: 1
    extraVolumes:
      - name: data
        mountPath: /data
        storageClass: standard
        size: 100Gi
```

`kind: StatefulSet` works for every collector and processor. It pays off for
caches worth keeping per replica, like Git's mirrors. `emptyDir` volumes of
a StatefulSet are not claims and stay scratch space.

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
claims in the volume list makes `helm upgrade` fail with
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
