{{/*
Image tag of the API, gateway and router, and of every collector and
processor without its own tag: backpack.version, or else the chart's
appVersion. Expects the chart root context.
*/}}
{{- define "backpack.version" -}}
{{- .Values.backpack.version | default .Chart.AppVersion -}}
{{- end -}}

{{/*
Image of a workload: <image>:<tag>, with the tag defaulting to
backpack.version. Expects a dict with "root" (the chart root context),
"workload" (the workload's values) and "key" (its values path, for errors).
*/}}
{{- define "backpack.image" -}}
{{- $image := required (printf "%s.image must be set" .key) .workload.image -}}
{{- printf "%s:%v" $image (.workload.tag | default (include "backpack.version" .root)) -}}
{{- end -}}

{{/*
Labels of a workload's pods. "app" is what every selector matches on. Never
change it: selectors are immutable, so changing it breaks upgrades.
Expects a dict with "root", "name" (e.g. backpack-api) and "component".
*/}}
{{- define "backpack.podLabels" -}}
app: {{ .name }}
app.kubernetes.io/name: backpack
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Labels of every resource the chart creates. Expects a dict with "root" and,
for resources that belong to one workload, "name" and "component".
*/}}
{{- define "backpack.labels" -}}
app.kubernetes.io/name: backpack
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- with .component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- with .name }}
app: {{ . }}
{{- end }}
{{- end -}}

{{/*
Name of one of the chart's credential Secrets ("common", "api", "gateway" or
"collector"): existingSecrets.<secret> if set, otherwise <secret>-env-secret.
Expects a dict with "root" and "secret".
*/}}
{{- define "backpack.secretName" -}}
{{- get (.root.Values.existingSecrets | default (dict)) .secret | default (printf "%s-env-secret" .secret) -}}
{{- end -}}

{{/*
MongoDB connection string (BP_MONGO_STR) shared by the API and the gateway.

The username and password are percent-encoded, as the MongoDB connection
string spec requires, so characters like @ : / ? # % work in them. urlquery
encodes everything except A-Z a-z 0-9 - _ . ~ but turns spaces into "+",
which drivers would decode as a literal plus. A "+" can only come from a
space (a literal "+" becomes %2B), so replacing it with %20 is safe.

Unset parts render empty, rather than as "<no value>", because the result is
base64 encoded into a Secret and Helm only strips "<no value>" from the
rendered manifest, not from the output of include.
*/}}
{{- define "backpack.mongo.connectionString" -}}
{{- with .Values.mongo -}}
{{- $user := .user | default "" | urlquery | replace "+" "%20" -}}
{{- $pass := .pass | default "" | urlquery | replace "+" "%20" -}}
mongodb://{{ $user }}:{{ $pass }}@{{ .host | default "" }}:{{ .port | default "" }}/
{{- end -}}
{{- end -}}

{{/*
A pod or container setting of a workload, rendered as YAML (empty when unset).
The workload's own value wins whenever it sets the key, even to {} or [], so
a workload can opt out of a default; otherwise .Values.defaults.<key> is used.
Expects a dict with "root", "workload" and "key".
*/}}
{{- define "backpack.setting" -}}
{{- $workload := .workload | default (dict) -}}
{{- $defaults := .root.Values.defaults | default (dict) -}}
{{- $value := ternary (get $workload .key) (get $defaults .key) (hasKey $workload .key) -}}
{{- with $value }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/*
Pod-level fields shared by every workload: securityContext (from
podSecurityContext), nodeSelector, affinity, tolerations and imagePullSecrets
(each falling back to .Values.defaults), hostAliases and volumes.
Expects a dict with:
  root         the chart root context
  workload     the workload's values
  hostAliases  true to add .Values.hosts as hostAliases
  ca           true to add the volume of .Values.ca_certificates
  volumes      optional list of further volumes
*/}}
{{- define "backpack.pod.spec" -}}
{{- $ctx := . -}}
{{- range $field, $key := dict "securityContext" "podSecurityContext" "nodeSelector" "nodeSelector" "affinity" "affinity" "tolerations" "tolerations" }}
{{- with include "backpack.setting" (dict "root" $ctx.root "workload" $ctx.workload "key" $key) }}
{{ $field }}:
  {{- . | nindent 2 }}
{{- end }}
{{- end }}
{{- with include "backpack.setting" (dict "root" .root "workload" .workload "key" "imagePullSecrets") | fromYamlArray }}
imagePullSecrets:
  {{- range . }}
  - name: {{ if kindIs "map" . }}{{ .name | quote }}{{ else }}{{ . | quote }}{{ end }}
  {{- end }}
{{- end }}
{{- if .hostAliases }}
{{- with .root.Values.hosts }}
hostAliases:
  {{- range . }}
  - ip: {{ .ip | quote }}
    hostnames:
      {{- range .hostnames }}
      - {{ . | quote }}
      {{- end }}
  {{- end }}
{{- end }}
{{- end }}
{{- $volumes := .volumes | default (list) }}
{{- if and .ca .root.Values.ca_certificates }}
{{- $volumes = prepend $volumes (dict "name" "ca-certificates-config-volume" "configMap" (dict "name" "ca-certificates")) }}
{{- end }}
{{- with $volumes }}
volumes:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Container-level fields shared by every workload: securityContext and
resources (falling back to .Values.defaults), the probes (which do not, since
they depend on the image) and volumeMounts. Expects a dict with "root",
"workload", "ca" (true to mount .Values.ca_certificates) and an optional list
of further "volumeMounts".
*/}}
{{- define "backpack.container.spec" -}}
{{- $ctx := . -}}
{{- range $key := list "securityContext" "resources" }}
{{- with include "backpack.setting" (dict "root" $ctx.root "workload" $ctx.workload "key" $key) }}
{{ $key }}:
  {{- . | nindent 2 }}
{{- end }}
{{- end }}
{{- range $key := list "livenessProbe" "readinessProbe" "startupProbe" }}
{{- with get ($ctx.workload | default (dict)) $key }}
{{ $key }}:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- $mounts := .volumeMounts | default (list) }}
{{- if and .ca .root.Values.ca_certificates }}
{{- $mounts = prepend $mounts (dict "name" "ca-certificates-config-volume" "mountPath" "/etc/ssl/certs/ca-certificates.crt" "subPath" "ca-certificates.crt") }}
{{- end }}
{{- with $mounts }}
volumeMounts:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
env of a collector or processor container. Every entry has a name and either
a value or a valueFrom (e.g. secretKeyRef). Values are quoted, so numbers and
booleans work as they always have. Expects the list of entries.
*/}}
{{- define "backpack.env" -}}
{{- range . }}
- name: {{ required "every env entry needs a name" .name | quote }}
  {{- if not (kindIs "invalid" .value) }}
  value: {{ .value | quote }}
  {{- end }}
  {{- with .valueFrom }}
  valueFrom:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Service of the API or the GUI. Expects a dict with "root", "name",
"component" and "values" (.Values.api or .Values.gui).
*/}}
{{- define "backpack.service" -}}
{{- $values := .values -}}
{{- $service := $values.service | default (dict) -}}
{{- $type := $service.type | default "LoadBalancer" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels:
    {{- include "backpack.labels" (dict "root" .root "name" .name "component" .component) | nindent 4 }}
  {{- with $service.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ $type }}
  {{- if and (eq $type "LoadBalancer") $values.loadBalancerIP }}
  loadBalancerIP: {{ $values.loadBalancerIP | quote }}
  {{- end }}
  ports:
    - name: http
      protocol: TCP
      port: {{ required (printf "%s.port must be set" .component) $values.port }}
      targetPort: http
      {{- if and (ne $type "ClusterIP") $service.nodePort }}
      nodePort: {{ $service.nodePort }}
      {{- end }}
  selector:
    app: {{ .name }}
{{- end -}}

{{/*
Ingress of the API or the GUI, empty unless ingress.enabled. Expects the same
dict as backpack.service.
*/}}
{{- define "backpack.ingress" -}}
{{- $ingress := .values.ingress | default (dict) -}}
{{- if $ingress.enabled -}}
{{- if not $ingress.hosts -}}
{{- fail (printf "%s.ingress.hosts needs at least one entry when the ingress is enabled" .component) -}}
{{- end -}}
{{- $name := .name -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .name }}
  labels:
    {{- include "backpack.labels" (dict "root" .root "name" .name "component" .component) | nindent 4 }}
  {{- with $ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with $ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with $ingress.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- range $ingress.hosts }}
    - http:
        paths:
          {{- range .paths | default (list (dict)) }}
          - path: {{ .path | default "/" }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $name }}
                port:
                  name: http
          {{- end }}
      {{- with .host }}
      host: {{ . | quote }}
      {{- end }}
    {{- end }}
{{- end -}}
{{- end -}}
