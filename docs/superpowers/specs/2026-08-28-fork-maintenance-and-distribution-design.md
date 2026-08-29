# fxXL Fork Maintenance and Distribution Design

> **Historical record:** This dated design preserves prior rationale. It is not
> current project state, repository-wide policy, or an active work tracker. Use
> [`../../state/current.md`](../../state/current.md) for current continuation
> state and [`../../README.md`](../../README.md) for canonical knowledge routes.

## Purpose

Turn `jcd3dr/fxXL` into a maintainable downstream distribution of
`vercel-labs/fx`: upstream remains the technical base, while fxXL carries a
small, explicit patch stack for OpenAI-compatible inference and fork-owned
distribution.

The result must install with one Linux command, update only from fxXL releases,
and remain straightforward to rebase onto future upstream changes.

## Current-State Evidence

The fork currently diverges from its merge base at upstream commit
`d00dcda52ec70bac5e3b148e17b4c7d2ad8573cf` by 33 files, 2,912 insertions, and
25 deletions. Most of that surface is additive:

- 2,476 lines live in five new provider-specific modules.
- Existing source files generally contain small enum, routing, persistence, or
  presentation hooks.
- Seven fork-touched files also changed between the merge base and the current
  upstream `main`.
- A real rebase rehearsal of all eight fork commits onto upstream `main` on
  2026-08-28 completed without conflicts.

The provider implementation is therefore structurally suitable for a
downstream patch. The present distribution and governance are not:

- `AGENTS.md` still says every repository URL must identify upstream.
- The release workflows depend on upstream-only Vercel Blob and Apple signing
  secrets.
- No fork-owned `setup.sh` exists.
- The in-product updater still downloads upstream artifacts.
- The README contains contradictory fork and upstream installation commands.
- Six documentation commits represent churn rather than durable patch
  boundaries.

## Downstream Model

The maintained state is defined as:

```text
verified upstream base
  + OpenAI-compatible provider patch
  + fxXL distribution patch
  + fxXL governance and documentation patch
```

Upstream code is never copied into a disconnected repository. The Git remote
named `upstream` identifies `https://github.com/vercel-labs/fx.git`. Updates are
integrated by rebasing the fxXL patch stack onto a reviewed upstream commit.

The first maintenance conversion may rewrite the existing eight fork commits
into coherent patches. Before that rewrite, the exact current state
`8da0fe89da2bdd0875869a54b551ed8d808e35c1` must receive a durable archival Git
reference. Subsequent changes must not rewrite published fxXL release tags.

## Patch Boundaries

### OpenAI-Compatible Provider Patch

Owns only the generic OpenAI-compatible provider and the smallest required
integration hooks. Its contract is:

- The user explicitly supplies the base URL.
- HTTPS is accepted for external endpoints.
- Plain HTTP is accepted for loopback hosts only: `localhost`, `127.0.0.1`, and
  `::1`.
- The endpoint exposes `GET /models` and `POST /chat/completions` beneath the
  supplied base URL.
- A stored credential is scoped to its base URL and never sent to upstream
  services.
- No vendor, including OpenRouter, is the architectural owner of this route.
  Vendors are examples only.

Provider-specific modules remain separate from upstream gateway modules. Hooks
inside upstream-owned files must stay small and typed.

### fxXL Distribution Patch

Owns everything that makes fxXL installable and updateable without upstream
infrastructure:

- Fork release identity and version.
- Linux release workflow.
- Release manifest and checksums.
- `setup.sh`.
- Stable auto-update and `fx upgrade` release source.

This patch must never require `releases.fx.sh`, Vercel Blob, an upstream
deployment hook, upstream credentials, or Apple signing credentials.

### Governance and Documentation Patch

Owns downstream maintenance rules, installation instructions, external and
local inference examples, release instructions, and upstream synchronization
procedure. It must clearly distinguish upstream documentation links from fxXL
installation and release links.

## Release Architecture

GitHub Releases in `jcd3dr/fxXL` are the only production artifact authority.
The initial supported release targets are:

- `linux-x86_64`
- `linux-aarch64`

Each stable release contains:

- `fx-linux-x86_64.tar.gz`
- `fx-linux-x86_64.tar.gz.sha256`
- `fx-linux-aarch64.tar.gz`
- `fx-linux-aarch64.tar.gz.sha256`
- `manifest.json`

`manifest.json` contains a bounded schema with the fxXL release version, the
upstream base commit, the fxXL source commit, and the supported artifact names.
The stable manifest is retrieved through GitHub's latest-release asset URL:

```text
https://github.com/jcd3dr/fxXL/releases/latest/download/manifest.json
```

Artifacts and checksums use the same latest-release URL family. Redirects are
accepted only from GitHub-controlled HTTPS origins. Checksums are mandatory
before extraction or replacement.

The workflow uses the repository-provided `GITHUB_TOKEN` with `contents: write`.
It does not require new external accounts or repository secrets. Stable release
publication is serialized and happens only after required build and test jobs
succeed.

The fork release version is independent from the upstream application version.
It is stored outside `src/main.zig`, so upstream version changes do not create a
routine merge conflict. A release records both versions and both commits.

The fork initially supports only the stable update channel. Any existing dev
channel command must fail explicitly as unsupported by this downstream
distribution rather than silently consulting upstream infrastructure.

## Installer Contract

The canonical installation command is:

```bash
curl -fsSL https://raw.githubusercontent.com/jcd3dr/fxXL/main/setup.sh | bash
```

`setup.sh` is a generic Linux installer, not a WSL-specific installer. It:

1. Requires Linux and maps `x86_64` or `aarch64` to the release artifact.
2. Requires a supported downloader, `tar`, and a SHA-256 verification tool.
3. Downloads the latest fxXL release manifest, archive, and checksum over
   HTTPS.
4. Verifies the checksum before extraction.
5. Installs atomically into `${FX_INSTALL_DIR:-$HOME/.local/bin}` without
   requiring root.
6. Preserves an existing executable until the replacement has been verified.
7. Runs the installed binary with `--version` and reports the exact path.
8. Provides actionable errors for unsupported systems, missing tools, download
   failures, checksum failures, and unwritable destinations.

The script supports bounded environment overrides for deterministic tests, but
production defaults always identify `jcd3dr/fxXL`.

## Updater Contract

The updater reuses the same release manifest and artifact naming contract as
`setup.sh`. It must:

- Compare the embedded current fxXL release version with the latest manifest.
- Download only a newer stable fxXL release.
- Verify the archive checksum before replacing the current executable.
- Preserve the existing transactional replacement and resume behavior.
- Never contact an upstream release origin.
- Report the fork release version and upstream base in status output where
  practical.

The release origin belongs in a focused distribution module rather than being
scattered through provider or application logic.

## Agent Governance

`AGENTS.md` remains the mandatory instruction file and receives a leading
section named `fxXL Downstream Fork Policy`. It overrides incompatible upstream
instructions while preserving upstream engineering standards.

Every agent must:

- Treat upstream as the base and fxXL changes as a minimal patch stack.
- Inspect the merge base and patch surface before changing upstream-owned code.
- Prefer new fork-owned modules over broad edits to upstream modules.
- Keep provider, distribution, and documentation concerns in separate commits.
- Never point installation, release, or update behavior back to upstream.
- Never merge or rebase upstream changes without recording the selected base
  commit and running the required validation.
- Drop a downstream patch when upstream fully supersedes it; reduce the patch
  when upstream partially supersedes it.
- Preserve Apache-2.0 notices and upstream attribution.
- Avoid unrelated cleanup while resolving an upstream synchronization.
- Use `--force-with-lease`, never an unconditional force push, if an approved
  patch-stack rebase requires updating the fork branch.

The policy includes the exact synchronization and release checklist. Any
upstream statement that `vercel-labs/fx` is the canonical repository is
interpreted as canonical for the base project, not as authority for fxXL
installation or distribution URLs.

## Documentation Contract

The README presents, in order:

1. fxXL's relationship to upstream.
2. The one-command installation from fxXL.
3. Running the installed binary.
4. Generic external OpenAI-compatible configuration.
5. Loopback HTTP examples, including Ollama at
   `http://localhost:11434/v1`.
6. Updating through `fx upgrade` from fxXL.
7. Building from source from `jcd3dr/fxXL` as an advanced alternative.

The Windows document only explains that the same Linux installer is run inside
an existing WSL distribution and that a PowerShell wrapper is optional. It does
not redefine the installer or make WSL part of the product architecture.

## Validation

Implementation is acceptable only when all of the following evidence exists:

- Focused Zig tests prove manifest parsing, version comparison, origin
  selection, stable download selection, checksum failure, and unsupported dev
  channel behavior.
- Installer tests prove architecture selection, successful installation,
  checksum rejection, and preservation of an existing binary on failure.
- The Linux release workflow is statically validated and builds both target
  archives with matching checksums and manifest entries.
- `zig fmt --check src/` passes.
- `zig build test -Doptimize=ReleaseSafe` passes locally where resources allow.
- `zig build -Doptimize=ReleaseSafe` succeeds.
- The freshly built `./zig-out/bin/fx` exercises the changed status or upgrade
  path without startup failure or unexpected stderr.
- A rebase rehearsal onto the selected current upstream commit completes, or
  every conflict is documented and resolved within the smallest affected
  downstream patch.
- GitHub CI passes for the exact release commit.
- A published release is installed into a temporary clean directory through
  the canonical `setup.sh` command before the release is declared usable.

## Non-Goals

- Creating a Windows-native executable or Windows-specific installer.
- Operating a custom CDN or release website.
- Adding vendor-specific providers when the generic compatibility route is
  sufficient.
- Automatically merging upstream without review.
- Supporting macOS release signing in the initial fxXL distribution.
- Rewriting or republishing upstream release tags.

## Recovery and Continuity

The specification, implementation plan, and work progress live in Git on the
`maintenance/fork-distribution` branch. Commits are made at independently
verifiable boundaries. The repository, not the chat session, is the durable
source of truth for continuing the work.
