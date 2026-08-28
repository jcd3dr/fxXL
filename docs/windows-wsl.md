# Windows 11 and WSL

fxXL uses its normal Linux build inside WSL. There is no separate WSL package,
installer, update channel, or fork of the runtime.

## Install

Open your Linux distribution in WSL and run:

```bash
curl -fsSL https://raw.githubusercontent.com/jcd3dr/fxXL/main/setup.sh | bash
```

The installer detects the Linux architecture, verifies the fxXL release
checksum, validates the downloaded binary, and installs it at
`~/.local/bin/fx`. It does not use `sudo`.

If `~/.local/bin` is not already on `PATH`, add this to the shell profile inside
WSL, then open a new shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Confirm the installation:

```bash
fx --version
```

## Local OpenAI-compatible inference

For Ollama or another OpenAI-compatible server running inside the same WSL
distribution, loopback HTTP is supported:

```bash
export FX_COMPAT_BASE_URL=http://127.0.0.1:11434/v1
export FX_COMPAT_API_KEY=ollama
fx login compat
fx
```

The API key must be non-empty even when the local server ignores it.

If the model server runs on the Windows host instead of inside WSL, prefer a
Windows/WSL networking mode in which that service is reachable as
`localhost`. fxXL intentionally permits unencrypted HTTP only for loopback
addresses. It does not send credentials over plain HTTP to a Windows host IP,
LAN address, or arbitrary remote server. If localhost forwarding is not
available, run the provider inside WSL or place an HTTPS proxy in front of it.

## Update

The installed binary checks only the latest GitHub Release published by
`jcd3dr/fxXL`:

```bash
fx upgrade
```

Re-running the installer is also safe. A new binary replaces the previous one
only after the manifest, checksum, extraction, and executable validation all
succeed.
