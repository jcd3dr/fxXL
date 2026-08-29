# fxXL Downstream Contract

This document is the canonical statement of recorded fxXL downstream
requirements. Implementation and validation evidence must be checked before
claiming that a requirement is satisfied at a particular commit.

## Maintenance contract

1. fxXL remains a reviewed upstream base plus a small, explicit downstream
   patch stack.
2. `UPSTREAM_BASE` records the exact 40-character upstream commit used as the
   base.
3. OpenAI-compatible inference, fxXL distribution behavior, and downstream
   governance remain separable concerns.
4. Upstream integration requires explicit maintainer approval and review. It
   must not occur automatically as part of unrelated work.
5. A downstream capability is removed when upstream fully supersedes it and is
   reduced to the remaining gap when upstream partially supersedes it.
6. Apache-2.0 notices and upstream attribution are preserved.

## OpenAI-compatible provider contract

1. The route is vendor-neutral. OpenRouter, Ollama, and other services are
   examples, not architectural owners.
2. The user explicitly supplies a base URL and non-empty API key through
   `FX_COMPAT_BASE_URL` and `FX_COMPAT_API_KEY`, or uses the stored compatible
   profile created from them.
3. External endpoints require HTTPS. Plain HTTP is allowed only for loopback
   hosts such as `localhost`, `127.0.0.1`, and `::1`.
4. fxXL appends `/models` and `/chat/completions` beneath the configured base
   URL.
5. Compatible credentials are scoped to their configured endpoint and must not
   be sent to Vercel AI Gateway, OpenAI, xAI, or an unrelated endpoint.
6. Model IDs and capability metadata come from the compatible endpoint. The
   provider uses conservative fallbacks when the catalog lacks capability
   metadata.

## Distribution contract

1. Production fxXL installation and stable updates use GitHub Releases in
   `jcd3dr/fxXL` only.
2. Production behavior must not depend on `releases.fx.sh`, Vercel Blob, Apple
   signing credentials, or release artifacts owned by `vercel-labs/fx`.
3. The supported release targets are Linux x86_64 and Linux aarch64.
4. Each stable release provides a manifest, one archive per supported target,
   and one SHA-256 checksum per archive.
5. `setup.sh` verifies the checksum before extraction, preserves an existing
   executable until replacement succeeds, and installs without requiring root
   into `${FX_INSTALL_DIR:-$HOME/.local/bin}` by default.
6. Windows 11 usage runs the Linux installer inside WSL. A Windows-native
   executable or installer is not part of the current contract.
7. The updater consumes the same release manifest and artifact naming contract
   as the installer, verifies checksums, and preserves transactional
   replacement behavior.
8. The downstream updater supports the stable channel. An unsupported dev
   update request must fail explicitly before consulting upstream release
   infrastructure.
9. `FXXL_VERSION` is independent from the upstream application version.

## Release acceptance contract

A release is not installable merely because a tag or workflow exists. The
exact release commit must pass the repository's required CI, produce the
declared assets and checksums, and be installed into a temporary clean
directory through the canonical `setup.sh` command before being declared
usable.

See [`../validation/evidence.md`](../validation/evidence.md) for the available
proof surfaces and their limits.

## Non-goals

* Automatic or unreviewed upstream merging.
* A Windows-native build or installer.
* A custom release CDN.
* Vendor-specific provider ownership where the compatible route is sufficient.
* Initial macOS release signing and distribution through fxXL.
* Rewriting or republishing upstream release tags.
