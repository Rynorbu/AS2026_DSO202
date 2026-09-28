# DSO202 Assignment 2: StatefulSets and Ingress (Traefik)

Stack: Frontend (Deployment) -> Backend (Deployment) -> PostgreSQL (**StatefulSet**),
exposed through a **Traefik Ingress** with TLS and name-based virtual hosts.

Run every command from inside the `assignment-02/` folder.

---

## 1. Cluster check
```bash
kubectl cluster-info
kubectl get nodes
kubectl get storageclass          # a (default) class must exist for the PVCs
```

## 2. Namespace, quota, config
```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-quota.yaml
kubectl apply -f 02-secret.yaml
kubectl apply -f 03-configmap.yaml
kubectl get all,cm,secret -n dso202-assignment-02
```

## 3. Database: headless service and StatefulSet
```bash
kubectl apply -f db/service.yaml
kubectl apply -f db/statefulset.yaml

# Wait until db-0 is Ready
kubectl rollout status statefulset/db -n dso202-assignment-02
kubectl get statefulset,pods,svc,pvc -n dso202-assignment-02 -o wide
```
Expected: pod `db-0`, PVC `db-storage-db-0`, and `db-svc` with `CLUSTER-IP None`.

## 4. Backend and frontend
```bash
kubectl apply -f backend/
kubectl apply -f frontend/
kubectl get pods -n dso202-assignment-02
kubectl logs deploy/backend-deployment -n dso202-assignment-02
```

## 5. Install Traefik (no Helm)
```bash
kubectl apply -f traefik/traefik.yaml
kubectl rollout status deployment/traefik -n traefik
kubectl get pods,svc -n traefik
kubectl get ingressclass
```

## 6. TLS certificate and Ingress
```bash
# Self-signed certificate valid for both hostnames
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=app.dso202.local" \
  -addext "subjectAltName=DNS:app.dso202.local,DNS:api.dso202.local"

kubectl create secret tls dso202-tls \
  --cert=tls.crt --key=tls.key -n dso202-assignment-02

kubectl apply -f ingress/ingress.yaml
kubectl get ingress -n dso202-assignment-02
kubectl describe ingress dso202-ingress -n dso202-assignment-02
```

---

# VERIFY: StatefulSet

## A. Stable network identity (predictable pod name and DNS)
```bash
kubectl get pods -n dso202-assignment-02 -l tier=database
# Pod name is db-0 (not random like db-7d9f8-xxxxx)

# DNS test: resolve the headless service and the pod's own record
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 \
  -n dso202-assignment-02 -- sh -c "nslookup db-svc; nslookup db-0.db-svc"
```
- `db-svc` returns the pod IP(s) (headless, no virtual IP).
- `db-0.db-svc` returns db-0's IP, so `db-0.db-svc.dso202-assignment-02.svc.cluster.local` is its stable name.

## B. Stable storage: data survives pod deletion
```bash
# Create and insert data
kubectl exec -it db-0 -n dso202-assignment-02 -- \
  psql -U taskuser -d tasksdb -c \
  "CREATE TABLE IF NOT EXISTS proof(id serial, note text); INSERT INTO proof(note) VALUES ('before delete');"

# Note the pod IP, then delete the pod
kubectl get pod db-0 -n dso202-assignment-02 -o wide
kubectl delete pod db-0 -n dso202-assignment-02
kubectl get pods -n dso202-assignment-02 -w        # Ctrl+C when db-0 is Running 1/1

# Same name, same PVC, data still there
kubectl get pod db-0 -n dso202-assignment-02 -o wide
kubectl get pvc -n dso202-assignment-02
kubectl exec -it db-0 -n dso202-assignment-02 -- \
  psql -U taskuser -d tasksdb -c "SELECT * FROM proof;"
```
The pod IP may change, but the name `db-0`, the DNS name, the PVC and the data stay the same.

## C. Ordered deployment and scaling
Terminal 1 (watch):
```bash
kubectl get pods -n dso202-assignment-02 -l tier=database -w
```
Terminal 2 (scale up):
```bash
kubectl scale statefulset db --replicas=3 -n dso202-assignment-02
```
Pods are created **in order**: `db-1` must be Ready before `db-2` starts.
```bash
kubectl get pods,pvc -n dso202-assignment-02
# One PVC per pod: db-storage-db-0, db-storage-db-1, db-storage-db-2

kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 \
  -n dso202-assignment-02 -- sh -c "nslookup db-1.db-svc; nslookup db-2.db-svc"
```
Scale down (terminates in **reverse** order, `db-2` first):
```bash
kubectl scale statefulset db --replicas=1 -n dso202-assignment-02
kubectl get pods -n dso202-assignment-02 -l tier=database -w

# PVCs are kept after scale-down (data is protected)
kubectl get pvc -n dso202-assignment-02
```
> Note: db-1 and db-2 are independent Postgres instances, not replicas of db-0.
> The backend always uses `db-0.db-svc`. Scale back to 1 when done.

## D. Ordered rolling update
```bash
kubectl set resources statefulset db -n dso202-assignment-02 \
  --limits=cpu=250m,memory=256Mi -c db
kubectl rollout status statefulset/db -n dso202-assignment-02
kubectl rollout history statefulset/db -n dso202-assignment-02
```

---

# VERIFY: Ingress (Traefik)

## E. Expose Traefik locally
Leave this running in its own terminal (high ports need no sudo):
```bash
kubectl port-forward -n traefik svc/traefik 8000:80 8443:443
```

## F. HTTPS + name-based virtual hosting (no /etc/hosts edit)
```bash
# Host 1 -> frontend
curl -kv --resolve app.dso202.local:8443:127.0.0.1 https://app.dso202.local:8443/

# Host 2 -> backend (same IP and port, different Host header)
curl -kv --resolve api.dso202.local:8443:127.0.0.1 https://api.dso202.local:8443/

# Unknown host -> Traefik answers 404 (no matching rule)
curl -k --resolve other.local:8443:127.0.0.1 https://other.local:8443/ -i
```
Check the certificate served (TLS termination):
```bash
curl -kv --resolve app.dso202.local:8443:127.0.0.1 https://app.dso202.local:8443/ 2>&1 | grep -E "subject|issuer|SSL connection"
```

## G. Browser access (optional)
Add to `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`):
```
127.0.0.1 app.dso202.local api.dso202.local
```
Open `https://app.dso202.local:8443` and accept the self-signed certificate warning.

## H. Plain HTTP is not served (annotation `router.entrypoints: websecure`)
```bash
curl -i --resolve app.dso202.local:8000:127.0.0.1 http://app.dso202.local:8000/
# -> 404 because the router only exists on the websecure entrypoint
```

## I. Traefik dashboard and logs
```bash
kubectl port-forward -n traefik deploy/traefik 9000:8080
# Browser: http://localhost:9000/dashboard/   (see Routers/Services)

kubectl logs -n traefik deploy/traefik --tail=20      # access log lines per request
```

## J. End-to-end test
```bash
kubectl get all,ingress,pvc -n dso202-assignment-02
kubectl logs deploy/backend-deployment -n dso202-assignment-02 --tail=20
```

---

# Cleanup
```bash
kubectl delete -f ingress/ingress.yaml
kubectl delete secret dso202-tls -n dso202-assignment-02
kubectl delete -f traefik/traefik.yaml
kubectl delete namespace dso202-assignment-02   # also removes PVCs
rm -f tls.crt tls.key
```