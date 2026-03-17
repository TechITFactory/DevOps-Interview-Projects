#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-command bootstrap for Project 01: CI/CD with Jenkins + Docker
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# What it does (mirrors the README step-by-step guide):
#   1. Validates prerequisites
#   2. Initialises the Git remote
#   3. Builds and starts the custom Jenkins container
#   4. Waits for Jenkins to be ready
#   5. Creates the pipeline job via the Jenkins API
#   6. Triggers the first build and tails the log
#   7. Verifies the app endpoint
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration — override any of these with environment variables
# --------------------------------------------------------------------------- #
JENKINS_PORT="${JENKINS_PORT:-8080}"
APP_PORT="${APP_PORT:-5000}"
JENKINS_USER="${JENKINS_ADMIN_USER:-admin}"
JENKINS_PASS="${JENKINS_ADMIN_PASSWORD:-ChangeMe123!}"
JENKINS_IMAGE="custom-jenkins:2.452.3"
JENKINS_CONTAINER="jenkins"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[$(date +%T)] $*"; }
ok()   { echo "[$(date +%T)] ✓ $*"; }
fail() { echo "[$(date +%T)] ✗ $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# 1. Prerequisite checks
# --------------------------------------------------------------------------- #
log "Checking prerequisites..."
command -v docker  >/dev/null 2>&1 || fail "docker is not installed"
command -v git     >/dev/null 2>&1 || fail "git is not installed"
command -v curl    >/dev/null 2>&1 || fail "curl is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed (needed for job XML generation)"
docker info >/dev/null 2>&1        || fail "Docker daemon is not running"
ok "Prerequisites satisfied"

# --------------------------------------------------------------------------- #
# 2. Initialise local Git remote (idempotent)
# --------------------------------------------------------------------------- #
log "Initialising Git remote..."

REMOTE_DIR="${WORKSPACE_ROOT}/remote.git"
APP_DIR="${WORKSPACE_ROOT}/app"

if [ ! -d "${REMOTE_DIR}" ]; then
  git init --bare "${REMOTE_DIR}"
  ok "Created bare remote at ${REMOTE_DIR}"
else
  ok "Bare remote already exists — skipping"
fi

cd "${APP_DIR}"
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  git init -b main
  git add .
  git commit -m "Initial Flask app for Jenkins CI/CD"
  git remote add origin "${REMOTE_DIR}"
  git push -u origin main
  ok "Initialised app repo and pushed to remote"
else
  ok "App repo already initialised — skipping"
fi
cd "${WORKSPACE_ROOT}"

# --------------------------------------------------------------------------- #
# 3. Build custom Jenkins image
# --------------------------------------------------------------------------- #
log "Building Jenkins Docker image (${JENKINS_IMAGE})..."
docker build \
  --build-arg JENKINS_VERSION=2.452.3-lts-jdk17 \
  -t "${JENKINS_IMAGE}" \
  "${WORKSPACE_ROOT}/jenkins"
ok "Jenkins image built"

# --------------------------------------------------------------------------- #
# 4. Start Jenkins container (idempotent)
# --------------------------------------------------------------------------- #
log "Starting Jenkins container..."
docker rm -f "${JENKINS_CONTAINER}" 2>/dev/null || true
docker volume create jenkins_home >/dev/null

docker run -d \
  --name "${JENKINS_CONTAINER}" \
  --restart unless-stopped \
  -p "${JENKINS_PORT}:8080" \
  -p 50000:50000 \
  -e JENKINS_ADMIN_USER="${JENKINS_USER}" \
  -e JENKINS_ADMIN_PASSWORD="${JENKINS_PASS}" \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker \
  -v "${WORKSPACE_ROOT}:/workspace" \
  "${JENKINS_IMAGE}"

ok "Jenkins container started on port ${JENKINS_PORT}"

# --------------------------------------------------------------------------- #
# 5. Wait for Jenkins to be ready
# --------------------------------------------------------------------------- #
log "Waiting for Jenkins to become ready (up to 120 s)..."
for i in $(seq 1 24); do
  if curl -s "http://localhost:${JENKINS_PORT}/login" | grep -q "Jenkins"; then
    ok "Jenkins is ready (attempt ${i})"
    break
  fi
  if [ "${i}" -eq 24 ]; then
    fail "Jenkins did not start within 120 s — check: docker logs ${JENKINS_CONTAINER}"
  fi
  echo "  ... waiting (${i}/24)"
  sleep 5
done

# Helper: fetch Jenkins crumb (CSRF token) for API calls
get_crumb() {
  curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "http://localhost:${JENKINS_PORT}/crumbIssuer/api/json" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])"
}

# --------------------------------------------------------------------------- #
# 6. Create the pipeline job via Jenkins API
# --------------------------------------------------------------------------- #
log "Creating Jenkins pipeline job..."

# Build job-final.xml by injecting pipeline.groovy into the CDATA placeholder.
# Using Python avoids the shell quoting/escaping pitfalls that sed would cause
# when the Groovy script contains backslashes, special chars, or long lines.
# Pass WORKSPACE_ROOT into Python via an env var so the heredoc is portable
WORKSPACE_ROOT="${WORKSPACE_ROOT}" python3 - <<'PYEOF'
import os, pathlib

workspace = pathlib.Path(os.environ['WORKSPACE_ROOT'])
script   = (workspace / 'pipeline.groovy').read_text()
template = (workspace / 'job.xml').read_text()

# CDATA sections cannot contain ']]>' — escape it if present in the script
script_safe = script.replace(']]>', ']] >')
result = template.replace('PIPELINE_SCRIPT_PLACEHOLDER', script_safe)

(workspace / 'job-final.xml').write_text(result)
print("job-final.xml generated successfully")
PYEOF

CRUMB=$(get_crumb)

# Check if job already exists
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "http://localhost:${JENKINS_PORT}/job/flask-cicd/api/json")

if [ "${HTTP_CODE}" = "200" ]; then
  log "Job 'flask-cicd' already exists — updating config..."
  curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
    -H "${CRUMB}" \
    -H "Content-Type: application/xml" \
    -X POST "http://localhost:${JENKINS_PORT}/job/flask-cicd/config.xml" \
    --data-binary "@${WORKSPACE_ROOT}/job-final.xml" >/dev/null
else
  curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
    -H "${CRUMB}" \
    -H "Content-Type: application/xml" \
    -X POST "http://localhost:${JENKINS_PORT}/createItem?name=flask-cicd" \
    --data-binary "@${WORKSPACE_ROOT}/job-final.xml" >/dev/null
fi
ok "Pipeline job 'flask-cicd' created/updated"

# --------------------------------------------------------------------------- #
# 7. Trigger first build
# --------------------------------------------------------------------------- #
log "Triggering first build..."
CRUMB=$(get_crumb)
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  -H "${CRUMB}" \
  -X POST "http://localhost:${JENKINS_PORT}/job/flask-cicd/build" >/dev/null
ok "Build triggered"

# Wait for build #1 to start and stream the log
log "Waiting for build #1 to start..."
for i in $(seq 1 12); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "http://localhost:${JENKINS_PORT}/job/flask-cicd/1/api/json")
  [ "${CODE}" = "200" ] && break
  sleep 5
done

log "Streaming build log (Ctrl+C to stop following)..."
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "http://localhost:${JENKINS_PORT}/job/flask-cicd/1/consoleText" || true
echo ""

# --------------------------------------------------------------------------- #
# 8. Verify app endpoint
# --------------------------------------------------------------------------- #
log "Verifying app endpoint..."
for i in $(seq 1 10); do
  RESP=$(curl -s "http://localhost:${APP_PORT}/health" 2>/dev/null || true)
  if echo "${RESP}" | grep -q '"ok"'; then
    ok "App is healthy: ${RESP}"
    break
  fi
  if [ "${i}" -eq 10 ]; then
    echo "App not responding yet. Check build log above for errors."
  fi
  sleep 5
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo "============================================================"
echo " Project 01 — CI/CD Pipeline is running"
echo "============================================================"
echo "  Jenkins UI  : http://localhost:${JENKINS_PORT}"
echo "  Login       : ${JENKINS_USER} / ${JENKINS_PASS}"
echo "  App endpoint: http://localhost:${APP_PORT}/health"
echo ""
echo "  To trigger another build after a code change:"
echo "    cd app && git add . && git commit -m 'my change' && git push origin main"
echo "    # Jenkins polls every 2 min and will pick up the change automatically"
echo "============================================================"
