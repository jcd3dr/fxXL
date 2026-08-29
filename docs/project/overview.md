# Project Overview

## Identity and purpose

fxXL is the `jcd3dr/fxXL` downstream distribution of
[`vercel-labs/fx`](https://github.com/vercel-labs/fx). It preserves fx as the
technical base while owning a small downstream patch stack for generic
OpenAI-compatible inference, fork-controlled installation, and fork-controlled
updates.

The project serves users who want the fx CLI with either hosted third-party
OpenAI-compatible endpoints or local loopback endpoints such as Ollama, while
receiving binaries and updates from fxXL rather than upstream distribution
infrastructure.

## Scope

fxXL currently owns these downstream concerns:

* A vendor-neutral OpenAI-compatible provider.
* HTTPS access to external compatible endpoints and plain HTTP access limited
  to loopback endpoints.
* Linux x86_64 and Linux aarch64 release artifacts.
* One-command Linux installation, including use from Windows 11 through WSL.
* Stable updates sourced from GitHub Releases in `jcd3dr/fxXL`.
* A reviewed upstream base plus explicit downstream patches.

Shared fx capabilities, such as the Zig agent core, terminal UI, tools, MCP,
skills, sessions, permissions, ACP, and other providers, remain primarily
upstream-owned unless a downstream patch explicitly changes them.

## Authority

`vercel-labs/fx` is authoritative for the upstream technical base.
`jcd3dr/fxXL` is authoritative for fxXL source, downstream requirements,
installation artifacts, releases, and update origins. `UPSTREAM_BASE` records
the selected upstream commit on which the downstream patch stack is based.

The detailed downstream contract is in
[`../requirements/fork-contract.md`](../requirements/fork-contract.md). The
current repository baseline and unresolved obligations are in
[`../state/current.md`](../state/current.md).

## Terminology

* **Upstream:** `vercel-labs/fx`, the technical base project.
* **Origin:** `jcd3dr/fxXL`, the downstream distribution repository.
* **Downstream patch:** an fxXL-owned change applied over the recorded upstream
  base.
* **Compatible endpoint:** an explicitly configured service exposing the
  OpenAI-compatible model catalog and chat completions routes expected by fxXL.
* **Release version:** the fxXL version stored in `FXXL_VERSION`, independent
  from the upstream application version.
