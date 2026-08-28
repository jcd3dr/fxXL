# fxXL Fork Maintenance and Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make fxXL a maintainable downstream patch stack with fork-owned Linux releases, a one-command installer, fork-only upgrades, and mandatory agent governance.

**Architecture:** Preserve upstream as the code base and isolate fxXL behavior into three logical patches: OpenAI-compatible inference, GitHub Release distribution, and downstream governance/documentation. A bounded release manifest becomes the shared contract between GitHub Actions, `setup.sh`, and the Zig updater.

**Tech Stack:** Zig 0.16, POSIX shell, GitHub Actions, GitHub Releases, SHA-256, Git.

**Spec:** `docs/superpowers/specs/2026-08-28-fork-maintenance-and-distribution-design.md`

## Global Constraints

- Production installation, release, and update URLs identify `jcd3dr/fxXL`, never `vercel-labs/fx` or `releases.fx.sh`.
- External OpenAI-compatible endpoints require HTTPS; loopback endpoints may use HTTP.
- The release process initially supports Linux x86_64 and Linux aarch64.
- No Vercel Blob, Apple signing, new external account, or external secret is required.
- Fork release versioning is independent from `src/main.zig` upstream versioning.
- Every behavior change follows red-green-refactor and every completed task ends in a focused commit.
- Upstream source changes remain minimal; new fork-specific behavior prefers focused new files.

---

### Task 1: Normalize the Downstream Base and Persist Governance

**Files:**
- Modify: `AGENTS.md`
- Create: `UPSTREAM_BASE`
- Preserve: Git reference `archive/pre-fxxl-distribution`

**Interfaces:**
- Consumes: upstream remote `https://github.com/vercel-labs/fx.git` and current fork commit `8da0fe89da2bdd0875869a54b551ed8d808e35c1`.
- Produces: a clean branch based on the selected upstream commit plus the provider patch and durable downstream rules.

- [ ] **Step 1: Record the exact current fork state**

```bash
git tag archive/pre-fxxl-distribution 8da0fe89da2bdd0875869a54b551ed8d808e35c1
git remote get-url upstream
git fetch upstream main --tags
```

Expected: the archive tag resolves to `8da0fe8...` and `upstream/main` is current.

- [ ] **Step 2: Rebuild the maintenance branch as a patch stack**

Reset only `maintenance/fork-distribution` to `upstream/main`, then replay:

```text
1250f656f0f104016f57812e17d594d5fca13d69  OpenAI-compatible provider
6b0dec4                                      worktree ignore
b79516a                                      approved design
<this plan commit>                           implementation plan
```

Do not alter `main` or any published release tag during this step.

- [ ] **Step 3: Add the downstream policy to `AGENTS.md`**

Prepend `## fxXL Downstream Fork Policy` with these enforceable rules:

```text
upstream is the technical base; origin is the fxXL distribution
keep provider, distribution, and documentation patches separate
record the selected upstream commit in UPSTREAM_BASE
never restore upstream install, release, or update origins
rebase only after an explicit upstream review
drop or reduce patches superseded by upstream
validate provider behavior, installer behavior, and fork release origin
use force-with-lease only after explicit maintainer approval
```

Replace the incompatible repository-identity paragraph so upstream is canonical for base engineering while `jcd3dr/fxXL` is canonical for fxXL artifacts.

- [ ] **Step 4: Persist the upstream base**

Write exactly the selected 40-character upstream commit plus a trailing newline to `UPSTREAM_BASE`.

- [ ] **Step 5: Verify and commit**

```bash
git diff --check
rg -n "fxXL Downstream Fork Policy|UPSTREAM_BASE|releases.fx.sh" AGENTS.md UPSTREAM_BASE
git add AGENTS.md UPSTREAM_BASE
git commit -m "docs: establish fxXL downstream maintenance policy"
```

Expected: policy is present, base SHA is exact, and `releases.fx.sh` appears only in a prohibition.

---

### Task 2: Define Fork Release Identity and Manifest

**Files:**
- Create: `FXXL_VERSION`
- Create: `src/core/upgrade/fork_release.zig`
- Modify: `build.zig`
- Modify: `src/main.zig`

**Interfaces:**
- Produces: `fork_release.Manifest.parse(alloc, bytes)`, `fork_release.assetUrl(alloc, base, platform)`, `fork_release.checksumUrl(alloc, base, platform)`, and build option `fork_version`.
- Consumes: strict `MAJOR.MINOR.PATCH` version text and schema version `1`.

- [ ] **Step 1: Write failing manifest and URL tests**

Tests in `fork_release.zig` must assert:

```zig
const manifest = try Manifest.parse(
    std.testing.allocator,
    "{\"schema_version\":1,\"version\":\"0.1.0\",\"upstream_commit\":\"0123456789abcdef0123456789abcdef01234567\",\"source_commit\":\"abcdef0123456789abcdef0123456789abcdef01\"}",
);
try std.testing.expectEqualStrings("0.1.0", manifest.version);
try std.testing.expectEqualStrings(
    "https://github.com/jcd3dr/fxXL/releases/latest/download/fx-linux-x86_64.tar.gz",
    try assetUrl(std.testing.allocator, production_base, "linux-x86_64"),
);
```

Also reject unknown schema versions, malformed SemVer, non-hex or non-40-character commits, oversized input, and unsupported platform strings.

- [ ] **Step 2: Run the focused test and confirm RED**

```bash
zig build test -Doptimize=ReleaseSafe
```

Expected: compilation fails because `fork_release.zig` behavior is not implemented.

- [ ] **Step 3: Implement the bounded manifest module**

Use `std.json.parseFromSlice`, duplicate all retained strings, cap input at 4 KiB, and expose:

```zig
pub const production_base = "https://github.com/jcd3dr/fxXL/releases/latest/download";
pub const Manifest = struct {
    version: []u8,
    upstream_commit: []u8,
    source_commit: []u8,
    pub fn parse(alloc: Allocator, bytes: []const u8) !Manifest;
    pub fn deinit(self: *Manifest, alloc: Allocator) void;
};
pub fn assetUrl(alloc: Allocator, base: []const u8, platform: []const u8) ![]u8;
pub fn checksumUrl(alloc: Allocator, base: []const u8, platform: []const u8) ![]u8;
pub fn manifestUrl(alloc: Allocator, base: []const u8) ![]u8;
```

- [ ] **Step 4: Embed the fork version**

Write `0.1.0` to `FXXL_VERSION`. Extend `build.zig` with a bounded file reader equivalent to `readAppVersion` and add `fork_version` to every build-options module. Use it in `currentBuild()` without changing upstream's `pub const version`.

- [ ] **Step 5: Run focused verification and commit**

```bash
zig fmt src/core/upgrade/fork_release.zig src/main.zig build.zig
zig build test -Doptimize=ReleaseSafe
git add FXXL_VERSION build.zig src/main.zig src/core/upgrade/fork_release.zig
git commit -m "feat: define fxXL release identity"
```

---

### Task 3: Route Stable Upgrades Exclusively Through fxXL

**Files:**
- Modify: `src/core/upgrade/upgrade_helpers.zig`
- Modify: `src/core/upgrade/upgrade_runtime.zig`
- Modify: `src/core/upgrade/auto_upgrade.zig`
- Modify: `src/core/upgrade/update_target.zig`
- Modify: `src/core/cli/cli_surface.zig`
- Test: focused tests inside the modified Zig files

**Interfaces:**
- Consumes: latest-release `manifest.json` and fixed platform artifact names.
- Produces: stable fork-only upgrade behavior; explicit `dev` channel rejection.

- [ ] **Step 1: Write failing origin and manifest tests**

Replace the existing production-domain assertion with:

```zig
try std.testing.expectEqualStrings(
    "https://github.com/jcd3dr/fxXL/releases/latest/download",
    resolveReleaseBase(),
);
```

Add tests proving stable target resolution uses `manifest.json`, archive and checksum URLs contain no version directory, and `.dev` returns `error.UnsupportedChannel` before network I/O.

- [ ] **Step 2: Verify RED**

```bash
zig build test -Doptimize=ReleaseSafe
```

Expected: old CDN layout or missing release-manifest logic causes failure.

- [ ] **Step 3: Replace the CDN layout**

Rename the production concept from CDN to release base. Stable fetch downloads
and parses `manifest.json`; archive and checksum URLs use
`fork_release.assetUrl` and `fork_release.checksumUrl`. Keep the loopback E2E
override for deterministic tests. Remove every production reference to
`releases.fx.sh`.

- [ ] **Step 4: Preserve transactional replacement and reject dev**

Do not change checksum verification, extraction, binary replacement, resume,
or progress ownership. Return the explicit message
`the dev update channel is not published by fxXL` for `.dev`.

- [ ] **Step 5: Verify and commit**

```bash
zig fmt src/core/upgrade src/core/cli/cli_surface.zig
zig build test -Doptimize=ReleaseSafe
rg -n "releases\.fx\.sh|vercel-labs/fx" src/core/upgrade
git add src/core/upgrade src/core/cli/cli_surface.zig
git commit -m "fix: route fxXL upgrades through fork releases"
```

Expected: tests pass and the final `rg` returns no production origin reference.

---

### Task 4: Build the One-Command Linux Installer

**Files:**
- Create: `setup.sh`
- Create: `scripts/test-setup.sh`

**Interfaces:**
- Consumes: latest-release manifest, platform archive, and SHA-256 file.
- Produces: executable installed at `${FX_INSTALL_DIR:-$HOME/.local/bin}/fx`.

- [ ] **Step 1: Write the failing shell test harness**

The harness creates a temporary fake release, stubs `uname`, and invokes
`setup.sh` with `FXXL_RELEASE_BASE_URL=file://...` and a temporary
`FX_INSTALL_DIR`. It must cover:

```text
linux x86_64 selects fx-linux-x86_64.tar.gz
linux aarch64 selects fx-linux-aarch64.tar.gz
valid checksum installs and runs the candidate
invalid checksum leaves an existing fx byte-for-byte unchanged
unsupported OS or architecture exits nonzero
```

- [ ] **Step 2: Verify RED**

```bash
sh scripts/test-setup.sh
```

Expected: FAIL because `setup.sh` does not exist.

- [ ] **Step 3: Implement `setup.sh`**

Use `set -eu`, `mktemp -d`, a cleanup trap, HTTPS production defaults, curl or
wget fallback, `sha256sum` or `shasum -a 256`, tar extraction, executable
validation with `--version`, and atomic same-directory rename. Never use sudo,
never delete the existing binary before candidate validation, and never print
credentials.

- [ ] **Step 4: Verify GREEN and static syntax**

```bash
sh -n setup.sh scripts/test-setup.sh
sh scripts/test-setup.sh
```

- [ ] **Step 5: Commit**

```bash
git add setup.sh scripts/test-setup.sh
git commit -m "feat: install fxXL from GitHub Releases"
```

---

### Task 5: Replace Upstream Release Automation

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/dev-release.yml`
- Modify: `.github/workflows/cdn-backfill.yml`
- Modify: `.github/workflows/prepare-release.yml`

**Interfaces:**
- Consumes: `FXXL_VERSION`, `UPSTREAM_BASE`, exact GitHub source SHA.
- Produces: Linux archives, checksums, `manifest.json`, tag `fxxl-v<FXXL_VERSION>`, and a GitHub Release in `jcd3dr/fxXL`.

- [ ] **Step 1: Add a failing workflow contract check**

Create a temporary validation command in the development loop that requires:

```bash
rg -q 'FXXL_VERSION' .github/workflows/release.yml
! rg -n 'BLOB_READ_WRITE_TOKEN|APPLE_|releases\.fx\.sh|vercel-storage' .github/workflows/release.yml
```

Confirm it fails against the existing workflow.

- [ ] **Step 2: Reduce stable release automation to fork-owned Linux releases**

The workflow must run tests, build both Linux targets, package the documented
assets, generate checksums and manifest, create the version tag, and publish a
GitHub Release using only `GITHUB_TOKEN` with `contents: write`.

- [ ] **Step 3: Disable unsupported upstream publication paths explicitly**

Make dev release, CDN backfill, and AI-generated release preparation manual-only
or replace their executable bodies with a clear fxXL unsupported notice. They
must not run automatically and must not reference unavailable upstream secrets.

- [ ] **Step 4: Validate YAML and contract**

```bash
ruby -e 'require "yaml"; Dir[".github/workflows/*.yml"].each { |f| YAML.load_file(f) }'
rg -q 'FXXL_VERSION' .github/workflows/release.yml
! rg -n 'BLOB_READ_WRITE_TOKEN|APPLE_|vercel-storage' .github/workflows/release.yml
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows
git commit -m "ci: publish fxXL Linux releases on GitHub"
```

---

### Task 6: Correct User and Maintainer Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/windows-wsl.md`
- Modify: `CONTRIBUTING.md`

**Interfaces:**
- Consumes: canonical installer, provider contract, updater behavior, and downstream policy.
- Produces: one coherent installation and maintenance story.

- [ ] **Step 1: Write documentation assertions**

```bash
rg -q 'raw.githubusercontent.com/jcd3dr/fxXL/main/setup.sh' README.md
rg -q 'http://localhost:11434/v1' README.md
! rg -n 'git clone https://github.com/vercel-labs/fx.git' README.md docs/windows-wsl.md
rg -q 'upstream/main' CONTRIBUTING.md
```

Confirm at least the installer and maintenance assertions fail before editing.

- [ ] **Step 2: Rewrite installation and inference sections**

Make `setup.sh | bash` primary, source compilation advanced, OpenAI-compatible
inference generic, OpenRouter an example, and Ollama a loopback HTTP example.
Describe `fx upgrade` as fork-owned.

- [ ] **Step 3: Reduce the WSL document to an execution environment note**

The same Linux installer runs inside WSL. Retain the optional PowerShell
function but remove source-build duplication.

- [ ] **Step 4: Document upstream synchronization for maintainers**

Add the reviewed fetch, rebase, conflict-resolution, base-SHA update, focused
validation, and release sequence to `CONTRIBUTING.md`.

- [ ] **Step 5: Verify and commit**

```bash
git diff --check
rg -q 'raw.githubusercontent.com/jcd3dr/fxXL/main/setup.sh' README.md
rg -q 'http://localhost:11434/v1' README.md
! rg -n 'git clone https://github.com/vercel-labs/fx.git' README.md docs/windows-wsl.md
git add README.md docs/windows-wsl.md CONTRIBUTING.md
git commit -m "docs: document fxXL installation and maintenance"
```

---

### Task 7: End-to-End Verification and Publication Readiness

**Files:**
- Modify only files required by proven verification failures.

**Interfaces:**
- Consumes: complete patch stack.
- Produces: evidence for local correctness and a pushed branch ready for GitHub CI and first release publication.

- [ ] **Step 1: Run repository checks**

```bash
zig fmt --check src/ build.zig
./scripts/check-public-surface.sh
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
sh scripts/test-setup.sh
```

- [ ] **Step 2: Exercise the freshly built binary**

```bash
./zig-out/bin/fx --version
./zig-out/bin/fx --help
./zig-out/bin/fx upgrade --channel dev
```

Expected: version/help exit successfully; dev upgrade exits with the explicit fxXL unsupported message and never contacts the network.

- [ ] **Step 3: Audit origins and patch surface**

```bash
rg -n 'releases\.fx\.sh|blob\.vercel-storage\.com' setup.sh README.md src/core/upgrade .github/workflows/release.yml
git diff --stat upstream/main...HEAD
git log --oneline upstream/main..HEAD
```

Expected: no upstream distribution origin and a small, legible patch stack.

- [ ] **Step 4: Rehearse the next upstream rebase**

Clone the branch into a temporary directory, fetch current upstream, and run
`git rebase upstream/main`. Record whether conflicts occur; do not alter the
verified working branch during rehearsal.

- [ ] **Step 5: Push and require exact-commit CI**

Push `maintenance/fork-distribution`, inspect GitHub Actions for that SHA, and
repair any fork-specific workflow failures. Do not create the stable version tag
manually; the release workflow owns it.

- [ ] **Step 6: Publish and smoke-test the first fxXL release**

After CI passes, merge the approved patch stack, allow the release workflow to
publish, then install into a temporary directory with the canonical `setup.sh`
and confirm the downloaded binary reports successfully. Publication is not
complete until this exact release smoke test passes.
