# Custom Jenkins image — pre-installs plugins and seeds the admin user.
# Build args allow overriding versions without editing the Dockerfile.
ARG JENKINS_VERSION=2.452.3-lts-jdk17
FROM jenkins/jenkins:${JENKINS_VERSION}

USER root

# Install git and the Docker CLI (socket is bind-mounted from the host at runtime).
# We intentionally do NOT install the Docker daemon — we use the host daemon.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git docker.io \
    && rm -rf /var/lib/apt/lists/*

# Allow the jenkins user to run docker commands via the host socket
RUN usermod -aG docker jenkins

USER jenkins

# Pre-install plugins declared in plugins.txt
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Seed admin account and CSRF config on first boot
COPY security.groovy /usr/share/jenkins/ref/init.groovy.d/security.groovy

# Skip the interactive setup wizard (config is fully automated)
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
