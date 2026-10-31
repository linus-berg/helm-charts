{{/*
Workload kind of a collector: "Deployment" (default) or "StatefulSet".
Expects an entry of .Values.collectors.
*/}}
{{- define "backpack.collector.kind" -}}
{{- $kind := .kind | default "Deployment" -}}
{{- if not (has $kind (list "Deployment" "StatefulSet")) -}}
{{- fail (printf "collectors[%s].kind must be Deployment or StatefulSet, got %q" .id $kind) -}}
{{- end -}}
{{- $kind -}}
{{- end -}}

{{/*
Pod template shared by collector Deployments and StatefulSets. A StatefulSet
gets its extraVolumes from volumeClaimTemplates, so only a Deployment
references the standalone claims from collector-pvc.yaml here.
Expects a dict with "root" (the chart root context) and "collector" (an
entry of .Values.collectors).
*/}}
{{- define "backpack.collector.podTemplate" -}}
{{- $root := .root -}}
{{- $collector := .collector -}}
{{- $claims := and $collector.extraVolumes (eq (include "backpack.collector.kind" $collector) "Deployment") -}}
metadata:
  labels:
    app: collector-{{ $collector.id }}
  annotations:
    backpack/version: {{ $root.Values.backpack.version }}
    checksum/config: {{ include (print $root.Template.BasePath "/common-configmap.yaml") $root | sha256sum }}
    checksum/secret: {{ include (print $root.Template.BasePath "/common-secret.yaml") $root | sha256sum }}
    checksum/collector-config: {{ include (print $root.Template.BasePath "/collector/collector-configmap.yaml") $root | sha256sum }}
    checksum/collector-secret: {{ include (print $root.Template.BasePath "/collector/collector-secret.yaml") $root | sha256sum }}
    checksum/ca-certificates: {{ include (print $root.Template.BasePath "/ca-certificates-configmap.yaml") $root | sha256sum }}
spec:
  {{- with include "backpack.pod.settings" (dict "root" $root "workload" $collector) | trim }}
  {{- . | nindent 2 }}
  {{- end }}
  {{- if $root.Values.hosts }}
  hostAliases:
    {{- range $root.Values.hosts }}
    - ip: {{ .ip | quote }}
      hostnames:
      {{- range .hostnames }}
        - {{ . | quote }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if or $root.Values.ca_certificates $claims }}
  volumes:
    {{- if $root.Values.ca_certificates }}
    - name: ca-certificates-config-volume
      configMap:
        name: ca-certificates
    {{- end }}
    {{- if $claims }}
    {{- range $collector.extraVolumes }}
    - name: {{ .name }}
      persistentVolumeClaim:
        claimName: collector-{{ $collector.id }}-{{ .name }}
    {{- end }}
    {{- end }}
  {{- end }}
  containers:
    - name: collector-{{ $collector.id }}
      image: {{ $collector.image }}:{{ $collector.tag }}
      {{- with include "backpack.container.settings" (dict "root" $root "workload" $collector) | trim }}
      {{- . | nindent 6 }}
      {{- end }}
      volumeMounts:
        {{- if $root.Values.ca_certificates }}
        - mountPath: /etc/ssl/certs/ca-certificates.crt
          name: ca-certificates-config-volume
          subPath: ca-certificates.crt
        {{- end }}
        {{- range $collector.extraVolumes }}
        - mountPath: {{ .mountPath }}
          name: {{ .name }}
        {{- end }}
      {{- with $collector.env }}
      env:
        {{- include "backpack.env" . | trim | nindent 8 }}
      {{- end }}
      envFrom:
        - configMapRef:
            name: common-env-config
        - secretRef:
            name: common-env-secret
        - configMapRef:
            name: collector-env-config
        - secretRef:
            name: collector-env-secret
{{- end -}}
