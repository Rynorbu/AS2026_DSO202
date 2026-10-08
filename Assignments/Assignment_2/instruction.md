# DSO202 Assignment 2: Step-by-Step Instructions (StatefulSet + Traefik Ingress)

Assignment 1's Task Tracker, rebuilt with the Unit 2 concepts:

| Unit 2 topic | Where it is used |
|---|---|
| 2.1.1 Use cases for StatefulSets | PostgreSQL moved from a Deployment + PVC to a StatefulSet (`db/statefulset.yaml`) |
| 2.1.2.1 Stable network identity | Pod `db-0`, DNS `db-0.db-headless`, which the backend uses as `DB_HOST` |
| 2.1.2.2 Ordered deployment and scaling | `podManagementPolicy: OrderedReady`; scale 1 → 3 → 1 |
| 2.1.3 Headless Service | `db/service.yaml` (`clusterIP: None`, name `db-headless`) |
| 2.1.4 Volume claim templates | `volumeClaimTemplates` creates one PVC per pod: `db-storage-db-0`, … |
| 2.2.1.1 Basic routing rules | `app.dso202.local/api` → backend, `/` → frontend |
| 2.2.1.2 TLS termination | `tls:` block + secret `dso202-tls` (self-signed) |
| 2.2.1.3 Name-based virtual hosting | `app.dso202.local` → frontend, `api.dso202.local` → backend (same IP and port) |
| 2.2.2.2 Traefik Ingress Controller | `traefik/traefik.yaml` |
| 2.2.3 Controller-specific annotations | `router.entrypoints`, `router.tls`, `router.middlewares` (HTTPS redirect + security headers) |

Final architecture:

```
Browser ──https://app.dso202.local──► 127.0.0.1:443 (kind port mapping)
                                         │
                              Traefik pod (control-plane node, hostPort 80/443)
                              TLS terminated here with secret dso202-tls
                     ┌───────────────┼────────────────────┐
           app.dso202.local/     app.dso202.local/api   api.dso202.local/
                     │               │                    │
               frontend-svc      backend-svc ◄────────────┘
               (ClusterIP)       (ClusterIP)
                                     │  DB_HOST=db-0.db-headless
                               db-headless (clusterIP: None)
                                     │
                               StatefulSet db → db-0 ── PVC db-storage-db-0
```

---

## 0. What was wrong and what was fixed

| Problem | Fix |
|---|---|
| `configmap.yaml` had `DB_HOST: db-0.db-svc`, but the headless Service is named `db-headless`, so the backend could never reach the DB | `DB_HOST: db-0.db-headless` |
| `BACKEND_URL: /api` made the frontend call `/api/api/tasks`, so a strip-prefix middleware was added as a workaround | `BACKEND_URL: "."`, so the frontend calls the relative `./api/tasks` on the same host and port; the Ingress routes `/api` on that host to the backend, so no prefix stripping is needed |
| 3 different Traefik installs (`traefik/deployment.yaml` v3.1, `traefik/traefik-ingress.yaml` v2.10, `traefik-ingress.yaml`) with different ServiceAccounts/ports | `traefik/traefik.yaml` (v3.1, CRD provider enabled, runs on the control-plane with hostPort 80/443, so no port-forward is needed) + `traefik/rbac.yaml` (required permissions, apply once) |
| 4 conflicting Ingresses (`app-ingress.yaml`, `ingress-backend.yaml`, `ingress-frontend.yaml`, `ingress.yaml`) all routing `/` or `/api` | One file: `Ingress/ingress.yaml` (HTTPS Ingress + HTTP→HTTPS redirect Ingress) |
| `Ingress/middleware.yaml` only had strip-prefix middlewares | Now `redirect-https` and `security-headers` (real controller-specific features) |
| `db/deployment.yaml`, `db/pvc.yaml` are Assignment 1 files (namespace `dso202-assignment-01`); `kubectl apply -f db/` would apply them | Not used; delete them (see below) |
| StatefulSet did not pass `PGDATA` | Added `PGDATA` env from the ConfigMap |
| Stale comments (`manifests/0X-...`, `taskdb`, `tasktracker.local`) | Updated |

The old duplicate files (extra Traefik installs, extra Ingresses, the Assignment 1 `db/deployment.yaml`/`db/pvc.yaml`, `setp.md`, old `tls.crt`/`tls.key`) have been deleted.

Files you will actually use:

```
kind-cluster.yaml
namespace.yaml  quota.yaml  secret.yaml  configmap.yaml
db/service.yaml  db/statefulset.yaml
backend/deployment.yaml  backend/service.yaml
frontend/deployment.yaml  frontend/service.yaml
traefik/rbac.yaml  traefik/traefik.yaml
Ingress/middleware.yaml  Ingress/ingress.yaml
```

---

## How to use this guide

- Run every command in **WSL (Ubuntu)** from the Assignment_2 folder:
  ```bash
  cd /mnt/c/Users/HP/OneDrive/Desktop/DSO202/Assignments/Assignment_2
  ```
- 📸 **SCREENSHOT `NN-name.png`** means: take a screenshot of the terminal (or browser) now and save it in `assets/` with that name. The names are new so they don't overwrite your old ones.
- Keep the terminal wide so long lines don't wrap.

---

## Step 0: Reset everything (start from zero)

Everything you created before (namespaces, Services, Deployments, the StatefulSet, PVCs, the NGINX controller, Traefik, the CRDs, the TLS secret) lives **inside the kind cluster**. Deleting the cluster removes all of it in one go, so you don't need to delete resources one by one.

**0a. Make sure Docker is running** (in WSL):

```bash
docker ps
# If you see "Cannot connect to the Docker daemon":
sudo service docker start        # (or start Docker Desktop on Windows)
```

**0b. Delete every old kind cluster:**

```bash
kind get clusters                       # shows e.g. "ingress" and/or "dso202"
for c in $(kind get clusters); do kind delete cluster --name "$c"; done
kind get clusters                       # must print: No kind clusters found.
docker ps -a --filter "label=io.x-k8s.kind.cluster"   # must be empty
```

> This also deletes your Assignment 1 cluster if it is in that list. If you still need it, delete only the Assignment 2 one(s), e.g. `kind delete cluster --name ingress`. Ports 80/443 must be free, so any cluster that maps them has to go.

**0c. Remove leftovers on your machine:**

```bash
cd /mnt/c/Users/HP/OneDrive/Desktop/DSO202/Assignments/Assignment_2
rm -f tls.crt tls.key                   # old self-signed cert; regenerated in Step 7
kubectl config get-contexts             # old kind-* contexts should be gone
sudo ss -ltnp | grep -E ':(80|443) '    # must print nothing (ports free)
```

If `ss` shows something on port 80/443 (e.g. Apache or nginx installed in WSL), stop it: `sudo service apache2 stop` / `sudo service nginx stop`.

Now continue with Step 1. Every step below, in order, is the full assignment.

---

## Step 1: Fresh kind cluster with ports 80/443 mapped

The Traefik pod binds host ports 80/443 on the control-plane node, and `kind-cluster.yaml` maps those to `127.0.0.1:80/443` on your machine. This only works if the cluster was **created** with this file.

```bash
kind create cluster --config kind-cluster.yaml
kubectl config use-context kind-ingress
```

> If `kind create` fails with an image error, your kind version is older than the pinned node image. Run `kind version`; if it is below v0.32.0, remove the three `image: kindest/node:…` lines from `kind-cluster.yaml` and run the command again.

Verify:

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get storageclass
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

📸 **SCREENSHOT `01-cluster.png`**: nodes `control-plane`, `worker-node-1`, `worker-node-2` Ready, `standard (default)` StorageClass, and `ingress-control-plane` showing `127.0.0.1:80->80/tcp, 127.0.0.1:443->443/tcp`.

---

## Step 2: Namespace, quota, Secret, ConfigMap

```bash
kubectl apply -f namespace.yaml
kubectl apply -f quota.yaml
kubectl apply -f secret.yaml
kubectl apply -f configmap.yaml

kubectl get ns dso202-assignment-02
kubectl get resourcequota,limitrange,secret,configmap -n dso202-assignment-02
kubectl describe configmap app-config -n dso202-assignment-02
```

📸 **SCREENSHOT `02-namespace-config.png`**: the apply output and the get output.
📸 **SCREENSHOT `03-configmap.png`**: the describe output, highlighting `DB_HOST: db-0.db-headless` (this is the stable network identity the backend uses).

---

## Step 3: Database: headless Service, then StatefulSet (2.1.2, 2.1.3, 2.1.4)

The headless Service must exist **before** the StatefulSet, because `serviceName: db-headless` is what gives each pod its DNS record.

```bash
kubectl apply -f db/service.yaml
kubectl get svc db-headless -n dso202-assignment-02
```

📸 **SCREENSHOT `04-headless-svc.png`**: `CLUSTER-IP` column shows **None**.

Open a **second terminal** and watch the pods (leave it running):

```bash
kubectl get pods -n dso202-assignment-02 -l app=db -w
```

In the first terminal:

```bash
kubectl apply -f db/statefulset.yaml
kubectl rollout status statefulset/db -n dso202-assignment-02
kubectl get statefulset,pods,pvc -n dso202-assignment-02 -o wide
kubectl get pv
```

📸 **SCREENSHOT `05-statefulset-ready.png`**: StatefulSet `db 1/1`, pod named **`db-0`** (not a random hash like Deployments), PVC **`db-storage-db-0`** Bound. This PVC was created by the `volumeClaimTemplates`; you did not write a PVC file.

```bash
kubectl describe statefulset db -n dso202-assignment-02
```

📸 **SCREENSHOT `06-describe-statefulset.png`**: show `Pod Management Policy: OrderedReady`, `Update Strategy: RollingUpdate`, `Volume Claims: db-storage 1Gi`, and the events `create Claim db-storage-db-0 … create Pod db-0`.

Check the DB initialised (seed rows from Assignment 1's `01-init.sql`):

```bash
kubectl logs db-0 -n dso202-assignment-02 --tail=15
kubectl exec -it db-0 -n dso202-assignment-02 -- psql -U taskuser -d tasksdb -c "SELECT id,title,status FROM tasks;"
```

📸 **SCREENSHOT `07-db-seed-data.png`**: the 3 seed tasks.

---

## Step 4: Stable network identity (DNS) (2.1.2.1, 2.1.3)

```bash
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -n dso202-assignment-02 -- \
  sh -c "nslookup db-headless.dso202-assignment-02.svc.cluster.local; echo ------; nslookup db-0.db-headless.dso202-assignment-02.svc.cluster.local"
kubectl get pod db-0 -n dso202-assignment-02 -o wide
```

📸 **SCREENSHOT `08-dns-stable-identity.png`**: both names resolve **directly to the pod IP** (same IP as in `get pod -o wide`). There is no virtual ClusterIP because the Service is headless.

---

## Step 5: Backend and frontend

```bash
kubectl apply -f backend/deployment.yaml -f backend/service.yaml
kubectl apply -f frontend/deployment.yaml -f frontend/service.yaml

kubectl rollout status deployment/backend-deployment -n dso202-assignment-02
kubectl rollout status deployment/frontend-deployment -n dso202-assignment-02
kubectl get deploy,pods,svc -n dso202-assignment-02 -o wide
kubectl logs deploy/backend-deployment -n dso202-assignment-02
```

📸 **SCREENSHOT `09-app-running.png`**: all pods Running; `backend-svc` and `frontend-svc` are **ClusterIP** (no NodePort any more; Ingress is the only entry point).
📸 **SCREENSHOT `10-backend-connected.png`**: backend log line `[db] connected` and `[server] listening on :8080`. This proves the backend reached `db-0.db-headless`.

> If a pod shows `ImagePullBackOff`, load the image into kind and delete the pod:
> ```bash
> docker pull rynorbu11/dso202-backend:1.0
> kind load docker-image rynorbu11/dso202-backend:1.0 --name ingress
> ```
> (same for `dso202-frontend:1.0` and `dso202-db:1.0`)

---

## Step 6: Install the Traefik Ingress Controller (2.2.2.2)

Install Traefik's CRDs first (needed for the `Middleware` objects used by annotations):

```bash
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.1/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
kubectl get crd | grep traefik
```

📸 **SCREENSHOT `11-traefik-crds.png`**

Give Traefik its permissions. This is required boilerplate (the controller must read Ingresses, Services and Secrets from the API server), so you don't need to explain it in the report:

```bash
kubectl apply -f traefik/rbac.yaml
```

Install the controller:

```bash
kubectl apply -f traefik/traefik.yaml
kubectl rollout status deployment/traefik -n traefik
kubectl get pods,svc -n traefik -o wide
kubectl get ingressclass
kubectl logs deploy/traefik -n traefik --tail=15
```

📸 **SCREENSHOT `12-traefik-running.png`**: Traefik pod Running **on node `control-plane`** (column NODE) and IngressClass `traefik` with controller `traefik.io/ingress-controller` (default).

> **Report point (2.2.2.1 vs 2.2.2.2):** your earlier NGINX attempt failed (`assets/error.png`: *didn't match Pod's node affinity/selector*, because the kind manifest for ingress-nginx requires an `ingress-ready=true` node label; `assets/error2.png`: admission webhook secret missing). With Traefik we solved the same placement problem explicitly with `nodeSelector: node-role.kubernetes.io/control-plane` + a toleration + `hostPort 80/443`.

---

## Step 7: TLS certificate and secret (2.2.1.2)

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=app.dso202.local/O=DSO202" \
  -addext "subjectAltName=DNS:app.dso202.local,DNS:api.dso202.local"

openssl x509 -in tls.crt -noout -subject -issuer -dates -ext subjectAltName

kubectl create secret tls dso202-tls --cert=tls.crt --key=tls.key -n dso202-assignment-02
kubectl get secret dso202-tls -n dso202-assignment-02
kubectl describe secret dso202-tls -n dso202-assignment-02
```

📸 **SCREENSHOT `13-tls-cert.png`**: subject, SAN with both hostnames, and the secret of type `kubernetes.io/tls` holding `tls.crt` and `tls.key`.

---

## Step 8: Middlewares and Ingress (2.2.1, 2.2.3)

```bash
kubectl apply -f Ingress/middleware.yaml
kubectl get middlewares.traefik.io -n dso202-assignment-02

kubectl apply -f Ingress/ingress.yaml
kubectl get ingress -n dso202-assignment-02
kubectl describe ingress dso202-ingress -n dso202-assignment-02
kubectl describe ingress dso202-ingress-http -n dso202-assignment-02
```

📸 **SCREENSHOT `14-middlewares.png`**
📸 **SCREENSHOT `15-ingress-list.png`**: both Ingresses, CLASS `traefik`, HOSTS `app.dso202.local,api.dso202.local`, ADDRESS `127.0.0.1`, PORTS `80, 443`.
📸 **SCREENSHOT `16-ingress-describe.png`**: TLS `dso202-tls terminates …`, the rules (host → path → backend with pod IPs), and the three Traefik annotations.

---

## Step 9: Add the hostnames

**WSL** (for curl):

```bash
echo "127.0.0.1 app.dso202.local api.dso202.local" | sudo tee -a /etc/hosts
```

**Windows** (for the browser): open Notepad **as Administrator**, open `C:\Windows\System32\drivers\etc\hosts`, add this line and save:

```
127.0.0.1 app.dso202.local api.dso202.local
```

---

## Step 10: Test the Ingress features

### 10a. Name-based virtual hosting (2.2.1.3)

Same IP and same port 443; only the `Host` header differs:

```bash
curl -k https://app.dso202.local/ | head -n 15          # HTML of the frontend
curl -k https://api.dso202.local/api/status             # {"status":"ok","db":"connected"}
curl -k https://api.dso202.local/api/tasks              # JSON list of tasks
curl -k -i https://unknown.dso202.local/ --resolve unknown.dso202.local:443:127.0.0.1   # 404, no rule for this host
```

📸 **SCREENSHOT `17-virtual-hosting.png`**

### 10b. Path-based routing on one host (2.2.1.1)

```bash
curl -k https://app.dso202.local/api/status    # /api  -> backend-svc
curl -k -s -o /dev/null -w "%{http_code} %{content_type}\n" https://app.dso202.local/   # /  -> frontend (text/html)
```

📸 **SCREENSHOT `18-path-routing.png`**

### 10c. TLS termination (2.2.1.2)

```bash
curl -kv https://app.dso202.local/ 2>&1 | grep -E "SSL connection|subject:|issuer:|subjectAltName|HTTP/"
echo | openssl s_client -connect 127.0.0.1:443 -servername app.dso202.local 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName
```

📸 **SCREENSHOT `19-tls-termination.png`**: the served certificate is **your** `CN=app.dso202.local` (not `TRAEFIK DEFAULT CERT`). Traefik decrypts HTTPS and talks plain HTTP to the pods on port 8080, so the pods never handle TLS.

### 10d. Controller-specific annotations (2.2.3)

HTTP → HTTPS redirect (`redirect-https` middleware on the `web` entrypoint):

```bash
curl -i http://app.dso202.local/
```

Security headers (`security-headers` middleware on the `websecure` entrypoint):

```bash
curl -k -I https://app.dso202.local/
```

📸 **SCREENSHOT `20-annotation-redirect.png`**: `HTTP/1.1 301 Moved Permanently` and `Location: https://app.dso202.local/`.
📸 **SCREENSHOT `21-annotation-headers.png`**: `X-Served-By: traefik-dso202`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Strict-Transport-Security`.

### 10e. Browser (end to end)

1. Open **https://app.dso202.local** in Chrome/Edge.
2. You get *"Your connection is not private"* because the certificate is self-signed. Click **Advanced → Proceed to app.dso202.local**.

📸 **SCREENSHOT `22-browser-cert-warning.png`**: the warning page (it proves TLS is served by Traefik with your self-signed cert). Optional: click the "Not secure" icon → Certificate details showing `app.dso202.local`.

3. The Task Tracker loads; the status pill shows **backend + db online**.
4. Add a task such as `StatefulSet persistence test`. Change a status and delete one task.

📸 **SCREENSHOT `23-browser-ui.png`**: the URL bar `https://app.dso202.local` + the task list.
📸 **SCREENSHOT `24-browser-devtools.png`** (optional): F12 → Network tab showing `https://app.dso202.local/api/tasks` with status 200/201.

5. Open **https://api.dso202.local/api/tasks** (accept the warning again).
📸 **SCREENSHOT `25-browser-api-host.png`**

### 10e-alt. Access through `kubectl port-forward` (instead of ports 80/443)

Forward local ports to the **Traefik Service**, so traffic still passes through the Ingress rules, TLS and middlewares. Leave this running in its own terminal:

```bash
kubectl port-forward -n traefik svc/traefik 8000:80 8443:443
```

Browser (the Windows hosts entry from Step 9 is still required, because Ingress routes by hostname):

| What | URL |
|---|---|
| Task Tracker UI | https://app.dso202.local:8443 |
| API (app host) | https://app.dso202.local:8443/api/tasks |
| API (api host) | https://api.dso202.local:8443/api/tasks |

curl from WSL:

```bash
curl -k https://app.dso202.local:8443/api/status
curl -k https://api.dso202.local:8443/api/tasks
```

📸 **SCREENSHOT `25b-port-forward.png`**: the port-forward terminal (`Forwarding from 127.0.0.1:8443 -> 8443`) next to the browser at `https://app.dso202.local:8443`.

> On port 8000 the HTTP→HTTPS redirect sends you to `https://app.dso202.local/` (port 443), so test the redirect on port 80 (Step 10d), not through the port-forward.

### 10f. Traefik dashboard (optional, nice for the report)

```bash
kubectl port-forward -n traefik deploy/traefik 9000:8080
```

Browser: **http://localhost:9000/dashboard/** → *HTTP Routers* and *HTTP Middlewares*.
📸 **SCREENSHOT `26-traefik-dashboard.png`**: the routers for both hosts with TLS and the middlewares. Press Ctrl+C in the terminal afterwards.

---

## Step 11: Stable storage: data survives pod deletion (2.1.4)

```bash
# Task you added in the browser is in the DB:
kubectl exec -it db-0 -n dso202-assignment-02 -- psql -U taskuser -d tasksdb -c "SELECT id,title,status FROM tasks;"
kubectl get pod db-0 -n dso202-assignment-02 -o wide          # note the IP and node

kubectl delete pod db-0 -n dso202-assignment-02
kubectl get pods -n dso202-assignment-02 -l app=db -w          # wait for db-0 1/1 Running, then Ctrl+C

kubectl get pod db-0 -n dso202-assignment-02 -o wide
kubectl get pvc -n dso202-assignment-02
kubectl exec -it db-0 -n dso202-assignment-02 -- psql -U taskuser -d tasksdb -c "SELECT id,title,status FROM tasks;"
```

📸 **SCREENSHOT `27-before-delete.png`**: the rows + pod IP before.
📸 **SCREENSHOT `28-after-delete.png`**: the pod comes back with the **same name `db-0`**, re-attached to the **same PVC `db-storage-db-0`**, and the same rows are still there (the IP may change, the DNS name does not).

Refresh the browser:
📸 **SCREENSHOT `29-browser-after-db-restart.png`**: your task is still there.

---

## Step 12: Ordered deployment and scaling (2.1.2.2)

Terminal 2 (watch):

```bash
kubectl get pods -n dso202-assignment-02 -l app=db -w
```

Terminal 1:

```bash
kubectl scale statefulset db --replicas=3 -n dso202-assignment-02
```

📸 **SCREENSHOT `30-scale-up-order.png`** (terminal 2): `db-1` goes Pending → ContainerCreating → Running **0/1 → 1/1**, and only then does `db-2` start. That's the OrderedReady policy.

```bash
kubectl get statefulset,pods,pvc -n dso202-assignment-02
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -n dso202-assignment-02 -- \
  sh -c "nslookup db-headless.dso202-assignment-02.svc.cluster.local; nslookup db-2.db-headless.dso202-assignment-02.svc.cluster.local"
```

📸 **SCREENSHOT `31-scaled-3-pvcs.png`**: 3 pods, **3 PVCs** (`db-storage-db-0/1/2`), one per pod from the volumeClaimTemplate.
📸 **SCREENSHOT `32-dns-3-pods.png`**: the headless Service now returns **3 pod IPs**; `db-2.db-headless` resolves to just db-2.

Ordered rolling update (reverse order: db-2 → db-1 → db-0):

```bash
kubectl rollout restart statefulset/db -n dso202-assignment-02
kubectl rollout status statefulset/db -n dso202-assignment-02
```

📸 **SCREENSHOT `33-rolling-update-order.png`** (terminal 2): pods terminate/recreate one at a time from the highest ordinal down.

Scale down (reverse order: db-2 first, then db-1):

```bash
kubectl scale statefulset db --replicas=1 -n dso202-assignment-02
kubectl get pvc -n dso202-assignment-02
```

📸 **SCREENSHOT `34-scale-down.png`**: db-2 terminates before db-1, and **the PVCs `db-storage-db-1/2` are kept** (`persistentVolumeClaimRetentionPolicy.whenScaled: Retain` protects the data).

> **Report note:** db-1 and db-2 are independent Postgres instances, not replicas of db-0 (real replication needs Postgres streaming replication or an operator). The backend always uses `db-0.db-headless`, which is exactly why the stable identity matters.

Stop the watch with Ctrl+C.

---

## Step 13: Final overview

```bash
kubectl get all,ingress,pvc,secret,configmap -n dso202-assignment-02
kubectl get all -n traefik
kubectl describe resourcequota dso202-a2-quota -n dso202-assignment-02
kubectl logs deploy/traefik -n traefik --tail=10
```

📸 **SCREENSHOT `35-final-overview.png`**
📸 **SCREENSHOT `36-quota-usage.png`**: used vs hard limits.
📸 **SCREENSHOT `37-traefik-access-log.png`**: access-log lines showing requests routed to the frontend/backend services.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `curl: (7) Failed to connect to … port 443` | Cluster not created with `kind-cluster.yaml` (check `docker ps` ports), or the Traefik pod is not on `control-plane` (`kubectl get pod -n traefik -o wide`). |
| Traefik pod `Pending`: *didn't match node selector* | Check the label exists: `kubectl get node control-plane --show-labels \| grep control-plane`. |
| Browser shows the cert `TRAEFIK DEFAULT CERT` | The secret `dso202-tls` is missing or in the wrong namespace. Recreate it in `dso202-assignment-02`. |
| Ingress returns 404 | Wrong Host (check hosts files), or the Ingress isn't picked up: `kubectl logs deploy/traefik -n traefik`. |
| `middleware ... does not exist` in Traefik logs | `Ingress/middleware.yaml` not applied, or CRDs not installed (Step 6). |
| UI says "backend unreachable" | Open `https://app.dso202.local/api/status` directly; accept the cert; check backend logs. |
| Backend log stays at `[db] not reachable yet` | `DB_HOST` wrong or db-0 not Ready. `kubectl get cm app-config -n dso202-assignment-02 -o yaml`, then `kubectl rollout restart deploy/backend-deployment -n dso202-assignment-02` after fixing. |
| Changed the ConfigMap but nothing happened | Env vars are read at pod start: `kubectl rollout restart deploy/frontend-deployment deploy/backend-deployment -n dso202-assignment-02`. |

---

## Cleanup (after you have all screenshots)

```bash
kubectl delete -f Ingress/ingress.yaml -f Ingress/middleware.yaml
kubectl delete secret dso202-tls -n dso202-assignment-02
kubectl delete namespace dso202-assignment-02
kubectl get pv            # StatefulSet PVCs use Retain policy; the namespace delete removes them
kubectl delete -f traefik/traefik.yaml -f traefik/rbac.yaml
kind delete cluster --name ingress
rm -f tls.crt tls.key     # don't commit private keys
```

---

## Suggested report structure (README.md)

1. **Overview**: what changed from Assignment 1 (table at the top of this file) + architecture diagram.
2. **Why a StatefulSet for the database (2.1.1)**: Deployment pods get random names, share one PVC and start in any order; a database needs a fixed identity, its own storage and ordered start/stop. Frontend/backend stay Deployments because they are stateless. → screenshots 04–07.
3. **Headless Service and stable network identity (2.1.2.1, 2.1.3)**: `clusterIP: None`, `serviceName`, DNS `db-0.db-headless…`, `DB_HOST` in the ConfigMap. → 03, 08, 10.
4. **Volume claim templates and persistence (2.1.4)**: one PVC per pod, data survives pod deletion, Retain policy. → 05, 27–29, 31, 34.
5. **Ordered deployment and scaling (2.1.2.2)**: OrderedReady, scale up/down, reverse-order rolling update. → 30–34.
6. **Ingress Controller choice (2.2.2)**: NGINX attempt and why it failed on kind (old `error.png`, `error2.png`); Traefik install, CRDs, nodeSelector/toleration/hostPort. → 11, 12.
7. **Ingress resource (2.2.1)**: basic routing, TLS termination, name-based virtual hosting. → 13–19, 22–25.
8. **Annotations (2.2.3)**: entrypoints, tls, middlewares; redirect and security headers. → 20, 21, 26.
9. **Challenges and fixes**: wrong `DB_HOST`, `/api/api` double prefix, duplicate controllers/Ingresses, nginx scheduling error, ImagePullBackOff.
10. **Conclusion**.
