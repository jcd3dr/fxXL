# fxXL Project Knowledge

This index is the canonical router for durable fxXL repository knowledge. It
implements the DARS lifecycle without requiring contributors to know DARS in
advance.

## Knowledge map

| Responsibility | Canonical source | Use it for |
| --- | --- | --- |
| Project | [`project/overview.md`](project/overview.md) | Purpose, scope, users, terminology, and authority |
| Requirements | [`requirements/fork-contract.md`](requirements/fork-contract.md) | Downstream behavior, distribution constraints, and non-goals |
| Architecture | [`architecture/fork-architecture.md`](architecture/fork-architecture.md) | Current component boundaries, flows, state, and trust boundaries |
| Decisions | [`decisions/`](decisions/) | Material choices and rationale that must survive future upstream integrations |
| State | [`state/current.md`](state/current.md) | Current baseline, known failures, unresolved obligations, and next safe continuation point |
| Development and operations | [`development/maintenance-and-release.md`](development/maintenance-and-release.md) | Setup, patch maintenance, upstream integration, installation, and release procedures |
| Validation evidence | [`validation/evidence.md`](validation/evidence.md) | Tests, CI, release evidence, and the limits of each check |

Root `README.md` remains the user-facing entry point. Root `AGENTS.md` remains
the mandatory agent contract and routes here for deeper knowledge.

## Authority rules

Repository implementation and configuration are evidence of current behavior.
The requirement and decision records define recorded downstream intent, but
they must not be used to claim unimplemented behavior. `state/current.md` owns
time-sensitive continuation facts. Dated documents under `superpowers/` record
the design and implementation process that produced the current downstream
patches; they are historical evidence and are not current status.

If sources disagree, preserve and record the disagreement. Do not silently
choose the most convenient source or rewrite code, tests, CI, or release
configuration during documentation-only work.

## Maintenance cycle

After a material change:

1. Identify which knowledge responsibilities are affected.
2. Update only their canonical sources.
3. Update current state when the continuation point or blockers changed.
4. Verify local routes, documentation integrity, and semantic fidelity.
5. Keep uncertainties explicit when repository evidence cannot resolve them.
