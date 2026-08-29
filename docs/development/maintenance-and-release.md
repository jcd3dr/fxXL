# Maintenance and Release Procedures

This document routes existing procedures and records fxXL-specific operational
steps. It does not grant permission to synchronize upstream, rewrite history,
publish releases, or modify runtime behavior.

## Local development

Requirements and general build commands are maintained in
[`../../CONTRIBUTING.md`](../../CONTRIBUTING.md). The primary native commands
are:

```bash
zig fmt --check src/
zig build -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

Use focused tests while developing. For implementation changes, run the freshly
built `./zig-out/bin/fx` through the affected happy path before claiming the
change is ready. Documentation verification complements, and does not override,
the readiness rules in `AGENTS.md`.

## Inspecting the downstream patch surface

Before changing upstream-owned code:

```bash
base=$(tr -d '[:space:]' < UPSTREAM_BASE)
git diff --stat "$base"..HEAD
git diff --name-status "$base"..HEAD
```

Treat provider, distribution, and governance documentation as separate patch
concerns. Prefer focused fxXL-owned modules over broad changes to upstream
modules.

## Upstream integration

Perform these steps only after explicit maintainer authorization:

1. Configure `upstream` as `https://github.com/vercel-labs/fx.git` if it is not
   already present.
2. Fetch and review the upstream range beginning at the commit in
   `UPSTREAM_BASE`.
3. Select the new upstream base deliberately.
4. Rebase the downstream patch stack and resolve each conflict within the
   smallest owning concern.
5. Remove patches fully superseded upstream and reduce partially superseded
   patches.
6. Update `UPSTREAM_BASE` to the exact selected commit.
7. Run provider, distribution, formatting, build, test, and manual runtime
   validation required by `AGENTS.md` and
   [`../validation/evidence.md`](../validation/evidence.md).
8. Rehearse the next rebase before considering the integration maintainable.
9. Update architecture, decisions, state, procedures, and validation knowledge
   actually affected by the integration.

If an approved patch-stack rebase requires rewriting a remote downstream
branch, use `git push --force-with-lease`. Never use an unconditional force
push and never rewrite a published release tag.

## Stable release

1. Confirm the intended source commit and that exact-commit required CI is
   green.
2. Update `FXXL_VERSION` in a reviewed commit when publishing a new version.
3. Push the intended commit to `main`; `.github/workflows/release.yml` is the
   current release publisher.
4. Verify that the workflow produced `manifest.json`, both Linux archives, and
   both checksum files under `fxxl-vX.Y.Z`.
5. Install the exact published release into a temporary clean directory through
   the canonical `setup.sh` command.
6. Run the installed binary and verify its reported version and basic behavior.
7. Record any changed release baseline or unresolved failure in
   [`../state/current.md`](../state/current.md).

Do not declare a release usable from a tag, successful build, or checksum alone.

## DARS maintenance routing

| Material change | Knowledge to review |
| --- | --- |
| Project purpose, users, or downstream scope | Project and requirements |
| Provider endpoint, credential, or capability behavior | Requirements, architecture, decisions if rationale changed, state, validation |
| Installer, updater, manifest, target, or release workflow | Requirements, architecture, decisions if authority changed, development, state, validation |
| Upstream base integration | Architecture, decisions, development, state, validation |
| Test, CI, release, or external publishing result | State and validation |
| Documentation organization or authority | `docs/README.md`, affected canonical sources, and entry routes |

Historical implementation plans are not current progress trackers. Preserve
them as historical evidence and update the canonical current sources instead.
