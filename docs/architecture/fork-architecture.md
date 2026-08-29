# Downstream Architecture

## Maintained shape

The repository is maintained as:

```text
recorded upstream base
  + generic OpenAI-compatible provider patch
  + fxXL distribution patch
  + downstream governance and documentation patch
```

`UPSTREAM_BASE` identifies the recorded base. The Git history above that commit
is the objective patch surface; logical patch boundaries are maintained through
focused commits and fxXL-owned modules rather than by copying upstream into a
disconnected codebase.

## Component ownership

| Concern | Primary implementation evidence | Ownership |
| --- | --- | --- |
| Application composition and shared runtime | `src/main.zig`, `src/core/`, `src/ui/`, `src/tools/` | Primarily upstream |
| Compatible endpoint validation and profile state | `src/core/config/compat_endpoint.zig`, `src/core/auth/compat_session.zig` | fxXL patch |
| Compatible transport, catalog, protocol, and permission review | `src/gateway/openai_compat*.zig` | fxXL patch |
| Fork release identity and manifest parsing | `FXXL_VERSION`, `src/core/upgrade/fork_release.zig` | fxXL patch |
| Stable update selection and replacement | `src/core/upgrade/` | Shared upstream mechanism with fxXL distribution hooks |
| Installer and installer tests | `setup.sh`, `scripts/test-setup.sh` | fxXL patch |
| Release publication | `.github/workflows/release.yml` | fxXL patch |
| Downstream policy and durable knowledge | `AGENTS.md`, `docs/` | fxXL patch |

## Compatible inference flow

1. The user configures the compatible base URL and key.
2. Endpoint validation enforces HTTPS except for loopback hosts.
3. `fx login compat` persists the compatible profile under `~/.fx/`.
4. The catalog reads `GET {base_url}/models`.
5. Model turns use `POST {base_url}/chat/completions`.
6. Capability metadata from the catalog informs supported model behavior;
   missing metadata receives conservative defaults.
7. The compatible credential is sent only to its configured base URL.

## Installation and update flow

1. `setup.sh` selects the supported Linux architecture.
2. It downloads `manifest.json`, the matching archive, and checksum from the
   latest fxXL GitHub Release asset family.
3. It verifies SHA-256 before extraction and replacement.
4. The installed binary reports the fxXL release version embedded from
   `FXXL_VERSION`.
5. Stable `fx upgrade` resolves the same release base and manifest contract,
   downloads only a newer release, and uses the existing transactional
   replacement path.

GitHub Releases are the production artifact authority. The workflow is
triggered from `main`; branch CI and documentation do not publish a release.

## State and trust boundaries

Compatible credentials and profile state live under the user's `~/.fx/`
profile, outside the repository. Project configuration must not contain those
secrets. Release artifacts cross a remote trust boundary and therefore require
HTTPS origin restrictions plus checksum verification before executable
replacement. Upstream integration crosses a separate change-control boundary
and requires explicit review before the selected base changes.

The normative behavior is in
[`../requirements/fork-contract.md`](../requirements/fork-contract.md); current
verification and known failures are recorded separately so architecture is not
confused with status.
