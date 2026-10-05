# Practical 5: Environment-Specific Configuration with Kustomize on Kind

## Objectives

- Render a base and multiple overlays (dev, staging, prod, qa, sandbox)
- Deploy every environment without copying the base Deployment or Service
- Use namespace, labels, replicas, images, configMapGenerator, and patches
- Observe the ConfigMap hash → rollout behaviour
- Follow the safe workflow: **render → diff → apply → verify**
- Diagnose problems from rendered output

## Lab Topology

```
Kind cluster                Namespaces
├── control-plane           ├── webapp-dev
├── worker-node-1           ├── webapp-staging
└── worker-node-2           ├── webapp-prod
                            └── webapp-qa
```

---

### Task 0: Pre-flight checks

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl version --client -o yaml
```

![Pre-flight](assets/0.png)

All nodes are `Ready`, the context points to the Kind cluster and the client includes Kustomize, so `-k` is supported.

---

### Task 1: Repository structure

```bash
tree examples/webapp      
```

![Tree](assets/tree.png)

1. **Files that exist once for all environments:** `base/deployment.yaml`, `base/service.yaml`, `base/kustomization.yaml` (and the default `base/index.html`).
2. **Values that differ:** namespace, `environment` label, replica count, image tag, page content (`index.html`), resource requests/limits, annotations.
3. **Where the differences live:** only in `overlays/<env>/kustomization.yaml` plus small files next to it (`index.html`, `namespace.yaml`, patch files).

---

### Task 2: Render the base

```bash
kubectl kustomize examples/webapp/base
kubectl kustomize examples/webapp/base | grep '^kind:'
kubectl kustomize examples/webapp/base | grep 'name: web-content'
```

![Base render](assets/2.png)
![Base filters](assets/render.png)

- Resources rendered: `ConfigMap`, `Service`, `Deployment`.
- Generated ConfigMap name: `web-content-<hash>` (e.g. `web-content-t9bf58c444`).
- The Deployment volume `configMap.name` was rewritten from `web-content` to `web-content-<hash>`.

**Checkpoint — why is the name not `web-content`?**
`configMapGenerator` appends a hash of the ConfigMap's content to its name. Kustomize then rewrites every reference to it (here, the Deployment's volume). When the content changes, the name changes too, so the Deployment's pod template changes and Kubernetes rolls out new pods. Without the hash, pods would keep serving the old content.

---

### Task 3: Compare dev and prod renderings

```bash
kubectl kustomize examples/webapp/overlays/dev  > /tmp/webapp-dev.yaml
kubectl kustomize examples/webapp/overlays/prod > /tmp/webapp-prod.yaml
diff -u /tmp/webapp-dev.yaml /tmp/webapp-prod.yaml || true
```

![dev vs prod diff](assets/diff.png)

| # | Difference | dev | prod |
|---|---|---|---|
| 1 | Namespace | `webapp-dev` | `webapp-prod` |
| 2 | `environment` label | `dev` | `prod` |
| 3 | Replicas | 1 | 3 |
| 4 | Image | `nginx:1.25` | `nginx:1.25.5` |
| 5 | Resources (requests / limits CPU) | 50m / 100m | 200m / 500m |
| 6 | Page content / ConfigMap hash | development page | production page |
| 7 | Annotation | none | `training.example.com/tier: production` |

The diff is only a few readable lines. With fully copied manifests, a reviewer would have to compare two complete files to find the same changes.

---

### Task 4: Deploy dev safely

```bash
kubectl kustomize examples/webapp/overlays/dev
kubectl diff -k examples/webapp/overlays/dev || true
kubectl apply -k examples/webapp/overlays/dev
kubectl get all -n webapp-dev
kubectl get configmap -n webapp-dev
kubectl rollout status deployment/webapp -n webapp-dev
```

![dev render](assets/3.png)
![dev apply](assets/3.1.png)
![get all dev](assets/3.2.png)

The Deployment keeps the base name `webapp`. The `webapp-dev` namespace is what isolates the environment.

---

### Task 5: Access the application

```bash
kubectl port-forward -n webapp-dev service/webapp 8080:80
# second terminal
curl http://127.0.0.1:8080
```

![port-forward](assets/port_forwarding.png)
![curl dev](assets/curl_base.png)


The response is `<h1>This is for the development environment</h1>`, which confirms the dev overlay's content is being served.

---

### Task 6: Prove the ConfigMap hash → rollout chain

**Before**

```bash
kubectl get configmap -n webapp-dev
kubectl get pods -n webapp-dev -o wide
```

![before](assets/6.png)

Edit `examples/webapp/overlays/dev/index.html` → `<h1>DEV v2 — configuration changed</h1>`

```bash
kubectl kustomize examples/webapp/overlays/dev | grep 'name: web-content'
kubectl apply -k examples/webapp/overlays/dev
kubectl rollout status deployment/webapp -n webapp-dev
```

![render after edit](assets/6.1.png)

**After**

```bash
kubectl get configmap -n webapp-dev
kubectl get pods -n webapp-dev -o wide
```

![after](assets/6.2.png)

| | Before | After |
|---|---|---|
| ConfigMap | `web-content-XXXX` | `web-content-YYYY` |
| Pod | `webapp-XXXX-xxxxx` | `webapp-YYYY-yyyyy` |

```
file content changed → generated ConfigMap content changed
→ generated ConfigMap name hash changed → Deployment reference changed
→ Deployment pod template changed → rollout occurred
```

---

### Task 7: Deploy staging and prod

```bash
kubectl diff -k examples/webapp/overlays/staging || true
kubectl apply -k examples/webapp/overlays/staging
kubectl diff -k examples/webapp/overlays/prod || true
kubectl apply -k examples/webapp/overlays/prod
kubectl get deploy -A -l app.kubernetes.io/name=webapp
kubectl get pods -A -l app.kubernetes.io/name=webapp -o wide
```

![all envs](assets/7.png)

| Environment | Namespace | Replicas |
|---|---|---|
| dev | webapp-dev | 1 |
| staging | webapp-staging | 2 |
| prod | webapp-prod | 3 |

---

### Task 8: Inspect the prod patch

```bash
cat examples/webapp/overlays/prod/patch-resources.yaml
kubectl kustomize examples/webapp/overlays/prod
```

![prod patch](assets/8.png)

1. **Deleted or merged?** Merged. The strategic merge patch matched the container by `name: nginx` and replaced only the `resources` values. The image, ports and volumeMounts from the base were kept.
2. **Who owns the production policy?** The prod overlay (`overlays/prod/patch-resources.yaml`). The base and other environments are untouched.
3. **Why patch instead of copy?** A copy drifts: every later base change (new port, probe, image) would have to be repeated by hand in `prod/`. A patch states only the difference, so it stays small, reviewable and in sync with the base.

---

### Task 9: QA overlay

```bash
kubectl kustomize examples/webapp/overlays/qa | grep -B2 -A2 owner
kubectl diff -k examples/webapp/overlays/qa || true
kubectl apply -k examples/webapp/overlays/qa
kubectl get deployment webapp -n webapp-qa -o yaml
```

![qa render](assets/9.png)
![qa deployment](assets/9.1.png)

#### Strategic merge patch vs JSON 6902 patch

| | Strategic merge (prod) | JSON 6902 (qa) |
|---|---|---|
| Format | A partial Kubernetes object | A list of `op` / `path` / `value` operations |
| Target | Found from the patch's own `kind` + `metadata.name` | Must be given explicitly with `target:` |
| Lists | Merged by key (e.g. container `name`) | Addressed by index/path (`/spec/.../0/...`) |
| Best for | Changing or adding fields in a familiar shape | Exact operations: add, remove, replace, test a single path |

The base Deployment has no annotations, so the JSON patch adds the whole `/metadata/annotations` map. If annotations already existed, the safer path would be `/metadata/annotations/training.example.com~1owner` (`~1` escapes `/`).

---

### Challenge: `namePrefix` in a sandbox overlay

`overlays/sandbox/kustomization.yaml` adds `namePrefix: sandbox-`.

| Object / reference | Prediction | Actual |
|---|---|---|
| Deployment name | `sandbox-webapp` | `sandbox-webapp` |
| Service name | `sandbox-webapp` | `sandbox-webapp` |
| ConfigMap name | `sandbox-web-content-<hash>` | `sandbox-web-content-bf64f96mh8` |
| Deployment volume `configMap.name` | rewritten to the prefixed name | rewritten |
| Namespace object | not prefixed | `webapp-sandbox` (unchanged) |
| Volume name / container name | unchanged (not resource names) | unchanged |
| Service selector / labels | unchanged (labels are not names) | unchanged |

Kustomize knows which fields hold references to other resources, so renaming the ConfigMap also updated the Deployment that mounts it.

---

## Reflection: a Kustomize mistake and how the rendered output exposed it

My first dev overlay had `resources: ../../base` but **no `configMapGenerator` with `behavior: replace`**. I assumed that putting an `index.html` in `overlays/dev/` would be enough. When I curled the dev service, it returned the base page. Running `kubectl kustomize examples/webapp/overlays/dev | grep -A2 'index.html'` showed the cause: the ConfigMap still held `This is for the base environment`, and editing `dev/index.html` left the hash unchanged. Adding the generator with `behavior: replace` fixed it. Since then I render and grep the output before applying.

## Conclusion

One base and several small overlays deployed four environments with no copied Deployment or Service. The differences between environments are easy to read and review. The ConfigMap hash suffix turns a content change into a rollout, and the render → diff → apply → verify workflow catches mistakes before they reach the cluster.
