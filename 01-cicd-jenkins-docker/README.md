# Project 01: Production CI/CD Pipeline with Jenkins + Docker

## 1. Project Title
Zero-Downtime CI/CD Pipeline for a Containerized Flask API using Jenkins Declarative Pipeline and Docker

---

## 2. Problem Statement
A growing SaaS company ships bug fixes slowly because builds, tests, and deployments are manual and inconsistent across engineers. Releases frequently fail due to environment drift and missing test gates. The business needs an automated CI/CD pipeline that validates every change, builds immutable Docker images, and deploys safely with rollback capability.

---

## 3. Tech Stack

| Layer | Tool | Version |
|---|---|---|
| Infra | Local machine (Linux / macOS / WSL2) | — |
| CI Server | Jenkins LTS (Dockerized) | 2.452.3 |
| Container Runtime | Docker Engine | 26.1.4 |
| App Language | Python | 3.12 |
| App Framework | Flask | 3.0.3 |
| App Server | Gunicorn | 22.0.0 |
| Test Framework | pytest | 8.2.2 |
| Source Control | Git | 2.43+ |
| OS Tools | curl, jq | 8.x, 1.7 |

---

## 4. Architecture Diagram

```text
  DEVELOPER WORKSTATION
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  $ git commit -m "fix: update endpoint"                                      │
  │  $ git push origin main                                                      │
  └──────────────────────────────────────┬───────────────────────────────────────┘
                                         │ git push (SSH or HTTPS)
                                         ▼
  GIT REMOTE  (bare repo / GitHub / GitLab)
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  remote.git   branch: main                                                   │
  │  (local bare repo in this lab — replace with GitHub in production)           │
  └──────────────────────────────────────┬───────────────────────────────────────┘
                                         │ SCM poll every 2 min  (or webhook)
                                         ▼
  LOCAL MACHINE  (Linux / macOS / WSL2)
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │   JENKINS CONTAINER  (custom-jenkins:2.452.3)                                │
  │   ┌──────────────────────────────────────────────────────────────────────┐  │
  │   │  Port 8080 (UI/API)   Port 50000 (agent JNLP)                        │  │
  │   │  Volume: jenkins_home (/var/jenkins_home)                             │  │
  │   │  Volume bind: /workspace  ←→  project root on host                   │  │
  │   │  Docker socket: /var/run/docker.sock  (runs Docker commands on host) │  │
  │   │                                                                       │  │
  │   │  DECLARATIVE PIPELINE  (pipeline.groovy)                              │  │
  │   │  ┌─────────────────────────────────────────────────────────────────┐ │  │
  │   │  │                                                                  │ │  │
  │   │  │  Stage 1 ── CHECKOUT                                            │ │  │
  │   │  │             GitSCM → /workspace/app  (file:///workspace/remote.git)│ │  │
  │   │  │                                                                  │ │  │
  │   │  │  Stage 2 ── TEST                                                 │ │  │
  │   │  │             docker run --rm python:3.12-slim                     │ │  │
  │   │  │             pip install + pytest → test-results.xml (JUnit)      │ │  │
  │   │  │             ✗ FAIL → pipeline stops, no image built              │ │  │
  │   │  │                                                                  │ │  │
  │   │  │  Stage 3 ── BUILD IMAGE                                          │ │  │
  │   │  │             docker build --target runtime                        │ │  │
  │   │  │             flask-devops-app:BUILD_NUMBER                        │ │  │
  │   │  │             flask-devops-app:latest                              │ │  │
  │   │  │                                                                  │ │  │
  │   │  │  Stage 4 ── DEPLOY                                               │ │  │
  │   │  │             docker rm -f flask-devops-app (old container)        │ │  │
  │   │  │             docker run -d -p 5000:5000 flask-devops-app:N        │ │  │
  │   │  │                                                                  │ │  │
  │   │  │  Stage 5 ── SMOKE TEST                                           │ │  │
  │   │  │             docker inspect → get container IP                    │ │  │
  │   │  │             curl http://<IP>:5000/health  (retry loop 30 s)      │ │  │
  │   │  │             ✗ FAIL → logs dumped, build marked failed            │ │  │
  │   │  │                                                                  │ │  │
  │   │  │  Post ───── SUCCESS: log message + prune dangling images         │ │  │
  │   │  │             FAILURE: docker logs flask-devops-app                │ │  │
  │   │  └─────────────────────────────────────────────────────────────────┘ │  │
  │   └──────────────────────────────────────────────────────────────────────┘  │
  │                                          │                                   │
  │                                          │ docker run -p 5000:5000           │
  │                                          ▼                                   │
  │   APP CONTAINER  (flask-devops-app:BUILD_NUMBER)                             │
  │   ┌──────────────────────────────────────────────────────────────────────┐  │
  │   │  Runtime image: python:3.12-slim  (non-root user: appuser)           │  │
  │   │  Gunicorn 22.0.0 · 2 workers · port 5000                             │  │
  │   │  GET /          → {"message": "CI/CD with Jenkins + Docker"}         │  │
  │   │  GET /health    → {"status": "ok", "version": "1.0.0"}               │  │
  │   │  HEALTHCHECK every 15 s (python urllib)                              │  │
  │   └──────────────────────────────────────────────────────────────────────┘  │
  │                                                                              │
  └──────────────────────────────────────────────────────────────────────────────┘
                                         │
                                         │ curl http://localhost:5000/health
                                         ▼
                               END USER / MONITORING

  ─────────────────────────────────────────────────────────────────────────────
  DATA FLOW SUMMARY
  ─────────────────────────────────────────────────────────────────────────────
  1. Developer pushes code  →  Git remote (main branch)
  2. Jenkins polls SCM every 2 min  →  detects new commit
  3. Stage: Checkout  →  clones latest code into /workspace/app
  4. Stage: Test  →  spins ephemeral Python container, runs pytest
     If tests fail  →  pipeline aborts, no image produced
  5. Stage: Build  →  creates immutable image tagged with build number
  6. Stage: Deploy  →  atomically replaces running container
  7. Stage: Smoke Test  →  validates /health returns 200
     If smoke fails  →  dumps logs, marks build failed (manual rollback needed)
  8. Post-success  →  prunes dangling images, logs success
  ─────────────────────────────────────────────────────────────────────────────
```

---

## 5. Step-by-Step Execution Guide

> **Fastest path:** run `./setup.sh` from the project root — it executes every step below automatically.
> Follow the manual steps if you want to understand each command as you run it.

### Step 0: Create project workspace
```bash
mkdir -p ~/devops-series/01-cicd-jenkins-docker && cd ~/devops-series/01-cicd-jenkins-docker
mkdir -p app jenkins
```
Expected output:
```text
(no output — directories created silently)
```

---

### Step 1: Create Flask application

Create `app/app.py`:
```python
import os
import logging
from flask import Flask, jsonify

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")

@app.get("/health")
def health():
    logger.info("health check requested")
    return jsonify({"status": "ok", "version": APP_VERSION}), 200

@app.get("/")
def home():
    logger.info("home endpoint requested")
    return jsonify({"message": "CI/CD with Jenkins + Docker", "version": APP_VERSION}), 200
```

Create `app/requirements.txt`:
```text
Flask==3.0.3
gunicorn==22.0.0
pytest==8.2.2
```

Create `app/test_app.py`:
```python
import pytest
from app import app

@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c

def test_health_returns_200(client):
    assert client.get("/health").status_code == 200

def test_health_payload(client):
    data = client.get("/health").get_json()
    assert data["status"] == "ok"
    assert "version" in data

def test_home_returns_200(client):
    assert client.get("/").status_code == 200

def test_home_payload(client):
    data = client.get("/").get_json()
    assert "CI/CD" in data["message"]
```

Create `app/Dockerfile`:
```dockerfile
# Stage 1 — run tests (CI validation gate)
FROM python:3.12-slim AS test
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN pytest -q

# Stage 2 — production runtime (lean image, no test deps)
FROM python:3.12-slim AS runtime
RUN useradd --no-create-home --shell /bin/false appuser
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir Flask==3.0.3 gunicorn==22.0.0
COPY --chown=appuser:appuser . .
USER appuser
EXPOSE 5000
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" || exit 1
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:5000", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
```

---

### Step 2: Initialize Git repository and local remote
```bash
cd ~/devops-series/01-cicd-jenkins-docker/app
git init -b main
git add .
git commit -m "Initial Flask app for Jenkins CI/CD"
cd ..
git init --bare remote.git
cd app
git remote add origin ../remote.git
git push -u origin main
```
Expected output:
```text
Initialized empty Git repository in .../remote.git/
[main (root-commit) a1b2c3d] Initial Flask app for Jenkins CI/CD
...
branch 'main' set up to track 'origin/main'.
```

---

### Step 3: Build custom Jenkins image with required plugins

Create `jenkins/plugins.txt`:
```text
workflow-aggregator:596.v8c21c963d92d
git:5.2.1
docker-workflow:572.v950f58993843
credentials-binding:642.v737c34dea_6c2
blueocean:1.27.10
junit:1265.v65b_14fa_f12b_0
```

Create `jenkins/security.groovy`:
```groovy
import jenkins.model.*
import hudson.security.*
import hudson.security.csrf.DefaultCrumbIssuer

def instance = Jenkins.getInstance()

// Read credentials from environment — never hardcode in source control
def adminUser = System.getenv("JENKINS_ADMIN_USER") ?: "admin"
def adminPass = System.getenv("JENKINS_ADMIN_PASSWORD") ?: "ChangeMe123!"

def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount(adminUser, adminPass)
instance.setSecurityRealm(hudsonRealm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// Enable CSRF protection
instance.setCrumbIssuer(new DefaultCrumbIssuer(true))
instance.save()
println("Jenkins security initialized — user: ${adminUser}")
```

Create `jenkins/Dockerfile`:
```dockerfile
ARG JENKINS_VERSION=2.452.3-lts-jdk17
FROM jenkins/jenkins:${JENKINS_VERSION}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git docker.io \
    && rm -rf /var/lib/apt/lists/*
RUN usermod -aG docker jenkins

USER jenkins
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
COPY security.groovy /usr/share/jenkins/ref/init.groovy.d/security.groovy
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
```

Build and run Jenkins:
```bash
cd ~/devops-series/01-cicd-jenkins-docker/jenkins
docker build -t custom-jenkins:2.452.3 .
docker volume create jenkins_home
docker run -d --name jenkins \
  --restart unless-stopped \
  -p 8080:8080 -p 50000:50000 \
  -e JENKINS_ADMIN_USER=admin \
  -e JENKINS_ADMIN_PASSWORD=ChangeMe123! \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker \
  -v ~/devops-series/01-cicd-jenkins-docker:/workspace \
  custom-jenkins:2.452.3
```

Wait for Jenkins to be ready:
```bash
until curl -s http://localhost:8080/login | grep -q "Jenkins"; do
  echo "waiting for jenkins..."; sleep 5
done
echo "Jenkins is ready"
```
Expected output:
```text
waiting for jenkins...
waiting for jenkins...
Jenkins is ready
```

---

### Step 4: Create Jenkins pipeline job via API

Create `pipeline.groovy` (see `pipeline.groovy` in project root — already provided).

Create `job.xml` (see `job.xml` in project root — already provided).

Generate `job-final.xml` and create the job:
```bash
cd ~/devops-series/01-cicd-jenkins-docker

# Generate job-final.xml by injecting pipeline.groovy into the XML template
WORKSPACE_ROOT="$PWD" python3 - <<'PYEOF'
import os, pathlib
workspace = pathlib.Path(os.environ['WORKSPACE_ROOT'])
script    = (workspace / 'pipeline.groovy').read_text()
template  = (workspace / 'job.xml').read_text()
result    = template.replace('PIPELINE_SCRIPT_PLACEHOLDER', script.replace(']]>', ']] >'))
(workspace / 'job-final.xml').write_text(result)
print("job-final.xml generated")
PYEOF

# Fetch CSRF crumb (required because CSRF protection is enabled)
CRUMB=$(curl -s -u admin:ChangeMe123! \
  http://localhost:8080/crumbIssuer/api/json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])")

# Create the pipeline job
curl -s -u admin:ChangeMe123! \
  -H "$CRUMB" \
  -H "Content-Type: application/xml" \
  -X POST "http://localhost:8080/createItem?name=flask-cicd" \
  --data-binary @job-final.xml
```
Expected output:
```text
job-final.xml generated
(empty body with HTTP 200 = success)
```

---

### Step 5: Trigger build and verify deployment
```bash
# Fetch crumb then trigger build
CRUMB=$(curl -s -u admin:ChangeMe123! \
  http://localhost:8080/crumbIssuer/api/json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])")

curl -s -u admin:ChangeMe123! -H "$CRUMB" \
  -X POST http://localhost:8080/job/flask-cicd/build

# Wait ~30 s then check console output
sleep 30
curl -s -u admin:ChangeMe123! \
  "http://localhost:8080/job/flask-cicd/lastBuild/consoleText" | tail -n 25

# Verify the app is live
curl -s http://localhost:5000/health
```
Expected output:
```text
[Pipeline] echo
Pipeline #1 completed successfully. Image: flask-devops-app:1
{"status":"ok","version":"1.0.0"}
```

---

### Step 6: Simulate a code change and watch auto-redeploy
```bash
cd ~/devops-series/01-cicd-jenkins-docker/app
sed -i 's/CI\/CD with Jenkins + Docker/CI\/CD with Jenkins + Docker v2/' app.py
git add app.py
git commit -m "Update homepage message to v2"
git push origin main

# Jenkins polls SCM every 2 min — wait for auto-trigger
echo "Waiting for Jenkins to detect the change (up to 2 min)..."
sleep 120

curl -s -u admin:ChangeMe123! \
  "http://localhost:8080/job/flask-cicd/lastBuild/consoleText" | tail -n 20
curl -s http://localhost:5000/
```
Expected output:
```text
[main a2b3c4d] Update homepage message to v2
...
{"message":"CI/CD with Jenkins + Docker v2","version":"1.0.0"}
```

---

## 6. Interview Questions Covered

1. **How does a Jenkins declarative pipeline differ from a scripted pipeline, and when would you choose each?**
2. **How do you make Jenkins builds reproducible and avoid "works on my machine" failures?**
3. **Why should CI pipelines run tests before building or pushing Docker images?**
4. **How do you secure Jenkins credentials and avoid secret leakage in console logs?**
5. **What strategies do you use for safe deployment and rollback with containers?**
6. **How would you scale Jenkins with distributed agents for parallel builds?**

---

## 7. Video Transcript

> The full recording script for this tutorial is in `TRANSCRIPT.md`.
> That file is excluded from student distribution (see `.gitignore`).

---

## 8. Resume Bullet Point

> Implemented a production-style Jenkins CI/CD pipeline for a Dockerized Python API, automating test / build / deploy / smoke-test stages and reducing manual release effort by over 80% while improving deployment consistency through immutable image tagging and CSRF-protected API automation.
