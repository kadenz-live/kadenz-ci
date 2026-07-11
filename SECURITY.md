# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities through GitHub's
**[private vulnerability reporting](https://github.com/kadenz-live/kadenz-ci/security/advisories/new)**
for this repository (it is enabled). Do **not** open a public issue for
security-relevant findings — private reporting gives us room to assess and
fix before disclosure.

Please include the image tag/digest you tested, the behaviour you observed,
and the deployment pattern in use (Docker runner / systemd-wrapped / other).
We will acknowledge reports as quickly as we can and keep you informed
through the advisory thread.

## Supported versions

The image is release-managed with a rolling SemVer patch cadence — a fresh
patch is cut at least daily (base-image security refresh), so fixes ship in
the **newest release** rather than being backported.

| Version | Supported |
| --- | --- |
| Latest release (`:latest`, newest `:X.Y` / `:vX.Y.Z`) | Yes |
| Older tags | No — upgrade to the newest patch; the `:X.Y` minor float auto-flows patches |

## Hardening documentation

The security model of the image (token handling, graceful de-registration,
the `ACCESS_TOKEN` trade-off, the GID-0 socket guard, and the docker-socket
trade-off) is documented on the
**[docs security page](https://kadenz-live.github.io/kadenz-ci/security/)**.

Verify image signatures before use — see the
[supply-chain page](https://kadenz-live.github.io/kadenz-ci/supply-chain/)
for the `cosign verify` command.
