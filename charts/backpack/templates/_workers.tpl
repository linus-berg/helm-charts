{{/*
Collectors and processors ("workers"). Every entry of .Values.collectors and
.Values.processors becomes a Deployment, or a StatefulSet with a headless
Service, named <type>-<id>. Unless noted otherwise the helpers expect a dict
with "root" (the chart root context), "worker" (the entry) and "type"
("collector" or "processor").
*/}}

{{- define "backpack.worker.name" -}}
{{- printf "%s-%s" .type (required (printf "every entry of %ss needs an id" .type) .worker.id | toString) -}}
{{- end -}}

{{/*
Values path of a worker, for error messages, e.g. collectors[git].
*/}}
{{- define "backpack.worker.key" -}}
{{- printf "%ss[%v]" .type .worker.id -}}
{{- end -}}

{{/*
Workload kind of a worker: "Deployment" (default) or "StatefulSet".
*/}}
{{- define "backpack.worker.kind" -}}
{{- $kind := .worker.kind | default "Deployment" -}}
{{- if not (has $kind (list "Deployment" "StatefulSet")) -}}
{{- fail (printf "%s.kind must be Deployment or StatefulSet, got %q" (include "backpack.worker.key" .) $kind) -}}
{{- end -}}
{{- $kind -}}
{{- end -}}

{{/*
Type of an extraVolumes entry: "persistentVolumeClaim" (default) or
"emptyDir". Expects the worker dict plus "volume".
*/}}
{{- define "backpack.worker.volumeType" -}}
{{- $type := .volume.type | default "persistentVolumeClaim" -}}
{{- if not (has $type (list "persistentVolumeClaim" "emptyDir")) -}}
{{- fail (printf "%s.extraVolumes[%s].type must be persistentVolumeClaim or emptyDir, got %q" (include "backpack.worker.key" .) .volume.name $type) -}}
{{- end -}}
{{- $type -}}
{{- end -}}

{{/*
The claims of a worker: its persistentVolumeClaim extraVolumes, as a YAML
list. Deployments get one Helm-managed PVC each, StatefulSets one per replica
through volumeClaimTemplates.
*/}}
{{- define "backpack.worker.claims" -}}
{{- $ctx := . -}}
{{- $claims := list -}}
{{- range .worker.extraVolumes -}}
{{- if eq (include "backpack.worker.volumeType" (dict "root" $ctx.root "worker" $ctx.worker "type" $ctx.type "volume" .)) "persistentVolumeClaim" -}}
{{- $claims = append $claims . -}}
{{- end -}}
{{- end -}}
{{- toYaml $claims -}}
{{- end -}}

{{/*
spec of a claim. Expects an extraVolumes entry.
*/}}
{{- define "backpack.worker.claimSpec" -}}
accessModes:
  - {{ .accessMode | default "ReadWriteOnce" }}
resources:
  requests:
    storage: {{ .size | default "1Gi" }}
{{- with .storageClass }}
storageClassName: {{ . }}
{{- end }}
{{- end -}}

{{/*
Pod template shared by worker Deployments and StatefulSets.
*/}}
{{- define "backpack.worker.podTemplate" -}}
{{- $ctx := . -}}
{{- $root := .root -}}
{{- $worker := .worker -}}
{{- $name := include "backpack.worker.name" . -}}
{{- $isDeployment := eq (include "backpack.worker.kind" .) "Deployment" -}}
{{- $volumes := list -}}
{{- $mounts := list -}}
{{- $credentialsVolume := include "backpack.credentials.volumeName" $root -}}
{{- range $worker.extraVolumes -}}
{{- if eq .name $credentialsVolume -}}
{{- fail (printf "%s.extraVolumes[%s]: the name %s is reserved for the credentials volume" (include "backpack.worker.key" $ctx) .name $credentialsVolume) -}}
{{- end -}}
{{- $mounts = append $mounts (dict "name" .name "mountPath" .mountPath) -}}
{{- if eq (include "backpack.worker.volumeType" (dict "root" $ctx.root "worker" $ctx.worker "type" $ctx.type "volume" .)) "emptyDir" -}}
{{- $volumes = append $volumes (dict "name" .name "emptyDir" (ternary (dict "sizeLimit" .size) (dict) (not (empty .size)))) -}}
{{- else if $isDeployment -}}
{{- /* StatefulSets get their claims from volumeClaimTemplates. */ -}}
{{- $volumes = append $volumes (dict "name" .name "persistentVolumeClaim" (dict "claimName" (printf "%s-%s" $name .name))) -}}
{{- end -}}
{{- end -}}
{{- $env := $worker.env | default (list) -}}
{{- if $worker.mountCredentials -}}
{{- if not (include "backpack.credentials.enabled" $root) -}}
{{- fail (printf "%s.mountCredentials is true, but no credentials are configured. Set credentials or existingSecrets.credentials." (include "backpack.worker.key" $ctx)) -}}
{{- end -}}
{{- $volumes = append $volumes (include "backpack.credentials.volume" $root | fromYaml) -}}
{{- $mounts = append $mounts (dict "name" $credentialsVolume "mountPath" (include "backpack.credentials.mountPath" $root) "readOnly" true) -}}
{{- $env = prepend $env (dict "name" "BP_CREDENTIALS_FILE" "value" (printf "%s/credentials.json" (include "backpack.credentials.mountPath" $root))) -}}
{{- end -}}
metadata:
  labels:
    {{- include "backpack.podLabels" (dict "root" $root "name" $name "component" .type) | nindent 4 }}
  annotations:
    backpack/version: {{ include "backpack.version" $root | quote }}
    checksum/config: {{ include (print $root.Template.BasePath "/common-configmap.yaml") $root | sha256sum }}
    checksum/secret: {{ include (print $root.Template.BasePath "/common-secret.yaml") $root | sha256sum }}
    {{- if eq .type "collector" }}
    checksum/collector-config: {{ include (print $root.Template.BasePath "/collector/collector-configmap.yaml") $root | sha256sum }}
    checksum/collector-secret: {{ include (print $root.Template.BasePath "/collector/collector-secret.yaml") $root | sha256sum }}
    {{- end }}
    checksum/ca-certificates: {{ include (print $root.Template.BasePath "/ca-certificates-configmap.yaml") $root | sha256sum }}
    {{- if $worker.mountCredentials }}
    {{- /* Backpack reads credentials.json at startup, so changing it restarts the pods. */}}
    checksum/credentials: {{ include (print $root.Template.BasePath "/credentials-secret.yaml") $root | sha256sum }}
    {{- end }}
spec:
  {{- with include "backpack.pod.spec" (dict "root" $root "workload" $worker "hostAliases" true "ca" true "volumes" $volumes) | trim }}
  {{- . | nindent 2 }}
  {{- end }}
  containers:
    - name: {{ $name }}
      image: {{ include "backpack.image" (dict "root" $root "workload" $worker "key" (include "backpack.worker.key" .)) }}
      {{- with include "backpack.container.spec" (dict "root" $root "workload" $worker "ca" true "volumeMounts" $mounts) | trim }}
      {{- . | nindent 6 }}
      {{- end }}
      {{- with $env }}
      env:
        {{- include "backpack.env" . | trim | nindent 8 }}
      {{- end }}
      envFrom:
        - configMapRef:
            name: common-env-config
        - secretRef:
            name: {{ include "backpack.secretName" (dict "root" $root "secret" "common") }}
        {{- if eq .type "collector" }}
        - configMapRef:
            name: collector-env-config
        - secretRef:
            name: {{ include "backpack.secretName" (dict "root" $root "secret" "collector") }}
        {{- end }}
{{- end -}}

{{/*
Deployment of a worker, followed by its PVCs.
*/}}
{{- define "backpack.worker.deployment" -}}
{{- $ctx := . -}}
{{- $name := include "backpack.worker.name" . -}}
{{- $worker := .worker -}}
{{- $claims := include "backpack.worker.claims" . | fromYamlArray -}}
{{- $strategy := $worker.strategy -}}
{{- if not $strategy -}}
{{- range $claims -}}
{{- if has (.accessMode | default "ReadWriteOnce") (list "ReadWriteOnce" "ReadWriteOncePod") -}}
{{- /* A RollingUpdate would start the new pod while the old one still holds the claim. */ -}}
{{- $strategy = dict "type" "Recreate" -}}
{{- end -}}
{{- end -}}
{{- end -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "backpack.labels" (dict "root" .root "name" $name "component" .type) | nindent 4 }}
spec:
  replicas: {{ $worker.replicas }}
  revisionHistoryLimit: 3
  {{- with $strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      app: {{ $name }}
  template:
    {{- include "backpack.worker.podTemplate" . | nindent 4 }}
{{- range $claims }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $name }}-{{ .name }}
  labels:
    {{- include "backpack.labels" (dict "root" $ctx.root "name" $name "component" $ctx.type) | nindent 4 }}
spec:
  {{- include "backpack.worker.claimSpec" . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
StatefulSet of a worker, preceded by its headless Service.

Kubernetes only allows changing replicas, template, updateStrategy,
persistentVolumeClaimRetentionPolicy, minReadySeconds and ordinals of an
existing StatefulSet. Anything else here, volumeClaimTemplates included, must
stay as it is or upgrades fail.
*/}}
{{- define "backpack.worker.statefulset" -}}
{{- $name := include "backpack.worker.name" . -}}
{{- $worker := .worker -}}
# Headless service governing the StatefulSet, workers expose no ports.
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  labels:
    {{- include "backpack.labels" (dict "root" .root "name" $name "component" .type) | nindent 4 }}
spec:
  clusterIP: None
  selector:
    app: {{ $name }}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $name }}
  labels:
    {{- include "backpack.labels" (dict "root" .root "name" $name "component" .type) | nindent 4 }}
spec:
  serviceName: {{ $name }}
  replicas: {{ $worker.replicas }}
  # Replicas compete on the same queue and never depend on each other.
  podManagementPolicy: Parallel
  {{- with $worker.persistentVolumeClaimRetentionPolicy }}
  persistentVolumeClaimRetentionPolicy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      app: {{ $name }}
  template:
    {{- include "backpack.worker.podTemplate" . | nindent 4 }}
  {{- with include "backpack.worker.claims" . | fromYamlArray }}
  # Every replica gets its own claim per volume (<volume>-<name>-<ordinal>).
  # The claims are not owned by Helm, so unless persistentVolumeClaimRetentionPolicy
  # says otherwise they outlive upgrades, scale-downs and uninstalls.
  volumeClaimTemplates:
    {{- range . }}
    - metadata:
        name: {{ .name }}
        labels:
          app: {{ $name }}
      spec:
        {{- include "backpack.worker.claimSpec" . | nindent 8 }}
    {{- end }}
  {{- end }}
{{- end -}}
