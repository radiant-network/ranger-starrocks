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
Non-secret env block for the migrate Job.
Secrets (DB password, account passwords) must be supplied via migrate.extraEnvFrom.
*/}}
{{- define "ranger.migrateEnv" -}}
- name: RANGER_DB_HOST
  value: {{ .Values.db.host | quote }}
- name: RANGER_DB_NAME
  value: {{ .Values.db.name | quote }}
- name: RANGER_DB_USER
  value: {{ .Values.db.user | quote }}
{{- end }}

{{/*
Non-secret env block for the serve Deployment.
Secrets (DB password) must be supplied via serve.extraEnvFrom.
*/}}
{{- define "ranger.serveEnv" -}}
- name: RANGER_DB_HOST
  value: {{ .Values.db.host | quote }}
- name: RANGER_DB_NAME
  value: {{ .Values.db.name | quote }}
- name: RANGER_DB_USER
  value: {{ .Values.db.user | quote }}
- name: RANGER_POLICYMGR_EXTERNAL_URL
  value: {{ .Values.ranger.policyMgrExternalUrl | quote }}
- name: RANGER_REGISTER_ON_SERVE
  value: "false"
{{- end }}

{{/*
Non-secret env block for the register Job.
Secrets (admin password, StarRocks credentials) must be supplied via register.extraEnvFrom.
*/}}
{{- define "ranger.registerEnv" -}}
- name: RANGER_ADMIN_URL
  value: {{ .Values.register.adminUrl | quote }}
- name: RANGER_ADMIN_USER
  value: {{ .Values.register.adminUser | quote }}
- name: RANGER_STARROCKS_JDBC_URL
  value: {{ .Values.starrocks.jdbcUrl | quote }}
- name: RANGER_STARROCKS_SERVICE_NAME
  value: {{ .Values.starrocks.serviceName | quote }}
- name: RANGER_STARROCKS_AUTOCOMPLETE
  value: {{ .Values.starrocks.autocomplete | quote }}
- name: RANGER_USERSYNC_USER
  value: {{ .Values.starrocks.usersyncUser | quote }}
- name: RANGER_TAGSYNC_USER
  value: {{ .Values.starrocks.tagsyncUser | quote }}
{{- end }}
