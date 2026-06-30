#!/usr/bin/env bash
#
# Entrypoint for the ci self-hosted GitHub Actions runner image.
#
# Two-phase by design:
#
#   PHASE 1 (root) — runs only while the container is still root. Grants the
#   non-root `runner` user access to the bind-mounted host Docker socket by
#   creating a group matching the socket's host GID and adding `runner` to it,
#   then drops to `runner` via `gosu` and re-execs this same script. This is
#   the fix for the Synology runners failing RSpec with
#   `permission denied … /var/run/docker.sock`: the socket is bind-mounted
#   root:root 0660, its host GID is unknowable at image-build time, so the
#   grant must happen at container start once the mount exists.
#
#   PHASE 2 (runner) — registers the runner against a repository (repo-scoped,
#   never org-scoped), starts it, and de-registers gracefully on container
#   stop. The runner job process never runs as root.
#
# The env-var interface mirrors myoung34/github-runner closely enough that the
# Synology compose only has to swap the `image:` line — see README.md.
#
# Required env:
#   RUNNER_TOKEN   GitHub Actions registration token (single-use, 1h expiry).
#                  Obtain from the repo's Settings -> Actions -> Runners page,
#                  or mint via `gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token`.
#   RUNNER_URL     Repository URL to register against
#                  (default: https://github.com/kadenz-live/kadenz).
#
# Optional env:
#   RUNNER_NAME    Runner name shown in the GitHub UI (default: container host).
#   RUNNER_LABELS  Comma-separated labels (default: kadenz-ci).
#                  The runner always self-applies self-hosted,Linux,X64; these
#                  are the EXTRA labels — keep `kadenz-ci` so the workflows'
#                  `runs-on: [self-hosted, Linux, X64, kadenz-ci]` matches.
#   RUNNER_GROUP   Runner group (default: Default).
#   RUNNER_WORKDIR Work directory (default: _work).
#   EPHEMERAL      When "true", register with --ephemeral so the runner
#                  de-registers itself after a single job (recommended for a
#                  clean, single-use lifecycle). Default: false.

set -euo pipefail

# Name of the unprivileged runner user. Baked into the image as an ENV by the
# Dockerfile; default kept here so the script is runnable in isolation.
RUNNER_USER="${RUNNER_USER:-runner}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

# --- PHASE 1: root-only socket-GID grant, then drop to the runner user ------
# `id -u` == 0 means we are still in the brief root phase. After the gosu
# re-exec below we come back in as `runner` and skip straight to PHASE 2.
if [[ "$(id -u)" -eq 0 ]]; then
  if [[ -S "${DOCKER_SOCK}" ]]; then
    # Host GID that owns the bind-mounted socket. The runner must be a member
    # of a group with THIS gid to pass the kernel's group permission check on
    # the socket (mode 0660, group rw).
    SOCK_GID="$(stat -c '%g' "${DOCKER_SOCK}")"

    # Reuse an existing group with that GID if the base image already has one
    # (e.g. the gid collides with `users`); otherwise create a synthetic
    # `dockerhost` group. Either way we then add `runner` to whatever group
    # name carries that GID.
    if ! getent group "${SOCK_GID}" >/dev/null 2>&1; then
      groupadd -g "${SOCK_GID}" dockerhost
    fi
    SOCK_GROUP_NAME="$(getent group "${SOCK_GID}" | cut -d: -f1)"

    usermod -aG "${SOCK_GROUP_NAME}" "${RUNNER_USER}"
    echo "Granted '${RUNNER_USER}' access to ${DOCKER_SOCK} via group '${SOCK_GROUP_NAME}' (gid ${SOCK_GID})."
  else
    # No socket mounted — not fatal. Jobs that need Docker will fail loudly at
    # job time; jobs that don't (gitleaks, rubocop, …) run fine. This keeps the
    # image usable on a host that deliberately omits the socket mount.
    echo "WARNING: ${DOCKER_SOCK} is not present or not a socket — skipping the docker-group grant." >&2
  fi

  # Hand off to the unprivileged runner. `exec gosu` replaces this root process
  # with the runner-owned re-exec of THIS script, so:
  #   * the runner job process is never root (no RUNNER_ALLOW_RUNASROOT), and
  #   * docker's SIGTERM/SIGINT on `docker stop` reaches the runner phase, so
  #     the de-register trap below still fires.
  # `--` ends gosu's option parsing; "$0" "$@" re-runs this script as `runner`.
  exec gosu "${RUNNER_USER}" "$0" "$@"
fi

# --- PHASE 2: runner-user registration + run --------------------------------
RUNNER_URL="${RUNNER_URL:-https://github.com/kadenz-live/kadenz}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-kadenz-ci}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
EPHEMERAL="${EPHEMERAL:-false}"

if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  echo "::error::RUNNER_TOKEN is required (Actions registration token)." >&2
  exit 1
fi

# RUNNER_HOME is baked as an ENV by the Dockerfile (/home/runner). Prefer it
# over $HOME so we don't depend on gosu/libcontainer having reset $HOME to the
# target user's passwd home during the privilege drop.
cd "${RUNNER_HOME:-${HOME}}/actions-runner"

# --- graceful de-registration -------------------------------------------
# On SIGTERM/SIGINT (docker stop / compose down), remove this runner from the
# repo so it doesn't linger as an offline entry. Best-effort: a single-use
# token may already be spent, so failure here is non-fatal.
deregister() {
  echo "Caught stop signal — de-registering runner '${RUNNER_NAME}'..."
  ./config.sh remove --token "${RUNNER_TOKEN}" || \
    echo "De-registration failed (token may be spent); remove manually if it lingers."
  exit 0
}
trap deregister SIGINT SIGTERM

# --- (re)register --------------------------------------------------------
# --replace re-uses the name if a stale registration exists. --unattended
# avoids interactive prompts. --disableupdate keeps the runner version pinned
# to the baked binary (auto-update would defeat the point of a pinned image).
CONFIG_ARGS=(
  --url "${RUNNER_URL}"
  --token "${RUNNER_TOKEN}"
  --name "${RUNNER_NAME}"
  --labels "${RUNNER_LABELS}"
  --runnergroup "${RUNNER_GROUP}"
  --work "${RUNNER_WORKDIR}"
  --unattended
  --replace
  --disableupdate
)
if [[ "${EPHEMERAL}" == "true" ]]; then
  CONFIG_ARGS+=(--ephemeral)
fi

echo "Registering runner '${RUNNER_NAME}' (labels: ${RUNNER_LABELS}) against ${RUNNER_URL}"
./config.sh "${CONFIG_ARGS[@]}"

# run.sh in the background + `wait` so the trap can fire on signal.
./run.sh &
RUNNER_PID=$!
wait "${RUNNER_PID}"
