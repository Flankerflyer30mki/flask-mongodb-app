# Flask + MongoDB on Kubernetes (Minikube)

A Python Flask application backed by MongoDB, deployed on a local Minikube cluster with:

- a Flask **Deployment** (2 replicas) exposed through a **NodePort Service**
- a MongoDB **StatefulSet** with **authentication enabled**, reachable only inside the cluster through a **headless Service**
- a **PersistentVolume / PersistentVolumeClaim** so MongoDB data survives pod restarts
- a **Horizontal Pod Autoscaler** scaling Flask from 2 to 5 replicas at 70% CPU
- **resource requests and limits** on every pod

## Contents

1. [Repository layout](#1-repository-layout)
2. [Application](#2-application)
3. [Prerequisites](#3-prerequisites)
4. [Part 1: running locally](#4-part-1-running-locally)
5. [Build and push the Docker image](#5-build-and-push-the-docker-image)
6. [Deploy to Minikube](#6-deploy-to-minikube)
7. [Verify the deployment](#7-verify-the-deployment)
8. [DNS resolution inside the cluster](#8-dns-resolution-inside-the-cluster)
9. [Resource requests and limits](#9-resource-requests-and-limits)
10. [Design choices](#10-design-choices)
11. [Testing scenarios](#11-testing-scenarios)
12. [Cleanup](#12-cleanup)

---

## 1. Repository layout

```
flask-mongodb-app/
├── app.py                    # Flask application (updated to authenticate with MongoDB)
├── requirements.txt          # Pinned Python dependencies
├── Dockerfile                # Image for the Flask application
├── .dockerignore
├── .env.example              # Environment for local (Part 1) runs
└── k8s/
    ├── mongo-secret.yaml       # MongoDB root username and password
    ├── mongo-pv.yaml           # PersistentVolume (hostPath on the Minikube node)
    ├── mongo-pvc.yaml          # PersistentVolumeClaim bound to the PV
    ├── mongo-service.yaml      # Headless Service, internal only
    ├── mongo-statefulset.yaml  # MongoDB with authentication
    ├── flask-deployment.yaml   # Flask, 2 replicas
    ├── flask-service.yaml      # NodePort Service, reachable from the host
    └── flask-hpa.yaml          # Autoscaler, 2-5 replicas at 70% CPU
```

## 2. Application

| Endpoint | Method | Behaviour |
|---|---|---|
| `/` | GET | `Welcome to the Flask app! The current time is: <Date and Time>` |
| `/data` | POST | Inserts the JSON body into the `flask_db.data` collection, returns `201` |
| `/data` | GET | Returns every document in `flask_db.data` (without `_id`), returns `200` |

### Change made for authentication

The original code connected with only `MONGODB_URI`. It now also reads `MONGO_USERNAME` and `MONGO_PASSWORD` (injected from the Kubernetes Secret) and passes them to `MongoClient` as keyword arguments with `authSource="admin"`:

```python
mongo_username = os.environ.get("MONGO_USERNAME")
client = MongoClient(
    os.environ.get("MONGODB_URI", "mongodb://localhost:27017/"),
    **({"username": mongo_username,
        "password": os.environ.get("MONGO_PASSWORD"),
        "authSource": "admin"} if mongo_username else {}),
)
```

- **Why keyword arguments instead of `mongodb://user:pass@host`:** a password containing `@`, `:` or `/` would break the URI unless URL-encoded. Keyword arguments need no encoding.
- **Why `authSource="admin"`:** the official `mongo` image creates the root user in the `admin` database. Without `authSource=admin` the driver would try to authenticate against `flask_db` and fail.
- **Why it is conditional:** when `MONGO_USERNAME` is not set, the app connects without credentials, so the Part 1 local setup (MongoDB without auth) still works unchanged.

The PDF's copy of the code had lost its double underscores; `Flask(__name__)` and `if __name__ == '__main__':` are restored.

## 3. Prerequisites

| Tool | Purpose | Install (macOS) |
|---|---|---|
| Docker | Build images, Minikube driver | Docker Desktop |
| Minikube | Local Kubernetes cluster | `brew install minikube` |
| kubectl | Talk to the cluster | `brew install kubectl` |
| Docker Hub account | Container registry | https://hub.docker.com |

**Python version:** the pinned dependencies (Flask 2.0.2, Werkzeug 2.0.3, pymongo 3.12.0) predate recent Python releases. Use Python 3.8–3.11 for local runs. The Docker image uses `python:3.11-slim`.

## 4. Part 1: running locally

```bash
python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

docker run -d -p 27017:27017 --name mongodb mongo:7.0

cp .env.example .env
export $(cat .env | xargs)

export FLASK_APP=app.py
flask run
```

```bash
curl http://localhost:5000/
curl -X POST -H "Content-Type: application/json" -d '{"sampleKey":"sampleValue"}' http://localhost:5000/data
curl http://localhost:5000/data
```

> On macOS, port 5000 may already be used by AirPlay Receiver. If so, run `flask run --port 5001`, or turn off AirPlay Receiver in System Settings.

### Why use a virtual environment

- **Isolation:** each project gets its own packages. This project needs Flask 2.0.2; another project on the same machine can use Flask 3 without conflict.
- **Reproducibility:** `requirements.txt` plus a clean venv recreates exactly the same dependency set on any machine.
- **No system pollution:** packages are not installed into the system Python, which the OS or other tools may depend on, and no `sudo` is needed.
- **Easy reset:** delete the `venv/` folder and recreate it to start clean.

## 5. Build and push the Docker image

The published image is [`ananya0419/flask-mongodb-app:1.0`](https://hub.docker.com/r/ananya0419/flask-mongodb-app) (`linux/amd64` and `linux/arm64`), and `k8s/flask-deployment.yaml` already points at it. To build and push your own copy, replace `<dockerhub-username>` with your Docker Hub username.

```bash
# Build
docker build -t <dockerhub-username>/flask-mongodb-app:1.0 .

# Log in and push
docker login
docker push <dockerhub-username>/flask-mongodb-app:1.0
```

Then set your image name in `k8s/flask-deployment.yaml`:

```yaml
image: <dockerhub-username>/flask-mongodb-app:1.0
```

**Apple Silicon note:** `docker build` on an M-series Mac produces an `arm64` image, which matches Minikube on the same Mac. To make the image run on `amd64` machines as well, build a multi-architecture image:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t <dockerhub-username>/flask-mongodb-app:1.0 --push .
```

**Without a registry (optional):** `minikube image load <dockerhub-username>/flask-mongodb-app:1.0` copies a locally built image straight into Minikube. The Deployment uses the default `IfNotPresent` pull policy for a fixed tag, so it uses the loaded image.

## 6. Deploy to Minikube

```bash
# 1. Start the cluster and enable metrics (required by the HPA)
minikube start --cpus=2 --memory=4096
minikube addons enable metrics-server

# 2. Secret first, because both MongoDB and Flask read it
kubectl apply -f k8s/mongo-secret.yaml

# 3. Storage
kubectl apply -f k8s/mongo-pv.yaml
kubectl apply -f k8s/mongo-pvc.yaml

# 4. MongoDB
kubectl apply -f k8s/mongo-service.yaml
kubectl apply -f k8s/mongo-statefulset.yaml
kubectl rollout status statefulset/mongodb

# 5. Flask
kubectl apply -f k8s/flask-deployment.yaml
kubectl apply -f k8s/flask-service.yaml
kubectl rollout status deployment/flask-app

# 6. Autoscaler
kubectl apply -f k8s/flask-hpa.yaml
```

Kubernetes reconciles in any order, so `kubectl apply -f k8s/` also works. The order above just avoids pods waiting on a Secret or PVC that does not exist yet.

## 7. Verify the deployment

```bash
kubectl get pods,svc,pv,pvc,hpa
```

Expected: 2 `flask-app` pods and 1 `mongodb-0` pod `Running`, PVC `mongo-pvc` `Bound` to `mongo-pv`, and the HPA showing `cpu: <n>%/70%` with `MINPODS 2`, `MAXPODS 5`. The HPA shows `<unknown>/70%` for the first minute while metrics-server collects data.

Get a URL reachable from your machine:

```bash
minikube service flask-service --url
# e.g. http://127.0.0.1:54321  (with the Docker driver on macOS, keep this terminal open)
```

```bash
URL=$(minikube service flask-service --url)   # or paste the URL from above
curl $URL/
curl -X POST -H "Content-Type: application/json" -d '{"sampleKey":"sampleValue"}' $URL/data
curl $URL/data
```

Confirm MongoDB rejects unauthenticated access:

```bash
kubectl exec -it mongodb-0 -- mongosh --quiet --eval 'db.getSiblingDB("flask_db").data.find()'
# MongoServerError: Command find requires authentication

kubectl exec -it mongodb-0 -- mongosh -u admin -p change-me-s3cret --authenticationDatabase admin \
  --quiet --eval 'db.getSiblingDB("flask_db").data.find()'
# [ { _id: ObjectId(...), sampleKey: 'sampleValue' } ]
```

Confirm MongoDB is not reachable from outside the cluster: `kubectl get svc mongodb` shows `CLUSTER-IP None` and no node port, so there is no address on the host to connect to.

## 8. DNS resolution inside the cluster

Pods are temporary: when one restarts it gets a new IP address. Applications therefore never connect by IP; they connect by **Service name**, and the cluster DNS turns the name into the current address.

**How it works**

1. Every cluster runs **CoreDNS** (in `kube-system`). It watches the Kubernetes API and keeps a DNS record for every Service and, for headless Services, for every backing pod.
2. The kubelet writes each pod's `/etc/resolv.conf` to point at CoreDNS, with search domains such as `default.svc.cluster.local svc.cluster.local cluster.local`.
3. A Service named `mongodb` in namespace `default` gets the fully qualified name `mongodb.default.svc.cluster.local`. Thanks to the search domains, a pod in the same namespace can use just `mongodb`.
4. What the name resolves to depends on the Service type:
   - **ClusterIP Service** (`flask-service`): resolves to one stable virtual IP. kube-proxy load-balances connections to that IP across the ready pods.
   - **Headless Service** (`mongodb`, `clusterIP: None`): no virtual IP. The name resolves directly to the pod IPs, and each StatefulSet pod also gets its own stable record, `<pod>.<service>`, for example `mongodb-0.mongodb.default.svc.cluster.local`.

**How the Flask app reaches MongoDB**

`flask-deployment.yaml` sets `MONGODB_URI=mongodb://mongodb:27017/`. When pymongo connects, the pod asks CoreDNS for `mongodb`, CoreDNS returns the current IP of `mongodb-0`, and the connection goes straight to it. If `mongodb-0` is rescheduled and gets a new IP, CoreDNS updates the record and the driver reconnects to the new address with no configuration change.

To see it from inside the cluster:

```bash
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup mongodb
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup mongodb-0.mongodb
```

## 9. Resource requests and limits

Both the Flask and MongoDB containers use:

| | CPU | Memory |
|---|---|---|
| **Request** | `200m` (0.2 CPU) | `250M` |
| **Limit** | `500m` (0.5 CPU) | `500M` |

**Request: the guaranteed minimum.**
- The scheduler places a pod only on a node with at least this much unreserved CPU and memory, so requests stop a node from being overbooked.
- The HPA calculates CPU utilisation as a percentage of the request. With a `200m` request and a 70% target, scaling starts when average usage passes `140m`. **Without a CPU request, the HPA cannot compute utilisation and does not scale.**

**Limit: the hard ceiling.**
- **CPU** is compressible: a container trying to use more than `500m` is throttled (slowed down), not killed.
- **Memory** is not compressible: a container exceeding `500M` is killed by the kernel (`OOMKilled`) and restarted.
- Limits stop one misbehaving pod (a memory leak, a runaway loop) from starving every other pod on the node.

**Use case.** Requests give predictable placement and autoscaling; limits give isolation and stability. Because request < limit, these pods are in the **Burstable** QoS class: they are guaranteed their request and can use spare capacity up to the limit. Setting request = limit would give the **Guaranteed** class (evicted last under node memory pressure) at the cost of reserving more capacity up front.

Note: `M` means megabytes (10^6 bytes) and `Mi` means mebibytes (2^20 bytes). The values given in the assignment (`250M`, `500M`) are used as written.

## 10. Design choices

| Decision | Chosen | Alternatives considered | Why |
|---|---|---|---|
| MongoDB workload | **StatefulSet**, 1 replica | Deployment | A StatefulSet gives the pod a stable name (`mongodb-0`), stable DNS and stable storage across restarts, which a database needs. A Deployment gives random pod names and is meant for interchangeable, stateless pods. |
| MongoDB replicas | **1** | 3-member replica set | A replica set needs `--replSet`, a keyfile for internal auth and an init step. Not required here; one instance with a persistent volume meets the persistence requirement. It is the next step for high availability. |
| MongoDB Service | **Headless** (`clusterIP: None`) | ClusterIP | A StatefulSet requires a governing headless Service for per-pod DNS. It is also internal-only, so one Service covers both needs. A plain ClusterIP would add a second Service with no benefit at 1 replica. |
| Authentication | **`MONGO_INITDB_ROOT_*` from a Secret** | Custom init script creating an app user | The official image enables `--auth` automatically when these are set. Simplest correct option. A dedicated least-privilege user for `flask_db` would be better in production. |
| Credentials | **Kubernetes Secret** | Plain env values, ConfigMap | Keeps credentials out of the Deployment and the image. The committed demo Secret is for reproducibility only; in production it would come from Sealed Secrets, External Secrets or Vault. |
| Storage | **Static hostPath PV + PVC** (`storageClassName: manual`) | Minikube's default dynamic provisioner, StatefulSet `volumeClaimTemplates` | The assignment asks for an explicit PV and PVC. `manual` stops the PVC binding to a dynamically provisioned volume. hostPath is fine on a single-node Minikube; on a real cluster this would be a cloud disk through a StorageClass and `volumeClaimTemplates`. |
| Reclaim policy | **Retain** | Delete | Deleting the PVC by mistake must not delete database files. |
| Flask exposure | **NodePort** | LoadBalancer, Ingress | NodePort works on Minikube with no extra add-ons. LoadBalancer needs `minikube tunnel`; Ingress needs the ingress add-on and a hostname. Both are better choices on a real cloud cluster. |
| MongoDB image | **`mongo:7.0`** (pinned) | `mongo:latest` | `latest` changes underneath you; a pinned version deploys the same way every time. |
| Base image | **`python:3.11-slim`** | `python:3.x` (full), Alpine | Slim is small and uses glibc, so wheels install without compilers. 3.11 is the newest Python the pinned dependencies support. Alpine's musl often forces source builds. |
| Container user | **`nobody`** | root (default) | No reason for the app to run as root; reduces impact of a compromise. |
| App server | **Flask built-in server** (`python app.py`) | gunicorn | Keeps the given application unchanged. For production, gunicorn with several workers would be used; the built-in server is meant for development. |
| Health checks | **Readiness and liveness probes** on `/` | None | Readiness keeps traffic away from a pod until it answers; liveness restarts a hung container. `/` does not touch MongoDB, so a database outage does not restart every Flask pod. |
| Autoscaling | **HPA on CPU**, 2–5 replicas, 70% | Memory or custom metrics | As specified. CPU tracks request load for this app. |

## 11. Testing scenarios

### 11.1 Database interaction

```bash
URL=$(minikube service flask-service --url)
curl -X POST -H "Content-Type: application/json" -d '{"name":"test1"}' $URL/data   # {"status":"Data inserted"}
curl $URL/data                                                                       # [{"name":"test1"}]
```

Repeat the GET several times. Both Flask replicas serve it and return the same data, because the state lives in MongoDB, not in the pods.

### 11.2 Data persistence

```bash
curl -X POST -H "Content-Type: application/json" -d '{"name":"before-restart"}' $URL/data
kubectl delete pod mongodb-0            # the StatefulSet recreates it with the same PVC
kubectl wait --for=condition=Ready pod/mongodb-0 --timeout=120s
curl $URL/data                          # "before-restart" is still there
```

### 11.3 Authentication

See [section 7](#7-verify-the-deployment): unauthenticated `mongosh` is refused, authenticated access succeeds.

### 11.4 Autoscaling under high traffic

Terminal 1, watch the autoscaler:

```bash
kubectl get hpa flask-hpa --watch
```

Terminal 2, generate load from inside the cluster:

```bash
kubectl create deployment load-generator --image=busybox:1.36 --replicas=4 -- \
  /bin/sh -c "while true; do wget -q -O- http://flask-service:5000/ > /dev/null; done"
```

Expected behaviour:
1. CPU in the HPA rises above `70%` within 1–2 minutes (metrics-server reports with a delay).
2. Replicas increase from 2 towards 5 (`kubectl get pods -l app=flask-app`).
3. Stop the load: `kubectl delete deployment load-generator`.
4. After the default 5-minute scale-down stabilisation window, replicas return to 2.

If CPU stays below 70%, raise the load: `kubectl scale deployment load-generator --replicas=8`.

### 11.5 Results

Environment: Minikube v1.39.0 (Kubernetes v1.37.0, Docker driver, 2 CPUs, 4 GB) on an Apple Silicon Mac.

| Scenario | Result | Evidence |
|---|---|---|
| POST and GET `/data` through the NodePort Service | Pass | `{"status":"Data inserted"}`, then `[{"sampleKey":"sampleValue"},{"name":"before-restart"}]` |
| Requests spread across both Flask replicas | Pass | 7 GET requests: 2 served by one pod, 5 by the other |
| Unauthenticated MongoDB access refused | Pass | `MongoServerError: Command find requires authentication`; with credentials, `countDocuments()` returned `2` |
| DNS resolution | Pass | `mongodb` and `mongodb-0.mongodb.default.svc.cluster.local` resolved to the pod IP `10.244.0.4`; `flask-service` resolved to its ClusterIP `10.104.134.231`; pod `resolv.conf` search list `default.svc.cluster.local svc.cluster.local cluster.local` |
| Data survives `mongodb-0` deletion | Pass | New pod (different UID) came back Ready; `GET /data` returned both documents; Flask pods needed 0 restarts |
| HPA scales 2 → 5 under load | Pass | See timeline below |
| HPA scales back to 2 after load stops | Pass | See timeline below |

**Scale-up** (4 busybox load-generator pods looping on `GET /`):

| Time since load started | Average CPU (of 200m request) | Replicas |
|---|---|---|
| 0 s | 1% | 2 |
| 46 s | 50% | 2 |
| 108 s | 147% | 2 → 4 |
| 123 s | 147% | 4 → 5 |
| 169 s | 110% | 5 (max) |

At 5 replicas, individual pods used 123m–225m CPU and 25–30 Mi memory, well below the 500m / 500M limits.

**Scale-down** (load generator deleted):

| Time since load stopped | Average CPU | Replicas |
|---|---|---|
| 0 s | 110% | 5 |
| 107 s | 63% | 5 |
| 168 s | 1% | 5 |
| 412 s | 1% | 2 |

**Observations and issues encountered**

- **Metrics lag.** metrics-server reports roughly every 15–60 s, so the HPA first saw the load at 46 s and only acted at 108 s. For bursty traffic, a higher `minReplicas` (more headroom up front) or a lower CPU target would absorb spikes sooner.
- **Scale-down is slow on purpose.** CPU fell to 1% within about 3 minutes, but replicas stayed at 5 for another ~4 minutes because of the HPA's default 300 s scale-down stabilisation window, which prevents flapping when load briefly dips.
- **Docker image names must be lowercase.** An early draft of the Deployment used an uppercase placeholder (`DOCKERHUB_USERNAME/...`), which Kubernetes rejects with `InvalidImageName`. Use a real, lowercase Docker Hub username.
- **Timestamps are UTC.** The welcome message prints the container's local time, which is UTC in `python:3.11-slim`. Set the `TZ` environment variable on the Deployment for a different zone.
- **`minikube service` keeps a tunnel open.** With the Docker driver on macOS the URL only works while that command is running.

**Before Kubernetes:** the image was also run against `mongo:7.0` with authentication in plain Docker. Without credentials, `GET /data` returned `500` with `OperationFailure` (authentication required). All 8 manifests pass schema validation with `kubeconform -strict`.

### Issues to watch for

- **HPA shows `<unknown>`:** metrics-server is not enabled, or the pod has no CPU request. Run `minikube addons enable metrics-server` and wait a minute.
- **Flask pods crash with authentication errors:** MongoDB only creates the root user when `/data/db` is empty. If the PV already holds data from a run with different credentials, delete the old data: `minikube ssh -- sudo rm -rf /data/mongo`, then recreate the MongoDB pod.
- **`ImagePullBackOff`:** the image name in `flask-deployment.yaml` does not match the pushed image, or the repository is private.
- **`minikube service` URL not reachable on macOS:** with the Docker driver, the command opens a tunnel and must stay running.

## 12. Cleanup

```bash
kubectl delete -f k8s/
minikube ssh -- sudo rm -rf /data/mongo   # the PV uses Retain, so data stays until removed
minikube stop
```
