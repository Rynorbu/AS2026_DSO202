# DSO202 Assignment 1: Three-Tier Application Deployment on Kubernetes Cluster
**Environment:** Windows/WSL (linux/amd64) on Kind Cluster

---

## Overview

This report documents the deployment of a three-tier Task Tracker application (frontend, backend, database) onto a local kind Kubernetes cluster, along with the architectural reasoning, configuration decisions, and verification evidence.

The application follows a standard three-tier pattern:

Container images used:

| Tier | Image | Internal Port |
|---|---|---|
| Frontend | `rynorbu11/dso202-frontend:1.0` | 8080 |
| Backend | `rynorbu11/dso202-backend:1.0` | 8080 |
| Database | `rynorbu11/dso202-db:1.0` | 5432 |




## Task 1: Namespace and Architecture Note
**Namespace:** `dso202-assignment-01`

### Architecture Description
The deployment of this three-tier application (Task Tracker) involves several core Kubernetes components:
- **Control Plane Interaction:** When the manifests are applied via `kubectl`, the **API Server** validates the objects and stores them in **etcd**. The **kube-scheduler** then identifies available nodes (worker-node-1 or 2) to place the pods.
- **Node Components:** On the worker nodes, the **kubelet** pulls the container images from my Docker Hub account (`rynorbu11/dso202-...`) and manages the pod lifecycle. **kube-proxy** maintains network rules to enable Service communication.
- **Object Choice:**
    - **Deployments:** Used for all tiers to ensure self-healing and rolling updates.
    - **PersistentVolumeClaim (PVC):** Specifically used for the Database tier to ensure data survives pod deletions.
    - **Services:** A **Headless Service** (`clusterIP: None`) for the database ensures stable internal DNS; a **ClusterIP** for the backend keeps the API private; and a **NodePort** for the frontend allows external browser access.

---

## Task 2: Configuration and Secrets
### Secret Handling and Security Note
As required by the assignment contract, the `app-secret` manifest contains base64-encoded credentials.
**Security Warning:** Kubernetes Secrets are **base64-encoded**, not encrypted at rest by default. In a professional environment, I would implement **Encryption at Rest** or use an external KMS (Key Management Service) provider, as base64 is easily decoded and does not provide true security.

I have mapped the `DB_*` variables (expected by the backend) and `POSTGRES_*` variables (expected by the database) to the same values in the ConfigMap and Secret to ensure successful authentication.

---

## Task 6: Namespace Resource Governance
I have applied a `ResourceQuota` and `LimitRange` with the following justifications:

- **ResourceQuota (Hard Limit 2Gi RAM):** Since the Kind cluster shares resources with my host Windows machine, a 2Gi limit ensures that this assignment doesn't consume all system memory.
- **LimitRange (Default 256Mi RAM):** 
    - **Database:** I set higher limits (256Mi) as PostgreSQL is process-heavy.
    - **Frontend/Backend:** Lower requests (64Mi/128Mi) are sufficient for these lightweight Node.js/Nginx containers.
- **Justification:** These values prevent "noisy neighbor" scenarios where one pod's memory leak could crash the entire namespace.

---

## Task 7: Verification and Interactivity

### a. Full CRUD Cycle
I verified the CRUD operations via `curl` through a port-forwarded backend.
- **Create:** `curl -X POST ... {"title":"ranjung demo task"}` -> Status 200 OK.
- **Update:** `curl -X PUT ... {"status":"done"}` -> ID 5 updated.
- **Delete:** `curl -X DELETE ... /api/tasks/5` -> Resource removed.

### b. Service DNS Resolution
I successfully reached the backend from inside the frontend pod using the service DNS name:
```bash
# Exec command
kubectl exec -it $FRONTEND_POD -n dso202-assignment-01 -- curl http://backend-svc:8080/api/status
# Result
{"status":"ok","db":"connected"}
```

c. Self-healing and Data Persistence

Created a task: {"title":"persistence check"} (ID 6).

Manually deleted the backend pod.

Observed the ReplicaSet recreate the pod (Transition from Terminating to Running).

Re-ran the GET request; Task ID 6 was still present, proving the PersistentVolume successfully kept the data independent of the Pod lifecycle.

d. Declarative vs. Imperative Comparison

I created the backend-svc both ways and compared the resulting YAML files.

    Declarative: kubectl apply -f backend/service.yaml

    Imperative: kubectl expose deployment backend-deployment --name=backend-svc ...

Comparison Analysis:

The diff between the two files revealed that the Declarative approach includes the kubectl.kubernetes.io/last-applied-configuration annotation.

    Declarative (Best Practice): Allows for "GitOps" workflows where the desired state is stored in version control. It supports complex updates where only changed fields are patched.

    Imperative (Testing Only): Faster for one-off commands but leaves no audit trail and makes it difficult to recreate the cluster state if the system fails.

Task 9: Troubleshooting Guide (AMD64 Architecture)

During deployment on Windows/WSL, I encountered ErrImagePull because the tutor's images were ARM64.
Resolution: I built custom images from the provided specification using a local Docker pipeline, pushed them to rynorbu11/dso202-..., and sideloaded them using kind load docker-image to ensure compatibility with my x86_64 architecture.