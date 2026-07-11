# Security

Hardening decisions in `entrypoint.sh`, from the 2026-07-10 pre-open-source
security review
([kadenz#890](https://github.com/kadenz-live/kadenz/issues/890)).

To report a vulnerability in this image, use GitHub's
[private vulnerability reporting](https://github.com/kadenz-live/kadenz-ci/security/advisories/new)
— see [`SECURITY.md`](https://github.com/kadenz-live/kadenz-ci/blob/main/SECURITY.md).

## Token handling

**Tokens are scrubbed from the environment before the runner starts.**
`RUNNER_TOKEN` (and `ACCESS_TOKEN`, if set) are copied into unexported shell
variables and `unset` before `config.sh`/`run.sh` run, so the listener — and
every job step it executes — never inherits them. Registration tokens are
repo-scoped and valid for ~1h; keeping them out of job environments removes
the window in which job-executed code could read a still-valid token.

**Accepted residual: token in process arguments.** Upstream `config.sh`
accepts the token only as a CLI argument (no stdin/env alternative), so it is
briefly visible in the process argument vector during register/remove.
Registration happens before any job runs, and de-registration only starts
after the listener has been stopped, so no job code runs concurrently with
either call; the 1h token expiry bounds the rest.

## Graceful de-registration

**De-registration is trap-covered for both signals and plain exits.** A
`SIGTERM`/`SIGINT` trap (docker stop / compose down) and an `EXIT` trap
(run.sh crashing on its own) share one idempotent cleanup path: stop the
listener first (bounded by `RUNNER_GRACEFUL_STOP_TIMEOUT`, default 5s), then
de-register, then exit. `RUNNER_MANUALLY_TRAP_SIG` is set for `run.sh` so it
forwards the stop signal to the listener (upstream mechanism).

## Token freshness and the `ACCESS_TOKEN` trade-off

Registration tokens expire after ~1h, so a long-lived runner cannot
de-register with its original token. Two ways out:

- **Provide the optional `ACCESS_TOKEN`** (PAT with repo-admin permission)
  and the entrypoint mints a fresh removal token at stop time via
  `POST /repos/{owner}/{repo}/actions/runners/remove-token`.
- **Use `EPHEMERAL=true`**, which de-registers after every job and needs no
  PAT at all.

The trade-off: the PAT is a **long-lived, broader credential** than the
single-use registration token — it grants repo-admin, sits on the runner
host (env file / compose environment), and must be rotated like any other
long-lived secret. It is scrubbed from the environment exactly like
`RUNNER_TOKEN` (job code never inherits it), but host-level compromise
still exposes it. If you cannot accept that, run without a PAT: removal
past the first hour fails best-effort and the runner lingers as an offline
entry until `--replace` (same `RUNNER_NAME`) or manual removal cleans it up
— or prefer `EPHEMERAL=true`.

## GID-0 socket guard

If the bind-mounted docker socket is owned by group `root` (gid 0 — a common
Docker-host default), the entrypoint does **not** add the runner user to the
root group (which would grant access to every group-0-writable path in the
image). It re-groups the socket onto a dedicated `dockerhost` group
(`DOCKER_SOCK_SYNTHETIC_GID`, default 2375) and grants membership in that
group only. If the re-group fails (e.g. read-only mount), no grant is made
at all and Docker-dependent jobs fail loudly at job time. Note that
re-grouping a bind-mounted socket changes the host inode's group too, until
the host daemon re-creates the socket.

## Docker-socket trade-off

Mounting `/var/run/docker.sock` makes job code effectively
host-root-equivalent on the runner host. That is an accepted architectural
trade-off for this pool (the runners serve a single private repository); the
GID guard above narrows in-container privileges, not this host-level
trade-off. If your workflows do not need Docker, omit the socket mount — the
entrypoint tolerates its absence.

## Runner scoping

The runner registers **repo-scoped, never org-scoped** — a compromised
workflow can only reach the one repository the runner serves. The non-root
`runner` user (UID 1001) executes all jobs; root exists only for the brief
socket-GID grant phase at container start (`RUNNER_ALLOW_RUNASROOT` is
intentionally left unset).
