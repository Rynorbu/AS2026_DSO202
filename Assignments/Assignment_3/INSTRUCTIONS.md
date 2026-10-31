# DSO202 Assignment 3: Step-by-Step Instructions

> Deploy the Assignment 1 Task Tracker with **Kustomize** (Part A) and **Helm** (Part B).
> The theory for every step is in [`CONCEPTS.md`](CONCEPTS.md).

**Environment:** Windows + Git Bash / WSL, kind cluster `ingress` (from Assignment 2), kubectl ≥ 1.30 (built-in Kustomize v5), Helm 3.18+ / Helm 4.

> 📸 = take a screenshot and save it in `Assignments/Assignment_3/assets/` for the report.
> The full list (file names, what must be visible, and where each one goes in the report) is in the **[Screenshot Checklist](#screenshot-checklist)** near the end of this file.

---

## Step 0: Prerequisites and Cluster

### 0.1 Check the tools

```bash
kubectl version --client      # shows Kustomize Version too
helm version
kind version
docker info > /dev/null && echo "docker ok"
```

> **Helm 3 vs 4:** the lecture uses Helm 4. Everything below works on both versions. The only difference: Helm 4 calls the flag `--rollback-on-failure`, and Helm 3 calls it `--atomic`.

### 0.2 Start the kind cluster (with the 30080 port mapping)

Use your existing **`ingress`** cluster from Assignment 2 (`Assignments/Assignment_2/kind-cluster.yaml`). It already maps `localhost:30080` to NodePort 30080, which this assignment needs.

```bash
cd ~/OneDrive/Desktop/DSO202          # adjust to your path
kind get clusters                      # is "ingress" listed?
kind create cluster --config Assignments/Assignment_2/kind-cluster.yaml   # only if it is not
kubectl config use-context kind-ingress
kubectl get nodes
```

> Traefik and the Assignment 2 app can stay running. They use ports 80/443 and a ClusterIP Service, so they don't clash with NodePort 30080.

📸 `kubectl get nodes` showing 1 control-plane and 2 workers.

### 0.3 Make sure the Assignment 1 images are available

The images `rynorbu11/dso202-{frontend,backend,db}:1.0` are pulled from Docker Hub. If they are **not** pushed, load them from your local Docker into kind:

```bash
for t in frontend backend db; do kind load docker-image rynorbu11/dso202-$t:1.0 --name ingress; done
```

### 0.4 Remove the old Assignment 1 deployment (frees NodePort 30080)

```bash
kubectl delete namespace dso202-assignment-01 --ignore-not-found
```

---

## Step 1: Folder Structure

Create this layout inside `Assignments/Assignment_3/`:

```
Assignment_3/
├── CONCEPTS.md
├── INSTRUCTIONS.md
├── README.md                     ← your final report (written at the end)
├── .gitignore
├── assets/                       ← screenshots
├── kustomize/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── db-secret.env         ← git-ignored
│   │   ├── db-secret.env.example
│   │   ├── db-pvc.yaml
│   │   ├── db-deployment.yaml
│   │   ├── db-service.yaml
│   │   ├── backend-deployment.yaml
│   │   ├── backend-service.yaml
│   │   ├── frontend-deployment.yaml
│   │   ├── frontend-service.yaml
│   │   └── quota.yaml
│   └── overlays/
│       ├── dev/
│       │   ├── kustomization.yaml
│       │   ├── namespace.yaml
│       │   └── patch-frontend-nodeport.yaml
│       └── prod/
│           ├── kustomization.yaml
│           ├── namespace.yaml
│           ├── patch-backend-resources.yaml
│           └── patch-db-pvc.yaml
└── helm/
    ├── task-tracker/             ← the chart
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   ├── values.schema.json
    │   ├── .helmignore
    │   ├── charts/
    │   └── templates/
    │       ├── _helpers.tpl
    │       ├── NOTES.txt
    │       ├── configmap.yaml
    │       ├── secret.yaml
    │       ├── db-pvc.yaml
    │       ├── db-deployment.yaml
    │       ├── db-service.yaml
    │       ├── backend-deployment.yaml
    │       ├── backend-service.yaml
    │       ├── frontend-deployment.yaml
    │       ├── frontend-service.yaml
    │       ├── quota.yaml
    │       └── tests/
    │           └── test-backend.yaml
    └── environments/
        ├── dev.yaml
        ├── prod.yaml
        ├── secrets-dev.yaml      ← git-ignored
        └── secrets-prod.yaml     ← git-ignored
```

```bash
cd Assignments/Assignment_3
mkdir -p assets kustomize/base kustomize/overlays/dev kustomize/overlays/prod \
         helm/task-tracker/templates/tests helm/task-tracker/charts helm/environments
```

### `.gitignore`

```gitignore
# real credentials - never commit
kustomize/base/db-secret.env
helm/environments/secrets-*.yaml
# packaged charts
*.tgz
```

---

# Part A: Kustomize

## Step 2: Build the Base

The base is your Assignment 1 YAML with three changes:

1. **No `namespace:`** in any file. The overlay sets it.
2. **No `namespace.yaml`, `configmap.yaml` or `secret.yaml`.** The namespace moves into the overlays, and the ConfigMap and Secret are **generated**.
3. The DB Deployment gets `strategy: Recreate` (RWO volume, see CONCEPTS §4.8).

### `kustomize/base/kustomization.yaml`

```yaml
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
```

### `kustomize/base/db-secret.env` (git-ignored) and `db-secret.env.example` (committed)

```env
DB_USER=taskuser
DB_PASSWORD=taskpass123
POSTGRES_USER=taskuser
POSTGRES_PASSWORD=taskpass123
```

For `db-secret.env.example`, use the same keys with placeholder values such as `DB_PASSWORD=<change-me>`.

### `kustomize/base/db-pvc.yaml`

```yaml
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
```

### `kustomize/base/db-deployment.yaml`

```yaml
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
```

### `kustomize/base/db-service.yaml`

```yaml
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
```

### `kustomize/base/backend-deployment.yaml`

Copy `Assignment_1/backend/deployment.yaml` and **delete the `namespace:` line**. Keep all the `configMapKeyRef` / `secretKeyRef` entries pointing at `app-config` / `app-secret`; Kustomize rewrites them to the hashed names.

```yaml
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
```

### `kustomize/base/backend-service.yaml`

```yaml
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
```

### `kustomize/base/frontend-deployment.yaml`

```yaml
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
```

### `kustomize/base/frontend-service.yaml`

The base uses **ClusterIP**, which is the safe default. Dev patches it to NodePort.

```yaml
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
```

### `kustomize/base/quota.yaml`

Copy `Assignment_1/quota.yaml` (ResourceQuota + LimitRange) and **delete both `namespace:` lines**.

```yaml
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
```

### Check the base renders

```bash
kubectl kustomize kustomize/base
```

You should see a ConfigMap `app-config-<hash>`, a Secret `app-secret-<hash>`, and Deployments whose `configMapKeyRef.name` already uses the hashed name. 📸

---

## Step 3: Dev Overlay

### `kustomize/overlays/dev/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dso202-a3-kust-dev
  labels:
    course: dso202
    assignment: "3"
```

### `kustomize/overlays/dev/patch-frontend-nodeport.yaml` (strategic merge)

```yaml
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
```

### `kustomize/overlays/dev/kustomization.yaml`

```yaml
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
```

---

## Step 4: Prod Overlay

### `kustomize/overlays/prod/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dso202-a3-kust-prod
  labels:
    course: dso202
    assignment: "3"
```

### `kustomize/overlays/prod/patch-backend-resources.yaml` (strategic merge)

```yaml
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
```

### `kustomize/overlays/prod/patch-db-pvc.yaml` (JSON 6902)

```yaml
- op: replace
  path: /spec/resources/requests/storage
  value: 2Gi
```

### `kustomize/overlays/prod/kustomization.yaml`

```yaml
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
```

> **Quota check for prod:** CPU requests = 2×150m + 2×50m + 100m = **500m**, which is within the `1` CPU quota. Limits = 2×300m + 2×150m + 250m = **1150m**, which is within the `2` CPU quota. That leaves room for rolling-update surge Pods.

---

## Step 5: Render and Compare (No Cluster Changes)

```bash
cd Assignments/Assignment_3/kustomize

kubectl kustomize overlays/dev  > /tmp/kust-dev.yaml
kubectl kustomize overlays/prod > /tmp/kust-prod.yaml

# what is different between environments?
diff /tmp/kust-dev.yaml /tmp/kust-prod.yaml

# spot-checks
grep -E "namespace:|nodePort|replicas:|storage:|app-config-" /tmp/kust-dev.yaml
grep -E "namespace:|replicas:|storage:|cpu: 150m|CORS" /tmp/kust-prod.yaml
```

📸 Take screenshots showing:
- the dev render with `nodePort: 30080`, namespace `dso202-a3-kust-dev`, and hashed `app-config-xxxx`
- the prod render with `replicas: 2`, `storage: 2Gi`, `cpu: 150m`, and a **different** hash for `app-config` (because `CORS_ORIGIN` differs)

---

## Step 6: Diff and Apply Dev

`kubectl diff` compares against the live cluster, so it fails with `namespaces "dso202-a3-kust-dev" not found` when the namespace does not exist yet. Create the namespace from the overlay first, then diff:

```bash
kubectl apply -f overlays/dev/namespace.yaml
kubectl diff  -k overlays/dev        # shows everything as new (+) the first time
kubectl apply -k overlays/dev
kubectl get all,cm,secret,pvc,quota,limitrange -n dso202-a3-kust-dev
kubectl get pods -n dso202-a3-kust-dev -w        # wait until all are Running, then Ctrl+C
```

> If you get `namespace not found` on the first apply, run the apply again. Kustomize orders the Namespace first, but on a very fresh cluster it can race.
>
> **For the report:** the first `kubectl diff` fails with `namespaces ... not found`. This shows that `diff` is a **server-side** comparison against the live state, while `kubectl kustomize` is purely local.

📸 `kubectl get all` with all 3 Pods `Running` and the NodePort Service `8080:30080`.

---

## Step 7: Verify Dev (Same Tests as Assignment 1)

### 7.1 Frontend in the browser
Open **http://localhost:30080**. 📸

### 7.2 Backend health and CRUD (backend is ClusterIP, so port-forward)

Terminal 1:
```bash
kubectl port-forward -n dso202-a3-kust-dev svc/backend-svc 8080:8080
```

Terminal 2:
```bash
curl -s http://localhost:8080/api/status                       # {"status":"ok","db":"connected"}

# Create
curl -s -X POST http://localhost:8080/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title":"kustomize dev task","description":"A3 part A","status":"pending"}'

# Read
curl -s http://localhost:8080/api/tasks

# Update (use the id returned by the POST)
curl -s -X PUT http://localhost:8080/api/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{"title":"kustomize dev task","status":"done"}'

# Delete
curl -s -X DELETE http://localhost:8080/api/tasks/1
```
📸 each response.

### 7.3 Labels and generated names were applied

```bash
kubectl get deploy -n dso202-a3-kust-dev --show-labels
kubectl get cm,secret -n dso202-a3-kust-dev
kubectl get deploy backend-deployment -n dso202-a3-kust-dev \
  -o jsonpath='{.spec.template.spec.containers[0].env[0].valueFrom.configMapKeyRef.name}'; echo
```
📸 shows `app.kubernetes.io/environment=dev` and the hashed ConfigMap name used by the Deployment.

---

## Step 8: Demonstrate Hash → Automatic Rollout

1. Note the current names:
   ```bash
   kubectl get cm -n dso202-a3-kust-dev
   kubectl get pods -n dso202-a3-kust-dev -l tier=backend
   ```
2. In `overlays/dev/kustomization.yaml`, add a dev-only config change:
   ```yaml
   configMapGenerator:
     - name: app-config
       behavior: merge
       literals:
         - CORS_ORIGIN=http://localhost:30080
   ```
3. Render, diff and apply:
   ```bash
   kubectl kustomize overlays/dev | grep "name: app-config-"
   kubectl diff  -k overlays/dev
   kubectl apply -k overlays/dev
   kubectl rollout status deploy/backend-deployment -n dso202-a3-kust-dev
   kubectl get cm,pods -n dso202-a3-kust-dev
   ```
4. Check the new value reached the Pod:
   ```bash
   kubectl exec -n dso202-a3-kust-dev deploy/backend-deployment -- printenv CORS_ORIGIN
   ```

📸 the `kubectl diff` output (new ConfigMap name in the Deployment), and **new backend Pod names** after apply.

> **Explain in the report:** In Assignment 1, editing `app-config` did **not** restart the Pods. Here, the hash changed the ConfigMap name, the Pod template changed, and the Deployment rolled out automatically. The old ConfigMap is left behind; that is normal, and you can prune it or ignore it.

---

## Step 9: Apply and Verify Prod

```bash
kubectl apply -f overlays/prod/namespace.yaml
kubectl diff  -k overlays/prod
kubectl apply -k overlays/prod
kubectl get all,pvc -n dso202-a3-kust-prod
kubectl get pvc db-pvc -n dso202-a3-kust-prod -o jsonpath='{.spec.resources.requests.storage}'; echo
kubectl describe quota -n dso202-a3-kust-prod
```

Frontend (ClusterIP in prod):
```bash
kubectl port-forward -n dso202-a3-kust-prod svc/frontend-svc 8081:8080     # open http://localhost:8081
```
Backend:
```bash
kubectl port-forward -n dso202-a3-kust-prod svc/backend-svc 8082:8080
curl -s http://localhost:8082/api/status
```

📸 2 frontend + 2 backend Pods, PVC 2Gi, quota usage.

### Side-by-side comparison of the environments

```bash
for ns in dso202-a3-kust-dev dso202-a3-kust-prod; do
  echo "== $ns"; kubectl get deploy,svc,pvc -n $ns -o wide
done
```
📸

---

## Step 10: Clean Up Part A

```bash
kubectl delete -k overlays/prod
kubectl delete -k overlays/dev      # frees NodePort 30080 for Helm
kubectl get ns | grep a3-kust        # should be gone (or Terminating)
```
📸

---

# Part B: Helm

```bash
cd ../helm           # Assignments/Assignment_3/helm
```

## Step 11: (Optional) Look at the scaffold

```bash
helm create scaffold && tree scaffold || ls -R scaffold
rm -rf scaffold
```
You write the chart by hand. The scaffold is only a reference.

## Step 12: Write the Chart

### `task-tracker/Chart.yaml`

```yaml
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
```

### `task-tracker/.helmignore`

```
.git/
*.swp
*.bak
*.tmp
.DS_Store
```

### `task-tracker/values.yaml`

```yaml
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
```

### `task-tracker/values.schema.json`

```json
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
```

### `task-tracker/templates/_helpers.tpl`

```yaml
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
```

### `task-tracker/templates/configmap.yaml`

`DB_HOST` and `BACKEND_URL` are **built from the same helpers** as the Service names, so they always match.

```yaml
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
```

### `task-tracker/templates/secret.yaml`

```yaml
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
```

### `task-tracker/templates/db-pvc.yaml`

```yaml
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
```

### `task-tracker/templates/db-deployment.yaml`

```yaml
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
```

### `task-tracker/templates/db-service.yaml`

```yaml
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
```

### `task-tracker/templates/backend-deployment.yaml`

```yaml
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
```

> **Probes:** readiness uses `/api/status`, which returns 503 when the DB is unreachable, so traffic stops until the DB is back. Liveness uses a plain TCP check, so a DB outage does **not** cause backend restart loops.

### `task-tracker/templates/backend-service.yaml`

```yaml
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
```

### `task-tracker/templates/frontend-deployment.yaml`

```yaml
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
```

### `task-tracker/templates/frontend-service.yaml`

```yaml
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
```

### `task-tracker/templates/quota.yaml`

```yaml
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
```

### `task-tracker/templates/NOTES.txt`

```
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
```

### `task-tracker/templates/tests/test-backend.yaml`

```yaml
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
```

> The test Pod sets its own `resources` because the namespace has a ResourceQuota.

---

## Step 13: Environment Values Files

### `environments/dev.yaml`

```yaml
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
```

### `environments/prod.yaml`

```yaml
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
```

### `environments/secrets-dev.yaml` (git-ignored)

```yaml
database:
  user: taskuser
  password: taskpass123
```

### `environments/secrets-prod.yaml` (git-ignored)

```yaml
database:
  user: taskuser
  password: change-me-prod-password
```

---

## Step 14: Lint, Render, Validate (No Cluster Changes)

```bash
cd Assignments/Assignment_3/helm

# 14.1 lint + render both environments
for env in dev prod; do
  helm lint ./task-tracker -f environments/$env.yaml -f environments/secrets-$env.yaml && \
  helm template tt-$env ./task-tracker -n dso202-a3-helm-$env \
    -f environments/$env.yaml -f environments/secrets-$env.yaml > /tmp/helm-$env.yaml && \
  echo "$env: ok"
done
```
Expected: `1 chart(s) linted, 0 chart(s) failed`, then `dev: ok` and `prod: ok`. 📸

```bash
# 14.2 inspect one template
helm template tt-dev ./task-tracker -f environments/dev.yaml -f environments/secrets-dev.yaml \
  -s templates/configmap.yaml
# DB_HOST: "tt-dev-task-tracker-db"   BACKEND_URL: "http://tt-dev-task-tracker-backend:8080"

# 14.3 compare environments
diff /tmp/helm-dev.yaml /tmp/helm-prod.yaml
```
📸

### 14.4 Show the validation layers catch bad input (📸 each error)

```bash
# a) missing secret -> `required`
helm template tt-dev ./task-tracker -f environments/dev.yaml
# Error: ... database.user must be set (use environments/secrets-<env>.yaml)

# b) missing environment -> `required`
helm template tt-dev ./task-tracker -f environments/secrets-dev.yaml
# Error: ... global.environment must be set (dev or prod)

# c) float image tag -> JSON schema
printf 'backend:\n  image:\n    tag: 1.0\n' > /tmp/bad-tag.yaml
helm template tt-dev ./task-tracker -f environments/dev.yaml -f environments/secrets-dev.yaml -f /tmp/bad-tag.yaml
# - at '/backend/image/tag': got number, want string

# d) invalid NodePort -> JSON schema
helm template tt-dev ./task-tracker -f environments/dev.yaml -f environments/secrets-dev.yaml \
  --set frontend.service.nodePort=80
# - at '/frontend/service/nodePort': minimum: got 80, want 30,000
```

> **Explain in the report:** without `tag` as a string, YAML reads `1.0` as a number, and Helm would silently render the image `...:1`. The schema stops this before anything reaches the cluster.

### 14.5 Server-side dry run (the strongest check)

```bash
helm template tt-dev ./task-tracker -n dso202-a3-helm-dev \
  -f environments/dev.yaml -f environments/secrets-dev.yaml \
  | kubectl apply --dry-run=server -f - 2>&1 | tail -5
```
On the first run this complains `namespaces "dso202-a3-helm-dev" not found`; that is expected. To see the full check pass, run `kubectl create ns dso202-a3-helm-dev` first. Helm can still install into it in the next step.

---

## Step 15: Install Dev (Revision 1)

Make sure Part A's dev overlay is deleted, because NodePort 30080 must be free.

```bash
helm upgrade --install tt-dev ./task-tracker \
  -n dso202-a3-helm-dev --create-namespace \
  -f environments/dev.yaml -f environments/secrets-dev.yaml \
  --wait --timeout 5m
#   Helm 4: add --rollback-on-failure   |   Helm 3: add --atomic
```
📸 the NOTES output.

```bash
helm list -n dso202-a3-helm-dev
helm status tt-dev -n dso202-a3-helm-dev
kubectl get all,cm,secret,pvc,quota -n dso202-a3-helm-dev
kubectl get secrets -n dso202-a3-helm-dev -l owner=helm     # the release record: sh.helm.release.v1.tt-dev.v1
```
📸

---

## Step 16: Test Dev

```bash
# 16.1 Helm test hook
helm test tt-dev -n dso202-a3-helm-dev
# Phase: Succeeded
```
📸

```bash
# 16.2 Browser
#   http://localhost:30080

# 16.3 CRUD via port-forward (terminal 1)
kubectl port-forward -n dso202-a3-helm-dev svc/tt-dev-task-tracker-backend 8080:8080

# terminal 2
curl -s http://localhost:8080/api/status
curl -s -X POST http://localhost:8080/api/tasks -H "Content-Type: application/json" \
  -d '{"title":"helm dev task - revision 1","status":"pending"}'
curl -s http://localhost:8080/api/tasks
```
📸 Keep the task you created. You use it in Step 18 to prove that the data survives a rollback.

---

## Step 17: Upgrade (Revision 2) and Its Pitfall

### 17.1 The correct way: change the values file, pass **all** `-f` files again

Edit `environments/dev.yaml`:
```yaml
backend:
  replicaCount: 2
  corsOrigin: "http://localhost:30080"
```

```bash
helm template tt-dev ./task-tracker -f environments/dev.yaml -f environments/secrets-dev.yaml > /tmp/helm-dev-v2.yaml
diff /tmp/helm-dev.yaml /tmp/helm-dev-v2.yaml      # replicas 1->2, CORS, checksum/config changed

helm upgrade --install tt-dev ./task-tracker \
  -n dso202-a3-helm-dev \
  -f environments/dev.yaml -f environments/secrets-dev.yaml \
  --wait --timeout 5m

kubectl get pods -n dso202-a3-helm-dev -l app.kubernetes.io/component=backend
kubectl exec -n dso202-a3-helm-dev deploy/tt-dev-task-tracker-backend -- printenv CORS_ORIGIN
```
📸 2 backend Pods, **new Pod names** for all Pods that read the ConfigMap (the `checksum/config` annotation changed, so they rolled), and the new CORS value.

### 17.2 The pitfall: `--set` without the values files

```bash
helm upgrade tt-dev ./task-tracker -n dso202-a3-helm-dev --set backend.replicaCount=3
# Error: ... global.environment must be set (dev or prod)
```
📸

> **Explain:** `helm upgrade` with any `--set` **resets** to chart defaults and does **not** reuse the previous values. My `required` checks made Helm **fail safely**, instead of deploying with no password and a ClusterIP frontend. Always pass the `-f` files again, or use `--reset-then-reuse-values`.

---

## Step 18: History and Rollback (Revision 3)

```bash
helm history tt-dev -n dso202-a3-helm-dev
helm get values tt-dev -n dso202-a3-helm-dev --revision 1
helm get values tt-dev -n dso202-a3-helm-dev --revision 2

helm rollback tt-dev 1 -n dso202-a3-helm-dev --wait
helm history tt-dev -n dso202-a3-helm-dev
# REVISION 3: "Rollback to 1" - a NEW revision, history is not rewritten
kubectl get pods -n dso202-a3-helm-dev -l app.kubernetes.io/component=backend   # back to 1 replica
```
📸 history before and after.

**Data survives the rollback.** Port-forward again and list tasks. The task from Step 16 is still there:
```bash
kubectl port-forward -n dso202-a3-helm-dev svc/tt-dev-task-tracker-backend 8080:8080 &
curl -s http://localhost:8080/api/tasks
```
📸

> Helm rolled back the **Kubernetes objects**, not the **PostgreSQL rows**. The PVC was never deleted.

Revert your edit to `environments/dev.yaml` (`replicaCount: 1`, `corsOrigin: "*"`) so the file matches the running release.

---

## Step 19: Install Prod

```bash
helm upgrade --install tt-prod ./task-tracker \
  -n dso202-a3-helm-prod --create-namespace \
  -f environments/prod.yaml -f environments/secrets-prod.yaml \
  --wait --timeout 5m

helm list -A
kubectl get deploy,svc,pvc -n dso202-a3-helm-prod
helm test tt-prod -n dso202-a3-helm-prod

kubectl port-forward -n dso202-a3-helm-prod svc/tt-prod-task-tracker-frontend 8081:8080
# open http://localhost:8081
```
📸 `helm list -A` with both releases, prod with 2+2 replicas, and PVC 2Gi.

---

## Step 20: Security Observation (for the Report)

```bash
helm get values tt-dev -n dso202-a3-helm-dev          # password visible in the release record!
kubectl get secret tt-dev-task-tracker-secret -n dso202-a3-helm-dev \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
```
📸 Explain that anyone with read access to Secrets in the namespace can recover the password. Improvements to mention (not required to implement): Sealed Secrets, External Secrets Operator + a vault, SOPS, and RBAC limiting `get secrets`.

---

## Step 21: Uninstall

```bash
helm uninstall tt-prod -n dso202-a3-helm-prod
helm uninstall tt-dev  -n dso202-a3-helm-dev
helm list -A

kubectl get all,pvc -n dso202-a3-helm-dev
# PVC tt-dev-task-tracker-db-pvc is STILL there (helm.sh/resource-policy: keep)
# the namespace is also still there (Helm does not own it)
```
📸

Final cleanup:
```bash
kubectl delete ns dso202-a3-helm-dev dso202-a3-helm-prod
```

### (Optional) Package the chart

```bash
helm package ./task-tracker          # -> task-tracker-0.1.0.tgz
helm show chart task-tracker-0.1.0.tgz
```

---

## Screenshot Checklist

### How to take good screenshots

1. **Windows:** press `Win + Shift + S`, drag over the terminal or browser area, then paste into Paint (or click the notification) and **Save As** PNG into `Assignments/Assignment_3/assets/`.
2. **Show the command and its output together** in the same picture. The marker needs to see what you ran.
3. **Clear the terminal before each one** (`clear`) so only the relevant output is visible.
4. **Use the exact file names below.** They have no spaces, so they work in Markdown without `<...>` (in Assignment 1, `put curl.png` needed `<>`).
5. For long output (renders, diffs), pipe through `grep` / `head -40` as shown, so the important lines fit in one shot.
6. For the browser, include the **address bar** so the URL (`localhost:30080` / `localhost:8081`) is visible.
7. To show folder structure in Git Bash: `find kustomize -type f | sort`. In PowerShell: `tree /F kustomize`.

**Priority:** ⭐ = must have (core evidence). Others are recommended but can be skipped if the report gets too long.

### Setup

| # | File name | Step | Command(s) to run | What must be visible | Report section |
|---|---|---|---|---|---|
| 01 ⭐ | `01-cluster-nodes.png` | 0.2 | `kubectl config current-context` + `kubectl get nodes` | Context `kind-ingress`, 3 nodes `Ready` (`control-plane`, `worker-node-1`, `worker-node-2`) | Overview |
| 02 | `02-tool-versions.png` | 0.1 | `kubectl version --client` + `helm version` | kubectl version, Kustomize version, Helm version | Overview |

### Part A: Kustomize

| # | File name | Step | Command(s) to run | What must be visible | Report section |
|---|---|---|---|---|---|
| 03 ⭐ | `03-kust-structure.png` | 1–4 | `find kustomize -type f \| sort` | `base/` and `overlays/dev`, `overlays/prod` with all files | Part A: Base vs overlay |
| 04 ⭐ | `04-kust-base-render.png` | 2 | `kubectl kustomize kustomize/base \| grep -E "^kind:\|name: app-"` | `ConfigMap app-config-<hash>`, `Secret app-secret-<hash>`, and Deployments referring to the hashed names | Part A: Generators |
| 05 ⭐ | `05-kust-render-dev.png` | 5 | `grep -E "namespace:\|nodePort\|replicas:\|storage:\|app-config-" /tmp/kust-dev.yaml` | `namespace: dso202-a3-kust-dev`, `nodePort: 30080`, `replicas: 1`, `storage: 1Gi` | Part A: Render |
| 06 ⭐ | `06-kust-render-prod.png` | 5 | `grep -E "namespace:\|replicas:\|storage:\|cpu: 150m\|CORS\|app-config-" /tmp/kust-prod.yaml` | `dso202-a3-kust-prod`, `replicas: 2`, `storage: 2Gi`, `cpu: 150m`, a **different** `app-config-<hash>` than dev | Part A: Patches |
| 07 | `07-kust-diff-envs.png` | 5 | `diff /tmp/kust-dev.yaml /tmp/kust-prod.yaml \| head -40` | Lines that differ between dev and prod | Part A: Render |
| 08 ⭐ | `08-kust-apply-dev.png` | 6 | `kubectl apply -k overlays/dev` | All objects `created` (namespace, cm, secret, svc, deploy, pvc, quota, limitrange) | Part A: Apply |
| 09 ⭐ | `09-kust-get-all-dev.png` | 6 | `kubectl get all,cm,secret,pvc -n dso202-a3-kust-dev` | 3 Pods `Running`, `frontend-svc` `NodePort 8080:30080`, PVC `Bound` | Part A: Apply |
| 10 ⭐ | `10-kust-browser-dev.png` | 7.1 | Open `http://localhost:30080` | Task Tracker UI with the URL bar | Part A: Verify |
| 11 ⭐ | `11-kust-crud-dev.png` | 7.2 | The `curl` status + POST + GET + PUT + DELETE commands | `"db":"connected"`, created task JSON, list, updated `status: done`, delete response | Part A: Verify |
| 12 | `12-kust-labels.png` | 7.3 | `kubectl get deploy -n dso202-a3-kust-dev --show-labels` + the `jsonpath` command | `app.kubernetes.io/environment=dev`, `part-of=task-tracker`, hashed ConfigMap name inside the Deployment | Part A: Labels |
| 13 ⭐ | `13-kust-hash-before.png` | 8.1 | `kubectl get cm -n dso202-a3-kust-dev` + `kubectl get pods -n dso202-a3-kust-dev -l tier=backend` | Old ConfigMap name + old backend Pod name | Part A: Hash rollout |
| 14 ⭐ | `14-kust-hash-diff.png` | 8.3 | `kubectl diff -k overlays/dev` | `-` old / `+` new `app-config-<hash>` in the Deployment, new `CORS_ORIGIN` | Part A: Hash rollout |
| 15 ⭐ | `15-kust-hash-after.png` | 8.3–8.4 | `kubectl get cm,pods -n dso202-a3-kust-dev` + `printenv CORS_ORIGIN` | **Two** ConfigMaps (old + new), **new** backend Pod name, `http://localhost:30080` | Part A: Hash rollout |
| 16 ⭐ | `16-kust-prod-get.png` | 9 | `kubectl get all,pvc -n dso202-a3-kust-prod` | 2 frontend + 2 backend + 1 db Pods `Running`, frontend Service `ClusterIP`, PVC 2Gi | Part A: Prod |
| 17 | `17-kust-prod-quota.png` | 9 | `kubectl describe quota -n dso202-a3-kust-prod` | Used vs Hard for CPU / memory / pods | Part A: Prod |
| 18 | `18-kust-prod-browser.png` | 9 | port-forward 8081 then open `http://localhost:8081` | UI loads from the prod namespace | Part A: Prod |
| 19 ⭐ | `19-kust-compare-envs.png` | 9 | The `for ns in ...` loop | dev vs prod side by side (replicas, Service types, PVC sizes) | Part A: Prod |
| 20 | `20-kust-delete.png` | 10 | `kubectl delete -k overlays/prod` + `kubectl delete -k overlays/dev` + `kubectl get ns \| grep a3-kust` | Objects `deleted`, namespaces gone / Terminating | Part A: Cleanup |

### Part B: Helm

| # | File name | Step | Command(s) to run | What must be visible | Report section |
|---|---|---|---|---|---|
| 21 ⭐ | `21-helm-structure.png` | 12–13 | `find helm -type f \| sort` | `Chart.yaml`, `values.yaml`, `values.schema.json`, all templates, `tests/`, `environments/` | Part B: Chart structure |
| 22 ⭐ | `22-helm-lint-template.png` | 14.1 | The `for env in dev prod` lint + template loop | `0 chart(s) failed` twice, `dev: ok`, `prod: ok` | Part B: Validation |
| 23 ⭐ | `23-helm-configmap-render.png` | 14.2 | `helm template ... -s templates/configmap.yaml` | `DB_HOST: "tt-dev-task-tracker-db"`, `BACKEND_URL: "http://tt-dev-task-tracker-backend:8080"` | Part B: Templating |
| 24 | `24-helm-diff-envs.png` | 14.3 | `diff /tmp/helm-dev.yaml /tmp/helm-prod.yaml \| head -40` | replicas, Service type, CORS, storage differences | Part B: Templating |
| 25 ⭐ | `25-helm-fail-secret.png` | 14.4a | `helm template tt-dev ./task-tracker -f environments/dev.yaml` | `database.user must be set ...` | Part B: Validation |
| 26 ⭐ | `26-helm-fail-env.png` | 14.4b | `helm template tt-dev ./task-tracker -f environments/secrets-dev.yaml` | `global.environment must be set (dev or prod)` | Part B: Validation |
| 27 ⭐ | `27-helm-fail-tag.png` | 14.4c | The `bad-tag.yaml` command | `'/backend/image/tag': got number, want string` | Part B: Validation |
| 28 ⭐ | `28-helm-fail-nodeport.png` | 14.4d | The `--set frontend.service.nodePort=80` command | `minimum: got 80, want 30,000` | Part B: Validation |
| 29 | `29-helm-dryrun-server.png` | 14.5 | `helm template ... \| kubectl apply --dry-run=server -f -` | Objects listed as `(server dry run)` | Part B: Validation |
| 30 ⭐ | `30-helm-install-dev.png` | 15 | The `helm upgrade --install tt-dev ...` command | `STATUS: deployed`, `REVISION: 1`, and the NOTES text | Part B: Install |
| 31 ⭐ | `31-helm-list-status.png` | 15 | `helm list -n dso202-a3-helm-dev` + `helm status tt-dev -n dso202-a3-helm-dev` | Release `tt-dev`, chart `task-tracker-0.1.0`, app version `1.0`, deployed | Part B: Install |
| 32 ⭐ | `32-helm-get-all-dev.png` | 15 | `kubectl get all,cm,secret,pvc -n dso202-a3-helm-dev` | All Pods `Running`, `tt-dev-task-tracker-*` names, NodePort 30080, PVC `Bound` | Part B: Install |
| 33 | `33-helm-release-secret.png` | 15 | `kubectl get secrets -n dso202-a3-helm-dev -l owner=helm` | `sh.helm.release.v1.tt-dev.v1` (where Helm stores its history) | Part B: How Helm works |
| 34 ⭐ | `34-helm-test-dev.png` | 16.1 | `helm test tt-dev -n dso202-a3-helm-dev` | Test Pod `tt-dev-task-tracker-test-backend`, `Phase: Succeeded` | Part B: Test |
| 35 ⭐ | `35-helm-browser-dev.png` | 16.2 | Open `http://localhost:30080` | UI + URL bar | Part B: Test |
| 36 ⭐ | `36-helm-crud-dev.png` | 16.3 | port-forward + curl status, POST, GET | `"db":"connected"`, task `helm dev task - revision 1` created and listed (note its `id`) | Part B: Test |
| 37 | `37-helm-upgrade-diff.png` | 17.1 | `diff /tmp/helm-dev.yaml /tmp/helm-dev-v2.yaml` | `replicas: 1 → 2`, CORS change, `checksum/config` change | Part B: Upgrade |
| 38 ⭐ | `38-helm-upgrade-dev.png` | 17.1 | `helm upgrade --install ...` + `kubectl get pods ... -l app.kubernetes.io/component=backend` + `printenv CORS_ORIGIN` | `REVISION: 2`, 2 backend Pods with **new names**, new CORS value | Part B: Upgrade |
| 39 ⭐ | `39-helm-upgrade-pitfall.png` | 17.2 | `helm upgrade tt-dev ./task-tracker -n dso202-a3-helm-dev --set backend.replicaCount=3` | `Error: ... global.environment must be set` (Helm failed safely) | Part B: Upgrade pitfall |
| 40 ⭐ | `40-helm-history-before.png` | 18 | `helm history tt-dev ...` + `helm get values ... --revision 1` and `--revision 2` | Revisions 1 and 2, and the values difference (`replicaCount`) | Part B: Rollback |
| 41 ⭐ | `41-helm-rollback.png` | 18 | `helm rollback tt-dev 1 ...` + `helm history` + backend `kubectl get pods` | Revision **3** = `Rollback to 1`, backend back to **1** Pod | Part B: Rollback |
| 42 ⭐ | `42-helm-data-survives.png` | 18 | port-forward + `curl -s http://localhost:8080/api/tasks` | The task from screenshot 36 is **still there** after the rollback | Part B: Rollback |
| 43 ⭐ | `43-helm-prod-install.png` | 19 | `helm list -A` + `kubectl get deploy,svc,pvc -n dso202-a3-helm-prod` | Both releases `tt-dev` and `tt-prod`; prod 2/2 frontend + 2/2 backend, ClusterIP, PVC 2Gi | Part B: Prod |
| 44 | `44-helm-test-prod.png` | 19 | `helm test tt-prod -n dso202-a3-helm-prod` | `Phase: Succeeded` | Part B: Prod |
| 45 | `45-helm-browser-prod.png` | 19 | port-forward 8081, open `http://localhost:8081` | UI from prod | Part B: Prod |
| 46 ⭐ | `46-helm-secret-exposed.png` | 20 | `helm get values tt-dev ...` + the `base64 -d` command | Password readable in plain text from both places (it's a dummy password, so this is safe to show) | Security considerations |
| 47 ⭐ | `47-helm-uninstall.png` | 21 | `helm uninstall` x2 + `helm list -A` + `kubectl get all,pvc -n dso202-a3-helm-dev` | Releases gone, but **PVC still present** (resource-policy keep), namespace still exists | Part B: Uninstall |
| 48 | `48-helm-package.png` | 21 (optional) | `helm package ./task-tracker` + `helm show chart task-tracker-0.1.0.tgz` | `task-tracker-0.1.0.tgz` created | Part B: Distribution |

### How to put a screenshot in the report

Use the same pattern as your Assignment 1 README: image, then a one-line explanation in a quote block.

```markdown
![Kustomize hash rollout - diff](assets/14-kust-hash-diff.png)

> `kubectl diff -k` shows the Deployment's ConfigMap reference changing from `app-config-9dk9996b5h`
> to a new hash. Because the Pod template changed, Kubernetes rolled out new backend Pods automatically.
```

For a pair of screenshots that belong together (before/after), put them one after the other and write a single explanation below both.

### Final check before submitting

```bash
ls Assignments/Assignment_3/assets | wc -l                     # expect ~35 (all ⭐) to 48
grep -o 'assets/[^)]*' Assignments/Assignment_3/README.md | while read f; do
  [ -f "Assignments/Assignment_3/$f" ] || echo "MISSING: $f"
done                                                           # prints nothing if every image link works
```

---

## Step 22: Write the Report (`Assignment_3/README.md`)

Suggested sections. Match the style of your Assignment 1 and 2 READMEs:

1. **Overview**: the aim and the Assignment 1 recap (architecture image from A1 `assets/arch.png`)
2. **Problems with plain manifests**: the table from CONCEPTS §1
3. **Part A: Kustomize**
   - Base vs overlay design (tree + what is in each)
   - Generators + hash suffix (screenshot of the hashed name and the rollout)
   - Patches: strategic merge vs JSON 6902 (one of each)
   - Why no `namePrefix` (CONCEPTS §3.6)
   - Render → diff → apply → verify → delete evidence
4. **Part B: Helm**
   - Chart structure and `values.yaml` design
   - Templating techniques (helpers, `required`, checksum, `if`, `toYaml`)
   - Validation layers (4 failure screenshots)
   - Install, test, CRUD, upgrade, pitfall, history, rollback, data survives
   - Prod install, uninstall + kept PVC
5. **Kustomize vs Helm comparison**: the table from CONCEPTS §5, plus your own opinion of which you'd use for this app and why
6. **Security considerations**: secrets in Git and in Helm release records
7. **Challenges faced and how I solved them**
8. **Conclusion**

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `provided port is already allocated` (30080) | Another Service still uses NodePort 30080. Delete the A1 namespace or the Kustomize dev overlay first: `kubectl get svc -A \| grep 30080`. |
| Pods `Pending`, event `exceeded quota` | Requests are over the ResourceQuota (often during a rolling-update surge). Lower the replicas or raise `quota.hard`. |
| `ErrImagePull` / `ImagePullBackOff` | Images are not on Docker Hub. Run `kind load docker-image rynorbu11/dso202-<tier>:1.0 --name ingress`. |
| Backend `0/1 Ready` | `/api/status` returns 503 because the DB is not ready yet. Wait, or check `kubectl logs deploy/...-db`. |
| `kubectl apply -k` error `must be a directory` | `-k` takes a **folder** with a `kustomization.yaml`, not a file. |
| `secretGenerator`: `no such file db-secret.env` | You cloned without the git-ignored file. Copy `db-secret.env.example` to `db-secret.env`. |
| Helm: `rendered manifests contain a resource that already exists` | Objects with the same name exist but are not Helm-managed. Delete them, or use a different namespace. |
| Helm: `UPGRADE FAILED: another operation is in progress` | A previous command was interrupted. Run `helm history`, then `helm rollback <release> <last-good-rev>`. |
| DB Pod stuck `ContainerCreating` after an upgrade | The RWO volume is still attached to the old Pod. Make sure `strategy: Recreate` is set on the DB Deployment. |
| Template error at line N | Run `helm template ... --debug` to see the raw output, and check the `nindent` numbers. |
