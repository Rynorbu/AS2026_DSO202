# Assignment 2 Explained: From Assignment 1 to StatefulSets and Ingress

This file explains the ideas behind Assignment 2 in detail. It covers:

1. The basic Kubernetes concepts the assignment is built on
2. How I built the app in Assignment 1
3. What was wrong with that design (the flaws)
4. What I changed in Assignment 2 and why each change fixes a flaw
5. How a request travels through my cluster, step by step

---

## Part 1: The Application

My app is a **three-tier Task Tracker** called *Field Log*. "Three-tier" means it's split into three separate parts, and each part has one job:

| Tier | What it is | What it does | Port |
|---|---|---|---|
| **Frontend** | `rynorbu11/dso202-frontend:1.0` | The web page (HTML, CSS, JavaScript) the user sees in the browser | 8080 |
| **Backend** | `rynorbu11/dso202-backend:1.0` | The API. It receives requests like "add a task" and talks to the database | 8080 |
| **Database** | `rynorbu11/dso202-db:1.0` | PostgreSQL. It stores the tasks permanently | 5432 |

The flow is always: **Browser → Frontend page → Backend API → Database**.

I used the **same three images** in both assignments. The app code didn't change at all. Only the way I deployed it on Kubernetes changed.

---

## Part 2: Basic Kubernetes Concepts

Before looking at the two assignments, here are the building blocks they use.

### 2.1 Cluster, nodes, control-plane and workers

A **cluster** is a group of machines (called **nodes**) that Kubernetes manages together. My cluster is made with **kind** (Kubernetes in Docker), so each node is actually a Docker container on my laptop.

There are two kinds of nodes:

- **Control-plane node**: the "brain" of the cluster. It runs the parts of Kubernetes that make decisions:
  - **kube-apiserver**: the front desk; every `kubectl` command goes here
  - **etcd**: the database where Kubernetes stores the state of the cluster
  - **kube-scheduler**: decides which node each new pod should run on
  - **kube-controller-manager**: keeps checking that what's running matches what I asked for, and fixes it if not
- **Worker nodes**: the "hands". They run my application pods. Each node has a **kubelet** (starts and watches containers) and **kube-proxy** (sets up networking for Services).

My cluster has three nodes:

| Node | Role |
|---|---|
| `control-plane` | Runs Kubernetes itself, and in Assignment 2 also runs the Traefik Ingress Controller |
| `worker-node-1` | Runs application pods |
| `worker-node-2` | Runs application pods |

By default, kind puts a **taint** on the control-plane node. A taint is like a "Keep out" sign: normal pods won't be scheduled there. A pod can only run on a tainted node if it has a matching **toleration**.

### 2.2 Pods

A **pod** is the smallest thing Kubernetes runs. It wraps one (or more) containers. Each pod gets its own IP address inside the cluster.

Pods are **temporary**. If a pod crashes or is deleted, it's gone, and a new one (with a new IP) must take its place. Because of this, I never create pods by hand. I use a **controller** (like a Deployment or StatefulSet) that creates and replaces pods for me.

### 2.3 Deployments

A **Deployment** is a controller for **stateless** apps. I tell it "I want 1 copy of the backend running", and it makes sure that's always true. If the pod dies, the Deployment creates a new one.

Important things about a Deployment:

- All its pods are **identical and interchangeable**. Kubernetes doesn't care which one is which.
- Pod names are **random**, for example `backend-deployment-7554f5fc47-bwh25`. A new pod gets a new random name.
- When updating, it uses a **rolling update** by default: it starts the new pod first, then removes the old one.

This is perfect for the frontend and backend, because they don't store anything. Any copy can answer any request.

### 2.4 Services

Since pod IPs keep changing, other parts of the app can't rely on them. A **Service** gives a group of pods one stable name and address. It finds its pods using **labels** (for example `app=backend`).

There are several types of Service:

| Type | What it does | Reachable from |
|---|---|---|
| **ClusterIP** (default) | Gives one virtual IP inside the cluster and spreads traffic across the pods | Inside the cluster only |
| **NodePort** | Same as ClusterIP, plus opens a port (30000–32767) on **every node** | Outside, via `node-ip:port` |
| **Headless** (`clusterIP: None`) | No virtual IP. DNS returns the pod IPs directly | Inside the cluster only |

### 2.5 DNS inside the cluster

Kubernetes runs **CoreDNS**, which gives names to Services. The backend can reach the database by name instead of IP:

- A Service gets a name like `backend-svc` (full name: `backend-svc.dso202-assignment-02.svc.cluster.local`).
- With a **headless Service** and a **StatefulSet**, **each pod** also gets its own name, like `db-0.db-headless`.

These names only work **inside** the cluster. My Windows browser can't look up `backend-svc`. This becomes important in the flaws section.

### 2.6 Storage: PV, PVC and StorageClass

Containers lose their files when they restart. A database needs storage that survives the pod, so Kubernetes has:

- **PersistentVolume (PV)**: an actual piece of disk
- **PersistentVolumeClaim (PVC)**: a request for disk ("I need 1Gi, ReadWriteOnce")
- **StorageClass**: tells Kubernetes how to create a PV automatically when a PVC asks for one. In kind this is `standard` (the `local-path` provisioner).

**ReadWriteOnce (RWO)** means the disk can be mounted read-write by **one node** at a time.

### 2.7 ConfigMaps and Secrets

- A **ConfigMap** stores normal settings (like `DB_HOST`, `DB_PORT`).
- A **Secret** stores sensitive values (like the database password).

Both are passed to containers as environment variables, so I don't have to hard-code them inside the images.

### 2.8 Namespace, ResourceQuota and LimitRange

- A **Namespace** is a separate area inside the cluster. All my resources live in `dso202-assignment-02`.
- A **ResourceQuota** limits the total resources the namespace can use (pods, CPU, memory, PVCs).
- A **LimitRange** gives default CPU and memory values to containers that don't set their own.

---

## Part 3: The New Concepts in Assignment 2

### 3.1 StatefulSet

A **StatefulSet** is a controller for **stateful** apps, meaning apps that store data, like databases. It's similar to a Deployment, but each pod has its own **identity**:

| Feature | What it means |
|---|---|
| **Stable name** | Pods are named `<name>-0`, `<name>-1`, `<name>-2`… My database pod is always `db-0`. If it's deleted, the new pod is also called `db-0`. |
| **Stable network identity** | With a headless Service, each pod gets its own DNS name: `db-0.db-headless`. This name always points to that pod, even after its IP changes. |
| **Stable storage** | Each pod gets **its own PVC** from `volumeClaimTemplates`. `db-0` always gets back `db-storage-db-0`. |
| **Ordered deployment** | With `podManagementPolicy: OrderedReady`, pods start one by one: `db-1` is only created after `db-0` is **Ready**, and `db-2` after `db-1`. |
| **Ordered scale-down** | Pods are removed in reverse order: `db-2` first, then `db-1`. |
| **Ordered updates** | A rolling update replaces pods from the highest number down: `db-2` → `db-1` → `db-0`. |

### 3.2 Headless Service (with a StatefulSet)

A headless Service has `clusterIP: None`. Instead of hiding the pods behind one virtual IP, it lets DNS return each pod's IP directly.

When a StatefulSet points to it with `serviceName: db-headless`, every pod gets a DNS record in this form:

```
<pod-name>.<service-name>.<namespace>.svc.cluster.local
db-0.db-headless.dso202-assignment-02.svc.cluster.local
```

That's why my backend can use `DB_HOST: db-0.db-headless`. It always reaches the exact database pod, even if the pod restarts on a different node with a new IP.

### 3.3 volumeClaimTemplates

Instead of writing a PVC file by hand, I put a **template** inside the StatefulSet. For every pod, Kubernetes creates a PVC from that template, named `<template-name>-<pod-name>`:

| Pod | PVC created |
|---|---|
| `db-0` | `db-storage-db-0` |
| `db-1` | `db-storage-db-1` |
| `db-2` | `db-storage-db-2` |

I also set `persistentVolumeClaimRetentionPolicy` to `Retain`, so these PVCs are **kept** when I scale down or delete the StatefulSet. The data is never thrown away by accident.

### 3.4 Readiness probe

A **readiness probe** is a check Kubernetes runs to decide whether a pod is ready to receive traffic. My database uses:

```
pg_isready -h 127.0.0.1 -U $POSTGRES_USER -d $POSTGRES_DB
```

This only succeeds once PostgreSQL is really accepting connections. This matters for `OrderedReady`: without the probe, a pod would count as "Ready" as soon as the container started, even while Postgres was still setting up, and the next pod would start too early.

I also added a **liveness probe** with the same command. If Postgres stops responding, Kubernetes restarts the container.

### 3.5 Ingress

An **Ingress** is a set of **rules** that say how HTTP traffic from outside should reach Services inside the cluster. For example:

- "If the hostname is `ranjung.com` and the path starts with `/api`, send it to `backend-svc`."
- "If the hostname is `ranjung.com` and the path is anything else, send it to `frontend-svc`."
- "If the hostname is `api.ranjung.com`, send it to `backend-svc`."

The Ingress gives me:

- **One entry point**: all traffic comes in on port 80, instead of a separate port per Service.
- **Path-based routing**: the URL path decides which Service gets the request.
- **Name-based virtual hosting**: several hostnames share the same IP and port. The `Host` header in the request decides where it goes.

### 3.6 Ingress Controller

An Ingress on its own **does nothing**. It's just rules written down. An **Ingress Controller** is a program running in the cluster that reads those rules and actually forwards the traffic. It works like a receptionist who reads the instructions and sends each visitor to the right room.

I used **Traefik** as my Ingress Controller. Traefik:

- watches the Kubernetes API for Ingress objects
- listens on port 80
- looks at each request's hostname and path
- forwards it to the right Service's pods

An **IngressClass** (`traefik`) connects an Ingress to its controller. My Ingress says `ingressClassName: traefik`, so Traefik handles it.

### 3.7 Annotations, CRDs and Middleware

The standard Ingress can only describe **hosts, paths and backends**. Extra features are different for each controller, so they're set with **annotations**, which are extra key–value notes that only that controller understands:

| Annotation | Meaning |
|---|---|
| `traefik.ingress.kubernetes.io/router.entrypoints: web` | Listen on Traefik's `web` entrypoint (port 80) |
| `traefik.ingress.kubernetes.io/router.middlewares: dso202-assignment-02-security-headers@kubernetescrd` | Run the `security-headers` Middleware on every request |

A **CRD (Custom Resource Definition)** adds a new type of object to Kubernetes. Traefik's CRDs add the **Middleware** type. My `security-headers` Middleware adds these headers to every response:

| Header | What it protects against |
|---|---|
| `X-Frame-Options: DENY` | Other sites showing my app inside a hidden frame (clickjacking) |
| `X-Content-Type-Options: nosniff` | The browser guessing a file's type and running it as a script |
| `Referrer-Policy: no-referrer` | My URL being sent to other websites |
| `X-Served-By: traefik-dso202` | (custom) lets me see that Traefik handled the request |

### 3.8 nodeSelector, toleration and hostPort

kind only connects **port 80 of the control-plane node** to `127.0.0.1:80` on my laptop (through `extraPortMappings` in `kind-cluster.yaml`). So Traefik **must** run on the control-plane node and listen on port 80 there:

- **`nodeSelector: node-role.kubernetes.io/control-plane`**: "only run on the control-plane node"
- **Toleration** for the control-plane taint: "I'm allowed past the Keep out sign"
- **`hostPort: 80`**: bind port 80 directly on that node
- **`strategy: Recreate`**: only one pod can hold port 80 on a node. The default rolling update would start the new pod while the old one still held the port, so the new pod would stay `Pending` forever. `Recreate` removes the old pod first.

### 3.9 The hosts file

`ranjung.com` isn't registered in real DNS for my cluster, so I tell my computer where to find it. I added this line to the **hosts file**, which the computer checks before asking real DNS:

```
127.0.0.1    ranjung.com api.ranjung.com
```

- Windows (`C:\Windows\System32\drivers\etc\hosts`) is used by the **browser**.
- WSL (`/etc/hosts`) is used by **curl** in Ubuntu.

Both are needed because Windows and WSL each have their own hosts file.

### 3.10 HTTP vs HTTPS

My app runs on **HTTP**, not **HTTPS**. HTTPS needs a **TLS certificate** to encrypt the traffic. I didn't set one up, so the browser shows **"Not Secure"**. The app still works. It only means the traffic between the browser and Traefik isn't encrypted. On a real website I would add a TLS certificate to the Ingress.

---

## Part 4: How I Built Assignment 1

In Assignment 1 (namespace `dso202-assignment-01`), I deployed the app like this:

| Tier | Kubernetes objects | Key settings |
|---|---|---|
| Frontend | Deployment + **NodePort** Service `frontend-svc` | `nodePort: 30080` |
| Backend | Deployment + ClusterIP Service `backend-svc` | port 8080, internal only |
| Database | **Deployment** `db-deployment` + a separate **PVC** `db-pvc` + headless Service `db-svc` | `replicas: 1`, PVC 1Gi RWO |

And the ConfigMap had:

```yaml
DB_HOST: "db-svc"
BACKEND_URL: "http://backend-svc:8080"
```

**How I used it:**

- I opened the frontend at `http://localhost:30080` (kind mapped port 30080 to my laptop).
- The page loaded, but it showed **"BACKEND UNREACHABLE"**, because the browser tried to call `http://backend-svc:8080`.
- To test the API, I used `kubectl port-forward svc/backend-svc 8080:8080` and sent requests with curl and Postman.
- I also tried a workaround: mapping `backend-svc` to `127.0.0.1` in the Windows hosts file, together with the port-forward.

It worked for the assignment, but the design had several problems.

---

## Part 5: The Flaws in Assignment 1

### Flaw 1: The database ran as a Deployment

A Deployment treats pods as **interchangeable**, but a database pod is **not** interchangeable, because it owns the data.

- **Random pod name.** The pod was called something like `db-deployment-xxxxx-yyyy`. Every restart gave a new name, so nothing could refer to "the database pod" in a stable way.
- **Risky updates.** A Deployment's default rolling update starts the **new** database pod before stopping the old one. Both pods would try to use the **same disk** (`db-pvc`) at the same time. With a ReadWriteOnce disk, the new pod can get stuck if it lands on another node. If it lands on the same node, two PostgreSQL servers could write to the same data folder, which can corrupt the data.
- **Couldn't scale.** If I set `replicas: 2`, both pods would share the **one** PVC `db-pvc`. Two databases can't safely share one data folder.
- **No ordering.** Pods start and stop in any order, with no waiting.

### Flaw 2: The headless Service didn't give a stable pod identity

In Assignment 1, `db-svc` was already headless (`clusterIP: None`). But a headless Service with a **Deployment** only returns "whatever pod IPs exist right now". The pods don't get their own DNS names like `db-0.db-svc`, because that only works with a StatefulSet. So `DB_HOST: db-svc` pointed at "some database pod", not one specific, stable instance.

### Flaw 3: Storage was created by hand and shared

I had to write `db/pvc.yaml` myself and connect it to the Deployment by name (`claimName: db-pvc`). There was only one disk for the whole database tier, so adding more database pods was impossible without writing more PVC files by hand.

### Flaw 4: No health checks on the database

The database had **no readiness or liveness probe**. Kubernetes marked the pod as "Running" as soon as the container started, even if PostgreSQL wasn't ready yet. The backend could try to connect too early, and if Postgres froze, Kubernetes wouldn't notice.

### Flaw 5: The frontend was exposed with a NodePort

- **Odd port.** Users had to type `:30080`. Real websites use port 80 (HTTP) or 443 (HTTPS).
- **One port per Service.** Every Service I wanted to expose would need its own NodePort, and I'd have to remember which number belonged to which Service.
- **Opened on every node.** A NodePort opens the port on all nodes, not just one entry point.
- **No hostnames or paths.** A NodePort can only forward a port. It can't say "send `/api` to the backend" or "send `api.ranjung.com` to the backend".

### Flaw 6: The browser couldn't reach the backend

`BACKEND_URL` was `http://backend-svc:8080`. That's a **cluster-internal** DNS name. The JavaScript runs in my **browser**, outside the cluster, and the browser can't look up `backend-svc`. So the frontend showed **"BACKEND UNREACHABLE"**, with CORS / `NS_ERROR_DOM_BAD_URI` errors.

The workarounds (`kubectl port-forward` and editing the hosts file for `backend-svc`) were only for testing. Port-forward stops when the terminal closes, and it isn't a real way to serve an app.

### Summary of the flaws

| # | Flaw | Effect |
|---|---|---|
| 1 | Database as a Deployment | Random name, risky updates, can't scale, no order |
| 2 | Headless Service + Deployment | No stable per-pod DNS name |
| 3 | Hand-made, shared PVC | Only one disk; extra pods impossible |
| 4 | No probes on the database | "Running" didn't mean "ready"; failures not detected |
| 5 | NodePort for the frontend | Odd port, one port per Service, no routing |
| 6 | `BACKEND_URL` used an internal name | Browser couldn't reach the API; port-forward needed |

---

## Part 6: How I Fixed Each Flaw in Assignment 2

### Fix 1: Database → StatefulSet (fixes Flaw 1)

I replaced `db/deployment.yaml` with `db/statefulset.yaml`.

- The pod is now always **`db-0`**. When I deleted it, Kubernetes recreated it with the **same name** in about 12 seconds.
- `podManagementPolicy: OrderedReady` means pods start **one at a time**, each waiting for the previous one to be Ready. When I scaled to 3, `db-2` only started after `db-1` was `1/1`.
- Rolling updates replace pods **one at a time in reverse order** (`db-2` → `db-1` → `db-0`), and each pod is stopped before its replacement starts. Two copies of the same pod never use the same disk.

### Fix 2: Stable network identity (fixes Flaw 2)

I renamed the headless Service to `db-headless` and linked it with `serviceName: db-headless`. Now the pod has its own DNS name, **`db-0.db-headless`**, and I changed the ConfigMap:

```yaml
DB_HOST: "db-0.db-headless"   # was "db-svc"
```

When I deleted `db-0`, its IP changed from `10.244.1.3` to `10.244.1.4`, but the backend kept working, because the name `db-0.db-headless` automatically pointed to the new IP.

### Fix 3: volumeClaimTemplates (fixes Flaw 3)

I deleted `db/pvc.yaml` and added `volumeClaimTemplates` to the StatefulSet. Kubernetes now creates **one PVC per pod** (`db-storage-db-0`, `db-storage-db-1`, …). After deleting `db-0`, it reattached to the **same** `db-storage-db-0`, and all the tasks were still there. After scaling down, the PVCs of `db-1` and `db-2` stayed `Bound` because of `whenScaled: Retain`.

### Fix 4: Readiness and liveness probes (fixes Flaw 4)

Both probes run `pg_isready`. Now `db-0` only becomes `1/1 Ready` once PostgreSQL really accepts connections, and Kubernetes restarts it if it stops responding.

### Fix 5: Ingress instead of NodePort (fixes Flaw 5)

- I changed `frontend-svc` from **NodePort** to **ClusterIP**. Now neither the frontend nor the backend is directly exposed.
- I installed the **Traefik Ingress Controller** on the control-plane node, listening on **port 80**.
- I wrote **one Ingress** with:
  - **path-based routing** on `ranjung.com`: `/api` → backend, `/` → frontend
  - **name-based virtual hosting**: `ranjung.com` → full app, `api.ranjung.com` → API only, both on the same IP and port
- I used **Traefik annotations** to choose the entrypoint and add the security-headers Middleware.

Now users just open `http://ranjung.com`, with no odd port number.

### Fix 6: Same-origin API calls (fixes Flaw 6)

I changed the ConfigMap:

```yaml
BACKEND_URL: "."   # was "http://backend-svc:8080"
```

Now the frontend calls **`./api/tasks`**, a relative URL on the **same hostname** the page came from (`ranjung.com`). The browser sends the request to `http://ranjung.com/api/tasks`, Traefik sees the `/api` path and sends it to `backend-svc`. The browser never needs to know the internal name `backend-svc`, and because the page and the API share one address, there are no CORS problems. **No port-forward is needed any more.** The status shows **BACKEND + DB ONLINE** straight away.

### Summary: before and after

| Area | Assignment 1 | Assignment 2 |
|---|---|---|
| Database controller | Deployment | **StatefulSet** |
| Database pod name | random | **`db-0`** (fixed) |
| `DB_HOST` | `db-svc` | **`db-0.db-headless`** |
| Database storage | one hand-made PVC `db-pvc` | **one PVC per pod** from `volumeClaimTemplates` |
| Start / stop order | none | **OrderedReady**, reverse on scale-down |
| Database health checks | none | **readiness + liveness** (`pg_isready`) |
| Frontend Service | **NodePort 30080** | **ClusterIP** |
| Entry point | `localhost:30080` | **Traefik Ingress on port 80** |
| Hostnames | none | **`ranjung.com`**, **`api.ranjung.com`** |
| Routing | none | **path-based** (`/api`, `/`) + **host-based** |
| `BACKEND_URL` | `http://backend-svc:8080` (browser can't resolve) | **`.`** (same origin) |
| Testing the API | `kubectl port-forward` | directly at `http://ranjung.com/api/...` |
| Extra features | none | **security headers** via Traefik Middleware |

---

## Part 7: How a Request Travels in Assignment 2

Here is what happens when I open **http://ranjung.com** and click "File it" to add a task:

```
 1. Browser (Windows)
       │  "Where is ranjung.com?"  → hosts file → 127.0.0.1
       │  POST http://ranjung.com/api/tasks   (port 80)
       ▼
 2. kind port mapping
       │  127.0.0.1:80 on my laptop → port 80 of the control-plane container
       ▼
 3. control-plane node ── Traefik pod (hostPort 80 → container port 8000)
       │  Host = ranjung.com, path = /api/tasks
       │  matches rule  "ranjung.com  /api → backend-svc:8080"
       │  runs the security-headers Middleware
       ▼
 4. Cluster network
       │  Traefik forwards to a backend pod behind backend-svc
       ▼
 5. worker-node-1 ── backend pod (port 8080)
       │  connects to DB_HOST = db-0.db-headless:5432
       │  CoreDNS → IP of db-0
       ▼
 6. worker-node-2 ── db-0 pod (PostgreSQL)
       │  INSERT INTO tasks …  → saved on PVC db-storage-db-0
       ▼
 7. The answer goes back the same way:
       db-0 → backend → Traefik (adds security headers) → browser
```

**The control-plane node is only the front door.** Traefik accepts the request and passes it on. The real work (serving the page, running the API, storing data) happens on the **worker nodes**. This works because all pods can talk to each other over the cluster network, whichever node they run on.

And when the page itself loads (`GET http://ranjung.com/`), step 3 matches the `/` rule instead, and Traefik sends the request to `frontend-svc` on `worker-node-1`.

---

## Part 8: What I Proved With the Tests

| Test | What I did | What it proved |
|---|---|---|
| **Stable identity** | `nslookup db-0.db-headless` | The pod has its own DNS name pointing to its IP |
| **Persistence** | Deleted `db-0` | Same name `db-0`, same PVC, same data; only the IP changed |
| **Ordered scale-up** | Scaled 1 → 3 | `db-1` Ready before `db-2` was created |
| **Ordered update** | `rollout restart` | Pods replaced one at a time, `db-2` → `db-1` → `db-0` |
| **Ordered scale-down** | Scaled 3 → 1 | `db-2` removed first; PVCs kept (`Retain`) |
| **Virtual hosting** | `curl ranjung.com` vs `curl api.ranjung.com` | Same IP and port, different Services |
| **Path routing** | `ranjung.com/api/status` vs `ranjung.com/` | `/api` → backend JSON, `/` → frontend HTML |
| **Annotations** | `curl -I http://ranjung.com/` | Security headers added by Traefik |
| **End-to-end** | Used the app in the browser | Frontend, backend and database all work through the Ingress |

---

## Part 9: Limitations That Are Still There

My Assignment 2 setup is much better, but it's still a learning setup:

- **No HTTPS.** The traffic isn't encrypted, so the browser says "Not Secure". A real site would add a TLS certificate to the Ingress.
- **No database replication.** When I scaled to 3, `db-1` and `db-2` were **separate, empty** databases, not copies of `db-0`. A StatefulSet gives each pod an identity and its own disk, but copying data between them needs PostgreSQL replication (or a database operator). That's why the backend always uses `db-0`.
- **One Traefik pod.** If the control-plane node goes down, the entry point goes down too. In a real cluster, the Ingress Controller would run on several nodes behind a load balancer.
- **Local hostnames.** `ranjung.com` only works on my computer because of the hosts file. A real site would need a DNS record.
- **One replica of the frontend and backend.** They could easily be scaled up, because they're Deployments behind Services, but with only 1 replica each, the app stops working for a moment if one of those pods restarts.

---

## Part 10: Key Takeaways

1. **Use the right controller for the job.** Deployments are for stateless apps (frontend, backend). StatefulSets are for apps that store data (database).
2. **A StatefulSet gives each pod an identity**: a fixed name, a fixed DNS name (with a headless Service), its own disk, and an ordered life cycle.
3. **A headless Service** returns pod IPs directly. Together with a StatefulSet, it gives each pod a DNS name like `db-0.db-headless`.
4. **volumeClaimTemplates** create one PVC per pod automatically, and with `Retain` the data is kept.
5. **An Ingress is just rules.** An **Ingress Controller** (Traefik) is needed to make them work.
6. **One entry point** (port 80) can serve many Services, using **paths** and **hostnames**.
7. **Annotations** unlock controller-specific features, like Traefik Middlewares.
8. **Where things run matters.** On kind, Traefik must run on the control-plane node, because that's where port 80 is mapped. The app runs on the worker nodes.
9. **Browsers live outside the cluster.** They can't use internal names like `backend-svc`. Routing `/api` through the Ingress on the same hostname fixes this cleanly.
