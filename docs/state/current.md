# Current Project State

**Last evidence review:** 2026-08-29 UTC

This file is the canonical continuation record. Update it when the baseline,
active objective, blockers, release state, or material unresolved obligations
change.

## Baseline

Before the DARS documentation commit, both `origin/main` and
`origin/maintenance/fork-distribution` resolved to
`5ab777ac58ed0b12ccaeb04b3da03dda949f7b5f`. This DARS adoption is intentionally
being committed only to `maintenance/fork-distribution`; it does not change
`main`.

The recorded upstream base is
`1b87677de6ff787ac0ce19a88dc1ca8a860a25d3`. No upstream synchronization was
performed during DARS adoption.

The recorded fxXL version is `0.1.0`. GitHub Release `fxxl-v0.1.0` was published
from `0c7e239ae480214859962978302db772a4d8072d` with the manifest, Linux x86_64
archive and checksum, and Linux aarch64 archive and checksum required by the
distribution contract.

Commit `5ab777ac58ed0b12ccaeb04b3da03dda949f7b5f` is newer than that release tag.
No repository evidence records whether its distribution-version contract
changes require a later fxXL release. Because `FXXL_VERSION` remains `0.1.0`
and the corresponding tag already exists, the release workflow does not
publish that commit as a new fxXL version.

## Known validation failures at the pre-DARS baseline

The exact pre-DARS commit is not fully green:

* Full CI run `33210726747` failed. All native ReleaseSafe jobs passed, but the
  shard containing `tui-startup.test.ts` timed out on its first attempt and
  bounded retry on Linux x86_64, Linux aarch64, macOS x86_64, and macOS
  aarch64. Repository evidence does not establish whether the cause is a
  product defect, test defect, or environment interaction.
* Publish libfx run `33212215313` built all four native packages and both WASM
  surfaces, then failed publishing `libfx@0.0.6-dev.3.g5ab777ac58ed` with npm
  `E404`, reporting that the package was unavailable or the workflow lacked
  permission. Whether this fork intends to publish `libfx` is not recorded as
  a maintainer decision.

These failures are documentation findings, not authorization to modify source,
tests, CI, credentials, or package ownership.

## Open obligations

1. Resolve or explicitly classify the cross-platform `tui-startup.test.ts`
   Full CI failure before declaring a later implementation commit ready.
2. Decide whether fxXL is intended to publish `libfx`. If yes, establish the
   required npm package ownership or permission; if no, make that product and
   workflow decision explicit before changing automation.
3. Decide whether the post-release change at `5ab777a` requires a new fxXL
   release version.
4. Keep `UPSTREAM_BASE` unchanged until a separately authorized upstream review
   and integration is completed.

## Historical material

The dated specification and plan under `docs/superpowers/` explain how the
current patch stack was designed and implemented. Their unchecked task boxes
are not evidence that implementation remains pending. Use Git history,
implementation, current CI, releases, and this file for present state.
