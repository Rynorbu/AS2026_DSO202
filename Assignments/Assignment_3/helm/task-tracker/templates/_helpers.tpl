{{/*
_helpers.tpl - named templates shared by every file in templates/.
*/}}

{{/* task-tracker.name: the chart name, or nameOverride when set. */}}
{{- define "task-tracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
task-tracker.fullname: base name of every object, e.g. "tt-dev-task-tracker".
If the release name already contains the chart name it is used alone.
*/}}
{{- define "task-tracker.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* task-tracker.chart: "<name>-<version>" for the helm.sh/chart label. */}}
{{- define "task-tracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* task-tracker.environment: fails the render when no environment is given. */}}
{{- define "task-tracker.environment" -}}
{{- required "global.environment must be set (dev or prod)" .Values.global.environment }}
{{- end }}

{{/* task-tracker.selectorLabels: stable labels - never add changing values here. */}}
{{- define "task-tracker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "task-tracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* task-tracker.labels: the full recommended label set. */}}
{{- define "task-tracker.labels" -}}
helm.sh/chart: {{ include "task-tracker.chart" . }}
{{ include "task-tracker.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: task-tracker
dso202/environment: {{ include "task-tracker.environment" . | quote }}
{{- end }}

{{/* Service names - used by the ConfigMap so DNS names always match. */}}
{{- define "task-tracker.dbHost" -}}
{{ include "task-tracker.fullname" . }}-db
{{- end }}
{{- define "task-tracker.backendHost" -}}
{{ include "task-tracker.fullname" . }}-backend
{{- end }}
{{- define "task-tracker.frontendHost" -}}
{{ include "task-tracker.fullname" . }}-frontend
{{- end }}
