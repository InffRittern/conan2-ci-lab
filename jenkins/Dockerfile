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

# Toolchain and Conan used by the sandbox pipeline. Kept in the image so a
# container recreation does not drop the CI dependencies.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o Acquire::ForceIPv4=true \
        ca-certificates cmake gcc-13 g++-13 ninja-build python3 python3-pip python3-venv; \
    rm -rf /var/lib/apt/lists/*; \
    python3 -m venv /opt/conan-venv; \
    /opt/conan-venv/bin/pip install --no-cache-dir 'conan==2.33.0'; \
    /opt/conan-venv/bin/conan --version

ENV PATH="/opt/conan-venv/bin:${PATH}"

USER jenkins
