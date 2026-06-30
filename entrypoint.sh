#!/usr/bin/env bash
#
# Entrypoint for the kadenz-ci self-hosted GitHub Actions runner image.
#
# Registers the runner against a repository (repo-scoped, never org-scoped),
# starts it, and de-registers gracefully on container stop. The env-var
# interface mirrors myoung34/github-runner closely enough that the Synology
# compose only has to swap the `image:` line — see README.md.
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

cd "${HOME}/actions-runner"

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
