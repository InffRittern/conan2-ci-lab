# Jenkins + Docker CLI.
# CLI нужен, чтобы из CI-джобов обращаться к sidecar-демону docker:dind
# (в образе jenkins/jenkins docker CLI отсутствует).
# Никаких артефактов хоста: только скачивание статического бинарника.
FROM jenkins/jenkins:2.580.1-lts-jdk21

ARG DOCKER_CLI_VERSION=29.8.2

USER root

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) cli_arch=x86_64 ;; \
        arm64) cli_arch=aarch64 ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${cli_arch}/docker-${DOCKER_CLI_VERSION}.tgz" \
        | tar -xz --strip-components=1 -C /usr/local/bin docker/docker; \
    docker --version

USER jenkins
