# kadenz-ci

Custom self-hosted **GitHub Actions runner image** for the Kadenz CI pool.
Published as **`ghcr.io/kadenz-live/ci`** (short image name; this repo stays `kadenz-ci`).

It bakes the full toolchain that the [`kadenz-live/kadenz`](https://github.com/kadenz-live/kadenz)
workflows assume is pre-installed on a runner labelled `kadenz-ci`
(`runs-on: [self-hosted, Linux, X64, kadenz-ci]`), so a CI job behaves
**identically whether it lands on a bare-metal / VM runner (systemd-based)
or a Docker runner (containerized, docker-compose based)**.

It **replaces `myoung34/github-runner:latest`** on the Docker runners. The
generic image lacks `gitleaks`, `tflint`'s download prerequisites, the
Playwright/chromium system libraries, and the native-gem build chain, so jobs
fail with `gitleaks: command not found`, tflint download timeouts, and missing
`libpq`/`libvips` at gem-compile time.

> [!NOTE]
> This repository and the published image are intended to be made **public**.
> No secrets live here — only a Dockerfile, an entrypoint, a build workflow,
> and docs.

## Image reference

The pipeline is **SemVer release-managed**. The source of truth for the version
is the git tags `vX.Y.Z`; every build on `main` (push / daily schedule / manual
dispatch) cuts a new **patch** and publishes the full tag set:

```
ghcr.io/kadenz-live/ci:vX.Y.Z          # immutable full version (also a git tag + GitHub Release)
ghcr.io/kadenz-live/ci:X.Y             # minor float — auto-updates to the newest patch (Docker runners pin here)
ghcr.io/kadenz-live/ci:X               # major float
ghcr.io/kadenz-live/ci:latest          # newest release
ghcr.io/kadenz-live/ci:sha-<gitsha>    # immutable, pin to an exact commit
```

Built + pushed by [`.github/workflows/build.yml`](.github/workflows/build.yml)
(GitHub-hosted runner, `linux/amd64`) on:

- **push to `main`** (excluding `CHANGELOG.md`-only commits),
- a **daily `03:00 UTC` schedule** (= 05:00 CEST / 04:00 CET — the cron is UTC,
  so the Berlin wall-clock shifts by an hour across DST), which guarantees a
  fresh patch every day so a runner restart picks up that day's base-image
  security updates even with zero code change, and
- **manual `workflow_dispatch`**.

Each run also Cosign-keyless-signs the pushed digest, creates the `vX.Y.Z` git
tag + a GitHub Release with auto-generated notes, and regenerates
[`CHANGELOG.md`](CHANGELOG.md) via [git-cliff](https://git-cliff.org)
([`cliff.toml`](cliff.toml)) committed back with `[skip ci]`.

**Verify a signature** before trusting an image:

```sh
cosign verify \
  --certificate-identity-regexp 'https://github.com/kadenz-live/kadenz-ci/.github/workflows/build.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/kadenz-live/ci:1.0
```

## What's baked in

The pinned versions mirror the Kadenz monorepo's Ansible roles that provision
the bare-metal / VM runner, so the two stay in lock-step:

| Component | Version | Source-of-truth (monorepo role) | Why |
| --- | --- | --- | --- |
| actions/runner | `2.335.1` (SHA-256 pinned) | `roles/github_runner/defaults/main.yml` | The runner agent itself; matches the bare-metal / VM runner. |
| gitleaks | `8.21.2` (SHA-256 pinned) | `roles/runner_gitleaks/defaults/main.yml` | `gitleaks.yml` runs the binary directly. |
| hcloud CLI | `1.66.0` (SHA-256 pinned) | `roles/runner_toolchain/defaults/main.yml` | IaC workflows shell out to `hcloud` for server discovery. |
| trivy | `0.72.0` (SHA-256 pinned) | `roles/runner_toolchain/defaults/main.yml` | Pre-installed so `trivy` resolves on PATH baseline; see the caveat below and [kadenz#1186](https://github.com/kadenz-live/kadenz/issues/1186). |
| Docker CLI + buildx + compose plugins | apt (noble `stable`) | — | Service containers (`api.yml`) + image builds (`release.yml`). Daemon is host-provided. |
| Node.js | apt (Ubuntu noble) | `roles/runner_toolchain/defaults/main.yml` | JS composite actions (`setup-terraform` wrapper, `setup-tflint`) need a system `node`. |
| gh CLI | apt (cli/cli upstream) | `roles/runner_toolchain/defaults/main.yml` | `gh workflow run` in release deploy + Dependabot auto-merge cron. |
| libvips42 | apt | `roles/runner_toolchain/defaults/main.yml` | `ruby-vips` / ActiveStorage image processing in RSpec. |
| Playwright chromium system libs + `fonts-liberation` | apt (noble `t64` ABI) | `roles/runner_toolchain/defaults/main.yml` | `e2e.yml` + `frontend-e2e.yml` run `npx playwright install chromium` without `--with-deps`. |
| native-gem build chain | apt | — | `build-essential`, `pkg-config`, `libpq-dev`, `libyaml-dev`, `libffi-dev`, `libssl-dev`, `zlib1g-dev`, `libreadline-dev`, `libgmp-dev`, `libxml2-dev`, `libxslt1-dev` — headers `pg`, `psych`, `ffi`, `nokogiri`, `bcrypt` compile against. |
| Python 3 + pip + venv | apt | — | In-workflow `pip install ansible-core==2.18.* ansible-lint==25.5.0` (`iac-scan.yml`, `ansible.yml`). |
| `jq`, `unzip`, `curl`, `git`, `ca-certificates` | apt | — | Generic CI plumbing. |

### Provided by the job, **not** baked (by design)

These are installed per-job by `setup-*` actions or run as action containers,
so baking them would be redundant or would fight the version the workflow pins:

- **Ruby** — `ruby/setup-ruby@v1` per job (`api.yml`, `release.yml`). The image
  only carries the headers/libs native gems compile against.
- **Terraform `1.10.5`** — `hashicorp/setup-terraform` (`terraform.yml`).
- **tflint `v0.55.0`** — `terraform-linters/setup-tflint` (`iac-scan.yml`).
- **Node 24** — `actions/setup-node` overlays the system Node where a workflow
  pins it (`frontend.yml`, `e2e.yml`).
- **ansible-core `2.18.*` / ansible-lint `25.5.0`** — in-workflow `pip install`.
- **sops `3.13.1`** — in-workflow download (`ansible.yml`).
- **checkov, cosign, syft** — run as **Docker action containers**
  (`bridgecrewio/checkov-action`, `sigstore/cosign-installer`,
  `anchore/sbom-action`). They need the Docker CLI + daemon (provided), not
  host installs.
- **trivy** is the one exception: `aquasecurity/trivy-action` calls its own
  `aquasecurity/setup-trivy` step by default on every invocation regardless
  of a pre-installed system trivy — it never probes for or reuses one. The
  system trivy baked into this image (table above) only becomes
  load-bearing once a workflow step passes `skip-setup-trivy: true`; until
  then it is a defence-in-depth PATH baseline, not a full bypass of
  setup-trivy's own download. See [kadenz#1186](https://github.com/kadenz-live/kadenz/issues/1186).

## How the Docker runner consumes it

Swap the `image:` line in the Docker runner's `docker-compose.yml` from the
generic image to this one:

```yaml
services:
  kadenz-ci-runner:
    image: ghcr.io/kadenz-live/ci:1.0             # pin the MINOR float — patches 1.0.* auto-flow
    pull_policy: always                           # re-pull the newest 1.0.x patch on every start
    network_mode: host                            # service-container ports reach the job
    restart: unless-stopped
    environment:
      RUNNER_URL: https://github.com/kadenz-live/kadenz   # repo-scoped, never org-scoped
      RUNNER_LABELS: kadenz-ci                            # gates runs-on: [..., kadenz-ci]
      RUNNER_NAME: docker-runner-1
      RUNNER_TOKEN: ${RUNNER_TOKEN}                       # single-use registration token
      # ACCESS_TOKEN: ${ACCESS_TOKEN} # optional PAT: mints a FRESH removal token on stop, so
      #                               # de-registration works even after the 1h registration-
      #                               # token expiry (see "Security notes" below)
      # EPHEMERAL: "true"   # optional: de-register after each job for a clean lifecycle
      # RUNNER_GRACEFUL_STOP_TIMEOUT: "60"  # raise together with stop_grace_period
    # stop_grace_period: "90s"  # recommended: docker's 10s default cuts graceful shutdown short
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock         # service containers + image builds
      # optional: persist _work across restarts
      # - kadenz-ci-work:/home/runner/actions-runner/_work
```

The entrypoint's env interface (`RUNNER_URL` / `RUNNER_TOKEN` / `RUNNER_NAME`
/ `RUNNER_LABELS` / `EPHEMERAL`) mirrors `myoung34/github-runner`, so the
existing compose needs little more than the `image:` swap. Get a fresh
registration token from
`https://github.com/kadenz-live/kadenz/settings/actions/runners` or:

```sh
gh api -X POST repos/kadenz-live/kadenz/actions/runners/registration-token --jq .token
```

> The runner is **repo-scoped** to `kadenz-live/kadenz` on purpose — it never
> registers org-wide, which keeps the blast radius of a compromised workflow to
> a single repository.

## Security notes

Hardening decisions in `entrypoint.sh`, from the 2026-07-10 pre-open-source
security review ([kadenz#890](https://github.com/kadenz-live/kadenz/issues/890)):

- **Tokens are scrubbed from the environment before the runner starts.**
  `RUNNER_TOKEN` (and `ACCESS_TOKEN`, if set) are copied into unexported shell
  variables and `unset` before `config.sh`/`run.sh` run, so the listener — and
  every job step it executes — never inherits them. Registration tokens are
  repo-scoped and valid for ~1h; keeping them out of job environments removes
  the window in which job-executed code could read a still-valid token.
- **Accepted residual: token in process arguments.** Upstream `config.sh`
  accepts the token only as a CLI argument (no stdin/env alternative), so it
  is briefly visible in the process argument vector during register/remove.
  Registration happens before any job runs, and de-registration only starts
  after the listener has been stopped, so no job code runs concurrently with
  either call; the 1h token expiry bounds the rest.
- **De-registration is trap-covered for both signals and plain exits.** A
  `SIGTERM`/`SIGINT` trap (docker stop / compose down) and an `EXIT` trap
  (run.sh crashing on its own) share one idempotent cleanup path: stop the
  listener first (bounded by `RUNNER_GRACEFUL_STOP_TIMEOUT`, default 5s), then
  de-register, then exit. `RUNNER_MANUALLY_TRAP_SIG` is set for `run.sh` so it
  forwards our stop signal to the listener (upstream mechanism).
- **Token-freshness limitation.** Registration tokens expire after ~1h, so a
  long-lived runner cannot de-register with its original token. Provide the
  optional `ACCESS_TOKEN` (PAT with repo-admin) and the entrypoint mints a
  fresh removal token at stop time via
  `POST /repos/{owner}/{repo}/actions/runners/remove-token`. Without a PAT,
  removal past the first hour fails best-effort and the runner lingers as an
  offline entry until `--replace` (same `RUNNER_NAME`) or manual removal
  cleans it up — or use `EPHEMERAL=true`, which de-registers after every job.
- **GID-0 socket guard.** If the bind-mounted docker socket is owned by group
  `root` (gid 0 — a common Docker-host default), the entrypoint does **not** add the
  runner user to the root group (which would grant access to every
  group-0-writable path in the image). It re-groups the socket onto a
  dedicated `dockerhost` group (`DOCKER_SOCK_SYNTHETIC_GID`, default 2375)
  and grants membership in that group only. If the re-group fails (e.g.
  read-only mount), no grant is made at all and Docker-dependent jobs fail
  loudly at job time. Note that re-grouping a bind-mounted socket changes the
  host inode's group too, until the host daemon re-creates the socket.
- **Docker-socket trade-off (pre-existing).** Mounting `/var/run/docker.sock`
  makes job code effectively host-root-equivalent on the runner host. That is
  an accepted architectural trade-off for this pool (the runners serve a
  single private repository); the GID guard above narrows in-container
  privileges, not this host-level trade-off.

## Bumping a tool version

1. Edit the matching `ARG` in [`Dockerfile`](Dockerfile) (version **and**
   SHA-256 together). Copy the checksum from the tool's official release-asset
   checksums file.
2. **Keep the Kadenz monorepo Ansible role in sync** so the bare-metal / VM
   runner doesn't drift from this image:
   - `gitleaks` -> `infra/ansible/roles/runner_gitleaks/defaults/main.yml`
   - `hcloud` / `trivy` / apt packages -> `infra/ansible/roles/runner_toolchain/defaults/main.yml`
   - runner binary -> `infra/ansible/roles/github_runner/defaults/main.yml`
3. For apt-sourced tools (Node, gh, Playwright libs), the bump is implicit in
   the Ubuntu base-image digest — re-pin the `FROM ubuntu:24.04@sha256:...`
   digest deliberately when you want a refresh.
4. Push to `main`; `build.yml` cuts a new patch `vX.Y.(Z+1)` and republishes
   the `:X.Y` minor float (plus `:vX.Y.Z`, `:X`, `:latest`, `:sha-<gitsha>`).
5. The Docker runner hosts pin the `:X.Y` minor float with `pull_policy: always`, so
   a `docker compose up -d` / restart re-pulls the newest patch automatically —
   no manual `docker compose pull` needed. Bumping to a new **minor** is a
   deliberate pin change in the compose.

## Relationship to the bare-metal / VM runner

The bare-metal / VM runner is provisioned **directly on the host** (systemd
service) by the Kadenz monorepo Ansible roles (`github_runner` +
`runner_toolchain` + `runner_gitleaks`), not by this image. This image is the
**container-based equivalent** for the Docker runners.
The pinned versions above are kept identical between the two so a
`kadenz-ci` job is reproducible regardless of which runner picks it up. If you
bump one, bump the other.

## Supply-chain

`build.yml` attaches SLSA build provenance (`provenance: mode=max`) and an SBOM
(`sbom: true`) to the pushed image via buildkit, then **Cosign keyless-signs**
the pushed digest (Fulcio cert via the workflow OIDC token, signature recorded
in the public Rekor transparency log). Verify with `cosign verify` as shown
under [Image reference](#image-reference).

GitHub security features on this repo: secret scanning + push protection,
Dependabot alerts + automated security fixes, and a weekly Dependabot config
([`.github/dependabot.yml`](.github/dependabot.yml)) that keeps the SHA-pinned
action refs and the Dockerfile base-image digest current.

## License

[MIT](LICENSE).
