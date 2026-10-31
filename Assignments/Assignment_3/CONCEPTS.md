# DSO202 Assignment 3: Concepts and What I Am Doing

> **Task:** Use the Unit 4 concepts (package and configuration management) to deploy **Assignment 1** (the three-tier Task Tracker) with **Kustomize** and **Helm**.

This file explains **why** and **what**. The step-by-step **how** is in [`INSTRUCTIONS.md`](INSTRUCTIONS.md).

---

## 1. Where I Am Starting From (Assignment 1)

In Assignment 1 I deployed a Task Tracker app with three tiers in the namespace `dso202-assignment-01`.

| Tier | Image | Kubernetes objects | Service type |
|---|---|---|---|
| Frontend (nginx) | `rynorbu11/dso202-frontend:1.0` | Deployment + Service | NodePort `30080` |
| Backend (Node.js / Express) | `rynorbu11/dso202-backend:1.0` | Deployment + Service | ClusterIP (internal only) |
| Database (PostgreSQL) | `rynorbu11/dso202-db:1.0` | Deployment + PVC + Service | Headless (`clusterIP: None`) |

Shared objects: `Namespace`, `ConfigMap app-config`, `Secret app-secret`, `ResourceQuota`, `LimitRange`.

I deployed everything with plain `kubectl apply -f <file>` for each YAML file, one at a time.

### Problems with that approach

| Problem | Example from my Assignment 1 |
|---|---|
| **Hard-coded namespace** | Every file says `namespace: dso202-assignment-01`. A second environment (e.g. prod) means copying and editing **every** file. |
| **Copy-paste drift** | With a `dev/` copy and a `prod/` copy, I could fix a probe in one and forget the other. |
| **Secrets in Git** | `secret.yaml` holds base64 values. Base64 is **encoding, not encryption**, so anyone can decode it. |
| **ConfigMap changes don't restart Pods** | If I edit `app-config`, the running backend keeps the old environment variables until I restart it by hand. |
| **No version / no undo** | There is no version number for "the whole app" and no single command to roll back a bad change. |
| **Messy removal** | I must remember every file to delete; forgotten objects stay behind (orphans). |
| **Manual ordering** | I applied files by hand in the right order (namespace → config → db → backend → frontend). |

**Unit 4 tools solve these problems.** In this assignment I use two of them on the same application.

---

## 2. Configuration Management vs Package Management

| | **Configuration management** | **Package management** |
|---|---|---|
| Question it answers | "How do I keep **one** set of YAML and change it per environment?" | "How do I **package, version, install, upgrade and roll back** an app as one unit?" |
| Tool in this unit | **Kustomize** | **Helm** |
| Input | Plain Kubernetes YAML + `kustomization.yaml` | A **chart** (templates + `values.yaml`) |
| Output | Plain Kubernetes YAML | Plain Kubernetes YAML + a **release record** in the cluster |

Both tools end in the same place: **ordinary Kubernetes YAML sent to the API server**. They differ in how they build it and what they remember afterwards.

---

## 3. Kustomize: Template-Free Customisation

### 3.1 The core idea

> **The base stores what is shared. An overlay stores what is different. Kustomize renders the final YAML.**

Kustomize never uses `{{ }}` placeholders. My base files are **real, valid Kubernetes YAML**. Kustomize only **adds to, transforms, or patches** them.

```
kustomize/
├── base/                  ← the Assignment 1 app, with no namespace and no environment
└── overlays/
    ├── dev/               ← "dev differences": namespace, NodePort 30080
    └── prod/              ← "prod differences": namespace, 2 replicas, more CPU, bigger PVC
```

### 3.2 `kustomization.yaml` is an instruction, not a resource

`kustomization.yaml` is **never sent to Kubernetes**. It is a build recipe:

```
resource YAML + kustomization rules  →  kubectl kustomize  →  plain YAML  →  API server
```

### 3.3 The three verbs

| Verb | Field(s) | What I use it for |
|---|---|---|
| **Compose** | `resources:` | The base lists all the Assignment 1 manifests. Each overlay lists `../../base` plus its own `namespace.yaml`. |
| **Transform** | `namespace:`, `labels:`, `replicas:`, `images:` | Set the namespace on every object, add an `environment` label, scale prod to 2, pin image tags. |
| **Patch** | `patches:` | Change the frontend Service to NodePort in dev; give the backend more CPU and the PVC more storage in prod. |

### 3.4 The two patch styles

| Style | Looks like | Best for | Where I use it |
|---|---|---|---|
| **Strategic merge** | A small piece of a Kubernetes object | Readable changes to named fields or containers | `patch-frontend-nodeport.yaml`, `patch-backend-resources.yaml` |
| **JSON 6902** | A list of `op / path / value` operations | Exact paths, removals, keys containing `/` | `patch-db-pvc.yaml` (`replace /spec/resources/requests/storage`) |

> *Strategic merge speaks Kubernetes. JSON 6902 speaks paths.*

### 3.5 Generators: replacing `configmap.yaml` and `secret.yaml`

Instead of hand-writing the ConfigMap and the base64 Secret, I **generate** them:

- `configMapGenerator`, using `literals:` (`DB_HOST=db-svc`, …)
- `secretGenerator`, using `envs: [db-secret.env]` (a plain `KEY=value` file that is **git-ignored**)

**The hash suffix.** Generated objects get a content hash in their name, e.g. `app-config-9dk9996b5h`. Kustomize **automatically rewrites** every `configMapKeyRef` / `secretKeyRef` in my Deployments to the new name.

So when a config value changes:

```
value changes → hash changes → ConfigMap name changes → Deployment Pod template changes → rolling update
```

This fixes the Assignment 1 problem of a ConfigMap change not restarting Pods.

### 3.6 Why I do **not** use `namePrefix`

`namePrefix: dev-` would rename `backend-svc` to `dev-backend-svc`. Kustomize updates **references between objects**, but it does **not** look inside ConfigMap **values**. So `DB_HOST=db-svc` and `BACKEND_URL=http://backend-svc:8080` would point at Services that no longer exist.

I keep environments apart with **separate namespaces** instead. DNS names like `db-svc` resolve inside each namespace on their own.

### 3.7 Labels and selectors

I add labels with `includeSelectors: false`. A Deployment's `spec.selector` **cannot be changed** after creation, and Service selectors decide where traffic goes. Adding environment labels to selectors could break routing or block future applies.

### 3.8 The safe workflow

```
render (kubectl kustomize) → diff (kubectl diff -k) → apply (kubectl apply -k) → verify → delete -k
```

> *The rendered YAML is the truth. Debug what the overlay renders, not the overlay itself.*

---

## 4. Helm: The Package Manager for Kubernetes

### 4.1 Key words

| Word | Meaning in my assignment |
|---|---|
| **Chart** | The `task-tracker/` folder: templates for all three tiers plus default values. |
| **Values** | The settings: replicas, image tags, NodePort, DB credentials, quota. |
| **Release** | One installed copy of the chart, e.g. `tt-dev` in namespace `dso202-a3-helm-dev`. |
| **Revision** | A numbered version of a release. Install = 1, every upgrade or rollback adds one. |
| **Repository / OCI registry** | Where charts are shared (I used `podinfo` in the lecture; my chart stays local). |

### 4.2 How Helm works

```
Chart templates + values  →  (rendered on my machine)  →  YAML  →  API server
                                                        ↘ release record saved as a Secret:
                                                          sh.helm.release.v1.tt-dev.v1, .v2, ...
```

- Helm labels everything it creates with `app.kubernetes.io/managed-by: Helm`.
- The release record stores the values **in a readable form**. That is why `helm get values` can reveal the DB password, and why secrets need care.
- Helm does **not** build images, does not keep re-syncing the cluster (that is GitOps / Argo CD), and does not protect secrets.

### 4.3 Chart structure I build

| Path | Purpose |
|---|---|
| `Chart.yaml` | Name, chart `version` (0.1.0), `appVersion` ("1.0" = my image tag) |
| `values.yaml` | Default settings for frontend, backend, database and quota |
| `values.schema.json` | Type checks: tag must be a string, replicas 1–5, nodePort 30000–32767, env ∈ {dev, prod} |
| `templates/_helpers.tpl` | Named templates: `fullname`, labels, selector labels, Service host names |
| `templates/*.yaml` | ConfigMap, Secret, PVC, 3 Deployments, 3 Services, Quota + LimitRange |
| `templates/NOTES.txt` | Message printed after install (how to reach the app) |
| `templates/tests/test-backend.yaml` | A `helm test` Pod that calls `/api/status` and checks `"db":"connected"` |
| `environments/dev.yaml`, `prod.yaml` | Per-environment overrides (outside the chart) |
| `environments/secrets-*.yaml` | DB credentials, **git-ignored** |

### 4.4 Go templating concepts I use

| Concept | Example in my chart |
|---|---|
| Value reference | `{{ .Values.backend.replicaCount }}` |
| Built-in objects | `.Release.Name`, `.Release.Namespace`, `.Chart.AppVersion` |
| Default | `{{ .Values.backend.image.tag \| default .Chart.AppVersion }}` |
| Required | `required "database.password must be set" .Values.database.password` |
| `include` + `nindent` | `{{- include "task-tracker.labels" . \| nindent 4 }}` |
| `toYaml` | `{{- toYaml .Values.backend.resources \| nindent 12 }}` |
| `if` | Emit `nodePort:` only when the Service type is NodePort |
| `b64enc` | Encode the DB user and password into the Secret |
| `sha256sum` checksum | `checksum/config` annotation, so a ConfigMap/Secret change rolls the Pods (Helm's version of Kustomize's hash suffix) |

**A Helm advantage over Kustomize here:** Service names come from the release name (`tt-dev-task-tracker-db`), and the ConfigMap **builds** `DB_HOST` and `BACKEND_URL` from the **same helper**. Names and references can never drift apart, which is the problem from section 3.6.

### 4.5 Values precedence (lowest → highest)

1. `task-tracker/values.yaml` (chart defaults)
2. `-f environments/dev.yaml`
3. `-f environments/secrets-dev.yaml` (rightmost file wins)
4. `--set key=value` (overrides all files)

Maps **merge deeply**; lists and scalar values are **replaced**.

**Upgrade pitfall:** `helm upgrade` with only `--set` resets everything else to chart defaults. Always pass the `-f` files again.

### 4.6 Validation layers (weakest → strongest)

`required` → `values.schema.json` → `helm lint` → `helm template` → `helm install --dry-run=server` → `helm template | kubectl apply --dry-run=server -f -`

Each layer catches mistakes the one before it misses. For example, a misspelled field like `replica:` passes lint and template, and is caught only by the server-side dry run.

### 4.7 Release lifecycle

| Command | Revision effect |
|---|---|
| `helm upgrade --install` | Installs (rev 1) or upgrades (rev n+1). Idempotent, so it is safe in CI. |
| `helm history` | Shows all revisions |
| `helm rollback tt-dev 1` | Creates a **new** revision that copies rev 1 (history is never rewritten) |
| `helm test` | Runs the test Pod |
| `helm uninstall` | Removes the release's objects. **Not** the namespace, and **not** my PVC, which I mark `helm.sh/resource-policy: keep` so the database data survives. |

> A rollback does **not** roll back **data**. Rows written to PostgreSQL stay, because only the Kubernetes objects are reverted.

### 4.8 Database Deployment strategy: `Recreate`

The DB uses a **ReadWriteOnce** PVC. In a rolling update, the new DB Pod can start before the old one stops. Two Pods would then fight over the same volume, or the new one would get stuck. With `strategy: Recreate`, the old Pod stops first. I use this in both the Kustomize base and the Helm chart.

---

## 5. Kustomize vs Helm (What I Will Compare in My Report)

| Point | Kustomize | Helm |
|---|---|---|
| Approach | Patches plain YAML (no templates) | Go templates + values |
| Learning curve | Low: it is just YAML | Higher: template syntax, whitespace, scoping |
| Built into kubectl | Yes (`kubectl apply -k`) | No, a separate binary |
| Environments | Overlays (directories) | Values files |
| Config change → rollout | Hash suffix on generated ConfigMap/Secret | `checksum/config` annotation |
| Versioning | None (relies on Git) | Chart `version` + `appVersion` |
| Release history / rollback | No | Yes (`helm history`, `helm rollback`) |
| Distribution | Git directories / remote bases | Chart repos, OCI registries |
| Input validation | Rendered output only | `required`, JSON schema, lint, `helm test` |
| Secrets | `secretGenerator` (still only base64) | Template + values (stored in the release record) |
| Best for | My own app, small per-environment differences | Packaging, sharing, versioned upgrades and rollbacks |

They can also be **combined**: Helm renders a chart, then Kustomize post-processes it. In Unit 4, Argo CD (GitOps) can deploy either one from Git.

---

## 6. What I Am Doing: Summary

1. **Restructure Assignment 1** into a Kustomize **base** with no namespace and generated ConfigMap/Secret.
2. Create **dev** and **prod** overlays. They differ only in namespace, frontend Service type, replicas, resources and PVC size.
3. **Render, diff, apply, verify, and test CRUD**. Show that a ConfigMap change triggers a rollout through the hash. Clean up.
4. Build a **Helm chart** `task-tracker` for the same app, with helpers, a schema, NOTES and a test hook.
5. **Lint and template** for dev and prod. Show that the validation layers catch bad input.
6. **Install** dev (and prod), run `helm test`, CRUD, **upgrade** (scale + config change), **history**, **rollback**, prove that data survives, then **uninstall**.
7. **Compare** the two tools using evidence from my own run.

### Namespaces used

| Tool | dev | prod |
|---|---|---|
| Kustomize | `dso202-a3-kust-dev` | `dso202-a3-kust-prod` |
| Helm | `dso202-a3-helm-dev` (release `tt-dev`) | `dso202-a3-helm-prod` (release `tt-prod`) |

> **NodePort 30080** is mapped to `localhost:30080` by the kind cluster, and only **one** Service can use it at a time. Kustomize-dev and Helm-dev both use it, so I delete the Kustomize deployment before installing Helm-dev. Prod environments use ClusterIP and are reached with `kubectl port-forward`.
