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
Expects a dict with "root" (the chart root context), "workload" (the values
of one workload, e.g. .Values.api or an entry of .Values.collectors) and "key".
*/}}
{{- define "backpack.setting" -}}
{{- $workload := .workload | default (dict) -}}
{{- $defaults := .root.Values.defaults | default (dict) -}}
{{- $value := ternary (get $workload .key) (get $defaults .key) (hasKey $workload .key) -}}
{{- with $value }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/*
Pod-level settings of a workload: securityContext (from podSecurityContext),
nodeSelector, affinity and tolerations, each falling back to .Values.defaults.
Expects the same dict as backpack.setting, minus "key".
*/}}
{{- define "backpack.pod.settings" -}}
{{- $ctx := . -}}
{{- range $field, $key := dict "securityContext" "podSecurityContext" "nodeSelector" "nodeSelector" "affinity" "affinity" "tolerations" "tolerations" }}
{{- with include "backpack.setting" (dict "root" $ctx.root "workload" $ctx.workload "key" $key) }}
{{ $field }}:
  {{- . | nindent 2 }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Container-level settings of a workload: securityContext and resources, which
fall back to .Values.defaults, and the probes, which do not since they depend
on the image. Expects the same dict as backpack.pod.settings.
*/}}
{{- define "backpack.container.settings" -}}
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
