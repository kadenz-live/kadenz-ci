# kadenz-ci

Custom self-hosted **GitHub Actions runner image** for the Kadenz CI pool.
Published as **`ghcr.io/kadenz-live/ci`** (short image name; this repo stays `kadenz-ci`).

It bakes the full toolchain that the [`kadenz-live/kadenz`](https://github.com/kadenz-live/kadenz)
workflows assume is pre-installed on a runner labelled `kadenz-ci`
(`runs-on: [self-hosted, Linux, X64, kadenz-ci]`), so a CI job behaves
**identically whether it lands on the Hetzner bastion runner or a Synology
NAS runner**.

It **replaces `myoung34/github-runner:latest`** on the Synology runners. The
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
ghcr.io/kadenz-live/ci:X.Y             # minor float — auto-updates to the newest patch (Synology pins here)
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
the bastion runner, so the two stay in lock-step:

| Component | Version | Source-of-truth (monorepo role) | Why |
| --- | --- | --- | --- |
| actions/runner | `2.335.1` (SHA-256 pinned) | `roles/github_runner/defaults/main.yml` | The runner agent itself; matches the bastion. |
| gitleaks | `8.21.2` (SHA-256 pinned) | `roles/runner_gitleaks/defaults/main.yml` | `gitleaks.yml` runs the binary directly. |
| hcloud CLI | `1.66.0` (SHA-256 pinned) | `roles/runner_toolchain/defaults/main.yml` | `ansible.yml` discovers Hetzner server IPs. |
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
- **checkov, trivy, cosign, syft** — run as **Docker action containers**
  (`bridgecrewio/checkov-action`, `aquasecurity/trivy-action`,
  `sigstore/cosign-installer`, `anchore/sbom-action`). They need the Docker CLI
  + daemon (provided), not host installs.

## How the Synology runner consumes it

Swap the `image:` line in the Synology runner's `docker-compose.yml` from the
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
      RUNNER_NAME: synology-ci-1
      RUNNER_TOKEN: ${RUNNER_TOKEN}                       # single-use registration token
      # EPHEMERAL: "true"   # optional: de-register after each job for a clean lifecycle
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

## Bumping a tool version

1. Edit the matching `ARG` in [`Dockerfile`](Dockerfile) (version **and**
   SHA-256 together). Copy the checksum from the tool's official release-asset
   checksums file.
2. **Keep the Kadenz monorepo Ansible role in sync** so the bastion runner
   doesn't drift from the Synology image:
   - `gitleaks` -> `infra/ansible/roles/runner_gitleaks/defaults/main.yml`
   - `hcloud` / apt packages -> `infra/ansible/roles/runner_toolchain/defaults/main.yml`
   - runner binary -> `infra/ansible/roles/github_runner/defaults/main.yml`
3. For apt-sourced tools (Node, gh, Playwright libs), the bump is implicit in
   the Ubuntu base-image digest — re-pin the `FROM ubuntu:24.04@sha256:...`
   digest deliberately when you want a refresh.
4. Push to `main`; `build.yml` cuts a new patch `vX.Y.(Z+1)` and republishes
   the `:X.Y` minor float (plus `:vX.Y.Z`, `:X`, `:latest`, `:sha-<gitsha>`).
5. The Synology hosts pin the `:X.Y` minor float with `pull_policy: always`, so
   a `docker compose up -d` / restart re-pulls the newest patch automatically —
   no manual `docker compose pull` needed. Bumping to a new **minor** is a
   deliberate pin change in the compose.

## Relationship to the bastion runner

The Hetzner bastion runner is provisioned **bare-metal** by the Kadenz monorepo
Ansible roles (`github_runner` + `runner_toolchain` + `runner_gitleaks`), not by
this image. This image is the **container-based equivalent** for the Synology
NAS runners. The pinned versions above are kept identical between the two so a
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
