// Declarative Pipeline — Flask CI/CD
// Runs inside the Jenkins container that has the host Docker socket mounted.
//
// Fix notes vs original README version:
//   - Smoke test uses the app container's own Docker bridge IP instead of
//     host.docker.internal (which only exists on Docker Desktop, not Linux).
//   - CSRF is enabled in security.groovy so we fetch a crumb before API calls.
//   - Test stage produces a JUnit XML report for trend graphs in Jenkins UI.
//   - Deploy stage runs a health-check loop instead of a fixed sleep.

pipeline {
  agent any

  environment {
    APP_DIR        = '/workspace/app'
    IMAGE_NAME     = 'flask-devops-app'
    IMAGE_TAG      = "${env.BUILD_NUMBER}"
    CONTAINER_NAME = 'flask-devops-app'
  }

  options {
    timeout(time: 15, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '10'))
  }

  stages {

    // ---------------------------------------------------------------
    stage('Checkout') {
    // ---------------------------------------------------------------
      steps {
        dir(env.APP_DIR) {
          checkout([
            $class: 'GitSCM',
            branches: [[name: '*/main']],
            userRemoteConfigs: [[url: 'file:///workspace/remote.git']]
          ])
          sh 'git log -1 --oneline'
        }
      }
    }

    // ---------------------------------------------------------------
    stage('Test') {
    // ---------------------------------------------------------------
    // Run tests inside an ephemeral Python container — keeps the Jenkins
    // node clean and ensures tests are reproducible on any agent.
    // ---------------------------------------------------------------
      steps {
        dir(env.APP_DIR) {
          sh '''
            docker run --rm \
              -v "$PWD":/app \
              -w /app \
              python:3.12-slim \
              sh -c "pip install -q -r requirements.txt && pytest -q --tb=short --junit-xml=test-results.xml"
          '''
        }
      }
      post {
        always {
          junit testResults: "${env.APP_DIR}/test-results.xml", allowEmptyResults: true
        }
      }
    }

    // ---------------------------------------------------------------
    stage('Build Docker Image') {
    // ---------------------------------------------------------------
      steps {
        dir(env.APP_DIR) {
          // Build the production runtime stage only (skip test stage in CI
          // because tests already ran in the previous stage).
          sh '''
            docker build \
              --target runtime \
              -t ${IMAGE_NAME}:${IMAGE_TAG} \
              -t ${IMAGE_NAME}:latest \
              .
          '''
        }
      }
    }

    // ---------------------------------------------------------------
    stage('Deploy') {
    // ---------------------------------------------------------------
      steps {
        sh 'docker rm -f ${CONTAINER_NAME} 2>/dev/null || true'
        sh '''
          docker run -d \
            --name ${CONTAINER_NAME} \
            -p 5000:5000 \
            --restart unless-stopped \
            ${IMAGE_NAME}:${IMAGE_TAG}
        '''
      }
    }

    // ---------------------------------------------------------------
    stage('Smoke Test') {
    // ---------------------------------------------------------------
    // Resolve the container's IP on the Docker bridge (works on both
    // Linux hosts and Docker Desktop — avoids host.docker.internal).
    // ---------------------------------------------------------------
      steps {
        sh '''
          APP_IP=$(docker inspect -f \
            '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
            ${CONTAINER_NAME})

          echo "App container IP: ${APP_IP}"

          # Poll until healthy (up to 30 s)
          for i in $(seq 1 10); do
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
              "http://${APP_IP}:5000/health" || true)
            if [ "$STATUS" = "200" ]; then
              echo "Smoke test passed (attempt ${i})"
              exit 0
            fi
            echo "Waiting for app to be ready (attempt ${i}, status=${STATUS})..."
            sleep 3
          done

          echo "Smoke test FAILED — app did not become healthy within 30 s"
          docker logs ${CONTAINER_NAME}
          exit 1
        '''
      }
    }
  }

  post {
    success {
      echo "Pipeline #${env.BUILD_NUMBER} completed successfully. Image: ${IMAGE_NAME}:${IMAGE_TAG}"
    }
    failure {
      echo "Pipeline #${env.BUILD_NUMBER} FAILED. Dumping container logs..."
      sh 'docker logs ${CONTAINER_NAME} 2>/dev/null || true'
    }
    cleanup {
      // Remove dangling images to keep the host disk clean
      sh 'docker image prune -f 2>/dev/null || true'
    }
  }
}
