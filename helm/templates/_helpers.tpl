{{/*
Expand the name of the chart.
*/}}
{{- define "ranger.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "ranger.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "ranger.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/name: {{ include "ranger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for the serve Deployment / Service.
*/}}
{{- define "ranger.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ranger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Image reference shared by all three phases.
*/}}
{{- define "ranger.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end }}

{{/*
Ingress host derived from ranger.externalUrl (scheme + port stripped).
Returns empty string if externalUrl is not set.
*/}}
{{- define "ranger.derivedIngressHost" -}}
{{- if .Values.ranger.externalUrl -}}
{{- $parsed := .Values.ranger.externalUrl | urlParse -}}
{{- $parsed.host | splitList ":" | first -}}
{{- end -}}
{{- end }}

{{/*
Render one env entry that is either a literal value or sourced from a Secret/ConfigMap, with a
group-level default Secret name and a default key.
Takes (dict "name" <ENV> "spec" <field> "secret" <group-secret> "key" <default-key>).

<field> resolves as:
  - "literal" (non-empty scalar)  -> plain value
  - { value: x }                  -> plain value
  - { configMap: { name, key } }  -> configMapKeyRef
  - { secret: { name?, key? } }   -> secretKeyRef (name/key fall back to <group-secret>/<default-key>)
  - {} / "" / unset               -> secretKeyRef { <group-secret>, <default-key> } if both set,
                                     else nothing.
*/}}
{{- define "ranger.credEnv" -}}
{{- $name := .name -}}
{{- $gsecret := .secret | default "" -}}
{{- $dkey := .key | default "" -}}
{{- if kindIs "map" .spec -}}
{{- $s := .spec -}}
{{- if $s.value }}
- name: {{ $name }}
  value: {{ $s.value | quote }}
{{- else if $s.configMap }}
- name: {{ $name }}
  valueFrom:
    configMapKeyRef:
      name: {{ $s.configMap.name | quote }}
      key: {{ $s.configMap.key | quote }}
{{- else if $s.secret }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $s.secret.name | default $gsecret | quote }}
      key: {{ $s.secret.key | default $dkey | quote }}
{{- else if and $gsecret $dkey }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $gsecret | quote }}
      key: {{ $dkey | quote }}
{{- end }}
{{- else if .spec }}
- name: {{ $name }}
  value: {{ .spec | quote }}
{{- else if and $gsecret $dkey }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $gsecret | quote }}
      key: {{ $dkey | quote }}
{{- end -}}
{{- end }}

{{/*
Env block for the migrate Job: DB connection + every credential migrate populates.
Routed credentials: DB password (+ root), all four account passwords.
*/}}
{{- define "ranger.migrateEnv" -}}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_HOST" "spec" .Values.db.host "secret" .Values.db.secret "key" "RANGER_DB_HOST") -}}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_NAME" "spec" .Values.db.name "secret" .Values.db.secret "key" "RANGER_DB_NAME") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_USER" "spec" .Values.db.user "secret" .Values.db.secret "key" "RANGER_DB_USER") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_ROOT_USER" "spec" .Values.db.rootUser "secret" .Values.db.secret "key" "RANGER_DB_ROOT_USER") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_PASSWORD" "spec" .Values.db.password "secret" .Values.db.secret "key" "RANGER_DB_PASSWORD") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_ROOT_PASSWORD" "spec" .Values.db.rootPassword "secret" .Values.db.secret) }}
{{- include "ranger.credEnv" (dict "name" "RANGER_ADMIN_PASSWORD" "spec" .Values.accounts.admin "secret" .Values.accounts.secret "key" "RANGER_ADMIN_PASSWORD") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_KEYADMIN_PASSWORD" "spec" .Values.accounts.keyadmin "secret" .Values.accounts.secret "key" "RANGER_KEYADMIN_PASSWORD") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_TAGSYNC_PASSWORD" "spec" .Values.accounts.tagsync "secret" .Values.accounts.secret "key" "RANGER_TAGSYNC_PASSWORD") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_USERSYNC_PASSWORD" "spec" .Values.accounts.usersync "secret" .Values.accounts.secret "key" "RANGER_USERSYNC_PASSWORD") }}
{{- end }}

{{/*
Env block for the serve Deployment: DB connection + DB password only (user auth resolves
against the DB that migrate populated).
*/}}
{{- define "ranger.serveEnv" -}}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_HOST" "spec" .Values.db.host "secret" .Values.db.secret "key" "RANGER_DB_HOST") -}}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_NAME" "spec" .Values.db.name "secret" .Values.db.secret "key" "RANGER_DB_NAME") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_USER" "spec" .Values.db.user "secret" .Values.db.secret "key" "RANGER_DB_USER") }}
- name: RANGER_POLICYMGR_EXTERNAL_URL
  value: {{ .Values.ranger.externalUrl | quote }}
- name: RANGER_REGISTER_ON_SERVE
  value: "false"
{{- include "ranger.credEnv" (dict "name" "RANGER_DB_PASSWORD" "spec" .Values.db.password "secret" .Values.db.secret "key" "RANGER_DB_PASSWORD") }}
{{- end }}

{{/*
Env block for the register Job: admin endpoint/creds + StarRocks config and creds. No DB.
*/}}
{{- define "ranger.registerEnv" -}}
- name: RANGER_ADMIN_URL
  value: {{ .Values.register.adminUrl | quote }}
- name: RANGER_ADMIN_USER
  value: {{ .Values.register.adminUser | quote }}
- name: RANGER_STARROCKS_AUTOCOMPLETE
  value: {{ ternary "yes" "no" .Values.starrocks.autocomplete | quote }}
{{- include "ranger.credEnv" (dict "name" "RANGER_STARROCKS_JDBC_URL" "spec" .Values.starrocks.jdbcUrl "secret" .Values.starrocks.secret "key" "RANGER_STARROCKS_JDBC_URL") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_STARROCKS_SERVICE_NAME" "spec" .Values.starrocks.serviceName "secret" .Values.starrocks.secret "key" "RANGER_STARROCKS_SERVICE_NAME") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_ADMIN_PASSWORD" "spec" .Values.accounts.admin "secret" .Values.accounts.secret "key" "RANGER_ADMIN_PASSWORD") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_STARROCKS_USERNAME" "spec" .Values.starrocks.username "secret" .Values.starrocks.secret "key" "RANGER_STARROCKS_USERNAME") }}
{{- include "ranger.credEnv" (dict "name" "RANGER_STARROCKS_PASSWORD" "spec" .Values.starrocks.password "secret" .Values.starrocks.secret "key" "RANGER_STARROCKS_PASSWORD") }}
{{- end }}
