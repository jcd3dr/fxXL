# Decision 0002: Use fxXL GitHub Releases as Artifact Authority

**Status:** Accepted

## Context

The upstream release path depends on infrastructure and credentials not owned
by fxXL. Reusing upstream installation or update origins would make the fork's
distribution dependent on artifacts that may not contain its downstream
patches.

## Decision

Use GitHub Releases in `jcd3dr/fxXL` as the only production authority for fxXL
installation and stable updates. Publish Linux x86_64 and Linux aarch64
archives, SHA-256 files, and a bounded manifest. Make `setup.sh` and the updater
consume the same asset contract. Keep the fxXL release version in
`FXXL_VERSION`, independent from the upstream application version.

Do not use `releases.fx.sh`, Vercel Blob, upstream release artifacts, Apple
signing credentials, or a custom CDN for the current downstream distribution.
Reject the unsupported dev update channel explicitly.

## Consequences

fxXL controls the provenance of its installed binary and can verify archive
integrity before replacement. The fork must operate and validate its own
release workflow. The first release surface is Linux only; Windows use depends
on WSL and native macOS distribution remains outside current scope.

Detailed requirements are canonical in
[`../requirements/fork-contract.md`](../requirements/fork-contract.md).
