# Decisions and Architecture Decision Records (ADRs)

This is the canonical index of recorded material decisions for fxXL. In this
repository, **decision record** and **architecture decision record (ADR)** refer
to the same durable responsibility: preserving a consequential choice, its
rationale, status, and effects so later contributors do not have to reconstruct
it from code or private conversations.

| Record | Status | Decision |
| --- | --- | --- |
| [`0001-downstream-patch-stack.md`](0001-downstream-patch-stack.md) | Accepted | Maintain fxXL as a reviewed upstream base plus explicit downstream patches. |
| [`0002-fork-owned-distribution.md`](0002-fork-owned-distribution.md) | Accepted | Use GitHub Releases in `jcd3dr/fxXL` as the production artifact authority. |

Each record declares its own status and scope. If a material decision changes,
preserve the earlier rationale and make the supersession explicit rather than
silently rewriting history. Current implementation or continuation issues that
do not change a decision belong in [`../state/current.md`](../state/current.md),
not in this index.
