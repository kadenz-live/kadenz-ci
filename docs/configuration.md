# Configuration

The container is configured entirely through environment variables. The
interface mirrors `myoung34/github-runner` closely enough that an existing
compose file usually only needs the `image:` line swapped.

Source of truth is [`entrypoint.sh`](https://github.com/kadenz-live/kadenz-ci/blob/main/entrypoint.sh)
— the tables below are generated from it.

## Required

| Variable | Description |
| --- | --- |
| `RUNNER_TOKEN` | GitHub Actions **registration token** (single-use, ~1h expiry). Obtain from the repository's *Settings → Actions → Runners* page, or mint via `gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token`. Scrubbed from the environment before the runner starts so job processes never inherit it — see [Security](security.md). |

## Optional

| Variable | Default | Description |
| --- | --- | --- |
| `RUNNER_URL` | `https://github.com/kadenz-live/kadenz` | Repository URL to register against. The runner is **repo-scoped by design** — it never registers org-wide. |
| `RUNNER_NAME` | container hostname | Runner name shown in the GitHub UI. |
| `RUNNER_LABELS` | `kadenz-ci` | Comma-separated **extra** labels. The runner always self-applies `self-hosted,Linux,X64`; keep `kadenz-ci` so `runs-on: [self-hosted, Linux, X64, kadenz-ci]` matches. |
| `RUNNER_GROUP` | `Default` | Runner group. |
| `RUNNER_WORKDIR` | `_work` | Work directory (relative to the runner install). |
| `EPHEMERAL` | `false` | When `"true"`, register with `--ephemeral` so the runner de-registers itself after a single job — the cleanest lifecycle, and the recommended way to avoid the token-freshness limitation entirely. |
| `ACCESS_TOKEN` | *(unset)* | Optional GitHub PAT (myoung34-compatible name), used **only** to mint a fresh removal token at de-registration time via `POST /repos/{owner}/{repo}/actions/runners/remove-token`. Needs repo-admin permission (classic `repo` scope). Scrubbed from the environment like `RUNNER_TOKEN`. See the trade-off discussion in [Security](security.md#token-freshness-and-the-access_token-trade-off). |
| `RUNNER_GRACEFUL_STOP_TIMEOUT` | `5` | Seconds to wait for the runner listener to shut down before de-registering on container stop. Keep this **below** the container runtime's stop grace period, and raise both together (compose `stop_grace_period`) if in-flight jobs should get a chance to finish — docker's default grace is only 10s. Non-numeric values fall back to `5`. |
| `DOCKER_SOCK` | `/var/run/docker.sock` | Path of the bind-mounted host Docker socket the entrypoint inspects for the group grant. |
| `DOCKER_SOCK_SYNTHETIC_GID` | `2375` | GID used for the synthetic `dockerhost` group when the bind-mounted docker socket is owned by gid 0 — see the [GID-0 socket guard](security.md#gid-0-socket-guard). |

## Baked image environment

Set by the Dockerfile; normally not overridden:

| Variable | Value | Purpose |
| --- | --- | --- |
| `RUNNER_USER` | `runner` | Name of the unprivileged user (UID/GID 1001) the entrypoint drops to via `gosu` before the runner starts. |
| `RUNNER_HOME` | `/home/runner` | Runner install location (`$RUNNER_HOME/actions-runner`). |
| `AGENT_TOOLSDIRECTORY` | `/opt/hostedtoolcache` | Pre-created, runner-owned tool cache so `ruby/setup-ruby` / `actions/setup-node` can populate it without chown failures. |

## Behavioural notes

- **Registration flags:** the entrypoint always registers with `--unattended
  --replace --disableupdate`. `--replace` re-uses the name if a stale
  registration exists; `--disableupdate` keeps the runner version pinned to
  the baked binary (auto-update would defeat a pinned image).
- **No socket, no problem:** if `DOCKER_SOCK` is absent, the entrypoint logs
  a warning and continues — jobs that need Docker fail loudly at job time,
  everything else runs fine.
- **Exit code:** the container exits with the runner's own exit code; the
  `EXIT` trap still de-registers on the way out.
