# kadenz-ci

Custom self-hosted **GitHub Actions runner image** for the Kadenz CI pool,
published as **`ghcr.io/kadenz-live/ci`**.

It bakes the full toolchain that the
[`kadenz-live/kadenz`](https://github.com/kadenz-live/kadenz) workflows assume
is pre-installed on a runner labelled `kadenz-ci`
(`runs-on: [self-hosted, Linux, X64, kadenz-ci]`), so a CI job behaves
identically whether it lands on a **bare-metal / VM runner** (systemd-based)
or a **Docker runner** (containerized, docker-compose based).

It replaces the generic `myoung34/github-runner:latest` image, which lacks
`gitleaks`, `tflint`'s download prerequisites, the Playwright/chromium system
libraries, and the native-gem build chain.

!!! note
    No secrets live in this repository — only a Dockerfile, an entrypoint,
    the build workflow, and these docs.

## Image tags

The pipeline is **SemVer release-managed**. The source of truth for the
version is the git tags `vX.Y.Z`; every build on `main` (push / daily
schedule / manual dispatch) cuts a new **patch** and publishes the full tag
set:

```text
ghcr.io/kadenz-live/ci:vX.Y.Z          # immutable full version (also a git tag + GitHub Release)
ghcr.io/kadenz-live/ci:X.Y             # minor float — auto-updates to the newest patch (Docker runners pin here)
ghcr.io/kadenz-live/ci:X               # major float
ghcr.io/kadenz-live/ci:latest          # newest release
ghcr.io/kadenz-live/ci:sha-<gitsha>    # immutable, pin to an exact commit
```

Every pushed digest is Cosign keyless-signed — see
[Supply chain](supply-chain.md) for the verification command.

## Quickstart

1. Mint a repo-scoped registration token:

    ```sh
    gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token
    ```

2. Start the runner with the docker socket bind-mounted:

    ```sh
    docker run -d --name ci-runner \
      --network host \
      -e RUNNER_URL=https://github.com/<owner>/<repo> \
      -e RUNNER_TOKEN=<registration-token> \
      -e RUNNER_LABELS=kadenz-ci \
      -v /var/run/docker.sock:/var/run/docker.sock \
      ghcr.io/kadenz-live/ci:1.0
    ```

3. The runner registers, appears under the repository's
   *Settings → Actions → Runners*, and de-registers gracefully on
   `docker stop` (see [Security](security.md) for the token-freshness
   caveat on long-lived runners).

For production-shaped setups (compose, systemd) see
[Deployment patterns](deployment.md); for the full environment-variable
interface see [Configuration](configuration.md).

## What's baked in

| Component | Version | Why |
| --- | --- | --- |
| actions/runner | `2.335.1` (SHA-256 pinned) | The runner agent itself. |
| gitleaks | `8.21.2` (SHA-256 pinned) | Secret-scanning jobs run the binary directly. |
| hcloud CLI | `1.66.0` (SHA-256 pinned) | IaC workflows shell out to `hcloud` for server discovery. |
| trivy | `0.72.0` (SHA-256 pinned) | PATH baseline for `aquasecurity/trivy-action` (see the caveat in the README). |
| Docker CLI + buildx + compose plugins | apt (noble `stable`) | Service containers + image builds; the daemon is host-provided. |
| Node.js | apt (Ubuntu noble) | JS composite actions need a system `node`. |
| gh CLI | apt (cli/cli upstream) | `gh workflow run`, Dependabot auto-merge crons. |
| libvips42 | apt | `ruby-vips` / ActiveStorage image processing. |
| Playwright chromium system libs + `fonts-liberation` | apt (noble `t64` ABI) | Playwright jobs install chromium without `--with-deps`. |
| Native-gem build chain | apt | Headers/libs that `pg`, `psych`, `ffi`, `nokogiri`, `bcrypt` compile against. |
| Python 3 + pip + venv | apt | In-workflow `pip install` (ansible-core, ansible-lint). |
| `jq`, `unzip`, `curl`, `git`, `ca-certificates` | apt | Generic CI plumbing. |

Ruby, Terraform, tflint, a pinned Node version, ansible-core/-lint, sops,
checkov, cosign, and syft are deliberately **not** baked — they are provided
per-job by `setup-*` actions, in-workflow installs, or Docker action
containers. See the
[README](https://github.com/kadenz-live/kadenz-ci#provided-by-the-job-not-baked-by-design)
for the rationale per tool.
