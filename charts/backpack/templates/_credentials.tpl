{{/*
Credentials for private sources (e.g. a GitHub Enterprise instance), looked
up by host by the workers that set mountCredentials: true. The chart renders
them into credentials.json plus one token file per host and mounts both into
those workers at backpack.credentials.mountPath, pointing BP_CREDENTIALS_FILE
at credentials.json. See "Private sources" in README.md.

Tokens are mounted as files without subPath, so Kubernetes updates them in
place when a Secret changes and Backpack, which re-reads token files on every
fetch, uses a rotated token without a restart.
*/}}

{{- define "backpack.credentials.mountPath" -}}
/run/secrets/backpack
{{- end -}}

{{/*
Name of the credentials volume in worker pods.
*/}}
{{- define "backpack.credentials.volumeName" -}}
backpack-credentials
{{- end -}}

{{/*
True (non-empty) when credentials are configured, either through
.Values.credentials or existingSecrets.credentials. Expects the root context.
*/}}
{{- define "backpack.credentials.enabled" -}}
{{- if or .Values.credentials (get (.Values.existingSecrets | default (dict)) "credentials") -}}
true
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding credentials.json: existingSecrets.credentials if
set, otherwise the chart's credentials-secret. Expects the root context.
*/}}
{{- define "backpack.credentials.secretName" -}}
{{- get (.Values.existingSecrets | default (dict)) "credentials" | default "credentials-secret" -}}
{{- end -}}

{{/*
Host as used in Secret keys and file names. Secret keys only allow
[-._a-zA-Z0-9], so the ":" of host:port becomes "_". Expects the host.
*/}}
{{- define "backpack.credentials.slug" -}}
{{- regexReplaceAll "[^-._a-zA-Z0-9]" . "_" -}}
{{- end -}}

{{/*
Validates .Values.credentials and fails with a readable message on the first
problem. Expects the root context.
*/}}
{{- define "backpack.credentials.validate" -}}
{{- $slugs := dict -}}
{{- range $host, $credential := .Values.credentials -}}
{{- $key := printf "credentials[%s]" $host -}}
{{- if not (kindIs "map" $credential) -}}
{{- fail (printf "%s must be a map with token or tokenSecret" $key) -}}
{{- end -}}
{{- $hasToken := not (empty (toString ($credential.token | default ""))) -}}
{{- $hasSecret := not (empty $credential.tokenSecret) -}}
{{- if eq $hasToken $hasSecret -}}
{{- fail (printf "%s needs exactly one of token or tokenSecret" $key) -}}
{{- end -}}
{{- if $hasSecret -}}
{{- if not (and $credential.tokenSecret.name $credential.tokenSecret.key) -}}
{{- fail (printf "%s.tokenSecret needs a name and a key" $key) -}}
{{- end -}}
{{- end -}}
{{- $slug := include "backpack.credentials.slug" $host -}}
{{- if hasKey $slugs $slug -}}
{{- fail (printf "credentials[%s] and credentials[%s] map to the same token file %s, rename one of them" (get $slugs $slug) $host $slug) -}}
{{- end -}}
{{- $_ := set $slugs $slug $host -}}
{{- end -}}
{{- end -}}

{{/*
credentials.json as Backpack reads it (see Core.Kernel/HostCredentials.cs):
host -> {username, token_file}. Expects the root context.
*/}}
{{- define "backpack.credentials.json" -}}
{{- $root := . -}}
{{- $out := dict -}}
{{- range $host, $credential := .Values.credentials -}}
{{- $entry := dict "token_file" (printf "%s/tokens/%s" (include "backpack.credentials.mountPath" $root) (include "backpack.credentials.slug" $host)) -}}
{{- with $credential.username -}}
{{- $_ := set $entry "username" (toString .) -}}
{{- end -}}
{{- $_ := set $out $host $entry -}}
{{- end -}}
{{- toPrettyJson $out -}}
{{- end -}}

{{/*
The credentials volume of a worker pod, a projected volume combining the
chart's (or your) Secret with the Secrets named in tokenSecret. Rendered as
YAML. Expects the root context.
*/}}
{{- define "backpack.credentials.volume" -}}
{{- $root := . -}}
{{- $sources := list -}}
{{- if get (.Values.existingSecrets | default (dict)) "credentials" -}}
{{- /* Your Secret is mounted as it is: credentials.json and its token files. */ -}}
{{- $sources = append $sources (dict "secret" (dict "name" (include "backpack.credentials.secretName" $root))) -}}
{{- else -}}
{{- $items := list (dict "key" "credentials.json" "path" "credentials.json") -}}
{{- $external := list -}}
{{- range $host, $credential := .Values.credentials -}}
{{- $slug := include "backpack.credentials.slug" $host -}}
{{- if $credential.tokenSecret -}}
{{- $external = append $external (dict "secret" (dict "name" $credential.tokenSecret.name "items" (list (dict "key" $credential.tokenSecret.key "path" (printf "tokens/%s" $slug))))) -}}
{{- else -}}
{{- $items = append $items (dict "key" (printf "token-%s" $slug) "path" (printf "tokens/%s" $slug)) -}}
{{- end -}}
{{- end -}}
{{- $sources = concat (list (dict "secret" (dict "name" (include "backpack.credentials.secretName" $root) "items" $items))) $external -}}
{{- end -}}
name: {{ include "backpack.credentials.volumeName" $root }}
projected:
  sources:
    {{- toYaml $sources | nindent 4 }}
{{- end -}}
