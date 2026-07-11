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
#                  Scrubbed from the environment before the runner starts so
#                  job processes never inherit it (kadenz#890 S-01).
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
#   ACCESS_TOKEN   Optional GitHub PAT (myoung34-compatible name) used ONLY to
#                  mint a fresh removal token at de-registration time.
#                  Registration tokens expire after ~1h, so a long-lived
#                  runner can never de-register with the token it registered
#                  with — providing a PAT makes graceful de-registration
#                  reliable (kadenz#890 S-03). Needs repo-admin permission
#                  (classic `repo` scope) per the GitHub REST docs for
#                  POST /repos/{owner}/{repo}/actions/runners/remove-token.
#                  Scrubbed from the environment like RUNNER_TOKEN.
#   RUNNER_GRACEFUL_STOP_TIMEOUT
#                  Seconds to wait for the runner listener to shut down before
#                  de-registering on container stop (default: 5). Keep this
#                  BELOW the container runtime's stop grace period, and raise
#                  both together (compose `stop_grace_period`) if you want
#                  in-flight jobs to have a chance to finish — the docker
#                  default grace is only 10s.
#   DOCKER_SOCK_SYNTHETIC_GID
#                  GID used for the synthetic `dockerhost` group when the
#                  bind-mounted docker socket is owned by gid 0 (default:
#                  2375). See the GID-0 note in PHASE 1 (kadenz#890 S-04).

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

    if [[ "${SOCK_GID}" -eq 0 ]]; then
      # GID-0 edge case (kadenz#890 S-04): the socket is owned by group root
      # (root:root 0660 — the Synology default). Adding `runner` to gid 0
      # would grant it group-level access to EVERY group-0-writable path in
      # the image, far beyond the socket. Instead, re-group the socket onto a
      # dedicated synthetic gid and grant membership in that group only.
      #
      # Note: chgrp on a bind-mounted socket changes the group on the host
      # inode as well (the host daemon re-creates the socket with its own
      # ownership on restart). If the mount is read-only or the chgrp fails
      # for any other reason, we fail CLOSED: no grant is made, and jobs that
      # need Docker fail loudly at job time instead of the runner user
      # silently joining group root.
      SYNTHETIC_GID="${DOCKER_SOCK_SYNTHETIC_GID:-2375}"
      echo "WARNING: ${DOCKER_SOCK} is owned by gid 0 (root). Re-grouping it to a dedicated group (gid ${SYNTHETIC_GID}) instead of adding '${RUNNER_USER}' to the root group." >&2
      if ! getent group "${SYNTHETIC_GID}" >/dev/null 2>&1; then
        groupadd -g "${SYNTHETIC_GID}" dockerhost
      fi
      SOCK_GROUP_NAME="$(getent group "${SYNTHETIC_GID}" | cut -d: -f1)"
      if chgrp "${SOCK_GROUP_NAME}" "${DOCKER_SOCK}"; then
        usermod -aG "${SOCK_GROUP_NAME}" "${RUNNER_USER}"
        echo "Granted '${RUNNER_USER}' access to ${DOCKER_SOCK} via group '${SOCK_GROUP_NAME}' (gid ${SYNTHETIC_GID})."
      else
        echo "WARNING: could not re-group ${DOCKER_SOCK} (read-only mount?). Skipping the docker grant entirely — '${RUNNER_USER}' will NOT be added to group root. Jobs that need Docker will fail at job time." >&2
      fi
    else
      # Reuse an existing group with that GID if the base image already has
      # one (e.g. the gid collides with `users`); otherwise create a synthetic
      # `dockerhost` group. Either way we then add `runner` to whatever group
      # name carries that GID.
      if ! getent group "${SOCK_GID}" >/dev/null 2>&1; then
        groupadd -g "${SOCK_GID}" dockerhost
      fi
      SOCK_GROUP_NAME="$(getent group "${SOCK_GID}" | cut -d: -f1)"

      usermod -aG "${SOCK_GROUP_NAME}" "${RUNNER_USER}"
      echo "Granted '${RUNNER_USER}' access to ${DOCKER_SOCK} via group '${SOCK_GROUP_NAME}' (gid ${SOCK_GID})."
    fi
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
RUNNER_GRACEFUL_STOP_TIMEOUT="${RUNNER_GRACEFUL_STOP_TIMEOUT:-5}"
[[ "${RUNNER_GRACEFUL_STOP_TIMEOUT}" =~ ^[0-9]+$ ]] || RUNNER_GRACEFUL_STOP_TIMEOUT=5

if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  echo "::error::RUNNER_TOKEN is required (Actions registration token)." >&2
  exit 1
fi

# --- token hygiene (kadenz#890 S-01) -----------------------------------------
# Copy the tokens into UNEXPORTED shell variables and remove the exported
# copies from the environment BEFORE config.sh / run.sh start. Exported env
# vars are inherited by the Runner.Listener process tree and therefore by
# every job step it executes; unexported shell variables are not. Within its
# ~1h validity window a registration token permits attaching an additional
# runner to the repository, so it must never be visible to job code.
_REG_TOKEN="${RUNNER_TOKEN}"
unset RUNNER_TOKEN
_ACCESS_TOKEN="${ACCESS_TOKEN:-}"
unset ACCESS_TOKEN

# RUNNER_HOME is baked as an ENV by the Dockerfile (/home/runner). Prefer it
# over $HOME so we don't depend on gosu/libcontainer having reset $HOME to the
# target user's passwd home during the privilege drop.
cd "${RUNNER_HOME:-${HOME}}/actions-runner"

# --- graceful stop + de-registration (kadenz#890 S-03) -----------------------
# Covers three paths:
#   * SIGTERM/SIGINT (docker stop / compose down) — signal trap, then
#   * ANY script exit, including run.sh crashing on its own — EXIT trap,
# with an idempotency guard so the two traps never de-register twice.
#
# Ordering inside cleanup matters: the runner listener is stopped FIRST (so
# `config.sh remove` cannot overlap a still-running job — see the S-02 note
# below), then de-registration runs, then PID 1 exits.
#
# Token freshness: registration tokens expire after ~1h, so for any
# non-ephemeral runner that has been up longer (the normal case under
# `restart: unless-stopped`) the original token can no longer authenticate
# the removal. If ACCESS_TOKEN (PAT) is provided we mint a FRESH removal
# token at trap time via
#   POST /repos/{owner}/{repo}/actions/runners/remove-token
# (1h validity, per GitHub REST docs). Without a PAT we fall back to the
# original registration token best-effort and document the limitation: past
# the first hour the removal will fail and the runner lingers as an offline
# entry until `--replace` (same RUNNER_NAME) or a manual removal cleans it up.
RUNNER_PID=""
CLEANUP_DONE="false"

# shellcheck disable=SC2329  # invoked indirectly (from cleanup, itself trap-invoked)
fetch_removal_token() {
  # Derive owner/repo from RUNNER_URL (https://github.com/<owner>/<repo>).
  local repo_path
  repo_path="${RUNNER_URL#https://github.com/}"
  repo_path="${repo_path%/}"
  curl -fsS -X POST \
    -H "Authorization: Bearer ${_ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${repo_path}/actions/runners/remove-token" \
    | jq -r '.token // empty'
}

# shellcheck disable=SC2329  # invoked via the EXIT trap and on_stop_signal
cleanup() {
  # Idempotency guard: reachable from both the signal trap and the EXIT trap.
  [[ "${CLEANUP_DONE}" == "true" ]] && return 0
  CLEANUP_DONE="true"

  # (1) Stop the listener first, bounded. run.sh only forwards signals when
  # RUNNER_MANUALLY_TRAP_SIG is set (see where run.sh is started below).
  if [[ -n "${RUNNER_PID}" ]] && kill -0 "${RUNNER_PID}" 2>/dev/null; then
    echo "Stopping runner listener (pid ${RUNNER_PID}, timeout ${RUNNER_GRACEFUL_STOP_TIMEOUT}s)..."
    kill -TERM "${RUNNER_PID}" 2>/dev/null || true
    local waited=0
    while kill -0 "${RUNNER_PID}" 2>/dev/null \
        && [[ "${waited}" -lt "${RUNNER_GRACEFUL_STOP_TIMEOUT}" ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "${RUNNER_PID}" 2>/dev/null; then
      echo "Runner listener still up after ${RUNNER_GRACEFUL_STOP_TIMEOUT}s — proceeding to de-register; it will be torn down with the container." >&2
    fi
  fi

  # (2) De-register with the freshest token available.
  local remove_token=""
  if [[ -n "${_ACCESS_TOKEN}" ]]; then
    echo "Minting a fresh removal token via the GitHub API..."
    remove_token="$(fetch_removal_token || true)"
    [[ -z "${remove_token}" ]] && \
      echo "Could not mint a removal token (PAT lacks repo-admin, or API unreachable) — falling back to the registration token." >&2
  fi
  if [[ -z "${remove_token}" ]]; then
    # Known limitation: registration tokens expire after ~1h. For a runner
    # that has been up longer, this call fails and the runner remains listed
    # offline until --replace or manual removal. Provide ACCESS_TOKEN to make
    # de-registration reliable, or use EPHEMERAL=true.
    remove_token="${_REG_TOKEN}"
  fi

  echo "De-registering runner '${RUNNER_NAME}'..."
  # S-02 (accepted residual): config.sh offers no stdin/env token input, so
  # the token appears in this process's argument vector for the duration of
  # the remove call, readable by same-UID processes in this PID namespace.
  # Exposure is bounded by stopping the listener BEFORE this call (no job
  # code runs concurrently) and by the token's 1h expiry.
  ./config.sh remove --token "${remove_token}" || \
    echo "De-registration failed (token expired or already removed); remove manually if it lingers." >&2
}

# shellcheck disable=SC2329  # invoked via the SIGINT/SIGTERM trap
on_stop_signal() {
  # Reset the signal traps so a repeated signal during cleanup cannot
  # re-enter the handler; the EXIT trap still runs but cleanup() is guarded.
  trap - SIGINT SIGTERM
  echo "Caught stop signal."
  cleanup
  exit 0
}
trap on_stop_signal SIGINT SIGTERM
trap cleanup EXIT

# --- (re)register --------------------------------------------------------
# --replace re-uses the name if a stale registration exists. --unattended
# avoids interactive prompts. --disableupdate keeps the runner version pinned
# to the baked binary (auto-update would defeat the point of a pinned image).
#
# S-02 (accepted residual): config.sh accepts the token only as a CLI
# argument (no stdin/env alternative upstream), so it is briefly visible in
# the process argument vector. Registration happens before any job runs, so
# no untrusted same-UID reader exists at this point; the environment scrub
# above (S-01) plus the token's 1h expiry bound the remaining exposure.
CONFIG_ARGS=(
  --url "${RUNNER_URL}"
  --token "${_REG_TOKEN}"
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

# run.sh in the background + `wait` so the traps can fire on signal.
# RUNNER_MANUALLY_TRAP_SIG makes run.sh run the listener in the background
# and forward SIGINT/SIGTERM to it (upstream actions/runner
# src/Misc/layoutroot/run.sh, runWithManualTrap: `trap 'kill -INT -$PID' INT
# TERM`) — without it, run.sh ignores our TERM in cleanup() and the listener
# would only die with the container teardown.
RUNNER_MANUALLY_TRAP_SIG=1 ./run.sh &
RUNNER_PID=$!

RUNNER_EXIT=0
wait "${RUNNER_PID}" || RUNNER_EXIT=$?

if [[ "${EPHEMERAL}" == "true" && "${RUNNER_EXIT}" -eq 0 ]]; then
  # An ephemeral runner de-registers itself after its single job — a remove
  # call would only produce a spurious failure message. Skip cleanup.
  CLEANUP_DONE="true"
fi

# Falling off the end (run.sh finished or crashed) still de-registers via the
# EXIT trap; the runner's own exit code is preserved as the container's.
exit "${RUNNER_EXIT}"
