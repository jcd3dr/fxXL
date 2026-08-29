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

Root `README.md` remains the user-facing project orientation. Root `AGENTS.md`
is the canonical cross-agent repository contract and routes here for deeper
knowledge. Vendor-specific instruction files are compatibility bridges only and
must route to `AGENTS.md` rather than duplicate repository policy.

## Repository document roles and authority

The role of a document is determined by this routing and its declared scope,
not by filename, length, recency, directory pattern, discovery order, or by an
agent runtime loading it automatically.

| Source | Role and authority |
| --- | --- |
| `AGENTS.md` | Canonical repository-wide contract for AI agents, including critical boundaries, working rules, DARS routing, and maintenance obligations. |
| `README.md` | User-facing product orientation, installation, usage, and public behavior. It does not replace the agent contract or contribution procedures. |
| `CONTRIBUTING.md` | Canonical detailed source for contribution, development, testing, collaboration, and PR procedures where those procedures are not fully restated in `AGENTS.md`. It is task-relevant detail reached through the repository contract, not the repository-wide authority for every kind of knowledge. |
| `UPSTREAM_BASE` | Authoritative machine-readable marker of the exact reviewed upstream baseline for the downstream patch stack. |
| `docs/README.md` | Canonical router for deeper durable DARS knowledge and the roles of overlapping documentation. |
| `docs/state/current.md` | Canonical source for time-sensitive continuation state, blockers, current baseline, and unresolved obligations. |
| `docs/superpowers/` | Historical task/design artifacts. They may provide evidence of past reasoning but do not define current repository-wide workflow or policy unless a current canonical source explicitly adopts that rule. |
| subsystem README/AGENTS files | Authoritative only within their declared subsystem scope unless a repository-wide source explicitly gives them broader authority. |

When `AGENTS.md` gives a repository-wide rule and `CONTRIBUTING.md` provides
more detailed procedure for the same topic, use `AGENTS.md` for the governing
boundary and `CONTRIBUTING.md` for the procedure within that boundary. If the
two materially disagree, do not silently choose one; surface the contradiction
and determine whether scope, freshness, or maintainer authority resolves it.

## Authority rules

Repository implementation and configuration are evidence of current behavior.
The requirement and decision records define recorded downstream intent, but
they must not be used to claim unimplemented behavior. `state/current.md` owns
time-sensitive continuation facts. Dated documents under `superpowers/` record
the design and implementation process that produced the current downstream
patches; they are historical evidence and are not current status.

Do not promote an inference into repository policy merely because a convention
looks familiar. In particular, the existence of `CONTRIBUTING.md`, dated plans,
repeated directory patterns, CI workflows, branch names, or previous task files
proves that those artifacts exist; it does not by itself establish a universal
repository rule beyond the scope declared by canonical routing.

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
