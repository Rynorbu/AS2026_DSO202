#!/usr/bin/env bash
# setup-files.sh - creates every folder and file for DSO202 Assignment 3.
# Run from Assignments/Assignment_3:   bash setup-files.sh
# Existing files are NOT overwritten (they are skipped).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p assets helm/environments helm/task-tracker helm/task-tracker/charts helm/task-tracker/templates helm/task-tracker/templates/tests kustomize/base kustomize/overlays/dev kustomize/overlays/prod

write() {
  if [ -e "$1" ]; then echo "skip   $1 (already exists)"; cat > /dev/null; else cat > "$1"; echo "create $1"; fi
}

write .gitignore <<'__EOF__'
# real credentials - never commit
kustomize/base/db-secret.env
helm/environments/secrets-*.yaml
# packaged charts
*.tgz
__EOF__

write kustomize/base/kustomization.yaml <<'__EOF__'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - db-pvc.yaml
  - db-deployment.yaml
  - db-service.yaml
  - backend-deployment.yaml
  - backend-service.yaml
  - frontend-deployment.yaml
  - frontend-service.yaml
  - quota.yaml

labels:
  - pairs:
      app.kubernetes.io/part-of: task-tracker
      app.kubernetes.io/managed-by: kustomize
    includeSelectors: false
    includeTemplates: true

configMapGenerator:
  - name: app-config
    literals:
      - DB_HOST=db-svc
      - DB_PORT=5432
      - DB_NAME=tasksdb
      - APP_PORT=8080
      - CORS_ORIGIN=*
      - BACKEND_URL=http://backend-svc:8080
      - POSTGRES_DB=tasksdb

secretGenerator:
  - name: app-secret
    envs:
      - db-secret.env
__EOF__

write kustomize/base/db-secret.env <<'__EOF__'
DB_USER=taskuser
DB_PASSWORD=taskpass123
POSTGRES_USER=taskuser
POSTGRES_PASSWORD=taskpass123
__EOF__

write kustomize/base/db-pvc.yaml <<'__EOF__'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-pvc
  labels:
    tier: database
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
__EOF__

write kustomize/base/db-deployment.yaml <<'__EOF__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-deployment
  labels:
    tier: database
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      tier: database
  template:
    metadata:
      labels:
        tier: database
    spec:
      containers:
        - name: db
          image: rynorbu11/dso202-db:1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: POSTGRES_DB
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: db-storage
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
      volumes:
        - name: db-storage
          persistentVolumeClaim:
            claimName: db-pvc
__EOF__

write kustomize/base/db-service.yaml <<'__EOF__'
apiVersion: v1
kind: Service
metadata:
  name: db-svc
  labels:
    tier: database
spec:
  clusterIP: None
  selector:
    tier: database
  ports:
    - port: 5432
      targetPort: 5432
__EOF__

write kustomize/base/backend-deployment.yaml <<'__EOF__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deployment
  labels:
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      tier: backend
  template:
    metadata:
      labels:
        tier: backend
    spec:
      containers:
        - name: backend
          image: rynorbu11/dso202-backend:1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: DB_HOST
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: DB_HOST
            - name: DB_PORT
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: DB_PORT
            - name: DB_NAME
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: DB_NAME
            - name: APP_PORT
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: APP_PORT
            - name: CORS_ORIGIN
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: CORS_ORIGIN
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: DB_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: DB_PASSWORD
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
__EOF__

write kustomize/base/backend-service.yaml <<'__EOF__'
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  labels:
    tier: backend
spec:
  type: ClusterIP
  selector:
    tier: backend
  ports:
    - port: 8080
      targetPort: 8080
__EOF__

write kustomize/base/frontend-deployment.yaml <<'__EOF__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-deployment
  labels:
    tier: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      tier: frontend
  template:
    metadata:
      labels:
        tier: frontend
    spec:
      containers:
        - name: frontend
          image: rynorbu11/dso202-frontend:1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: BACKEND_URL
              valueFrom:
                configMapKeyRef:
                  name: app-config
                  key: BACKEND_URL
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "150m"
              memory: "128Mi"
__EOF__

write kustomize/base/frontend-service.yaml <<'__EOF__'
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  labels:
    tier: frontend
spec:
  type: ClusterIP
  selector:
    tier: frontend
  ports:
    - port: 8080
      targetPort: 8080
__EOF__

write kustomize/base/quota.yaml <<'__EOF__'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dso202-quota
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: dso202-limitrange
spec:
  limits:
    - type: Container
      default:
        cpu: "200m"
        memory: "256Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      min:
        cpu: "50m"
        memory: "64Mi"
      max:
        cpu: "500m"
        memory: "512Mi"
__EOF__

write kustomize/overlays/dev/namespace.yaml <<'__EOF__'
apiVersion: v1
kind: Namespace
metadata:
  name: dso202-a3-kust-dev
  labels:
    course: dso202
    assignment: "3"
__EOF__

write kustomize/overlays/dev/patch-frontend-nodeport.yaml <<'__EOF__'
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
spec:
  type: NodePort
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 30080
__EOF__

write kustomize/overlays/dev/kustomization.yaml <<'__EOF__'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
  - namespace.yaml

namespace: dso202-a3-kust-dev

labels:
  - pairs:
      app.kubernetes.io/environment: dev
    includeSelectors: false
    includeTemplates: true

patches:
  - path: patch-frontend-nodeport.yaml
__EOF__

write kustomize/overlays/prod/namespace.yaml <<'__EOF__'
apiVersion: v1
kind: Namespace
metadata:
  name: dso202-a3-kust-prod
  labels:
    course: dso202
    assignment: "3"
__EOF__

write kustomize/overlays/prod/patch-backend-resources.yaml <<'__EOF__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deployment
spec:
  template:
    spec:
      containers:
        - name: backend
          resources:
            requests:
              cpu: "150m"
              memory: "128Mi"
            limits:
              cpu: "300m"
              memory: "256Mi"
__EOF__

write kustomize/overlays/prod/patch-db-pvc.yaml <<'__EOF__'
- op: replace
  path: /spec/resources/requests/storage
  value: 2Gi
__EOF__

write kustomize/overlays/prod/kustomization.yaml <<'__EOF__'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
  - namespace.yaml

namespace: dso202-a3-kust-prod

labels:
  - pairs:
      app.kubernetes.io/environment: prod
    includeSelectors: false
    includeTemplates: true

replicas:
  - name: backend-deployment
    count: 2
  - name: frontend-deployment
    count: 2

images:
  - name: rynorbu11/dso202-backend
    newTag: "1.0"
  - name: rynorbu11/dso202-frontend
    newTag: "1.0"

configMapGenerator:
  - name: app-config
    behavior: merge
    literals:
      - CORS_ORIGIN=http://localhost:8081

patches:
  - path: patch-backend-resources.yaml
  - path: patch-db-pvc.yaml
    target:
      kind: PersistentVolumeClaim
      name: db-pvc
__EOF__

write helm/task-tracker/Chart.yaml <<'__EOF__'
apiVersion: v2
name: task-tracker
description: Three-tier Task Tracker (nginx frontend, Node.js backend, PostgreSQL) from DSO202 Assignment 1
type: application
version: 0.1.0
appVersion: "1.0"
kubeVersion: ">=1.30.0-0"
keywords:
  - dso202
  - three-tier
  - postgres
maintainers:
  - name: Rynorbu
__EOF__

write helm/task-tracker/.helmignore <<'__EOF__'
.git/
*.swp
*.bak
*.tmp
.DS_Store
__EOF__

write helm/task-tracker/values.yaml <<'__EOF__'
# Default values for the task-tracker chart.
# Every environment file in ../environments only overrides what differs.

global:
  environment: ""            # dev | prod - required, set in environments/<env>.yaml

nameOverride: ""
fullnameOverride: ""

frontend:
  replicaCount: 1
  image:
    repository: rynorbu11/dso202-frontend
    tag: ""                  # empty -> .Chart.AppVersion
    pullPolicy: IfNotPresent
  service:
    type: ClusterIP          # ClusterIP | NodePort
    port: 8080
    nodePort: null           # 30000-32767, only used when type is NodePort
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {cpu: 150m, memory: 128Mi}

backend:
  replicaCount: 1
  image:
    repository: rynorbu11/dso202-backend
    tag: ""
    pullPolicy: IfNotPresent
  port: 8080
  corsOrigin: "*"
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {cpu: 250m, memory: 256Mi}

database:
  image:
    repository: rynorbu11/dso202-db
    tag: ""
    pullPolicy: IfNotPresent
  port: 5432
  name: tasksdb
  # Credentials have no defaults on purpose. Supply them from a values file
  # that is NOT committed (environments/secrets-<env>.yaml).
  user: ""
  password: ""
  persistence:
    size: 1Gi
    storageClassName: ""     # empty -> cluster default StorageClass
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {cpu: 250m, memory: 256Mi}

quota:
  enabled: true
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
  limitRange:
    default: {cpu: 200m, memory: 256Mi}
    defaultRequest: {cpu: 100m, memory: 128Mi}
    min: {cpu: 50m, memory: 64Mi}
    max: {cpu: 500m, memory: 512Mi}
__EOF__

write helm/task-tracker/values.schema.json <<'__EOF__'
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["global", "frontend", "backend", "database"],
  "properties": {
    "global": {
      "type": "object",
      "properties": {
        "environment": { "type": "string", "enum": ["", "dev", "prod"] }
      }
    },
    "frontend": {
      "type": "object",
      "properties": {
        "replicaCount": { "type": "integer", "minimum": 1, "maximum": 5 },
        "image": {
          "type": "object",
          "properties": { "tag": { "type": "string" } }
        },
        "service": {
          "type": "object",
          "properties": {
            "type": { "type": "string", "enum": ["ClusterIP", "NodePort"] },
            "port": { "type": "integer" },
            "nodePort": {
              "anyOf": [
                { "type": "null" },
                { "type": "integer", "minimum": 30000, "maximum": 32767 }
              ]
            }
          }
        }
      }
    },
    "backend": {
      "type": "object",
      "properties": {
        "replicaCount": { "type": "integer", "minimum": 1, "maximum": 5 },
        "image": {
          "type": "object",
          "properties": { "tag": { "type": "string" } }
        },
        "port": { "type": "integer" },
        "corsOrigin": { "type": "string" }
      }
    },
    "database": {
      "type": "object",
      "properties": {
        "image": {
          "type": "object",
          "properties": { "tag": { "type": "string" } }
        },
        "port": { "type": "integer" },
        "name": { "type": "string", "minLength": 1 },
        "user": { "type": "string" },
        "password": { "type": "string" },
        "persistence": {
          "type": "object",
          "properties": {
            "size": { "type": "string", "pattern": "^[0-9]+(Mi|Gi)$" }
          }
        }
      }
    }
  }
}
__EOF__

write helm/task-tracker/templates/_helpers.tpl <<'__EOF__'
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
__EOF__

write helm/task-tracker/templates/configmap.yaml <<'__EOF__'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "task-tracker.fullname" . }}-config
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
data:
  DB_HOST: {{ include "task-tracker.dbHost" . | quote }}
  DB_PORT: {{ .Values.database.port | quote }}
  DB_NAME: {{ .Values.database.name | quote }}
  APP_PORT: {{ .Values.backend.port | quote }}
  CORS_ORIGIN: {{ .Values.backend.corsOrigin | quote }}
  BACKEND_URL: {{ printf "http://%s:%v" (include "task-tracker.backendHost" .) .Values.backend.port | quote }}
  POSTGRES_DB: {{ .Values.database.name | quote }}
__EOF__

write helm/task-tracker/templates/secret.yaml <<'__EOF__'
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "task-tracker.fullname" . }}-secret
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
type: Opaque
data:
  {{- $user := required "database.user must be set (use environments/secrets-<env>.yaml)" .Values.database.user }}
  {{- $pass := required "database.password must be set (use environments/secrets-<env>.yaml)" .Values.database.password }}
  DB_USER: {{ $user | b64enc | quote }}
  DB_PASSWORD: {{ $pass | b64enc | quote }}
  POSTGRES_USER: {{ $user | b64enc | quote }}
  POSTGRES_PASSWORD: {{ $pass | b64enc | quote }}
__EOF__

write helm/task-tracker/templates/db-pvc.yaml <<'__EOF__'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "task-tracker.fullname" . }}-db-pvc
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
    app.kubernetes.io/component: database
  annotations:
    # Keep the data volume when the release is uninstalled.
    helm.sh/resource-policy: keep
spec:
  accessModes:
    - ReadWriteOnce
  {{- with .Values.database.persistence.storageClassName }}
  storageClassName: {{ . }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.database.persistence.size }}
__EOF__

write helm/task-tracker/templates/db-deployment.yaml <<'__EOF__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "task-tracker.fullname" . }}-db
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
    app.kubernetes.io/component: database
spec:
  replicas: 1
  # ReadWriteOnce volume: the old Pod must stop before the new one starts.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "task-tracker.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: database
  template:
    metadata:
      labels:
        {{- include "task-tracker.labels" . | nindent 8 }}
        app.kubernetes.io/component: database
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    spec:
      containers:
        - name: db
          image: "{{ .Values.database.image.repository }}:{{ .Values.database.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.database.image.pullPolicy }}
          ports:
            - name: postgres
              containerPort: {{ .Values.database.port }}
          env:
            - name: POSTGRES_DB
              valueFrom:
                configMapKeyRef:
                  name: {{ include "task-tracker.fullname" . }}-config
                  key: POSTGRES_DB
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: {{ include "task-tracker.fullname" . }}-secret
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "task-tracker.fullname" . }}-secret
                  key: POSTGRES_PASSWORD
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            {{- toYaml .Values.database.resources | nindent 12 }}
          volumeMounts:
            - name: db-storage
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: db-storage
          persistentVolumeClaim:
            claimName: {{ include "task-tracker.fullname" . }}-db-pvc
__EOF__

write helm/task-tracker/templates/db-service.yaml <<'__EOF__'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "task-tracker.dbHost" . }}
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
    app.kubernetes.io/component: database
spec:
  clusterIP: None
  selector:
    {{- include "task-tracker.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: database
  ports:
    - name: postgres
      port: {{ .Values.database.port }}
      targetPort: postgres
__EOF__

write helm/task-tracker/templates/backend-deployment.yaml <<'__EOF__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "task-tracker.fullname" . }}-backend
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  replicas: {{ .Values.backend.replicaCount }}
  selector:
    matchLabels:
      {{- include "task-tracker.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: backend
  template:
    metadata:
      labels:
        {{- include "task-tracker.labels" . | nindent 8 }}
        app.kubernetes.io/component: backend
      annotations:
        # Roll the Pods whenever the ConfigMap or Secret content changes.
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
        checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    spec:
      containers:
        - name: backend
          image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.backend.port }}
          envFrom:
            - configMapRef:
                name: {{ include "task-tracker.fullname" . }}-config
          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: {{ include "task-tracker.fullname" . }}-secret
                  key: DB_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ include "task-tracker.fullname" . }}-secret
                  key: DB_PASSWORD
          readinessProbe:
            httpGet:
              path: /api/status
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            {{- toYaml .Values.backend.resources | nindent 12 }}
__EOF__

write helm/task-tracker/templates/backend-service.yaml <<'__EOF__'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "task-tracker.backendHost" . }}
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  type: ClusterIP
  selector:
    {{- include "task-tracker.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: backend
  ports:
    - name: http
      port: {{ .Values.backend.port }}
      targetPort: http
__EOF__

write helm/task-tracker/templates/frontend-deployment.yaml <<'__EOF__'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "task-tracker.fullname" . }}-frontend
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
spec:
  replicas: {{ .Values.frontend.replicaCount }}
  selector:
    matchLabels:
      {{- include "task-tracker.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: frontend
  template:
    metadata:
      labels:
        {{- include "task-tracker.labels" . | nindent 8 }}
        app.kubernetes.io/component: frontend
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      containers:
        - name: frontend
          image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.frontend.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: BACKEND_URL
              valueFrom:
                configMapKeyRef:
                  name: {{ include "task-tracker.fullname" . }}-config
                  key: BACKEND_URL
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            {{- toYaml .Values.frontend.resources | nindent 12 }}
__EOF__

write helm/task-tracker/templates/frontend-service.yaml <<'__EOF__'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "task-tracker.frontendHost" . }}
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
spec:
  type: {{ .Values.frontend.service.type }}
  selector:
    {{- include "task-tracker.selectorLabels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
  ports:
    - name: http
      port: {{ .Values.frontend.service.port }}
      targetPort: http
      {{- if and (eq .Values.frontend.service.type "NodePort") .Values.frontend.service.nodePort }}
      nodePort: {{ .Values.frontend.service.nodePort }}
      {{- end }}
__EOF__

write helm/task-tracker/templates/quota.yaml <<'__EOF__'
{{- if .Values.quota.enabled }}
apiVersion: v1
kind: ResourceQuota
metadata:
  name: {{ include "task-tracker.fullname" . }}-quota
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
spec:
  hard:
    {{- toYaml .Values.quota.hard | nindent 4 }}
---
apiVersion: v1
kind: LimitRange
metadata:
  name: {{ include "task-tracker.fullname" . }}-limitrange
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
spec:
  limits:
    - type: Container
      {{- toYaml .Values.quota.limitRange | nindent 6 }}
{{- end }}
__EOF__

write helm/task-tracker/templates/NOTES.txt <<'__EOF__'
Task Tracker deployed.

  Release:     {{ .Release.Name }} (revision {{ .Release.Revision }})
  Namespace:   {{ .Release.Namespace }}
  Environment: {{ include "task-tracker.environment" . }}
  Replicas:    frontend={{ .Values.frontend.replicaCount }} backend={{ .Values.backend.replicaCount }} db=1

Frontend:
{{- if and (eq .Values.frontend.service.type "NodePort") .Values.frontend.service.nodePort }}
  http://localhost:{{ .Values.frontend.service.nodePort }}
{{- else }}
  kubectl -n {{ .Release.Namespace }} port-forward svc/{{ include "task-tracker.frontendHost" . }} 8081:{{ .Values.frontend.service.port }}
  then open http://localhost:8081
{{- end }}

Backend API (internal only - port-forward to test):
  kubectl -n {{ .Release.Namespace }} port-forward svc/{{ include "task-tracker.backendHost" . }} 8080:{{ .Values.backend.port }}
  curl http://localhost:8080/api/status

Run the connectivity test:
  helm test {{ .Release.Name }} -n {{ .Release.Namespace }}
__EOF__

write helm/task-tracker/templates/tests/test-backend.yaml <<'__EOF__'
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "task-tracker.fullname" . }}-test-backend
  labels:
    {{- include "task-tracker.labels" . | nindent 4 }}
  annotations:
    helm.sh/hook: test
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  restartPolicy: Never
  containers:
    - name: wget
      image: busybox:1.37
      command:
        - sh
        - -c
        - |
          wget -qO- http://{{ include "task-tracker.backendHost" . }}:{{ .Values.backend.port }}/api/status | grep '"db":"connected"'
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {cpu: 100m, memory: 64Mi}
__EOF__

write helm/environments/dev.yaml <<'__EOF__'
global:
  environment: dev

frontend:
  replicaCount: 1
  service:
    type: NodePort
    nodePort: 30080

backend:
  replicaCount: 1
  corsOrigin: "*"
__EOF__

write helm/environments/prod.yaml <<'__EOF__'
global:
  environment: prod

frontend:
  replicaCount: 2

backend:
  replicaCount: 2
  corsOrigin: "http://localhost:8081"
  resources:
    requests: {cpu: 150m, memory: 128Mi}
    limits: {cpu: 300m, memory: 256Mi}

database:
  persistence:
    size: 2Gi
__EOF__

write helm/environments/secrets-dev.yaml <<'__EOF__'
database:
  user: taskuser
  password: taskpass123
__EOF__

write helm/environments/secrets-prod.yaml <<'__EOF__'
database:
  user: taskuser
  password: change-me-prod-password
__EOF__

write kustomize/base/db-secret.env.example <<'__EOF__'
DB_USER=<change-me>
DB_PASSWORD=<change-me>
POSTGRES_USER=<change-me>
POSTGRES_PASSWORD=<change-me>
__EOF__

echo; echo "Done: $(find kustomize helm -type f | wc -l) files under kustomize/ and helm/."
