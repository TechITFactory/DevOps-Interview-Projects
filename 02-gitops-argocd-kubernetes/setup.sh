#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-command bootstrap for Project 02: GitOps with ArgoCD
#
# Usage:
#   export GITHUB_USER="your-github-username"
#   chmod +x setup.sh
#   ./setup.sh
#
# Requirements: Docker running, minikube, kubectl, argocd CLI, gh CLI, git
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-gitops-lab}"
ARGOCD_NS="argocd"
APP_NS="production"
APP_NAME="web-prod"
ARGO_VERSION="v2.11.3"
GITHUB_USER="${GITHUB_USER:-}"
REPO_NAME="${REPO_NAME:-gitops-argocd-demo}"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGO_PORT="${ARGO_PORT:-8080}"

log()  { echo "[$(date +%T)] $*"; }
ok()   { echo "[$(date +%T)] ✓ $*"; }
fail() { echo "[$(date +%T)] ✗ $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# 1. Prerequisite checks
# --------------------------------------------------------------------------- #
log "Checking prerequisites..."
command -v docker   >/dev/null 2>&1 || fail "docker is not installed"
command -v minikube >/dev/null 2>&1 || fail "minikube is not installed (see README Step 0)"
command -v kubectl  >/dev/null 2>&1 || fail "kubectl is not installed (see README Step 0)"
command -v argocd   >/dev/null 2>&1 || fail "argocd CLI is not installed (see README Step 0)"
command -v git      >/dev/null 2>&1 || fail "git is not installed"
command -v gh       >/dev/null 2>&1 || fail "GitHub CLI (gh) is not installed (see README Step 0)"
docker info >/dev/null 2>&1         || fail "Docker daemon is not running"

if [ -z "${GITHUB_USER}" ]; then
  fail "GITHUB_USER is not set. Run: export GITHUB_USER=your-github-username"
fi

if ! gh auth status >/dev/null 2>&1; then
  fail "GitHub CLI is not authenticated. Run: gh auth login"
fi

ok "Prerequisites satisfied"

# --------------------------------------------------------------------------- #
# 2. Start minikube cluster (idempotent)
# --------------------------------------------------------------------------- #
if minikube status --profile="${MINIKUBE_PROFILE}" 2>/dev/null | grep -q "Running"; then
  ok "minikube profile '${MINIKUBE_PROFILE}' is already running — skipping start"
else
  log "Starting minikube cluster '${MINIKUBE_PROFILE}'..."
  minikube start \
    --profile="${MINIKUBE_PROFILE}" \
    --driver=docker \
    --kubernetes-version=v1.30.0 \
    --cpus=2 \
    --memory=4096
  ok "minikube cluster started"
fi

# Point kubectl at the minikube profile
kubectl config use-context "${MINIKUBE_PROFILE}"

log "Waiting for node to be Ready..."
kubectl wait node --all --for=condition=Ready --timeout=120s
ok "Node is Ready"
kubectl get nodes

# --------------------------------------------------------------------------- #
# 3. Install ArgoCD
# --------------------------------------------------------------------------- #
if kubectl get namespace "${ARGOCD_NS}" >/dev/null 2>&1; then
  ok "ArgoCD namespace already exists — skipping install"
else
  log "Installing ArgoCD ${ARGO_VERSION}..."
  kubectl create namespace "${ARGOCD_NS}"
  kubectl apply -n "${ARGOCD_NS}" \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"
fi

log "Waiting for argocd-server to roll out (up to 5 min)..."
kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NS}" --timeout=300s
ok "ArgoCD is running"

# --------------------------------------------------------------------------- #
# 4. Expose ArgoCD and log in
# --------------------------------------------------------------------------- #
log "Port-forwarding ArgoCD server on localhost:${ARGO_PORT}..."
pkill -f "kubectl port-forward.*argocd-server" 2>/dev/null || true
kubectl port-forward svc/argocd-server \
  -n "${ARGOCD_NS}" "${ARGO_PORT}:443" &
PF_PID=$!
sleep 3

ARGO_PWD=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

argocd login "localhost:${ARGO_PORT}" \
  --username admin \
  --password "${ARGO_PWD}" \
  --insecure
ok "Logged in to ArgoCD (admin password: ${ARGO_PWD})"

# --------------------------------------------------------------------------- #
# 5. Push manifests to GitHub (idempotent)
# --------------------------------------------------------------------------- #
log "Preparing GitOps repository..."

cd "${WORKSPACE_ROOT}"
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  git init -b main
  git add .
  git commit -m "Initial GitOps manifests"
fi

REPO_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

if gh repo view "${GITHUB_USER}/${REPO_NAME}" >/dev/null 2>&1; then
  ok "GitHub repo already exists — pushing latest..."
  git remote set-url origin "${REPO_URL}" 2>/dev/null || \
    git remote add origin "${REPO_URL}"
  git push origin main
else
  log "Creating GitHub repo and pushing..."
  gh repo create "${GITHUB_USER}/${REPO_NAME}" \
    --public \
    --source . \
    --remote origin \
    --push
fi
ok "Manifests pushed to ${REPO_URL}"

# --------------------------------------------------------------------------- #
# 6. Create ArgoCD Application
# --------------------------------------------------------------------------- #
log "Creating ArgoCD Application '${APP_NAME}'..."
argocd app create "${APP_NAME}" \
  --repo "${REPO_URL}" \
  --path manifests/base \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace "${APP_NS}" \
  --sync-policy automated \
  --self-heal \
  --auto-prune \
  --upsert

log "Triggering initial sync..."
argocd app sync "${APP_NAME}"

log "Waiting for application to be Healthy and Synced..."
argocd app wait "${APP_NAME}" \
  --health \
  --sync \
  --timeout 120
ok "Application '${APP_NAME}' is Healthy and Synced"

# --------------------------------------------------------------------------- #
# 7. Verify deployment
# --------------------------------------------------------------------------- #
log "Verifying Kubernetes resources in namespace '${APP_NS}'..."
kubectl get all -n "${APP_NS}"

POD_COUNT=$(kubectl get pods -n "${APP_NS}" \
  -l app=web --field-selector=status.phase=Running \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${POD_COUNT}" -ge 1 ] || fail "No running pods found in namespace ${APP_NS}"
ok "${POD_COUNT} pod(s) running"

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo "============================================================"
echo " Project 02 — GitOps with ArgoCD is running"
echo "============================================================"
echo "  ArgoCD UI   : https://localhost:${ARGO_PORT}"
echo "  Login       : admin / ${ARGO_PWD}"
echo "  App status  : argocd app get ${APP_NAME}"
echo "  Git repo    : ${REPO_URL}"
echo ""
echo "  To trigger a GitOps rollout:"
echo "    # edit manifests/base/deployment.yaml (e.g. change image tag)"
echo "    git add . && git commit -m 'upgrade nginx' && git push origin main"
echo "    argocd app wait ${APP_NAME} --health --sync"
echo ""
echo "  To simulate drift:"
echo "    kubectl scale deployment web -n ${APP_NS} --replicas=5"
echo "    sleep 30 && kubectl get deploy web -n ${APP_NS}"
echo "    # ArgoCD self-heals back to 2 replicas"
echo ""
echo "  To clean up everything:"
echo "    minikube delete --profile ${MINIKUBE_PROFILE}"
echo "    gh repo delete ${GITHUB_USER}/${REPO_NAME} --yes"
echo "============================================================"

log "ArgoCD port-forward is running (PID ${PF_PID}). Press Ctrl+C to stop."
wait ${PF_PID}
