# Supply chain

Every image push is signed, attested, and traceable to the exact workflow
run that built it.

## Verify the signature (Cosign, keyless)

The build workflow Cosign-keyless-signs the pushed **digest** (not a tag):
the workflow's OIDC token is exchanged with Fulcio for a short-lived signing
certificate bound to the repo + workflow path, and the signature is recorded
in the public Rekor transparency log.

Verify before trusting an image:

```sh
cosign verify \
  --certificate-identity-regexp 'https://github.com/kadenz-live/kadenz-ci/.github/workflows/build.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/kadenz-live/ci:1.0
```

A valid result prints the verified claims, including the certificate subject
(the `build.yml` workflow path) and the Rekor log index. Verification must
happen **before** the image is admitted to a host — not post-deploy.

## SBOM and provenance

`build.yml` attaches **SLSA build provenance** (`provenance: mode=max`) and
an **SBOM** (`sbom: true`) to the pushed image via BuildKit.

Retrieve them with `docker buildx imagetools` (per the Docker
attestation docs, docs.docker.com/build/metadata/attestations/):

```sh
# SPDX SBOM
docker buildx imagetools inspect ghcr.io/kadenz-live/ci:latest \
  --format '{{ json .SBOM }}'

# SLSA provenance
docker buildx imagetools inspect ghcr.io/kadenz-live/ci:latest \
  --format '{{ json .Provenance }}'
```

## SemVer release flow

- Source of truth is the git tags `vX.Y.Z`.
- Every build on `main` (push, daily 03:00 UTC schedule, manual dispatch)
  cuts a new **patch**, publishes the tag set
  (`:vX.Y.Z`, `:X.Y`, `:X`, `:latest`, `:sha-<gitsha>`), signs the digest,
  creates the git tag + GitHub Release, and regenerates
  [`CHANGELOG.md`](changelog.md) via git-cliff.
- The **daily schedule** guarantees a fresh patch every day, so a runner
  restart picks up that day's base-image security updates even with zero
  code change.
- Consumers pin the `:X.Y` minor float for auto-flowing patches, or an
  immutable `:vX.Y.Z` / `:sha-<gitsha>` / digest for strict reproducibility.

## Version pinning discipline

- The Ubuntu base image is pinned **by digest**, not the floating `:24.04`
  tag — a base refresh is an explicit, reviewable bump.
- Every downloaded binary (actions/runner, gitleaks, hcloud, trivy) is
  **SHA-256 verified** before it is trusted.
- GitHub Actions in the workflows are **SHA-pinned** with version comments;
  a weekly [Dependabot config](https://github.com/kadenz-live/kadenz-ci/blob/main/.github/dependabot.yml)
  keeps the action pins and the base-image digest current.

## Repository security features

Secret scanning + push protection, Dependabot alerts + automated security
fixes, and private vulnerability reporting are enabled on the repository.
