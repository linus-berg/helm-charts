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
