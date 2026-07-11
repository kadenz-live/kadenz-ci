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
#   the fix for the Docker runners failing RSpec with
#   `permission denied … /var/run/docker.sock`: the socket is bind-mounted
#   root:root 0660, its host GID is unknowable at image-build time, so the
#   grant must happen at container start once the mount exists.
#
#   PHASE 2 (runner) — registers the runner against a repository OR an
#   organization (auto-detected from RUNNER_URL), starts it, and de-registers
#   gracefully on container stop. The runner job process never runs as root.
#
# The env-var interface mirrors myoung34/github-runner closely enough that the
# Docker runner's compose only has to swap the `image:` line — see README.md.
#
# Required env (one of these two combinations):
#   RUNNER_TOKEN               A pre-minted GitHub Actions registration token
#                              (single-use, ~1h validity). Legacy path — kept
#                              for backward compatibility with deployments
#                              that inject a token from `.env` at start time.
#   ACCESS_TOKEN               A GitHub PAT with scope matching RUNNER_URL:
#                              `admin:org` for org-scoped URLs, `repo` for
#                              repo-scoped URLs. When set, the entrypoint
#                              mints a fresh registration token at start
#                              (if RUNNER_TOKEN is empty), automatically
#                              retries once with a freshly-minted token if
#                              `config.sh` rejects the supplied one, and mints
#                              a fresh removal token at stop time — making
#                              container recreates fully hands-off past the
#                              1h registration-token expiry (kadenz#1256).
#                              Both tokens are scrubbed from the environment
#                              before any job code runs (kadenz#890 S-01).
#
#   RUNNER_URL                 Scope URL. Auto-detected:
#                              * `https://github.com/<owner>`         -> org-scoped
#                              * `https://github.com/<owner>/<repo>`  -> repo-scoped
#                              Default: https://github.com/kadenz-live/kadenz.
#                              Anything else fails loud at start.
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
#
# Test hook:
#   KADENZ_CI_ENTRYPOINT_SOURCE_ONLY   Internal. When set to "1" the script
#                                      defines the helper functions and then
#                                      returns without running PHASE 1 or 2 —
#                                      used by tests/smoke.sh to exercise the
#                                      pure URL-parsing / endpoint helpers.
#                                      Never set this in a running container.

set -euo pipefail

# Name of the unprivileged runner user. Baked into the image as an ENV by the
# Dockerfile; default kept here so the script is runnable in isolation.
RUNNER_USER="${RUNNER_USER:-runner}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

# ============================================================================
# Pure helpers (also exercised directly by tests/smoke.sh)
# ============================================================================

# parse_runner_scope <url>
#
# Parse RUNNER_URL into scope kind + owner (+ repo, for repo-scoped). Sets
# globals _SCOPE_KIND (`org` or `repo`), _SCOPE_OWNER, _SCOPE_REPO (empty
# string for org-scoped). Returns 0 on match, 1 on anything else — caller
# decides how to surface the failure so we can format the error message with
# the actual bad URL.
#
# Accepts a trailing slash. Owner/repo character class matches GitHub's own
# permitted set (alnum plus `.`, `_`, `-`).
parse_runner_scope() {
  local url="${1:-}"
  url="${url%/}"
  if [[ "${url}" =~ ^https://github\.com/([A-Za-z0-9._-]+)$ ]]; then
    _SCOPE_KIND="org"
    _SCOPE_OWNER="${BASH_REMATCH[1]}"
    _SCOPE_REPO=""
    return 0
  fi
  if [[ "${url}" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
    _SCOPE_KIND="repo"
    _SCOPE_OWNER="${BASH_REMATCH[1]}"
    _SCOPE_REPO="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# scope_endpoint <registration|remove>
#
# Print the correct GitHub REST endpoint URL for the current scope + the
# requested token operation. Requires parse_runner_scope to have been called
# first (reads _SCOPE_KIND / _SCOPE_OWNER / _SCOPE_REPO). Verified against
# docs.github.com/rest/actions/self-hosted-runners:
#
#   org-scoped   POST /orgs/{org}/actions/runners/(registration|remove)-token
#   repo-scoped  POST /repos/{owner}/{repo}/actions/runners/(registration|remove)-token
scope_endpoint() {
  local op="${1:?scope_endpoint: operation required}"
  case "${op}" in
    registration|remove) ;;
    *) echo "scope_endpoint: unknown op '${op}'" >&2; return 2 ;;
  esac
  case "${_SCOPE_KIND:-}" in
    org)
      printf 'https://api.github.com/orgs/%s/actions/runners/%s-token\n' \
        "${_SCOPE_OWNER}" "${op}"
      ;;
    repo)
      printf 'https://api.github.com/repos/%s/%s/actions/runners/%s-token\n' \
        "${_SCOPE_OWNER}" "${_SCOPE_REPO}" "${op}"
      ;;
    *)
      echo "scope_endpoint: scope not initialized (call parse_runner_scope first)" >&2
      return 2
      ;;
  esac
}

# mint_token <registration|remove>
#
# Mint a fresh registration OR removal token via the GitHub REST API. Reads
# _ACCESS_TOKEN from the caller's scope. Emits the token on stdout, empty
# string on failure. Never echoes the token itself to stderr. curl's -fsS
# makes 4xx/5xx return non-zero without dumping the response body to stdout,
# and jq's `.token // empty` swallows unexpected shapes.
#
# shellcheck disable=SC2329  # invoked directly and indirectly (from cleanup)
mint_token() {
  local op="${1:?mint_token: operation required}" endpoint
  endpoint="$(scope_endpoint "${op}")" || return 1
  curl -fsS -X POST \
    -H "Authorization: Bearer ${_ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${endpoint}" \
    | jq -r '.token // empty'
}

# ============================================================================
# Test-mode short-circuit
# ============================================================================
# Sourced by tests/smoke.sh so the harness can call the helpers above without
# executing PHASE 1 or PHASE 2. `return` works only when sourced; when the
# script is exec'd normally this variable is unset and the guard is a no-op.
if [[ "${KADENZ_CI_ENTRYPOINT_SOURCE_ONLY:-0}" == "1" ]]; then
  # `return` works when this file is sourced by tests/smoke.sh; if the guard
  # was ever hit in an exec'd container we still want to bail rather than
  # continue into PHASE 1.
  # shellcheck disable=SC2317  # unreachable ONLY when sourced; reachable when exec'd
  { return 0 2>/dev/null || exit 0; }
fi

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
      # (root:root 0660 — a common Docker-host default). Adding `runner` to gid 0
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

# --- scope detection --------------------------------------------------------
# Fail loud before we touch any tokens if RUNNER_URL is neither org nor repo.
# Points the operator at the docs rather than guessing what they meant.
if ! parse_runner_scope "${RUNNER_URL}"; then
  echo "::error::RUNNER_URL '${RUNNER_URL}' does not match either supported shape." >&2
  echo "::error::  org-scoped:  https://github.com/<owner>" >&2
  echo "::error::  repo-scoped: https://github.com/<owner>/<repo>" >&2
  echo "::error::See https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners" >&2
  exit 1
fi
# shellcheck disable=SC2016  # inner ${_SCOPE_REPO} inside :+ IS expanded by bash
echo "Detected runner scope: ${_SCOPE_KIND} (owner='${_SCOPE_OWNER}'${_SCOPE_REPO:+, repo='${_SCOPE_REPO}'})"

# --- token hygiene (kadenz#890 S-01) -----------------------------------------
# Copy the tokens into UNEXPORTED shell variables and remove the exported
# copies from the environment BEFORE config.sh / run.sh start. Exported env
# vars are inherited by the Runner.Listener process tree and therefore by
# every job step it executes; unexported shell variables are not. Within its
# ~1h validity window a registration token permits attaching an additional
# runner to the scope, so it must never be visible to job code.
_REG_TOKEN="${RUNNER_TOKEN:-}"
unset RUNNER_TOKEN
_ACCESS_TOKEN="${ACCESS_TOKEN:-}"
unset ACCESS_TOKEN

# --- registration-token acquisition (kadenz#1256) ---------------------------
# Three-way input handling:
#
#   1. RUNNER_TOKEN provided                    -> use it as-is (legacy path).
#   2. RUNNER_TOKEN empty + ACCESS_TOKEN set    -> auto-mint a fresh one via
#                                                  the scope-appropriate REST
#                                                  endpoint. This is the mode
#                                                  that makes container
#                                                  recreates hands-off past
#                                                  the 1h registration-token
#                                                  expiry (kadenz#1256).
#   3. Both empty                               -> fail loud at start.
#
# Case (2) is the whole point of this branch: a Docker runner running under
# `restart: unless-stopped` whose original RUNNER_TOKEN has expired should
# not require the operator to hand-mint a token every recreate — the PAT does
# that on its behalf. The PAT itself never reaches job code because
# ACCESS_TOKEN is already scrubbed above.
if [[ -z "${_REG_TOKEN}" ]]; then
  if [[ -z "${_ACCESS_TOKEN}" ]]; then
    echo "::error::Neither RUNNER_TOKEN nor ACCESS_TOKEN is set." >&2
    echo "::error::Provide RUNNER_TOKEN (single-use, ~1h expiry) OR ACCESS_TOKEN (PAT with '${_SCOPE_KIND}'-appropriate scope: admin:org for org, repo for repo) so a fresh registration token can be minted at start." >&2
    exit 1
  fi
  echo "RUNNER_TOKEN is empty — minting a fresh ${_SCOPE_KIND}-scoped registration token via the GitHub API..."
  _REG_TOKEN="$(mint_token registration || true)"
  if [[ -z "${_REG_TOKEN}" ]]; then
    echo "::error::Auto-mint failed. Verify the PAT has the required scope (admin:org for org runners, repo for repo runners), that the ${_SCOPE_KIND} '${_SCOPE_OWNER}${_SCOPE_REPO:+/${_SCOPE_REPO}}' exists, and that api.github.com is reachable." >&2
    exit 1
  fi
fi

# RUNNER_HOME is baked as an ENV by the Dockerfile (/home/runner). Prefer it
# over $HOME so we don't depend on gosu/libcontainer having reset $HOME to the
# target user's passwd home during the privilege drop.
cd "${RUNNER_HOME:-${HOME}}/actions-runner"

# --- graceful stop + de-registration (kadenz#890 S-03, kadenz#1256) ----------
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
# token at trap time via the scope-appropriate endpoint (org vs repo,
# resolved by scope_endpoint). Without a PAT we fall back to the original
# registration token best-effort and document the limitation: past the first
# hour the removal will fail and the runner lingers as an offline entry until
# `--replace` (same RUNNER_NAME) or a manual removal cleans it up.
RUNNER_PID=""
CLEANUP_DONE="false"

# shellcheck disable=SC2329  # invoked indirectly (from cleanup, itself trap-invoked)
fetch_removal_token() {
  # Thin wrapper preserved for readability at the call site; the scope-aware
  # logic lives in mint_token / scope_endpoint above.
  mint_token remove
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
    echo "Minting a fresh ${_SCOPE_KIND}-scoped removal token via the GitHub API..."
    remove_token="$(fetch_removal_token || true)"
    [[ -z "${remove_token}" ]] && \
      echo "Could not mint a removal token (PAT lacks the required scope, or API unreachable) — falling back to the registration token." >&2
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
build_config_args() {
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
}

build_config_args
echo "Registering runner '${RUNNER_NAME}' (labels: ${RUNNER_LABELS}) against ${RUNNER_URL}"
if ! ./config.sh "${CONFIG_ARGS[@]}"; then
  # config.sh refused. Common causes: the supplied RUNNER_TOKEN is expired
  # (>1h since mint), the runner name is already-registered against a
  # different scope after a migration (repo -> org), or the API rejected the
  # token for another reason. If ACCESS_TOKEN is available, mint a fresh
  # registration token and retry ONCE — transparently, so a container
  # recreate after a token expiry does not crash-loop (kadenz#1256).
  if [[ -z "${_ACCESS_TOKEN}" ]]; then
    echo "::error::config.sh failed and ACCESS_TOKEN is not set — cannot auto-recover. Provide a fresh RUNNER_TOKEN or a PAT." >&2
    exit 1
  fi
  echo "config.sh refused the supplied registration token. Minting a fresh ${_SCOPE_KIND}-scoped token and retrying once..."
  fresh="$(mint_token registration || true)"
  if [[ -z "${fresh}" ]]; then
    echo "::error::Fresh registration-token mint failed on retry — giving up." >&2
    exit 1
  fi
  _REG_TOKEN="${fresh}"
  unset fresh
  build_config_args
  ./config.sh "${CONFIG_ARGS[@]}"
fi

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
