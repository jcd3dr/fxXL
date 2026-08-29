# Validation Evidence

Validation is layered. No single automated result proves semantic correctness,
release usability, or DARS continuity.

## Existing proof surfaces

| Surface | Evidence it can provide | What it does not prove |
| --- | --- | --- |
| Zig unit tests through `zig build test` | Contracts and behavior exercised by compiled test blocks | Full terminal startup, live provider behavior, or published artifact usability |
| `scripts/test-setup.sh` | Installer architecture selection, checksum behavior, and replacement scenarios encoded by the script | A real published release is reachable and usable |
| Deterministic Bun E2E tests | CLI, ACP, MCP, TUI, session, permission, and other runtime scenarios in the selected files | Credentialed live model behavior or every terminal environment |
| `zig fmt --check src/` | Zig formatting compliance | Build or runtime correctness |
| `scripts/check-public-surface.sh` | The public-surface constraints encoded by that script | Internal semantic correctness |
| Standard CI | Its declared matrix of formatting, builds, tests, and selected E2E checks | Full CI or manual ship-gate completion |
| Full CI | Native ReleaseSafe checks and all deterministic E2E shards on four supported runner architectures | Live evals, published artifact installation, or product intent |
| Release workflow | Version validation, tests, Linux archives, checksums, manifest, and GitHub Release publication when all jobs succeed | The installed release's end-to-end usability |
| Manual built-binary exercise | The selected happy path starts and behaves in the tested environment | Other platforms or untested paths |
| Clean-directory release installation | The exact published artifacts can be installed and started through the supported path | Unrelated runtime capabilities |

The detailed implementation gates in `AGENTS.md` and `CONTRIBUTING.md` remain
applicable. Current failures and unresolved interpretation belong in
[`../state/current.md`](../state/current.md), not in this stable evidence map.

## Documentation-only verification

For DARS documentation work:

1. Confirm the diff contains only documentation paths authorized by the task.
2. Run `git diff --check`.
3. Run the bundled DARS structural verifier.
4. Resolve every relative Markdown route from `README.md`, `AGENTS.md`, and the
   DARS documents.
5. Confirm the seven knowledge responsibilities are discoverable from normal
   entry points.
6. Review semantic fidelity against repository evidence and keep unknowns or
   contradictions explicit.

Structural verification cannot prove semantic DARS conformance. A contributor
must still confirm that the repository can be continued without the private
conversation that produced the documentation.

## Current baseline warning

The pre-DARS commit `5ab777ac58ed0b12ccaeb04b3da03dda949f7b5f` did not pass
Full CI or Publish libfx. See the current-state record for the exact observed
failures. Do not use a successful subset of jobs to describe that commit as
fully green.
