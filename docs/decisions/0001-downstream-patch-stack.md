# Decision 0001: Maintain fxXL as a Downstream Patch Stack

**Status:** Accepted

## Context

fxXL needs upstream improvements from `vercel-labs/fx` while retaining generic
OpenAI-compatible inference and fork-owned distribution. A disconnected copy
would make upstream integration opaque and expensive. Broad edits to upstream
modules would also increase recurring conflict cost.

## Decision

Maintain the repository as a reviewed upstream base plus explicit downstream
patches. Record the selected base in `UPSTREAM_BASE`. Prefer focused fxXL-owned
modules and keep hooks in upstream-owned files small. Separate provider,
distribution, and governance concerns so an upstream change can supersede or
conflict with one concern without forcing unrelated patches to be rebuilt.

Upstream integration is a reviewed maintenance operation, not an automatic
update. A history rewrite required to rebase a downstream patch stack needs
explicit maintainer approval and `git push --force-with-lease`; unconditional
force pushes are forbidden.

## Consequences

Future contributors must inspect both `UPSTREAM_BASE` and the downstream diff
before modifying upstream-owned files. Upstream adoption may still create
conflicts, but their scope remains attributable. If upstream implements a
downstream capability, the corresponding fxXL patch must be removed or reduced
rather than retained by inertia.

The original detailed rationale is preserved in the dated
[`../superpowers/specs/2026-08-28-fork-maintenance-and-distribution-design.md`](../superpowers/specs/2026-08-28-fork-maintenance-and-distribution-design.md).
That file is historical evidence, not current status.
