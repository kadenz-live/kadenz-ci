# Deployment patterns

Two generic archetypes cover how a `kadenz-ci` runner host is operated:

1. **Docker runner** — a containerized runner host; this image runs under
   docker-compose (or a systemd unit wrapping `docker run`).
2. **Bare-metal / VM runner** — a host provisioned directly (systemd
   service) by configuration management, **not** by this image; the image is
   the container-based equivalent, kept in version lock-step.

## Docker runner (docker-compose)

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
      #                               # token expiry (see the Security page)
      # EPHEMERAL: "true"   # optional: de-register after each job for a clean lifecycle
      # RUNNER_GRACEFUL_STOP_TIMEOUT: "60"  # raise together with stop_grace_period
    # stop_grace_period: "90s"  # recommended: docker's 10s default cuts graceful shutdown short
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock         # service containers + image builds
      # optional: persist _work across restarts
      # - kadenz-ci-work:/home/runner/actions-runner/_work
```

Operational notes:

- Pinning the `:X.Y` **minor float** with `pull_policy: always` means a
  `docker compose up -d` / restart re-pulls the newest patch automatically —
  no manual `docker compose pull` needed. Bumping to a new **minor** is a
  deliberate pin change.
- `network_mode: host` lets job-started service containers (postgres, redis)
  publish ports the job can reach on `localhost`.
- The docker-socket mount is required for jobs that build images or
  self-manage service containers — and it is a real trade-off, see
  [Security](security.md#docker-socket-trade-off).

## Docker runner (systemd-wrapped `docker run`)

For a VM or bare-metal host without compose, run the same container under a
systemd unit — systemd handles restart-on-failure and ordered shutdown:

```ini
# /etc/systemd/system/kadenz-ci-runner.service
[Unit]
Description=kadenz-ci GitHub Actions runner (containerized)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=5
# Must exceed the container's stop grace so graceful de-registration finishes.
TimeoutStopSec=120
# RUNNER_TOKEN=... / ACCESS_TOKEN=... live here, root-only readable (0600).
EnvironmentFile=/etc/kadenz-ci/runner.env
ExecStartPre=-/usr/bin/docker rm -f kadenz-ci-runner
ExecStartPre=/usr/bin/docker pull ghcr.io/kadenz-live/ci:1.0
ExecStart=/usr/bin/docker run --name kadenz-ci-runner \
  --network host \
  --env-file /etc/kadenz-ci/runner.env \
  --env RUNNER_NAME=vm-runner-1 \
  --env RUNNER_GRACEFUL_STOP_TIMEOUT=60 \
  --stop-timeout 90 \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/kadenz-live/ci:1.0
ExecStop=/usr/bin/docker stop --time 90 kadenz-ci-runner

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now kadenz-ci-runner.service
```

`docker stop` delivers `SIGTERM` to the entrypoint, which stops the listener
and de-registers before exiting — keep `--stop-timeout` (and
`TimeoutStopSec`) above `RUNNER_GRACEFUL_STOP_TIMEOUT`.

## Bare-metal / VM runner (native, no container)

The native archetype installs the runner and toolchain **directly on the
host** as a systemd service via configuration management (Ansible roles in
the Kadenz monorepo: `github_runner` + `runner_toolchain` +
`runner_gitleaks`). This image is not involved at runtime there — but the
pinned versions (actions/runner, gitleaks, hcloud, trivy, apt package set)
are kept **identical** between the roles and this Dockerfile, so a
`kadenz-ci` job is reproducible regardless of which runner archetype picks
it up.

If you bump a version in one place, bump the other — see
["Bumping a tool version"](https://github.com/kadenz-live/kadenz-ci#bumping-a-tool-version)
in the README.

## Getting a registration token

From the repository's *Settings → Actions → Runners* page, or:

```sh
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token
```

!!! warning "Repo-scoped on purpose"
    Register runners against a **single repository**, never org-wide — that
    keeps the blast radius of a compromised workflow to one repository.
