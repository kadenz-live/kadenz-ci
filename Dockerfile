# syntax=docker/dockerfile:1.9
#
# kadenz-ci — custom self-hosted GitHub Actions runner image for the Kadenz CI pool.
#
# This image bakes the full toolchain the kadenz-live/kadenz workflows assume
# pre-installed on a runner labelled `kadenz-ci`
# (`runs-on: [self-hosted, Linux, X64, kadenz-ci]`). It replaces the generic
# `myoung34/github-runner:latest` image used by the Synology runners, which
# lacks gitleaks, the Playwright system libs, the native-gem build chain, etc.
#
# Source-of-truth for the pinned versions below is the Kadenz monorepo's
# Ansible roles, which provision the bastion runners identically:
#   infra/ansible/roles/github_runner/defaults/main.yml   (runner binary + SHA)
#   infra/ansible/roles/runner_toolchain/defaults/main.yml (apt pkgs, hcloud)
#   infra/ansible/roles/runner_gitleaks/defaults/main.yml  (gitleaks + SHA)
# Keep this image and those roles in lock-step so a `kadenz-ci` job behaves
# identically whether it lands on the bastion or a Synology runner.
#
# Target platform: linux/amd64 only (bastion + Synology are x86_64).

# Ubuntu 24.04 (noble) base — matches the bastion runner's host OS, so the
# Playwright `nativeDeps` package names (the `t64` time64 ABI variants) and
# the `libvips42` package resolve identically. Pinned by digest, not by the
# floating `:24.04` tag, so a base-image refresh is an explicit, reviewable
# bump rather than a silent drift.
#
# Manifest-list digest for ubuntu:24.04, resolved 2026-06-30 (buildx selects
# the linux/amd64 child automatically). Re-pin on a deliberate base bump:
# `docker buildx imagetools inspect ubuntu:24.04`.
FROM ubuntu:24.04@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54

# --- Build-time pins -------------------------------------------------------
# Mirror infra/ansible/roles/*/defaults/main.yml. Bump version + checksum
# together (see README "Bumping a tool version"). Each download is SHA-256
# verified before it is trusted.
ARG RUNNER_VERSION=2.335.1
ARG RUNNER_SHA256=4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf

ARG GITLEAKS_VERSION=8.21.2
ARG GITLEAKS_SHA256=5bc41815076e6ed6ef8fbecc9d9b75bcae31f39029ceb55da08086315316e3ba

ARG HCLOUD_VERSION=1.66.0
ARG HCLOUD_SHA256=8b1a8598858232c491f58cbf65ce1bd0ec6f725114bb62ec967a20ab03e29a86

# Non-root runner user, per actions-runner convention. UID/GID 1001 keeps it
# clear of the base image's default `ubuntu` user (UID 1000).
ARG RUNNER_USER=runner
ARG RUNNER_UID=1001
ARG RUNNER_GID=1001

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_HOME=/home/runner \
    # ruby/setup-ruby + actions/setup-node populate this tree on a self-hosted
    # runner; pre-create with runner ownership so the actions don't try to
    # chown a root-owned path and fail (mirrors runner_toolchain role).
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# --- Base apt layer --------------------------------------------------------
# Grouped by purpose so the next maintainer can tell why each package is here.
# A single RUN keeps the layer count low and the apt cache out of the image.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      # --- runner + generic CI plumbing ---
      ca-certificates \
      curl \
      wget \
      git \
      jq \
      unzip \
      gnupg \
      lsb-release \
      tar \
      xz-utils \
      sudo \
      # --- JS-based composite actions (setup-terraform wrapper, setup-tflint,
      #     actions/cache, upload-artifact) shell out to a system node + unzip ---
      nodejs \
      # --- native-gem build chain. Ruby itself is provided per-job by
      #     ruby/setup-ruby; these are the headers/libs its native gems
      #     (pg, psych/libyaml, ffi, nokogiri, bcrypt, ...) compile against ---
      build-essential \
      pkg-config \
      libpq-dev \
      libyaml-dev \
      libffi-dev \
      libssl-dev \
      zlib1g-dev \
      libreadline-dev \
      libgmp-dev \
      libxml2-dev \
      libxslt1-dev \
      # --- Rails ActiveStorage / image_processing -> libvips backend
      #     (web/api Gemfile pins ruby-vips) ---
      libvips42 \
      # --- Playwright chromium system deps (Ubuntu 24.04 noble, time64 ABI).
      #     Source: microsoft/playwright nativeDeps.ts ubuntu24.04-x64-chromium.
      #     Bump when the playwright npm dep majors in web/frontend or e2e. ---
      libasound2t64 \
      libatk-bridge2.0-0t64 \
      libatk1.0-0t64 \
      libatspi2.0-0t64 \
      libcairo2 \
      libcups2t64 \
      libdbus-1-3 \
      libdrm2 \
      libgbm1 \
      libglib2.0-0t64 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libx11-6 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      # metric-compatible Arial/Times substitutes headless chromium expects;
      # without it Playwright screenshots + DOM measurements drift.
      fonts-liberation \
      # --- python for in-workflow pip installs (ansible-core, ansible-lint) ---
      python3 \
      python3-pip \
      python3-venv \
    ; \
    rm -rf /var/lib/apt/lists/*

# --- Docker CLI + buildx ---------------------------------------------------
# Jobs use service containers (postgres/redis in api.yml) and the release
# build-push-action talks to a Docker daemon. We install ONLY the client +
# buildx plugin — the daemon is provided by the host (the Synology compose
# bind-mounts /var/run/docker.sock; the bastion runs dockerd). Installed from
# the official Docker apt repo, pinned to the noble channel.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-buildx-plugin \
      docker-compose-plugin \
    ; \
    rm -rf /var/lib/apt/lists/*

# --- gh CLI (cli/cli upstream apt repo) ------------------------------------
# Used by the release deploy job (`gh workflow run`) and the Dependabot
# auto-merge cron (`gh pr list / merge`). Ubuntu's bundled `gh` lags upstream.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# --- gitleaks (SHA-256 pinned) ---------------------------------------------
# gitleaks.yml runs the binary directly (the action needs a paid licence in a
# private org). Pinned to match runner_gitleaks role defaults.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -o gitleaks.tar.gz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"; \
    echo "${GITLEAKS_SHA256}  gitleaks.tar.gz" | sha256sum -c -; \
    tar -xzf gitleaks.tar.gz gitleaks; \
    install -m 0755 gitleaks /usr/local/bin/gitleaks; \
    rm -f gitleaks gitleaks.tar.gz; \
    gitleaks version

# --- hcloud CLI (SHA-256 pinned) -------------------------------------------
# ansible.yml's "Discover server IPs from Hetzner" step shells out to hcloud.
# Pinned to match runner_toolchain role defaults.
RUN set -eux; \
    cd /tmp; \
    curl -fsSL -o hcloud.tar.gz \
      "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz"; \
    echo "${HCLOUD_SHA256}  hcloud.tar.gz" | sha256sum -c -; \
    tar -xzf hcloud.tar.gz hcloud; \
    install -m 0755 hcloud /usr/local/bin/hcloud; \
    rm -f hcloud hcloud.tar.gz; \
    hcloud version

# --- Non-root runner user --------------------------------------------------
RUN set -eux; \
    groupadd -g "${RUNNER_GID}" "${RUNNER_USER}"; \
    useradd -m -u "${RUNNER_UID}" -g "${RUNNER_GID}" -s /bin/bash "${RUNNER_USER}"; \
    # hosted-toolcache owned by the runner user so setup-ruby/setup-node can
    # write into it without a chown that would fail on a root-owned tree.
    mkdir -p "${AGENT_TOOLSDIRECTORY}"; \
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${AGENT_TOOLSDIRECTORY}"

# --- actions/runner binary (SHA-256 pinned) --------------------------------
# Pinned to match github_runner role defaults so bastion + Synology run the
# identical runner version.
RUN set -eux; \
    mkdir -p "${RUNNER_HOME}/actions-runner"; \
    cd "${RUNNER_HOME}/actions-runner"; \
    curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c -; \
    tar -xzf runner.tar.gz; \
    rm -f runner.tar.gz; \
    # installdependencies.sh apt-installs the runner's own .NET deps. We run
    # it here (still root) so the runner user never needs sudo at job time.
    ./bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}"

# --- Entrypoint ------------------------------------------------------------
# config.sh / run.sh registration + start is handled by this script. It is a
# thin wrapper so the Synology compose can pass RUNNER_TOKEN / RUNNER_URL /
# RUNNER_NAME / RUNNER_LABELS as env, mirroring the myoung34 interface this
# image replaces.
COPY --chown=${RUNNER_USER}:${RUNNER_USER} entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER ${RUNNER_USER}
WORKDIR ${RUNNER_HOME}/actions-runner

# Graceful de-registration on container stop is handled inside entrypoint.sh
# via a SIGTERM/SIGINT trap.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
