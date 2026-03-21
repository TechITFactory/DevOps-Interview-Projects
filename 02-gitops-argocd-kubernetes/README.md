# Project 02: GitOps Workflow with ArgoCD on Kubernetes

## 1. Project Title
Production GitOps Delivery on Kubernetes with ArgoCD Auto-Sync, Self-Heal, and Drift Correction

---

## 2. Problem Statement
A platform team managing multiple Kubernetes services sees frequent configuration drift because engineers apply manifests directly with `kubectl`. Auditing changes is difficult, rollback is slow, and outages happen during manual updates. The company needs a GitOps model where Git is the single source of truth and cluster state is continuously reconciled automatically.

---

## 3. Tech Stack

| Layer | Tool | Version |
|---|---|---|
| Infra | Local machine (Linux / macOS / WSL2) | — |
| Local Kubernetes | minikube | v1.33.1 |
| Kubernetes | k8s control plane | v1.30.0 |
| GitOps Controller | ArgoCD | v2.11.3 |
| Manifest Templating | Kustomize | built-in to kubectl 1.30 |
| App Image | nginx | 1.27.0 |
| Git Provider | GitHub | — |
| CLI Tools | kubectl, argocd CLI, gh CLI, git | 1.30.x, 2.11.3, 2.51+, 2.43+ |

---

## 4. Architecture Diagram

```text
  DEVELOPER WORKSTATION (your laptop)
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  $ vim manifests/base/deployment.yaml   # change image: nginx:1.27.1        │
  │  $ git commit -m "upgrade nginx"                                             │
  │  $ git push origin main                                                      │
  └──────────────────────────────────────┬───────────────────────────────────────┘
                                         │ HTTPS push
                                         ▼
  GITHUB REPOSITORY  (gitops-argocd-demo)
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  branch: main                                                                │
  │                                                                              │
  │  manifests/                                                                  │
  │  ├── base/                                                                   │
  │  │   ├── namespace.yaml      (Namespace: production)                         │
  │  │   ├── deployment.yaml     (Deployment: web, replicas: 2, nginx:1.27.x)    │
  │  │   ├── service.yaml        (Service: web, ClusterIP, port 80)              │
  │  │   └── kustomization.yaml  (references all base resources)                 │
  │  └── overlays/                                                               │
  │      ├── dev/                (1 replica, dev- prefix)                        │
  │      ├── staging/            (2 replicas, staging- prefix)                   │
  │      └── production/         (3 replicas, pinned tag)                        │
  └──────────────────────────────────────┬───────────────────────────────────────┘
                                         │ ArgoCD polls every 3 min
                                         │ (or webhook for instant sync)
                                         ▼
  LOCAL MACHINE (your laptop)
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │  minikube CLUSTER  (Kubernetes v1.30.0 · single node)                       │
  │  ┌──────────────────────────────────────────────────────────────────────┐   │
  │  │                                                                       │   │
  │  │  Namespace: argocd                                                    │   │
  │  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
  │  │  │  argocd-server        (UI + API · port-forwarded to :8080)      │ │   │
  │  │  │  argocd-repo-server   (clones Git repo, renders manifests)      │ │   │
  │  │  │  argocd-application-controller  (reconciliation loop)           │ │   │
  │  │  │  argocd-dex-server    (OIDC/SSO provider)                       │ │   │
  │  │  │  argocd-redis         (caching layer)                           │ │   │
  │  │  │                                                                  │ │   │
  │  │  │  RECONCILIATION LOOP (every 3 min or on Git change)             │ │   │
  │  │  │  ┌──────────────────────────────────────────────────────────┐   │ │   │
  │  │  │  │  1. Clone / fetch Git repo  (manifests/base)             │   │ │   │
  │  │  │  │  2. Render manifests with Kustomize                      │   │ │   │
  │  │  │  │  3. Compare desired state  vs  live cluster state        │   │ │   │
  │  │  │  │  4. Detect delta (diff)                                  │   │ │   │
  │  │  │  │     ├── No diff      → Status: Synced                    │   │ │   │
  │  │  │  │     └── Diff found   → Apply manifests (kubectl apply)   │   │ │   │
  │  │  │  │         ├── auto-sync ON   → applies immediately         │   │ │   │
  │  │  │  │         └── auto-sync OFF  → marks OutOfSync, waits      │   │ │   │
  │  │  │  └──────────────────────────────────────────────────────────┘   │ │   │
  │  │  │                                                                  │ │   │
  │  │  │  SELF-HEAL LOOP (continuous, separate from sync)                │ │   │
  │  │  │  ┌──────────────────────────────────────────────────────────┐   │ │   │
  │  │  │  │  Watches live cluster for drift from Git desired state   │   │ │   │
  │  │  │  │  e.g. kubectl scale → replicas changed manually          │   │ │   │
  │  │  │  │  → ArgoCD detects drift → re-applies Git manifests       │   │ │   │
  │  │  │  │  → live state restored to Git state within ~30 s         │   │ │   │
  │  │  │  └──────────────────────────────────────────────────────────┘   │ │   │
  │  │  └─────────────────────────────────────────────────────────────────┘ │   │
  │  │                           │ kubectl apply                             │   │
  │  │                           ▼                                           │   │
  │  │  Namespace: production                                                │   │
  │  │  ┌─────────────────────────────────────────────────────────────────┐ │   │
  │  │  │  Deployment: web                                                 │ │   │
  │  │  │  ├── ReplicaSet                                                  │ │   │
  │  │  │  │   ├── Pod: web-xxxxx (nginx:1.27.x · port 80)                │ │   │
  │  │  │  │   │   ├── readinessProbe: GET /  every 10 s                  │ │   │
  │  │  │  │   │   ├── livenessProbe:  GET /  every 20 s                  │ │   │
  │  │  │  │   │   └── resources: req 100m/128Mi · limit 250m/256Mi       │ │   │
  │  │  │  │   └── Pod: web-yyyyy  (second replica)                       │ │   │
  │  │  │  └── RollingUpdate strategy: maxUnavailable=1, maxSurge=1       │ │   │
  │  │  │                                                                  │ │   │
  │  │  │  Service: web  (ClusterIP · port 80 → targetPort 80)            │ │   │
  │  │  └─────────────────────────────────────────────────────────────────┘ │   │
  │  └──────────────────────────────────────────────────────────────────────┘   │
  │                                                                              │
  └──────────────────────────────────────────────────────────────────────────────┘

  ─────────────────────────────────────────────────────────────────────────────
  GITOPS FLOW SUMMARY
  ─────────────────────────────────────────────────────────────────────────────
  DEPLOY:   Developer edits manifest → git commit + push → ArgoCD detects
            delta → renders Kustomize → kubectl apply → rolling update

  ROLLBACK: git revert <bad-commit> → push → ArgoCD syncs old state back
            (Git history IS the deployment history)

  DRIFT:    Engineer runs kubectl scale → ArgoCD detects live ≠ desired
            → self-heal re-applies Git manifest → replicas restored

  AUDIT:    Every change traceable to a commit SHA, author, and timestamp
  ─────────────────────────────────────────────────────────────────────────────
```

---

## 5. Step-by-Step Execution Guide

> **Fastest path:** set `GITHUB_USER` then run `./setup.sh` — it automates every step below.
> Follow the manual steps to understand each command.

### Step 0: Install prerequisites

```bash
# System packages (Linux/WSL2)
sudo apt-get update
sudo apt-get install -y curl git jq

# macOS (Homebrew)
# brew install curl git jq
```

Install `kubectl`:
```bash
curl -LO "https://dl.k8s.io/release/v1.30.2/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```
Expected: `Client Version: v1.30.2`

Install `minikube`:
```bash
curl -LO https://storage.googleapis.com/minikube/releases/v1.33.1/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube version
```
Expected: `minikube version: v1.33.1`

Install `argocd` CLI:
```bash
curl -sSL -o argocd-linux-amd64 \
  https://github.com/argoproj/argo-cd/releases/download/v2.11.3/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
argocd version --client
```
Expected: `argocd: v2.11.3+...`

Install GitHub CLI:
```bash
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
  https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y
gh auth login
```

---

### Step 1: Start minikube cluster

```bash
minikube start \
  --driver=docker \
  --kubernetes-version=v1.30.0 \
  --cpus=2 \
  --memory=4096 \
  --profile=gitops-lab

kubectl get nodes
```
Expected output:
```text
😄  [gitops-lab] minikube v1.33.1 on Linux
✅  Done! kubectl is now configured to use "gitops-lab" profile
NAME          STATUS   ROLES           AGE   VERSION
gitops-lab    Ready    control-plane   ...   v1.30.0
```

> **Note:** minikube requires Docker to be running. On macOS you can also use `--driver=hyperkit` or `--driver=virtualbox`.

---

### Step 2: Install ArgoCD in the cluster

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.3/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl get pods -n argocd
```
Expected output:
```text
deployment "argocd-server" successfully rolled out
NAME                                   READY   STATUS    RESTARTS   AGE
argocd-application-controller-0        1/1     Running   0          ...
argocd-server-...                      1/1     Running   0          ...
```

---

### Step 3: Expose ArgoCD and log in

**Terminal A** — start port-forward (keep this running):
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

**Terminal B** — get password and log in:
```bash
ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD password: $ARGO_PWD"
argocd login localhost:8080 --username admin --password "$ARGO_PWD" --insecure
```
Expected: `'admin:login' logged in successfully`

Open your browser at `https://localhost:8080` to see the ArgoCD UI.

---

### Step 4: Create GitOps repo and push manifests

```bash
export GITHUB_USER="your-github-username"
export REPO_NAME="gitops-argocd-demo"
cd ~/devops-series/02-gitops-argocd-kubernetes
```

The `manifests/` directory in this project already contains all required files:
- `manifests/base/namespace.yaml` — creates the `production` namespace
- `manifests/base/deployment.yaml` — nginx Deployment with health probes and security hardening
- `manifests/base/service.yaml` — ClusterIP Service
- `manifests/base/kustomization.yaml` — Kustomize base config
- `manifests/overlays/dev/`, `staging/`, `production/` — environment-specific overrides

Push to GitHub:
```bash
git init -b main
git add .
git commit -m "Initial GitOps manifests"
gh repo create "$GITHUB_USER/$REPO_NAME" --public --source . --remote origin --push
```
Expected:
```text
[main (root-commit) ...] Initial GitOps manifests
https://github.com/your-github-username/gitops-argocd-demo
```

---

### Step 5: Create ArgoCD Application with auto-sync and self-heal

```bash
argocd app create web-prod \
  --repo "https://github.com/$GITHUB_USER/$REPO_NAME.git" \
  --path manifests/base \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production \
  --sync-policy automated \
  --self-heal \
  --auto-prune

argocd app sync web-prod
argocd app get web-prod
kubectl get all -n production
```
Expected:
```text
application 'web-prod' created
Name:          web-prod
Sync Status:   Synced to main (...)
Health Status: Healthy

NAME                       READY   STATUS    RESTARTS   AGE
pod/web-...                1/1     Running   0          ...
service/web                ClusterIP   ...
deployment.apps/web        2/2     2
```

---

### Step 6: Demonstrate GitOps change rollout

```bash
cd ~/devops-series/02-gitops-argocd-kubernetes
# Update image tag in Git — this triggers a rolling update
sed -i 's/nginx:1.27.0/nginx:1.27.1/' manifests/base/deployment.yaml
git add manifests/base/deployment.yaml
git commit -m "Upgrade nginx image to 1.27.1"
git push origin main

# Watch ArgoCD detect the Git change and apply it
argocd app wait web-prod --health --sync --timeout 120

# Confirm the cluster is now running the new image
kubectl get deploy web -n production \
  -o=jsonpath='{.spec.template.spec.containers[0].image}' && echo
```
Expected:
```text
application 'web-prod' synchronized and healthy
nginx:1.27.1
```

---

### Step 7: Demonstrate drift detection and self-heal

```bash
# Manually scale replicas — this creates config drift
kubectl scale deployment web -n production --replicas=5
kubectl get deploy web -n production
# Output shows 5/5 replicas — wrong!

# Wait for ArgoCD self-heal to kick in (~30 seconds)
argocd app wait web-prod --health --sync --timeout 60
kubectl get deploy web -n production
# Output shows 2/2 replicas — restored to Git desired state
```
Expected:
```text
deployment.apps/web scaled
... READY 5/5 ...
...
... READY 2/2 ...
```
ArgoCD detected that live state (5 replicas) diverged from desired state (2 replicas in Git) and automatically corrected it.

---

### Cleanup

```bash
# Delete the minikube cluster
minikube delete --profile gitops-lab

# Delete the GitHub repo (optional)
gh repo delete $GITHUB_USER/gitops-argocd-demo --yes
```

---

## 6. Interview Questions Covered

1. **What is GitOps, and how is it different from traditional CI/CD deployment?**
2. **How does ArgoCD reconcile desired state versus live cluster state?**
3. **What is configuration drift, and how does self-heal in ArgoCD address it?**
4. **What are the risks of enabling auto-prune and auto-sync in production?**
5. **How do you structure Kubernetes manifests for multi-environment GitOps repositories?**
6. **How do you roll back a bad deployment in a GitOps workflow?**

---

## 7. Video Transcript

NA

---

## 8. Resume Bullet Point

> Designed and implemented a Kubernetes GitOps platform with ArgoCD (auto-sync, self-heal, and drift correction), enabling fully auditable commit-driven deployments across dev / staging / production environments and eliminating manual kubectl apply from the deployment process.
